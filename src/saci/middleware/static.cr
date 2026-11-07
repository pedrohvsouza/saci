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
    class Static
      include HTTP::Handler
      include Conditional

      class Settings
        property enabled : Bool = true
        property root : String = "public"
        property headers : Hash(String, String) = {} of String => String
        property cache_control : String? = "public, max-age=3600"
        property index_files : Array(String) = ["index.html"]
        # How long the root's existence and its top-level entries are
        # remembered. Requests whose first path segment is not one of those
        # entries (e.g. `/api/...`) skip the filesystem entirely instead of
        # paying several stat calls each. Zero re-reads on every request.
        property entry_cache_ttl : Time::Span = 1.second

        def initialize
        end
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

        response = context.response
        raw_path = request.path || "/"
        decoded = decode_path(raw_path)
        if decoded.nil? || unsafe_path?(decoded)
          Middleware.respond_text(response, 404, "Not Found")
          return
        end

        segments = decoded.split('/').reject { |segment| segment.empty? || segment == "." }
        if first = segments.first?
          return call_next(context) unless entries.includes?(first)
        else
          return call_next(context) unless settings.index_files.any? { |name| entries.includes?(name) }
        end
        root = Path.new(settings.root).expand
        file = root
        segments.each { |segment| file = file.join(segment) }

        file = directory_index(file)
        return call_next(context) unless file

        info = File.info?(file)
        return call_next(context) unless info && info.file?
        return call_next(context) unless within_root?(root, file)

        serve(context, file, info)
      end

      private def serve(context : HTTP::Server::Context, file : Path, info : File::Info) : Nil
        response = context.response
        etag = %(W/"#{info.modification_time.to_unix}-#{info.size}")
        last_modified = info.modification_time

        response.headers["ETag"] = etag
        response.headers["Last-Modified"] = HTTP.format_time(last_modified)
        if cache_control = settings.cache_control
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

      # Decode until stable (bounded) so `%252e%252e` cannot slip through.
      private def decode_path(path : String) : String?
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

      private def unsafe_path?(path : String) : Bool
        return true if path.includes?('\0') || path.includes?('\\')
        path.split('/').any? do |segment|
          segment == ".." || segment.starts_with?(".")
        end
      end
    end
  end
end
