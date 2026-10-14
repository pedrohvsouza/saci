module Saci
  # ActiveJob-style background jobs (in-process adapters).
  #
  # ```
  # class WelcomeJob < Saci::Job::Base
  #   queue_as :mailers
  #   retry_on IO::Error, attempts: 3, wait: 5.seconds
  #   discard_on Saci::Record::RecordNotFound
  #
  #   def perform(payload : JSON::Any) : Nil
  #     puts "hello #{payload["user_id"]}"
  #   end
  # end
  #
  # WelcomeJob.perform_later({user_id: 1})
  # WelcomeJob.set(wait: 5.minutes).perform_later({user_id: 1})
  # WelcomeJob.perform_now({user_id: 1})
  # ```
  #
  # Payloads cross a JSON serialization boundary (even in-process), so only
  # JSON-safe arguments survive — pass ids, not objects. Adapters:
  # `:async` (spawned fiber, dev default), `:inline` (runs immediately —
  # use in specs), `:test` (records without running; assert on
  # `Saci::Job.enqueued_jobs`), `:db` (durable: persists to the database,
  # survives restarts — run `Saci::Job::Db.drain` / `work_once` to execute).
  # `Saci::Job.with_adapter(:inline) { }` scopes the switch.
  module Job
    @@adapter : Symbol = :async
    @@adapter_mutex = Mutex.new

    def self.queue_adapter : Symbol
      @@adapter_mutex.synchronize { @@adapter }
    end

    def self.queue_adapter=(name : Symbol) : Nil
      unless [:inline, :async, :test, :db].includes?(name)
        raise ArgumentError.new("Unknown queue adapter #{name.inspect} (expected :inline, :async, :test or :db)")
      end
      @@adapter_mutex.synchronize { @@adapter = name }
    end

    # Runs the block with a temporary adapter (restored afterwards) —
    # the spec-friendly way to force inline execution.
    def self.with_adapter(name : Symbol, & : -> T) : T forall T
      previous = queue_adapter
      self.queue_adapter = name
      begin
        yield
      ensure
        self.queue_adapter = previous
      end
    end

    @@error_handler : Proc(String, Exception, Nil)? = nil
    @@error_mutex = Mutex.new

    # Called with (job class name, error) on discard and on final failure.
    # Default: STDERR line. Override in apps (error tracker, logger, ...).
    def self.on_error(&handler : String, Exception ->) : Nil
      @@error_mutex.synchronize { @@error_handler = handler }
    end

    def self.reset_error_handler! : Nil
      @@error_mutex.synchronize { @@error_handler = nil }
    end

    def self.report_error(job_name : String, error : Exception) : Nil
      handler = @@error_mutex.synchronize { @@error_handler }
      if handler
        handler.call(job_name, error)
      else
        STDERR.puts "[saci][job] #{job_name} failed: #{error.class}: #{error.message}"
      end
    end

    # Recorded enqueues while the `:test` adapter is active.
    alias Enqueued = NamedTuple(job: String, payload: String)

    @@enqueued = [] of Enqueued
    @@enqueued_mutex = Mutex.new

    def self.enqueued_jobs : Array(Enqueued)
      @@enqueued_mutex.synchronize { @@enqueued.dup }
    end

    def self.clear_enqueued! : Nil
      @@enqueued_mutex.synchronize { @@enqueued.clear }
    end

    private def self.record_enqueued(job : String, payload : String) : Nil
      @@enqueued_mutex.synchronize { @@enqueued << {job: job, payload: payload} }
    end

    def self.enqueue(job_class : Base.class, payload_json : String, wait : Time::Span? = nil) : Nil
      case queue_adapter
      when :inline
        execute(job_class, payload_json)
      when :async
        spawn do
          sleep wait if wait
          begin
            execute(job_class, payload_json)
          rescue
            # Already reported via on_error hook.
          end
        end
      when :test
        record_enqueued(job_class.name, payload_json)
      when :db
        Db.enqueue(job_class.name, job_class.queue_name, payload_json, wait ? Time.utc + wait : Time.utc)
      end
    end

    # Runs one job with its retry/discard rules. `attempt` starts at 1;
    # each rule decides against its own `attempts` limit. Jobs declaring
    # `limits_concurrency` hold a per-key slot while running — a run that
    # arrives while the slot is full is skipped (not queued, not an error).
    def self.execute(job_class : Base.class, payload_json : String, attempt : Int32 = 1) : Nil
      if limit = job_class.__saci_concurrency_limit
        key = job_class.__saci_concurrency_key
        return unless concurrency_try_acquire(key, limit)
        begin
          execute_guarded(job_class, payload_json, attempt)
        ensure
          concurrency_release(key)
        end
      else
        execute_guarded(job_class, payload_json, attempt)
      end
    end

    private def self.execute_guarded(job_class : Base.class, payload_json : String, attempt : Int32) : Nil
      payload = JSON.parse(payload_json)
      instance = job_class.new
      begin
        instance.perform(payload)
      rescue ex
        case job_class.__saci_handle_error(ex, attempt)
        when :retry
          execute_guarded(job_class, payload_json, attempt + 1)
        when :discard
          report_error(job_class.name, ex)
        else
          report_error(job_class.name, ex)
          raise ex
        end
      end
    end

    # In-process concurrency slots, keyed by each job's `limits_concurrency`
    # key. The `:db` adapter honors limits through this same path (it runs
    # claimed rows via `execute`), so a duplicate claimed while its key is
    # held is skipped and its row resolves as usual.
    @@concurrency_running = {} of String => Int32
    @@concurrency_mutex = Mutex.new

    # Claims a slot for `key`, holding it until `concurrency_release`.
    # Returns false when `limit` runners already hold it (skip-if-running).
    def self.concurrency_try_acquire(key : String, limit : Int32) : Bool
      @@concurrency_mutex.synchronize do
        running = @@concurrency_running[key]? || 0
        return false if running >= limit
        @@concurrency_running[key] = running + 1
        true
      end
    end

    def self.concurrency_release(key : String) : Nil
      @@concurrency_mutex.synchronize do
        if running = @@concurrency_running[key]?
          if running <= 1
            @@concurrency_running.delete(key)
          else
            @@concurrency_running[key] = running - 1
          end
        end
      end
    end

    # Drops all held slots (spec isolation; normal runs release via ensure).
    def self.reset_concurrency! : Nil
      @@concurrency_mutex.synchronize { @@concurrency_running.clear }
    end

    # `MyJob.set(wait: 5.minutes).perform_later(args)` / `.perform_now(args)`.
    struct Setter
      def initialize(@klass : Base.class, @wait : Time::Span? = nil)
      end

      def perform_later(payload) : Nil
        Job.enqueue(@klass, payload.to_json, @wait)
      end

      def perform_now(payload) : Nil
        @klass.execute_now(payload)
      end
    end

    class Base
      macro inherited
        # Self-register for the durable adapter (which persists only the
        # class name — Crystal has no runtime constantize). Runs at class
        # definition time, alongside the error-chain method below.
        Saci::Job.register({{@type.name.stringify}}, self)

        def self.__saci_handle_error(ex : Exception, attempt : Int32) : Symbol
          super
        end
      end

      def self.__saci_handle_error(ex : Exception, attempt : Int32) : Symbol
        :raise
      end

      # Override in subclasses. Payload arrives as parsed JSON.
      def perform(payload : JSON::Any) : Nil
        raise "Define #{self.class}#perform(payload : JSON::Any)"
      end

      macro queue_as(name)
        def self.queue_name : String
          {{name.id.stringify}}
        end
      end

      def self.queue_name : String
        "default"
      end

      # No concurrency cap unless declared (nil = unlimited).
      def self.__saci_concurrency_limit : Int32?
        nil
      end

      def self.__saci_concurrency_key : String
        ""
      end

      # Caps concurrent executions (`to:`) under a shared `key:` — runs that
      # arrive while the slot is full are skipped (at-least-once everywhere,
      # so prefer this for recurring jobs like page-cache refreshes):
      #
      # ```
      # class CachePageJob < Saci::Job::Base
      #   limits_concurrency to: 1, key: "cache-page"
      # end
      # ```
      #
      # Without `key:` the class name is used. Explicit `perform_now` always
      # runs (the guard covers `perform_later` paths: `:inline`, `:async`
      # and `:db`).
      macro limits_concurrency(to = 1, key = nil)
        def self.__saci_concurrency_limit : Int32?
          ({{to}}).to_i32
        end

        def self.__saci_concurrency_key : String
          {% if key.is_a?(NilLiteral) %}
            self.name
          {% else %}
            ({{key}}).to_s
          {% end %}
        end
      end

      # Retries `error` up to `attempts` total tries, waiting `wait`
      # (`:exponential` backs off 1s/2s/4s… capped at 1 hour) between tries.
      macro retry_on(error, attempts = 3, wait = nil)
        def self.__saci_handle_error(ex : Exception, attempt : Int32) : Symbol
          if ex.is_a?({{error}}) && attempt < {{attempts}}
            {% if wait.is_a?(NilLiteral) %}
            {% elsif wait.is_a?(SymbolLiteral) && wait.id.stringify == "exponential" %}
              sleep [2 ** (attempt - 1), 3600].min.seconds
            {% else %}
              sleep {{wait}}
            {% end %}
            return :retry
          end
          previous_def
        end
      end

      macro discard_on(error)
        def self.__saci_handle_error(ex : Exception, attempt : Int32) : Symbol
          return :discard if ex.is_a?({{error}})
          previous_def
        end
      end

      def self.set(wait : Time::Span? = nil) : Setter
        Setter.new(self, wait)
      end

      def self.wait_until(time : Time) : Setter
        delay = time - Time.utc
        set(wait: delay > 0.seconds ? delay : 0.seconds)
      end

      def self.perform_later(payload) : Nil
        Job.enqueue(self, payload.to_json)
      end

      def self.perform_now(payload) : Nil
        execute_now(payload)
      end

      def self.execute_now(payload) : Nil
        parsed = payload.is_a?(String) ? JSON.parse(payload) : JSON.parse(payload.to_json)
        new.perform(parsed)
      end
    end
  end
end
