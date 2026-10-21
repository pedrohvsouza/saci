require "../exceptions"

module Saci
  module Middleware
    # Applies `config.exceptions_app` (and, in production, the built-in error
    # pages) to 400/404/422/500 responses produced downstream.
    #
    # The router handles its own exceptions and writes a response, so a plain
    # rescue wrapper would never see an unhandled error. Buffering the body
    # lets the middleware replace only those statuses while leaving successful
    # and streaming responses untouched. It is disabled in development unless
    # an explicit `exceptions_app` is configured, preserving the detailed
    # router error page.
    class ShowExceptions
      include HTTP::Handler
      include Conditional

      STATUSES = {400, 404, 422, 500}

      def initialize(@config : Configuration)
      end

      def enabled? : Bool
        !@config.exceptions_app.nil? || (@config.default_error_pages && Saci.production?)
      end

      def call(context : HTTP::Server::Context) : Nil
        return call_next(context) unless enabled?

        app = @config.exceptions_app
        if app.nil?
          # Built-in production pages only; the local development error page
          # keeps precedence when detailed exceptions are enabled.
          if Saci.show_detailed_exceptions? && Middleware.local_request?(context.request)
            return call_next(context)
          end
          app = Saci::Exceptions.default_app
        end

        response = context.response
        original_output = response.output
        buffer = IO::Memory.new
        response.output = buffer

        downstream_exception : Exception? = nil
        begin
          call_next(context)
        rescue ex
          downstream_exception = ex
        ensure
          response.output = original_output
        end

        if exception = downstream_exception
          response.status_code = 500
          clear_error_headers(response)
          begin
            app.call(context, 500, exception)
          rescue
            Saci::Exceptions.render_default(context, 500)
          end
          return
        end

        status = response.status_code
        unless STATUSES.includes?(status)
          buffer.rewind
          IO.copy(buffer, original_output)
          return
        end

        clear_error_headers(response)
        exception = context.saci_exception
        begin
          app.call(context, status, exception)
        rescue
          Saci::Exceptions.render_default(context, status)
        ensure
          context.saci_exception = nil
        end
      end

      private def clear_error_headers(response : HTTP::Server::Response) : Nil
        response.headers.delete("Content-Encoding")
        response.headers.delete("Content-Length")
        response.headers.delete("ETag")
        response.headers.delete("Last-Modified")
      end
    end
  end
end
