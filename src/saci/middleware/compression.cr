require "compress/gzip"

module Saci
  module Middleware
    # Buffered gzip response compression.
    #
    # ```
    # Saci.configure do |config|
    #   config.compression.enabled = true
    #   config.compression.min_size = 1024
    # end
    # ```
    #
    # The middleware buffers the downstream body so it can decide based on the
    # final size and content type. It only compresses:
    # * statuses `200..299` (not 204/304),
    # * non-`HEAD` requests,
    # * bodies at least `min_size` bytes,
    # * compressible content types and `Accept-Encoding: gzip` (q=0 is honored),
    # * responses that do not already carry `Content-Encoding`.
    #
    # `Content-Length` is rewritten to the compressed size and
    # `Vary: Accept-Encoding` is added. This is intentionally not a streaming
    # compressor; streaming/SSE responses should disable it.
    class Compression
      include HTTP::Handler
      include Conditional

      class Settings
        property enabled : Bool = false
        property min_size : Int32 = 1024
        property level : Int32 = Compress::Gzip::DEFAULT_COMPRESSION
        property content_types : Array(String) = [
          "text/",
          "application/json",
          "application/javascript",
          "application/xml",
          "application/xhtml+xml",
          "image/svg+xml",
        ]

        def initialize
        end
      end

      def initialize(@config : Configuration)
        @settings = nil
      end

      def initialize(enabled : Bool = true, min_size : Int32 = 1024)
        @config = nil
        @settings = Settings.new
        @settings.not_nil!.enabled = enabled
        @settings.not_nil!.min_size = min_size
      end

      def settings : Settings
        @settings || @config.not_nil!.compression
      end

      def enabled? : Bool
        settings.enabled
      end

      def call(context : HTTP::Server::Context) : Nil
        return call_next(context) unless enabled?
        return call_next(context) if context.request.method == "HEAD"

        response = context.response
        original_output = response.output
        buffer = IO::Memory.new
        response.output = buffer

        begin
          call_next(context)
        ensure
          response.output = original_output
        end

        body = buffer.to_slice
        if compressible?(context, body.size)
          compressed = IO::Memory.new
          Compress::Gzip::Writer.open(compressed, level: settings.level) do |gzip|
            gzip.write(body)
          end
          payload = compressed.to_slice
          response.headers["Content-Encoding"] = "gzip"
          response.headers["Content-Length"] = payload.size.to_s
          Middleware.vary(response, "Accept-Encoding")
          original_output.write(payload)
        else
          original_output.write(body)
        end
      end

      private def compressible?(context : HTTP::Server::Context, size : Int32) : Bool
        response = context.response
        return false unless response.status_code.in?(200..299)
        return false if size < settings.min_size
        return false if response.headers.has_key?("Content-Encoding")
        return false unless accepts_gzip?(context.request)
        content_type = response.headers["Content-Type"]?
        return false unless content_type
        content_type = content_type.downcase
        return false if content_type.starts_with?("text/event-stream")
        settings.content_types.any? do |candidate|
          candidate == "*" || content_type.starts_with?(candidate)
        end
      end

      private def accepts_gzip?(request : HTTP::Request) : Bool
        header = request.headers["Accept-Encoding"]?
        return false unless header
        header.split(',').any? do |entry|
          name, _, params = entry.strip.partition(';')
          next false unless name.strip.downcase == "gzip" || name.strip == "*"
          quality = 1.0
          params.split(';').each do |parameter|
            parameter = parameter.strip
            if parameter.starts_with?("q=")
              quality = parameter[2..].to_f? || 0.0
            end
          end
          quality > 0
        end
      end
    end
  end
end
