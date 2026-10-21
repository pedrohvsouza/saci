require "http/server"

module Saci
  module Deploy
    # Drains in-flight requests on SIGTERM/SIGINT (G139).
    #
    # Crystal's `HTTP::Server#close` stops accepting new connections and lets
    # already-accepted requests finish, but it does not wait for them. This
    # helper wraps the handler chain with an in-flight counter, closes the
    # server on a signal, waits up to `timeout`, then runs shutdown hooks.
    #
    # ```
    # shutdown = Saci::Deploy::GracefulShutdown.new(timeout: 10.seconds)
    # shutdown.on_shutdown { Saci::Job.stop }
    # Saci::Application.new(router).listen_gracefully(3000, shutdown: shutdown)
    # ```
    #
    # There is intentionally no cluster/worker management here: Crystal has no
    # Puma cluster mode. Run several processes behind a proxy (systemd units,
    # Kamal replicas or Docker) and let each one drain independently.
    class GracefulShutdown
      # Wraps a handler chain, counting requests that have entered but not yet
      # returned (the response is flushed just after the handler returns).
      class TrackingHandler
        include HTTP::Handler

        def initialize(@shutdown : GracefulShutdown, @inner : HTTP::Handler)
        end

        def call(context : HTTP::Server::Context) : Nil
          @shutdown.enter
          begin
            @inner.call(context)
          ensure
            @shutdown.leave
          end
        end
      end

      getter timeout : Time::Span
      getter signals : Array(Signal)
      getter? forced : Bool = false

      @server : HTTP::Server?
      @hooks = [] of Proc(Nil)
      @hooks_mutex = Mutex.new
      @in_flight = 0
      @in_flight_mutex = Mutex.new
      @complete_mutex = Mutex.new
      @completed = false
      @traps_installed = false
      @shutting_down = Atomic(Bool).new(false)

      def initialize(@timeout : Time::Span = 10.seconds, @signals : Array(Signal) = [Signal::TERM, Signal::INT])
      end

      # Registers a callback run after draining (or after the deadline).
      # Hooks are best-effort: an exception is logged and the remaining hooks
      # still run. Registering from multiple fibers is safe.
      def on_shutdown(&block : -> Nil) : self
        @hooks_mutex.synchronize { @hooks << block }
        self
      end

      # Number of requests currently executing the handler chain.
      def in_flight : Int32
        @in_flight_mutex.synchronize { @in_flight }
      end

      def shutting_down? : Bool
        @shutting_down.get
      end

      def enter : Nil
        @in_flight_mutex.synchronize { @in_flight += 1 }
      end

      def leave : Nil
        @in_flight_mutex.synchronize { @in_flight -= 1 if @in_flight > 0 }
      end

      # Wraps `inner` so requests are counted while the entire chain runs.
      def handler(inner : HTTP::Handler) : HTTP::Handler
        TrackingHandler.new(self, inner).as(HTTP::Handler)
      end

      # Runs `block`, counting it as an in-flight unit. Useful for custom
      # servers or long-lived handlers that do not use `handler`.
      def track(&block : -> T) : T forall T
        enter
        begin
          yield
        ensure
          leave
        end
      end

      # Blocks until the server stops (an external close or a trapped signal),
      # then drains and runs hooks. The server must already be bound.
      def run(server : HTTP::Server) : Nil
        @server = server
        install_signal_traps
        if shutting_down?
          begin
            server.close
          rescue
            # Already closed by the signal path.
          end
          complete_shutdown
          return
        end
        begin
          server.listen
        ensure
          request_shutdown
          complete_shutdown
        end
      end

      # Stops accepting new connections (idempotent) without blocking. Signal
      # handlers call this; `run` performs the drain afterwards.
      def request_shutdown : Nil
        return unless @shutting_down.compare_and_set(false, true)
        if server = @server
          begin
            server.close
          rescue
            # An external close (or a second signal) is already a shutdown.
          end
        end
      end

      # Stops accepting, waits for in-flight requests, runs hooks. Returns true
      # when every request drained before the deadline, false when some were
      # still running. Safe to call more than once (hooks run once).
      def shutdown! : Bool
        request_shutdown
        complete_shutdown
      end

      # Installs the signal traps once. Kept public so apps/tests can opt in
      # explicitly when they manage the server themselves.
      def install_signal_traps : Nil
        return if @traps_installed
        @traps_installed = true
        signals.each do |signal|
          signal.trap { |_received| request_shutdown }
        end
      end

      private def complete_shutdown : Bool
        @complete_mutex.synchronize do
          return !@forced if @completed
          @completed = true
          drained = drain
          @forced = !drained
          run_hooks
          drained
        end
      end

      private def drain : Bool
        deadline = Time.instant + timeout
        loop do
          break if in_flight == 0
          remaining = deadline - Time.instant
          break if remaining <= Time::Span.zero
          sleep(remaining < 10.milliseconds ? remaining : 10.milliseconds)
        end
        in_flight == 0
      end

      private def run_hooks : Nil
        hooks = @hooks_mutex.synchronize { @hooks.dup }
        hooks.each do |hook|
          begin
            hook.call
          rescue ex
            STDERR.puts "[saci] shutdown hook failed: #{ex.class}: #{ex.message}"
          end
        end
      end
    end
  end
end
