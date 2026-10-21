module Saci
  module Middleware
    # CORS (Cross-Origin Resource Sharing) middleware.
    #
    # ```
    # Saci.configure do |config|
    #   config.cors do |cors|
    #     cors.allowed_origins = ["https://app.example.com", "https://*.example.org"]
    #     cors.allowed_methods = ["GET", "POST", "PATCH", "DELETE"]
    #     cors.allowed_headers = ["Content-Type", "Authorization"]
    #     cors.exposed_headers = ["X-Request-Id"]
    #     cors.credentials = true
    #     cors.max_age = 600
    #   end
    # end
    # ```
    #
    # Origin entries are matched case-insensitively. `*` allows every origin;
    # a `*` inside an entry matches any characters except `/`, so
    # `https://*.example.com` matches subdomains (but not the apex). Ports are
    # part of the origin string, so include them when needed.
    #
    # Actual requests from disallowed origins pass through without CORS
    # headers. Preflight (`OPTIONS` + `Access-Control-Request-Method`) from a
    # disallowed origin is rejected with `403`; allowed preflights short-circuit
    # with `204 No Content`.
    class CORS
      include HTTP::Handler
      include Conditional

      class Settings
        property allowed_origins : Array(String) = [] of String
        property allowed_methods : Array(String) = ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"]
        property allowed_headers : Array(String) = ["*"]
        property exposed_headers : Array(String) = [] of String
        property credentials : Bool = false
        property max_age : Int32? = nil

        def initialize
        end

        def enabled? : Bool
          !@allowed_origins.empty?
        end

        def allow_origins(*origins : String) : self
          @allowed_origins = origins.to_a
          self
        end

        def allow_methods(*methods : String) : self
          @allowed_methods = methods.to_a
          self
        end

        def allow_headers(*headers : String) : self
          @allowed_headers = headers.to_a
          self
        end

        def expose_headers(*headers : String) : self
          @exposed_headers = headers.to_a
          self
        end

        def allowed_origin?(origin : String) : Bool
          @allowed_origins.any? { |pattern| CORS.origin_matches?(pattern, origin) }
        end

        def allowed_method?(method : String) : Bool
          @allowed_methods.any? { |entry| entry == "*" || entry.downcase == method.downcase }
        end

        def allowed_headers?(requested : String) : Bool
          return true if @allowed_headers.any? { |entry| entry == "*" }
          requested.split(',').all? do |header|
            name = header.strip
            name.empty? || @allowed_headers.any? { |entry| entry.downcase == name.downcase }
          end
        end

        def allow_origin_header(origin : String) : String
          if !@credentials && @allowed_origins.includes?("*")
            "*"
          else
            origin
          end
        end
      end

      def self.origin_matches?(pattern : String, origin : String) : Bool
        pattern = pattern.strip
        origin = origin.strip
        return false if pattern.empty? || origin.empty?
        return true if pattern == "*"

        pattern_down = pattern.downcase
        origin_down = origin.downcase
        return true if pattern_down == origin_down
        return false unless pattern_down.includes?('*')

        parts = pattern_down.split('*')
        regex = Regex.new("\\A" + parts.map { |part| Regex.escape(part) }.join("[^/]+") + "\\z")
        regex.matches?(origin_down)
      end

      def initialize(@config : Configuration)
        @settings = nil
      end

      # Convenience constructor for apps that do not need the configuration
      # object; `Saci.config.cors` is the normal entry point.
      def initialize(allowed_origins : Array(String))
        @config = nil
        @settings = Settings.new
        @settings.not_nil!.allowed_origins = allowed_origins
      end

      def settings : Settings
        @settings || @config.not_nil!.cors
      end

      def enabled? : Bool
        settings.enabled?
      end

      def call(context : HTTP::Server::Context) : Nil
        return call_next(context) unless enabled?

        request = context.request
        response = context.response
        origin = request.headers["Origin"]?
        return call_next(context) if origin.nil? || origin.empty?

        if preflight?(request)
          unless settings.allowed_origin?(origin)
            Middleware.vary(response, "Origin")
            Middleware.respond_text(response, 403, "CORS origin denied")
            return
          end

          requested_method = request.headers["Access-Control-Request-Method"]?
          if requested_method && !settings.allowed_method?(requested_method)
            Middleware.respond_text(response, 403, "CORS method denied")
            return
          end

          requested_headers = request.headers["Access-Control-Request-Headers"]?
          if requested_headers && !settings.allowed_headers?(requested_headers)
            Middleware.respond_text(response, 403, "CORS headers denied")
            return
          end

          apply_origin(response, origin)
          response.headers["Access-Control-Allow-Methods"] = settings.allowed_methods.join(", ")
          if requested_headers
            response.headers["Access-Control-Allow-Headers"] = requested_headers
          elsif !settings.allowed_headers.empty?
            response.headers["Access-Control-Allow-Headers"] = settings.allowed_headers.join(", ")
          end
          if max_age = settings.max_age
            response.headers["Access-Control-Max-Age"] = max_age.to_s
          end
          Middleware.vary(response, "Origin")
          Middleware.vary(response, "Access-Control-Request-Method")
          Middleware.vary(response, "Access-Control-Request-Headers")
          response.status_code = 204
          response.headers["Content-Length"] = "0"
          return
        end

        unless settings.allowed_origin?(origin)
          Middleware.vary(response, "Origin")
          return call_next(context)
        end

        apply_origin(response, origin)
        unless settings.exposed_headers.empty?
          response.headers["Access-Control-Expose-Headers"] = settings.exposed_headers.join(", ")
        end
        Middleware.vary(response, "Origin")
        call_next(context)
      end

      private def preflight?(request : HTTP::Request) : Bool
        request.method == "OPTIONS" && request.headers.has_key?("Access-Control-Request-Method")
      end

      private def apply_origin(response : HTTP::Server::Response, origin : String) : Nil
        response.headers["Access-Control-Allow-Origin"] = settings.allow_origin_header(origin)
        if settings.credentials
          response.headers["Access-Control-Allow-Credentials"] = "true"
        end
      end
    end
  end
end
