module Saci
  module Middleware
    # Answers `HEAD` with the headers the matching `GET` would send and no
    # body (Rack::Head). The router dispatches a `HEAD` without a route of
    # its own to the `GET` route; this handler, first in the stack, swaps the
    # response output for one that discards what the action writes and keeps
    # count, so `Content-Length` still matches the `GET` (compressed size
    # included, since `Compression` sits inside it).
    #
    # Crystal's `HTTP::Server` writes whatever the handler prints, even for
    # `HEAD`; without this, a body after the headers would break keep-alive
    # connections.
    class Head
      include HTTP::Handler

      def initialize(@config : Configuration? = nil)
      end

      def call(context : HTTP::Server::Context) : Nil
        if context.request.method == "HEAD"
          response = context.response
          response.output = BodyDiscarder.new(response, response.output)
        end
        call_next(context)
      end

      # Write-only IO that drops the body and records its size.
      class BodyDiscarder < IO
        getter bytes : Int64 = 0_i64

        def initialize(@response : HTTP::Server::Response, @inner : IO)
          @closed = false
        end

        def read(slice : Bytes) : Int32
          raise IO::Error.new("HEAD response body is write-only")
        end

        def write(slice : Bytes) : Nil
          @bytes += slice.size
        end

        # Headers go out on close, once the length is known.
        def flush : Nil
        end

        def closed? : Bool
          @closed
        end

        def close : Nil
          return if @closed
          @closed = true
          headers = @response.headers
          if @bytes > 0 && !headers.has_key?("Content-Length") && !headers.has_key?("Transfer-Encoding")
            headers["Content-Length"] = @bytes.to_s
          end
          @inner.close
        end
      end
    end
  end
end
