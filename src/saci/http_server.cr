require "http/server"

# The stdlib allocates a fixed 4096-byte read buffer per WebSocket. Saci makes
# it configurable (`Saci.config.websocket_buffer_size`): with thousands of
# idle sockets that buffer is a large share of each connection's memory.
class HTTP::WebSocket
  class_property read_buffer_size : Int32 = 4096

  def initialize(@ws : Protocol)
    @buffer = Bytes.new(HTTP::WebSocket.read_buffer_size)
    @current_message = IO::Memory.new
  end
end

module Saci
  # `HTTP::Server` with per-connection memory tuned for many idle sockets.
  #
  # Crystal's stdlib gives every accepted socket two 32 KiB I/O buffers (read
  # and write). That is generous for bulk HTTP but dominates the footprint of
  # long-lived WebSocket connections, which mostly carry small frames.
  # `socket_buffer_size` (`Saci.config.socket_buffer_size`, 8 KiB by default)
  # is applied before the first read, so a request never allocates the big
  # buffers. `nil` keeps the stdlib default.
  class HTTPServer < ::HTTP::Server
    property socket_buffer_size : Int32?

    def initialize(handler : ::HTTP::Handler | ::HTTP::Handler::HandlerProc, @socket_buffer_size : Int32? = nil)
      super(handler)
    end

    private def handle_client(io : IO)
      if (size = @socket_buffer_size) && io.is_a?(IO::Buffered)
        begin
          io.buffer_size = size
        rescue ArgumentError
          # Buffers already allocated (e.g. TLS socket after handshake).
        end
      end
      super
    end
  end

  # `HTTP::WebSocketHandler` that does not keep the HTTP response's own
  # 32 KiB output buffer alive for the lifetime of the socket: the 101 reply
  # is written unbuffered (`sync`), so that buffer is never allocated. Frames
  # go through the socket's own (smaller) buffer as before.
  class WebSocketHandler < ::HTTP::WebSocketHandler
    def call(context) : Nil
      if websocket_upgrade_request?(context.request)
        if output = context.response.output.as?(IO::Buffered)
          output.sync = true
        end
      end
      super
    end
  end
end
