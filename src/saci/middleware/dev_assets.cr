require "../assets"

module Saci
  module Middleware
    # Serves asset sources (`src/assets/`) under `/assets/*` in development
    # and test, so `asset_path("application.css")` (`/assets/application.css`
    # without a manifest) works without copying sources into `public/`.
    # Responses are `Cache-Control: no-cache`: the browser revalidates with
    # `ETag` / `Last-Modified` on every load and picks up edits at once.
    #
    # Production serves the fingerprinted copies `saci assets:precompile`
    # writes to `public/assets/` through `Static` instead.
    #
    # ```
    # Saci.configure do |config|
    #   config.assets.source = "app/assets" # default "src/assets"
    #   config.assets.enabled = true        # nil (default): development/test only
    # end
    # ```
    #
    # Misses fall through, so files under `public/assets/` still work.
    class DevAssets
      include HTTP::Handler
      include Conditional

      class Settings
        # nil = development and test only.
        property enabled : Bool? = nil
        property source : String = "src/assets"
        property prefix : String = Saci::Assets::DEFAULT_PREFIX

        def initialize
        end

        def active? : Bool
          on = enabled
          on = Saci.development? || Saci.test? if on.nil?
          on && Dir.exists?(source)
        end
      end

      @static : Static? = nil

      def initialize(@config : Configuration)
      end

      def settings : Settings
        @config.assets
      end

      def enabled? : Bool
        settings.active?
      end

      def call(context : HTTP::Server::Context) : Nil
        request = context.request
        return call_next(context) unless request.method.in?("GET", "HEAD")
        prefix = settings.prefix.rstrip('/')
        path = request.path || "/"
        return call_next(context) unless path.starts_with?(prefix + "/")
        return call_next(context) unless settings.active?
        call_next(context) unless static_for(settings.source).try_serve(context, path[prefix.size..])
      end

      private def static_for(source : String) : Static
        if (existing = @static) && existing.settings.root == source
          return existing
        end
        static = Static.new(source, cache_control: "no-cache")
        static.settings.digest_cache_control = nil
        static.settings.index_files = [] of String
        @static = static
      end
    end
  end
end
