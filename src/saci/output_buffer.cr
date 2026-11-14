module Saci
  module Views
    # The IO every ECR template, layout and partial writes into.
    #
    # ECR compiles `<% content_for(:head) do %><style>…</style><% end %>`
    # into a block whose body writes straight to the template's buffer, so a
    # block helper never sees that markup as a return value. `capture`
    # redirects the writes into a separate sink while the block runs and
    # hands the captured text back, which is how `content_for` and
    # `capture` accept ECR blocks.
    class OutputBuffer < IO
      def initialize
        @root = IO::Memory.new
        @sinks = [] of IO::Memory
      end

      def read(slice : Bytes) : Int32
        raise IO::Error.new("Saci::Views::OutputBuffer is write-only")
      end

      def write(slice : Bytes) : Nil
        (@sinks.last? || @root).write(slice)
      end

      # Runs the block with every write redirected, and returns what was
      # written in the meantime. Nested captures stack.
      def capture(& : ->) : String
        sink = IO::Memory.new
        @sinks.push(sink)
        begin
          yield
        ensure
          @sinks.pop
        end
        sink.to_s
      end

      # Everything written outside captures.
      def contents : String
        @root.to_s
      end
    end
  end

  class Controller
    @__saci_output_buffers : Array(Views::OutputBuffer)? = nil

    # Renders an ECR body into a fresh `OutputBuffer` (made current while
    # the block runs) and returns the result. Used by `render_template`,
    # `render_partial` and `render_to_string`.
    def __saci_buffered(& : Views::OutputBuffer ->) : String
      buffer = Views::OutputBuffer.new
      stack = (@__saci_output_buffers ||= [] of Views::OutputBuffer)
      stack.push(buffer)
      begin
        yield buffer
      ensure
        stack.pop
      end
      buffer.contents
    end

    # The markup a block produced: what it wrote to the current template
    # buffer (ECR `<% helper do %>…<% end %>`), or else its String value
    # (`helper { "<meta>" }`).
    def __saci_capture(& : -> _) : String
      result = nil
      captured = if buffer = @__saci_output_buffers.try(&.last?)
                   buffer.capture { result = yield }
                 else
                   result = yield
                   ""
                 end
      return captured unless captured.empty?
      value = result
      value.is_a?(String) ? value : ""
    end
  end
end
