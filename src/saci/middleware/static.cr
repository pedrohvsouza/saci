require "mime"
require "uri"

module Saci
  module Middleware
    # Serves files from a public root (Rails `ActionDispatch::Static`).
    #
    # ```
    # Saci.configure do |config|
    #   config.public_file_server.enabled = true
    #   config.public_file_server.root = "public"
    #   config.public_file_server.cache_control = "public, max-age=86400"
    #   config.public_file_server.headers["X-Content-Type-Options"] = "nosniff"
    # end
    # ```
    #
    # Safety properties:
    # * only `GET`/`HEAD` are considered; everything else falls through;
    # * percent-encoded paths are decoded up to three times and rejected if a
    #   `..` segment, a backslash, a NUL byte or a dotfile appears;
    # * the resolved file is checked against the expanded public root, including
    #   symlink resolution, so a symlink cannot escape it;
    # * missing files fall through to the router (which renders its 404);
    #   traversal/dotfile attempts return `404` directly and never touch disk
    #   outside the root.
    #
    # Responses carry `ETag`, `Last-Modified`, `Cache-Control` (when configured)
    # and answer `If-None-Match` / `If-Modified-Since` with `304 Not Modified`.
    #
    # Unless `cache_control` is set explicitly, development and test send
    # `no-cache` (the browser revalidates every time, which the validators
    # above make cheap, so edits show up on reload) and other environments
    # `public, max-age=3600`. Fingerprinted files (`app-<sha256>.css`, as
    # written by `saci assets:precompile`) never change, so they get
    # `digest_cache_control` (`public, max-age=31536000, immutable`).
    class Static
      include HTTP::Handler
      include Conditional

      class Settings
        property enabled : Bool = true
        property root : String = "public"
        property headers : Hash(String, String) = {} of String => String
        # For files whose name carries a SHA-256 digest; nil falls back to
        # `cache_control`.
        property digest_cache_control : String? = "public, max-age=31536000, immutable"
        property index_files : Array(String) = ["index.html"]
        # How long the root's existence and its top-level entries are
        # remembered. Requests whose first path segment is not one of those
        # entries (e.g. `/api/...`) skip the filesystem entirely instead of
        # paying several stat calls each. Zero re-reads on every request.
        property entry_cache_ttl : Time::Span = 1.second

        @cache_control : String? = nil
        @cache_control_set = false

        def initialize
        end

        # Explicit value, or the per-environment default (see class docs).
        # nil sends no `Cache-Control` header.
        def cache_control : String?
          return @cache_control if @cache_control_set
          Saci.development? || Saci.test? ? "no-cache" : "public, max-age=3600"
        end

        def cache_control=(value : String?) : String?
          @cache_control_set = true
          @cache_control = value
        end
      end

      DIGEST_FILENAME = /-[0-9a-f]{64}(\.[^\/]+)?\z/

      # True for `name-<64 hex>.ext` (a `Saci::Assets` fingerprint).
      def self.digested?(path : String | Path) : Bool
        File.basename(path.to_s).matches?(DIGEST_FILENAME)
      end

      @entries : Set(String)? = nil
      @entries_at : Time::Instant? = nil
      @entries_root : String? = nil
      @entries_mutex = Mutex.new

      def initialize(@config : Configuration)
        @settings = nil
      end

      def initialize(root : String, cache_control : String? = "public, max-age=3600")
        @config = nil
        @settings = Settings.new
        @settings.not_nil!.root = root
        @settings.not_nil!.cache_control = cache_control
      end

      def settings : Settings
        @settings || @config.not_nil!.public_file_server
      end

      def enabled? : Bool
        settings.enabled && !top_level_entries.nil?
      end

      # Names directly under the root (nil when the root does not exist),
      # cached for `entry_cache_ttl`.
      private def top_level_entries : Set(String)?
        root = settings.root
        ttl = settings.entry_cache_ttl
        now = Time.instant
        @entries_mutex.synchronize do
          if ttl > Time::Span.zero && @entries_root == root && (at = @entries_at) && now - at < ttl
            return @entries
          end
          entries = Dir.exists?(root) ? Dir.children(root).to_set : nil
          @entries, @entries_at, @entries_root = entries, now, root
          entries
        end
      rescue File::Error
        nil
      end

      def call(context : HTTP::Server::Context) : Nil
        return call_next(context) unless settings.enabled
        request = context.request
        return call_next(context) unless request.method.in?("GET", "HEAD")
        return call_next(context) unless entries = top_level_entries
        call_next(context) unless try_serve(context, request.path || "/", entries)
      end

      # Serves *raw_path* (URL path, still percent-encoded) relative to the
      # root. Returns false when no file matches (the caller falls through);
      # true when it responded, including the `404` for unsafe paths.
      # `entries` (the root's top-level names) short-circuits misses; nil
      # skips that check.
      def try_serve(context : HTTP::Server::Context, raw_path : String, entries : Set(String)? = nil) : Bool
        decoded = decode_path(raw_path)
        if decoded.nil? || unsafe_path?(decoded)
          Middleware.respond_text(context.response, 404, "Not Found")
          return true
        end

        segments = decoded.split('/').reject { |segment| segment.empty? || segment == "." }
        if known = entries
          if first = segments.first?
            return false unless known.includes?(first)
          else
            return false unless settings.index_files.any? { |name| known.includes?(name) }
          end
        end
        root = Path.new(settings.root).expand
        file = root
        segments.each { |segment| file = file.join(segment) }

        file = directory_index(file)
        return false unless file

        info = File.info?(file)
        return false unless info && info.file?
        return false unless within_root?(root, file)

        serve(context, file, info)
        true
      end

      private def serve(context : HTTP::Server::Context, file : Path, info : File::Info) : Nil
        response = context.response
        etag = %(W/"#{info.modification_time.to_unix}-#{info.size}")
        last_modified = info.modification_time

        response.headers["ETag"] = etag
        response.headers["Last-Modified"] = HTTP.format_time(last_modified)
        cache_control = Static.digested?(file) ? (settings.digest_cache_control || settings.cache_control) : settings.cache_control
        if cache_control
          response.headers["Cache-Control"] = cache_control
        end

        if not_modified?(context.request, etag, last_modified)
          response.status_code = 304
          apply_custom_headers(response)
          return
        end

        response.status_code = 200
        response.headers["Content-Type"] = MIME.from_filename(file.to_s, "application/octet-stream")
        response.headers["Content-Length"] = info.size.to_s
        apply_custom_headers(response)

        return if context.request.method == "HEAD"

        begin
          File.open(file) do |io|
            IO.copy(io, response)
          end
        rescue File::Error
          # The file disappeared between stat and open. Fall back to a plain
          # 404; headers may already be committed, but the status is the useful
          # signal for clients and logs.
          response.status_code = 404
        end
      end

      private def apply_custom_headers(response : HTTP::Server::Response) : Nil
        settings.headers.each do |name, value|
          response.headers[name] = value
        end
      end

      private def not_modified?(request : HTTP::Request, etag : String, last_modified : Time) : Bool
        if if_none_match = request.headers["If-None-Match"]?
          return if_none_match.split(',').any? do |candidate|
            candidate = candidate.strip
            candidate == "*" || candidate == etag ||
              candidate.lchop("W/") == etag.lchop("W/")
          end
        end

        if if_modified_since = request.headers["If-Modified-Since"]?
          if time = HTTP.parse_time(if_modified_since)
            return last_modified <= time + 1.second
          end
        end
        false
      end

      private def directory_index(path : Path) : Path?
        return path unless File.directory?(path)
        settings.index_files.each do |name|
          candidate = path.join(name)
          return candidate if File.file?(candidate)
        end
        nil
      end

      private def within_root?(root : Path, file : Path) : Bool
        real_root = File.realpath(root.to_s)
        real_file = File.realpath(file.to_s)
        real_file == real_root || real_file.starts_with?(real_root + "/")
      rescue File::Error
        false
      end

      private def decode_path(path : String) : String?
        Static.decode_path(path)
      end

      private def unsafe_path?(path : String) : Bool
        Static.unsafe_path?(path)
      end

      # Decode until stable (bounded) so `%252e%252e` cannot slip through.
      def self.decode_path(path : String) : String?
        decoded = path
        3.times do
          next_value = URI.decode(decoded)
          break if next_value == decoded
          decoded = next_value
        end
        decoded
      rescue
        nil
      end

      # Traversal (`..`), dotfiles, backslashes and NUL bytes.
      def self.unsafe_path?(path : String) : Bool
        return true if path.includes?('\0') || path.includes?('\\')
        path.split('/').any? do |segment|
          segment == ".." || segment.starts_with?(".")
        end
      end
    end
  end
end
