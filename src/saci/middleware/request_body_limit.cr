module Saci
  module Middleware
    # Rejects request bodies larger than `config.max_request_body` with `413`.
    #
    # Crystal's `HTTP::Server` does not expose Rack's body-size or per-request
    # timeout settings. Saci therefore enforces the limit in front of the
    # router: a `Content-Length` over the limit is rejected immediately, and a
    # body without a trustworthy length (chunked/unknown) is read once into
    # memory while counting bytes. The body is then replayed to the router, so
    # `Params` parsing is unaffected.
    #
    # `config.request_timeout` / `config.keep_alive_timeout` are exposed for
    # deployment documentation, but stdlib `HTTP::Server` 1.22 has no hooks for
    # them; set them at the proxy/container layer. `max_headers_size` and
    # `max_request_line_size` *are* applied by `Saci::Application#listen`.
    class RequestBodyLimit
      include HTTP::Handler
      include Conditional

      def initialize(@config : Configuration)
        @max_body = nil
      end

      def initialize(max_body : Int64?)
        @config = nil
        @max_body = max_body
      end

      def enabled? : Bool
        !max_body.nil?
      end

      def max_body : Int64?
        if config = @config
          config.max_request_body
        else
          @max_body
        end
      end

      def call(context : HTTP::Server::Context) : Nil
        max = max_body
        return call_next(context) unless max

        request = context.request
        if length = request.content_length
          if length > max
            reject(context, max)
            return
          end
        end

        if body = request.body
          raw = IO::Memory.new
          begin
            IO.copy(body, raw)
          rescue
            Middleware.respond_text(context.response, 400, "Bad Request")
            return
          end
          if raw.size > max
            reject(context, max)
            return
          end
          raw.rewind
          request.body = raw
        end

        call_next(context)
      end

      private def reject(context : HTTP::Server::Context, max : Int64) : Nil
        response = context.response
        response.headers["Connection"] = "close"
        Middleware.respond_text(response, 413, "Request Entity Too Large (max #{max} bytes)")
      end
    end
  end
end
