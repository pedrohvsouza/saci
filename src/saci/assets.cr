require "digest/sha256"
require "file_utils"
require "json"

module Saci
  # Minimal asset pipeline (Propshaft/Sprockets equivalent).
  #
  # Sources live in `src/assets/`. In development there is no manifest:
  # `asset_path("app.css")` falls back to the logical URL `/assets/app.css`
  # (documented fallback — a missing asset never raises, so templates keep
  # rendering), which `Middleware::DevAssets` serves straight from
  # `src/assets/`. For production, `saci assets:precompile` (also run by
  # the generated Dockerfile) copies them into `public/assets/` (build
  # output, gitignored) under fingerprinted names plus a manifest;
  # `saci assets:clobber` removes that output again. The underlying call:
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
    # `precompile` wraps it for `saci assets:precompile`; it is plain
    # Crystal (no external shard).
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

    DEFAULT_SOURCE = "src/assets"
    DEFAULT_OUTPUT = "public/assets"

    # `saci assets:precompile`: rebuilds *output* from *source*. Every file
    # is written under its fingerprinted name (served by `Static` with
    # `immutable` caching) and under its plain name (for references such
    # as a CSS `url(font.woff2)` that cannot know the digest), next to the
    # manifest. Previous output is clobbered first, so removed sources do
    # not linger.
    def self.precompile(source : String = DEFAULT_SOURCE, output : String = DEFAULT_OUTPUT) : Hash(String, String)
      source_dir = File.expand_path(source)
      output_dir = File.expand_path(output)
      raise ArgumentError.new("assets source directory does not exist: #{source}") unless Dir.exists?(source_dir)
      if source_dir == output_dir || output_dir.starts_with?(source_dir + "/") || source_dir.starts_with?(output_dir + "/")
        raise ArgumentError.new("assets source (#{source}) and output (#{output}) must be separate directories")
      end
      clobber(output, source)
      manifest = build_manifest(source, output)
      manifest.each_key do |logical|
        dest = File.join(output, logical)
        Dir.mkdir_p(File.dirname(dest))
        File.copy(File.join(source, logical), dest)
      end
      manifest
    end

    # `saci assets:clobber`: deletes what `precompile` wrote to *output* —
    # the manifest, the fingerprinted files it lists and the plain copies of
    # files that exist in *source* — and prunes emptied directories. Files
    # it did not produce are left alone, so pointing it at a directory of
    # hand-written assets is harmless. Returns the number of files removed.
    def self.clobber(output : String = DEFAULT_OUTPUT, source : String = DEFAULT_SOURCE) : Int32
      removed = 0
      MANIFEST_NAMES.each do |name|
        path = File.join(output, name)
        next unless File.file?(path)
        entries = begin
          parse_manifest(path)
        rescue ArgumentError
          {} of String => String
        end
        separate = File.expand_path(output) != File.expand_path(source)
        entries.each do |logical, hashed|
          digested = File.join(output, hashed.lchop("/").lchop("assets/"))
          if File.file?(digested)
            File.delete(digested)
            removed += 1
          end
          plain = File.join(output, logical)
          if separate && File.file?(plain) && File.file?(File.join(source, logical))
            File.delete(plain)
            removed += 1
          end
        end
        File.delete(path)
        removed += 1
      end
      prune_empty_dirs(output)
      reset!
      @@mutex.synchronize { @@manifest_path = nil }
      removed
    end

    private def self.prune_empty_dirs(dir : String) : Nil
      return unless Dir.exists?(dir)
      Dir.children(dir).each do |child|
        path = File.join(dir, child)
        prune_empty_dirs(path) if File.directory?(path) && !File.symlink?(path)
      end
      Dir.delete(dir) if Dir.empty?(dir)
    rescue File::Error
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
