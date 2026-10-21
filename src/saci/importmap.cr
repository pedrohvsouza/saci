require "json"
require "html"
require "./assets"

module Saci
  # Import maps for browser-native ES modules (Rails `importmap-rails`
  # equivalent), without npm or a bundler.
  #
  # ```
  # Saci::Importmap.draw do |map|
  #   map.pin "application", to: "app/javascript/application.js", preload: true
  #   map.pin "@hotwired/turbo", to: "vendor/javascript/turbo.js"
  #   map.pin_all_from "app/javascript/controllers", under: "controllers"
  # end
  #
  # Saci::Importmap.write("config/importmap.json")
  # # in a layout:
  # <%= importmap_tags %>
  # ```
  #
  # Pins are resolved through `Saci::Assets`, so a fingerprinted asset
  # manifest turns `app/javascript/application.js` into
  # `/assets/application-<digest>.js`. Known module roots are stripped while
  # resolving (`app/javascript`, `vendor/javascript`, `app/assets/javascripts`,
  # `app/assets/builds`, `public`); paths that do not match a root are kept
  # relative and served under `/assets/`.
  #
  # Inline JSON is escaped for a `<script>` element (`</` becomes `<\/`), so
  # pin names/paths containing `</script>` cannot break out. `pin_all_from`
  # scans `*.js` recursively at draw time; a missing directory is a no-op.
  class Importmap
    MODULE_ROOTS = [
      "app/javascript",
      "vendor/javascript",
      "app/assets/javascripts",
      "app/assets/builds",
      "public",
    ]

    # One import-map entry. `to` may be a project-relative source path, an
    # `/assets/...` URL, or an absolute/CDN URL.
    class Pin
      getter name : String
      getter to : String?
      getter preload : Bool

      def initialize(@name : String, @to : String? = nil, @preload : Bool = false)
        raise ArgumentError.new("importmap pin name cannot be empty") if @name.empty?
      end

      # The source string used when resolving this pin.
      def target : String
        @to || "#{@name}.js"
      end

      def resolved_path : String
        Importmap.resolve(self)
      end
    end

    # Mutable manifest built by the DSL. Pin names are unique: pinning the
    # same name twice replaces the earlier entry (last one wins).
    class Manifest
      getter pins : Array(Pin) = [] of Pin

      def pin(name : String, to : String? = nil, preload : Bool = false) : Pin
        @pins.reject! { |existing| existing.name == name }
        entry = Pin.new(name, to, preload)
        @pins << entry
        entry
      end

      # Pins every `.js` file under `dir` recursively. `under` prefixes the
      # logical names (`controllers/hello_controller`) and `to` optionally
      # prefixes the source path used for resolution. Returns `self` so calls
      # can be chained.
      def pin_all_from(dir : String, under : String? = nil, to : String? = nil, preload : Bool = false) : self
        stripped = dir.rstrip('/')
        relative_dir = Importmap.relative_to_root(stripped)
        root = stripped.starts_with?("/") ? stripped : File.join(Assets.root, relative_dir)
        return self unless Dir.exists?(root)

        Dir.glob(File.join(root, "**", "*.js")).sort.each do |file|
          next unless File.file?(file)
          relative = file[(root.size + 1)..]
          next if relative.empty? || relative.starts_with?(".")

          name = relative[0...-3]
          next if name.empty?
          if prefix = under.try(&.strip('/'))
            name = "#{prefix}/#{name}" unless prefix.empty?
          end

          source = if target_prefix = to.try(&.rstrip('/'))
                     target_prefix.empty? ? relative : "#{target_prefix}/#{relative}"
                   else
                     Importmap.relative_to_root(file)
                   end
          pin(name, to: source, preload: preload)
        end
        self
      end

      def empty? : Bool
        @pins.empty?
      end

      def imports : Hash(String, String)
        result = {} of String => String
        @pins.each { |entry| result[entry.name] = Importmap.resolve(entry) }
        result
      end

      def preloads : Array(Pin)
        @pins.select(&.preload)
      end

      def to_json : String
        JSON.build do |json|
          json.object do
            json.field "imports" do
              json.object do
                @pins.each do |entry|
                  json.field entry.name, Importmap.resolve(entry)
                end
              end
            end
          end
        end
      end
    end

    @@default : Manifest = Manifest.new
    @@mutex = Mutex.new

    # Process-wide manifest used by `importmap_tags` and the CLI.
    def self.default : Manifest
      @@mutex.synchronize { @@default }
    end

    def self.reset! : Manifest
      @@mutex.synchronize { @@default = Manifest.new }
    end

    # Replaces the default manifest with a freshly drawn one.
    def self.draw(& : Manifest ->) : Manifest
      manifest = Manifest.new
      yield manifest
      @@mutex.synchronize { @@default = manifest }
      manifest
    end

    def self.pin(name : String, to : String? = nil, preload : Bool = false) : Pin
      default.pin(name, to: to, preload: preload)
    end

    def self.pin_all_from(dir : String, under : String? = nil, to : String? = nil, preload : Bool = false) : Manifest
      default.pin_all_from(dir, under: under, to: to, preload: preload)
    end

    def self.to_json : String
      default.to_json
    end

    # Writes `config/importmap.json` (or the given path) and returns the path.
    # The file is standard `{"imports": {...}}` JSON with a trailing newline.
    def self.write(path : String = "config/importmap.json", manifest : Manifest = default) : String
      dir = File.dirname(path)
      Dir.mkdir_p(dir) unless dir == "." || dir.empty?
      File.write(path, "#{manifest.to_json}\n")
      path
    end

    # Resolves one pin to its public URL. Passthrough URLs and explicit
    # rooted paths are left alone unless an `/assets/...` manifest entry
    # provides a fingerprinted name.
    def self.resolve(pin : Pin) : String
      resolve_source(pin.target)
    end

    def self.resolve_source(source : String) : String
      return source if passthrough?(source)

      if source.starts_with?("/")
        key = normalize_asset_key(source)
        return Assets.asset_path(key) if key && Assets.exists?(key)
        return source
      end

      normalized = relative_to_root(source.sub(/\A\.\//, ""))
      relative = relative_key(normalized)
      [relative, normalized, File.basename(relative)].uniq.each do |candidate|
        return Assets.asset_path(candidate) if Assets.exists?(candidate)
      end

      Assets.asset_path(relative)
    end

    # `<script type="importmap">` plus optional modulepreload links. JSON is
    # escaped for inline use; preload hrefs are HTML-escaped.
    def self.importmap_tags(manifest : Manifest = default, preload : Bool = true) : String
      String.build do |io|
        io << %(<script type="importmap">)
        io << escape_json_for_script(manifest.to_json)
        io << %(</script>)
        if preload
          manifest.preloads.each do |entry|
            io << %(\n<link rel="modulepreload" href=") << HTML.escape(resolve(entry)) << %(">)
          end
        end
      end
    end

    # Prevents a JSON string from terminating the surrounding `<script>`.
    def self.escape_json_for_script(json : String) : String
      json.gsub("</", "<\\/")
        .gsub("<!--", "<\\u0021--")
        .gsub("\u2028", "\\u2028")
        .gsub("\u2029", "\\u2029")
    end

    # Absolute filesystem paths under the project root become root-relative.
    def self.relative_to_root(path : String) : String
      root = Assets.root.rstrip('/')
      return path unless path.starts_with?("#{root}/")
      path[(root.size + 1)..]
    end

    private def self.relative_key(path : String) : String
      MODULE_ROOTS.each do |root|
        prefix = "#{root}/"
        return path[prefix.size..] if path.starts_with?(prefix)
      end
      path
    end

    private def self.normalize_asset_key(path : String) : String?
      key = path.lstrip('/')
      prefix = "#{Assets::DEFAULT_PREFIX.lstrip('/')}/"
      key = key[prefix.size..] if key.starts_with?(prefix)
      key.empty? ? nil : key
    end

    private def self.passthrough?(source : String) : Bool
      source.starts_with?("http://") || source.starts_with?("https://") ||
        source.starts_with?("//") || source.starts_with?("data:") ||
        source.starts_with?("blob:")
    end
  end
end
