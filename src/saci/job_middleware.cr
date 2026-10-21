require "mutex"

module Saci
  module Job
    # Base class for job middleware. Middleware wraps both enqueueing and
    # performing, outermost around the job's `around_*` callbacks:
    #
    # ```
    # class TimingMiddleware < Saci::Job::Middleware
    #   def call(job : Saci::Job::Base, &block : -> Nil) : Nil
    #     started = Time.monotonic
    #     begin
    #       yield
    #     ensure
    #       puts "#{job.class.name}: #{Time.monotonic - started}"
    #     end
    #   end
    # end
    #
    # Saci::Job.middleware.use(TimingMiddleware.new)
    # ```
    #
    # The chain is global (`Saci::Job.middleware`); `MyJob.middleware`
    # returns the same object so both spellings work. Add entries in the
    # order they should nest (first added is outermost). A middleware that
    # does not call the block suppresses the operation, exactly like
    # ActiveJob middleware.
    class Middleware
      def call(job : Base, &block : -> Nil) : Nil
        yield
      end
    end

    alias MiddlewareHandler = Proc(Base, Proc(Nil), Nil)

    # Ordered middleware chain. All operations are mutex-protected because
    # apps commonly register middleware during boot while worker fibers
    # are already running.
    #
    # Names and handlers are kept in parallel arrays (rather than a
    # NamedTuple entry type) so this file can be required before
    # `Job::Base` exists without eagerly expanding a constant that
    # references it.
    class MiddlewareChain
      def initialize
        @names = [] of String
        @handlers = [] of MiddlewareHandler
        @mutex = Mutex.new
      end

      # Functional registration:
      #
      # ```
      # Saci::Job.middleware.add("metrics") do |job, nxt|
      #   Metrics.job_started(job.class.name)
      #   nxt.call
      # end
      # ```
      def add(name : String, handler : MiddlewareHandler) : self
        @mutex.synchronize do
          @names << name
          @handlers << handler
        end
        self
      end

      def add(name : String, &handler : MiddlewareHandler) : self
        add(name, handler)
      end

      # Object registration (`call(job, &block)` middleware).
      def use(middleware : Middleware) : self
        name = middleware.class.name
        add(name, ->(job : Base, nxt : Proc(Nil)) { middleware.call(job) { nxt.call } })
      end

      # Alias for `use` (some apps expect `middleware.add(instance)`).
      def add(middleware : Middleware) : self
        use(middleware)
      end

      # Removes every entry registered under `name` (including a class
      # middleware's fully-qualified class name). Returns true when one or
      # more entries were removed.
      def remove(name : String) : Bool
        @mutex.synchronize do
          before = @names.size
          kept_names = [] of String
          kept_handlers = [] of MiddlewareHandler
          @names.each_with_index do |entry_name, index|
            next if entry_name == name
            kept_names << entry_name
            kept_handlers << @handlers[index]
          end
          @names = kept_names
          @handlers = kept_handlers
          kept_names.size != before
        end
      end

      def clear! : Nil
        @mutex.synchronize do
          @names.clear
          @handlers.clear
        end
      end

      def names : Array(String)
        @mutex.synchronize { @names.dup }
      end

      def size : Int32
        @mutex.synchronize { @names.size }
      end

      def empty? : Bool
        size == 0
      end

      # Runs `final` wrapped by every middleware (first added outermost).
      def run(job : Base, final : Proc(Nil)) : Nil
        handlers = @mutex.synchronize { @handlers.dup }
        compose(handlers, 0, job, final).call
      end

      private def compose(handlers : Array(MiddlewareHandler), index : Int32,
                          job : Base, final : Proc(Nil)) : Proc(Nil)
        return final if index >= handlers.size
        handler = handlers[index]
        nxt = -> { compose(handlers, index + 1, job, final).call }
        -> { handler.call(job, nxt) }
      end
    end

    # Lazily created so this file can be required before `Job::Base` exists
    # (the chain's handler type references it).
    @@middleware : MiddlewareChain? = nil
    @@middleware_mutex = Mutex.new

    # Global middleware chain shared by every job class.
    def self.middleware : MiddlewareChain
      @@middleware_mutex.synchronize do
        @@middleware ||= MiddlewareChain.new
      end
    end
  end
end
