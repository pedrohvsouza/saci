require "http/server"
require "http/web_socket"

# Hooks that let a long-lived, mostly idle socket give back the buffers
# HTTP request handling sized for throughput. A WebSocket connection keeps
# its TCP socket (8 KiB read + 8 KiB write buffer), the upgrade response's
# 8 KiB output buffer and a 4 KiB receive buffer for as long as it is open:
# at tens of thousands of sockets that is most of the process's heap.
module IO::Buffered
  # :nodoc:
  # Drops both buffers (they are allocated again, at *size* bytes, the next
  # time they are needed) when they hold no data. Returns false, changing
  # nothing, when unread input or unflushed output is still buffered.
  def __saci_shrink_buffers(size : Int32) : Bool
    return false unless @in_buffer_rem.empty? && @out_count == 0
    @in_buffer_rem = Bytes.empty
    @in_buffer = Pointer(UInt8).null
    @out_buffer = Pointer(UInt8).null
    @buffer_size = size
    true
  end
end

class HTTP::WebSocket
  # :nodoc:
  # Replaces the frame receive buffer (larger frames are read in pieces of
  # this size and assembled as before).
  def __saci_receive_buffer_size=(size : Int32) : Int32
    @buffer = Bytes.new(size)
    size
  end
end

class HTTP::Server::Response
  # :nodoc:
  # The response's own buffered output, even when `output` was wrapped.
  def __saci_original_output : IO
    @original_output
  end
end
