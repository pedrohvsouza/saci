module Saci
  module Middleware
    # Built-in liveness endpoint (`GET /up` by default, Rails 8's generated
    # route). It answers before the router and therefore works for apps with no
    # `/up` route.
    #
    # ```
    # Saci.configure do |config|
    #   config.healthcheck_path = "/health" # nil disables the endpoint
    #   config.silence_healthcheck_path = true
    # end
    # ```
    #
    # `silence_healthcheck_path` suppresses the optional info log; the endpoint
    # never runs the router's request log because it short-circuits.
    class HealthCheck
      include HTTP::Handler
      include Conditional

      def initialize(@config : Configuration)
        @path = nil
        @silence = nil
      end

      def initialize(path : String? = "/up", silence : Bool = true)
        @config = nil
        @path = path
        @silence = silence
      end

      def enabled? : Bool
        !path.nil?
      end

      def path : String?
        if config = @config
          config.healthcheck_path
        else
          @path
        end
      end

      def silence? : Bool
        if config = @config
          config.silence_healthcheck_path
        else
          @silence.nil? ? true : @silence.not_nil!
        end
      end

      def call(context : HTTP::Server::Context) : Nil
        configured_path = path
        return call_next(context) unless configured_path
        request = context.request
        return call_next(context) unless request.method.in?("GET", "HEAD")
        return call_next(context) unless request.path == configured_path

        unless silence?
          Saci.logger.info { "Health check: #{request.method} #{configured_path}" }
        end

        response = context.response
        response.status_code = 200
        response.content_type = "text/plain; charset=utf-8"
        response.headers["Cache-Control"] = "no-store"
        response.headers["Content-Length"] = "2"
        response.print("OK") unless request.method == "HEAD"
      end
    end
  end
end
