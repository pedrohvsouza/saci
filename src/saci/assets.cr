require "digest/sha256"
require "json"

module Saci
  # Minimal asset pipeline (Propshaft/Sprockets equivalent).
  #
  # In development there is no manifest: `asset_path("app.css")` falls back
  # to the logical URL `/assets/app.css` (documented fallback — a missing
  # asset never raises, so templates keep rendering). For production, build
  # a fingerprint manifest:
  #
  # ```
  # Saci::Assets.build_manifest("src/assets", "public/assets")
  # # writes public/assets/.manifest.json:
  # # {"app.css" => "app-<64 hex>.css", "images/logo.png" => "images/logo-<64 hex>.png"}
  #
  # Saci::Assets.configure(root: Dir.current) # or manifest_path: "..."
  # Saci::Assets.asset_path("app.css")        # => "/assets/app-<digest>.css"
  # Saci::Assets.asset_url("app.css", host: "cdn.example.com")
  # # => "http://cdn.example.com/assets/app-<digest>.css"
  # ```
  #
  # Manifest discovery (first existing wins):
  # `public/assets/.manifest.json`, `public/assets/manifest.json`,
  # `manifest.json`. Values may be plain path strings or objects with a
  # `"path"` / `"digest"` key. The manifest is reloaded automatically when
  # the file's mtime changes.
  #
  # Absolute URLs (`http://`, `https://`, `//cdn/...`) and `data:` URIs
  # pass through unchanged. Rooted paths (`/foo`) pass through unchanged
  # too; a missing logical asset gets the `/assets/` prefix.
  module Assets
    MANIFEST_NAMES = [".manifest.json", "manifest.json"]
    DEFAULT_PREFIX = "/assets"

    @@root : String = Dir.current
    @@manifest_path : String? = nil
    @@manifest : Hash(String, String)? = nil
    @@manifest_mtime : Time? = nil
    @@mutex = Mutex.new

    # Project root used for manifest discovery. Defaults to the compile-time
    # working directory (the project root, matching `render_template`).
    def self.root : String
      @@root
    end

    def self.root=(path : String) : Nil
      @@mutex.synchronize do
        @@root = path
        @@manifest = nil
        @@manifest_mtime = nil
      end
    end

    # Pins the manifest path (or resets discovery when nil). Clears the
    # cached manifest.
    def self.manifest_path=(path : String?) : Nil
      @@mutex.synchronize do
        @@manifest_path = path
        @@manifest = nil
        @@manifest_mtime = nil
      end
    end

    def self.configure(root : String = Dir.current, manifest_path : String? = nil) : Nil
      @@mutex.synchronize do
        @@root = root
        @@manifest_path = manifest_path
        @@manifest = nil
        @@manifest_mtime = nil
      end
    end

    # Clears cached manifest data (configuration is kept).
    def self.reset! : Nil
      @@mutex.synchronize do
        @@manifest = nil
        @@manifest_mtime = nil
      end
    end

    def self.manifest_path : String?
      if configured = @@manifest_path
        return configured
      end
      MANIFEST_NAMES.each do |name|
        candidate = File.join(@@root, "public", "assets", name)
        return candidate if File.file?(candidate)
      end
      fallback = File.join(@@root, "manifest.json")
      File.file?(fallback) ? fallback : nil
    end

    # Loaded manifest (logical path => fingerprinted path). Empty when no
    # manifest is configured/found. Automatically refreshes on mtime change.
    def self.manifest : Hash(String, String)
      path = manifest_path
      return {} of String => String unless path && File.file?(path)
      mtime = File.info(path).modification_time
      @@mutex.synchronize do
        if cached = @@manifest
          return cached if @@manifest_mtime == mtime
        end
        loaded = parse_manifest(path)
        @@manifest = loaded
        @@manifest_mtime = mtime
        loaded
      end
    end

    # Resolves a logical asset (`"app.css"`, `"images/logo.png"`) to its
    # public URL. `digest: false` always returns the logical path.
    def self.asset_path(source : String, digest : Bool = true) : String
      return source if passthrough?(source)
      key = normalize_key(source)
      if digest && (hashed = manifest[key]?)
        return hashed if hashed.starts_with?("/") || hashed.starts_with?("http://") || hashed.starts_with?("https://") || hashed.starts_with?("//")
        return "/#{hashed}" if hashed.starts_with?("assets/")
        return "#{DEFAULT_PREFIX}/#{hashed}"
      end
      return source if source.starts_with?("/")
      "#{DEFAULT_PREFIX}/#{key}"
    end

    # Absolute asset URL. `host` may include a scheme (`https://cdn`), in
    # which case `protocol`/`port` are ignored.
    def self.asset_url(source : String, *, host : String, protocol : String = "http", port : Int32? = nil) : String
      path = asset_path(source)
      return path if passthrough?(path)
      base = if host.starts_with?("http://") || host.starts_with?("https://") || host.starts_with?("//")
               host
             else
               "#{protocol}://#{host}"
             end
      if port_value = port
        base = "#{base}:#{port_value}" unless base.matches?(/:\d+\z/)
      end
      "#{base.rstrip('/')}#{path.starts_with?("/") ? path : "/#{path}"}"
    end

    # Fingerprinted filename for a file path (`"app.css"` ->
    # `"app-<sha256>.css"`). Files without an extension still work.
    def self.digest_name(path : String) : String
      base = File.basename(path)
      ext = File.extname(base)
      stem = ext.empty? ? base : base[0...-ext.size]
      digest = Digest::SHA256.hexdigest(File.read(path))
      "#{stem}-#{digest}#{ext}"
    end

    # Builds (and writes) a fingerprint manifest by hashing every file under
    # `source_dir` and copying it to `output_dir` under its digested name.
    # The manifest maps logical relative paths to fingerprinted paths.
    #
    # This is the API a scaffold/`saci assets:precompile` task can call;
    # it is plain Crystal (no external shard).
    def self.build_manifest(source_dir : String, output_dir : String, manifest_name : String = ".manifest.json") : Hash(String, String)
      source = source_dir.rstrip('/')
      output = output_dir.rstrip('/')
      raise ArgumentError.new("assets source directory does not exist: #{source_dir}") unless Dir.exists?(source)
      manifest = {} of String => String
      Dir.mkdir_p(output_dir)
      separate_output = output != source
      Dir.glob(File.join(source, "**", "*")) do |file|
        next unless File.file?(file)
        next if separate_output && file.starts_with?(output + "/")
        logical = file[(source.size + 1)..]
        next if logical.empty? || logical == manifest_name || logical == ".manifest.json" || logical == "manifest.json"
        next if logical.split('/').any?(&.starts_with?("."))
        ext = File.extname(logical)
        stem = ext.empty? ? logical : logical[0...-ext.size]
        digest = Digest::SHA256.hexdigest(File.read(file))
        hashed = "#{stem}-#{digest}#{ext}"
        dest = File.join(output_dir, hashed)
        Dir.mkdir_p(File.dirname(dest))
        File.copy(file, dest)
        manifest[logical] = hashed
      end
      File.write(File.join(output_dir, manifest_name), manifest.to_json)
      path = File.join(output_dir, manifest_name)
      # Make the freshly built manifest active immediately (a subsequent
      # `configure(root:)` may point discovery somewhere else).
      @@mutex.synchronize do
        @@manifest = manifest
        @@manifest_path = path
        @@manifest_mtime = File.info(path).modification_time
      end
      manifest
    end

    def self.exists?(source : String) : Bool
      manifest.has_key?(normalize_key(source))
    end

    def self.digest_path(source : String) : String?
      manifest[normalize_key(source)]?
    end

    private def self.normalize_key(source : String) : String
      key = source
      key = key.lstrip('/') if key.starts_with?("/")
      key = key[(DEFAULT_PREFIX.size + 1)..] if key.starts_with?("#{DEFAULT_PREFIX}/")
      key
    end

    private def self.passthrough?(source : String) : Bool
      source.starts_with?("http://") || source.starts_with?("https://") ||
        source.starts_with?("//") || source.starts_with?("data:") || source.starts_with?("blob:")
    end

    private def self.parse_manifest(path : String) : Hash(String, String)
      parsed = JSON.parse(File.read(path))
      result = {} of String => String
      if hash = parsed.as_h?
        hash.each do |key, value|
          if str = value.as_s?
            result[key] = str
          elsif obj = value.as_h?
            if entry = obj["path"]?.try(&.as_s?) || obj["digest"]?.try(&.as_s?)
              result[key] = entry
            end
          end
        end
      end
      result
    rescue ex : JSON::ParseException
      raise ArgumentError.new("invalid asset manifest #{path}: #{ex.message}")
    end
  end
end
