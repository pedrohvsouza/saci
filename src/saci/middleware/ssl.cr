module Saci
  module Middleware
    # TLS-related request normalisation and response headers.
    #
    # This middleware does not terminate TLS and does not redirect — the
    # existing `Saci.force_ssl` redirect stays in `Router#call`. It:
    # * implements `config.assume_ssl` by treating requests as HTTPS (useful
    #   behind a proxy that terminates TLS but does not forward
    #   `X-Forwarded-Proto`);
    # * adds `Strict-Transport-Security` on secure responses when `force_ssl`
    #   or `assume_ssl` is enabled and `config.ssl_options.hsts` is true.
    #
    # `ssl_options.secure_cookies` is exposed for apps that build cookie
    # options; Saci's session/cookie code owns the actual `Secure` flag.
    class SSL
      include HTTP::Handler
      include Conditional

      class Settings
        property hsts : Bool = true
        property hsts_max_age : Int32 = 31_536_000
        property hsts_include_subdomains : Bool = true
        property hsts_preload : Bool = false
        property secure_cookies : Bool = true

        def initialize
        end
      end

      def initialize(@config : Configuration)
      end

      def enabled? : Bool
        @config.force_ssl || @config.assume_ssl
      end

      def call(context : HTTP::Server::Context) : Nil
        request = context.request
        secure = secure_request?(request)
        if @config.assume_ssl && !secure
          request.headers["X-Forwarded-Proto"] = "https"
          secure = true
        end

        if secure
          settings = @config.ssl_options
          if settings.hsts && !context.response.headers.has_key?("Strict-Transport-Security")
            value = "max-age=#{settings.hsts_max_age}"
            value += "; includeSubDomains" if settings.hsts_include_subdomains
            value += "; preload" if settings.hsts_preload
            context.response.headers["Strict-Transport-Security"] = value
          end
        end

        call_next(context)
      end

      private def secure_request?(request : HTTP::Request) : Bool
        request.headers["X-Forwarded-Proto"]?.try(&.downcase) == "https"
      end
    end
  end
end
