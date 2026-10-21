require "json"
require "html"

module Saci
  # Progressive Web App helpers (G219): a `manifest.json` model/serializer,
  # a versioned cache-first service-worker template, and head tags.
  #
  # ```
  # # app entrypoint / initializer
  # Saci::PWA.write_manifest("public/manifest.json", name: "My App")
  # Saci::PWA.write_service_worker("public/service-worker.js", version: "v1")
  #
  # # layout head
  # <%= pwa_tags(theme_color: "#0f172a") %>
  # ```
  #
  # The service worker is cache-first for same-origin GETs, removes old
  # `saci-pwa-*` caches on activate, and serves the offline URL for failed
  # navigation requests. It is deliberately dependency-free; there is no
  # Workbox/npm integration.
  module PWA
    SW_TEMPLATE = {{ read_file("#{__DIR__}/assets/service_worker.js") }}

    class Icon
      include JSON::Serializable

      property src : String
      property sizes : String
      property type : String
      @[JSON::Field(emit_null: false)]
      property purpose : String?

      def initialize(@src : String, @sizes : String, @type : String = "image/png", @purpose : String? = nil)
      end
    end

    class Manifest
      include JSON::Serializable

      property name : String
      property short_name : String
      property start_url : String
      property scope : String
      property display : String
      property orientation : String
      property background_color : String
      property theme_color : String
      @[JSON::Field(emit_null: false)]
      property description : String?
      property lang : String
      property icons : Array(Icon)

      def initialize(@name : String,
                     short_name : String? = nil,
                     @start_url : String = "/",
                     @scope : String = "/",
                     @display : String = "standalone",
                     @orientation : String = "portrait",
                     @background_color : String = "#ffffff",
                     @theme_color : String = "#000000",
                     @description : String? = nil,
                     @lang : String = "en",
                     icons : Array(Icon)? = nil)
        @short_name = short_name || @name
        @icons = icons || self.class.default_icons
      end

      def self.default_icons : Array(Icon)
        [
          Icon.new("/icon-192.png", "192x192", "image/png", "any"),
          Icon.new("/icon-512.png", "512x512", "image/png", "any"),
        ]
      end
    end

    # Builds a manifest object (defaults: standalone display, `/` start URL,
    # two placeholder icons).
    def self.manifest(name : String,
                      short_name : String? = nil,
                      start_url : String = "/",
                      scope : String = "/",
                      display : String = "standalone",
                      orientation : String = "portrait",
                      background_color : String = "#ffffff",
                      theme_color : String = "#000000",
                      description : String? = nil,
                      lang : String = "en",
                      icons : Array(Icon)? = nil) : Manifest
      Manifest.new(
        name,
        short_name: short_name,
        start_url: start_url,
        scope: scope,
        display: display,
        orientation: orientation,
        background_color: background_color,
        theme_color: theme_color,
        description: description,
        lang: lang,
        icons: icons
      )
    end

    def self.manifest_json(name : String,
                           short_name : String? = nil,
                           start_url : String = "/",
                           scope : String = "/",
                           display : String = "standalone",
                           orientation : String = "portrait",
                           background_color : String = "#ffffff",
                           theme_color : String = "#000000",
                           description : String? = nil,
                           lang : String = "en",
                           icons : Array(Icon)? = nil) : String
      manifest(
        name,
        short_name: short_name,
        start_url: start_url,
        scope: scope,
        display: display,
        orientation: orientation,
        background_color: background_color,
        theme_color: theme_color,
        description: description,
        lang: lang,
        icons: icons
      ).to_json
    end

    # Writes a manifest file and returns its path.
    def self.write_manifest(path : String = "public/manifest.json", **options) : String
      write_file(path, manifest_json(**options))
    end

    # Cache-first service worker with a versioned cache and offline fallback.
    def self.service_worker_source(version : String = "v1",
                                   cache_name : String? = nil,
                                   offline_url : String = "/offline.html",
                                   precache : Array(String) = ["/", "/manifest.json", "/offline.html"]) : String
      version = version.strip
      version = "v1" if version.empty?
      cache = cache_name || "saci-pwa-#{version}"
      SW_TEMPLATE
        .gsub("__SACI_VERSION__") { js_string_content(version) }
        .gsub("__SACI_CACHE__") { js_string_content(cache) }
        .gsub("__SACI_PRECACHE__") { precache.to_json }
        .gsub("__SACI_OFFLINE_URL__") { js_string_content(offline_url) }
    end

    def self.write_service_worker(path : String = "public/service-worker.js", **options) : String
      write_file(path, service_worker_source(**options))
    end

    # `<link rel="manifest">`, optional theme-color/apple-touch-icon, and the
    # service-worker registration script. Pass `service_worker: nil` (or
    # `register: false`) to omit registration.
    def self.pwa_tags(manifest_path : String = "/manifest.json",
                      service_worker : String? = "/service-worker.js",
                      theme_color : String? = nil,
                      icon : String? = nil,
                      scope : String = "/",
                      register : Bool = true) : String
      String.build do |io|
        io << %(<link rel="manifest" href=") << HTML.escape(manifest_path) << %(">)
        if color = theme_color
          io << %(\n<meta name="theme-color" content=") << HTML.escape(color) << %(">)
        end
        if apple_icon = icon
          io << %(\n<link rel="apple-touch-icon" href=") << HTML.escape(apple_icon) << %(">)
        end
        if register && (worker = service_worker)
          io << "\n<script>\n"
          io << "if (\"serviceWorker\" in navigator) {\n"
          io << "  window.addEventListener(\"load\", function () {\n"
          io << "    navigator.serviceWorker.register(" << script_json(worker)
          io << ", { scope: " << script_json(scope) << " }).catch(function () {});\n"
          io << "  });\n}\n"
          io << "</script>"
        end
      end
    end

    def self.manifest_tag(manifest_path : String = "/manifest.json", theme_color : String? = nil) : String
      String.build do |io|
        io << %(<link rel="manifest" href=") << HTML.escape(manifest_path) << %(">)
        if color = theme_color
          io << %(\n<meta name="theme-color" content=") << HTML.escape(color) << %(">)
        end
      end
    end

    private def self.write_file(path : String, content : String) : String
      dir = File.dirname(path)
      Dir.mkdir_p(dir) unless dir == "." || dir.empty?
      File.write(path, content)
      path
    end

    private def self.js_string_content(value : String) : String
      value.to_json[1...-1]
    end

    private def self.script_json(value : String) : String
      value.to_json.gsub("</", "<\\/").gsub("<!--", "<\\u0021--")
    end
  end
end
