require "json"
require "mutex"
require "set"
require "./job_middleware"
require "./job_gid"
require "./job_batch"

module Saci
  # ActiveJob-style background jobs (in-process adapters plus a durable DB
  # adapter).
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
  # WelcomeJob.set(wait: 5.minutes, queue: :high, priority: 10).perform_later({user_id: 1})
  # WelcomeJob.perform_now({user_id: 1})
  # ```
  #
  # Job arguments cross a JSON boundary (even in-process). `Job.encode`
  # accepts JSON primitives, arrays, tuples, hashes, `NamedTuple`s,
  # `JSON::Any` and `Saci::Record::Base` instances (serialized as record
  # references — resolve them with `Saci::Job::GlobalID.load`). Anything
  # else is rejected with a clear `ArgumentError`.
  #
  # Adapters:
  # `:async` (spawned fiber, dev default), `:inline` (runs immediately —
  # use in specs), `:test` (records without running; assert on
  # `Saci::Job.enqueued_jobs`), `:db` (durable: persists to the database,
  # survives restarts — run `Saci::Job::Db.drain` / `work_once` to execute).
  # `:immediate` is an alias for `:inline`. Custom adapters register through
  # `Saci::Job.register_adapter`. `Saci::Job.with_adapter(:inline) { }`
  # scopes the switch.
  #
  # Callbacks (`before_enqueue`, `after_enqueue`, `before_perform`,
  # `after_perform`, `around_enqueue`, `around_perform`, `rescue_from`) and
  # middleware (`Saci::Job.middleware.add/use`) work with every adapter.
  # Ordering is documented at each macro.
  module Job
    # Raised from enqueue callbacks to cancel the enqueue without failing.
    class Abort < Exception
    end

    UNIQUE_MODES     = [:until_executed, :until_executing, :while_executing]
    BUILTIN_ADAPTERS = [:inline, :async, :test, :db]

    alias AdapterHandler = Proc(Base.class, String, Time::Span?, String, Int32, Time?, String?, Nil)

    @@adapter : Symbol = :async
    @@adapter_mutex = Mutex.new
    @@custom_adapters = {} of Symbol => AdapterHandler

    def self.normalize_adapter(name : Symbol) : Symbol
      name == :immediate ? :inline : name
    end

    def self.queue_adapter : Symbol
      @@adapter_mutex.synchronize { @@adapter }
    end

    def self.queue_adapter=(name : Symbol) : Nil
      normalized = normalize_adapter(name)
      custom = @@adapter_mutex.synchronize { @@custom_adapters.has_key?(normalized) }
      unless BUILTIN_ADAPTERS.includes?(normalized) || custom
        raise ArgumentError.new(
          "Unknown queue adapter #{name.inspect} (expected :inline, :async, :test, :db, " \
          ":immediate or an adapter registered with Saci::Job.register_adapter)")
      end
      @@adapter_mutex.synchronize { @@adapter = normalized }
    end

    # Registers a custom adapter handler:
    #
    # ```
    # Saci::Job.register_adapter(:memory) do |job_class, payload_json, wait, queue, priority, wait_until, batch_id|
    #   # Persist/forward the job, then run it via `Saci::Job.execute`
    #   # (which applies callbacks, middleware, retries and callbacks).
    #   Saci::Job.execute(job_class, payload_json)
    # end
    # ```
    #
    # The block owns scheduling; returning means the job was accepted.
    # `Saci::Job::Batch` completion is the adapter's responsibility (inline,
    # async and DB notify it automatically).
    def self.register_adapter(name : Symbol, handler : AdapterHandler) : Nil
      normalized = normalize_adapter(name)
      if BUILTIN_ADAPTERS.includes?(normalized)
        raise ArgumentError.new("Cannot replace built-in queue adapter #{normalized.inspect}")
      end
      @@adapter_mutex.synchronize { @@custom_adapters[normalized] = handler }
    end

    def self.register_adapter(name : Symbol, &handler : AdapterHandler) : Nil
      register_adapter(name, handler)
    end

    def self.unregister_adapter(name : Symbol) : Bool
      normalized = normalize_adapter(name)
      @@adapter_mutex.synchronize { !@@custom_adapters.delete(normalized).nil? }
    end

    def self.adapters : Array(Symbol)
      custom = @@adapter_mutex.synchronize { @@custom_adapters.keys }
      (BUILTIN_ADAPTERS + custom).uniq.sort_by(&.to_s)
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

    # Global queue-name prefix (`queue_as :mailers` becomes
    # `"myapp_mailers"`). Applies to `set(queue:)` too and is idempotent.
    @@queue_name_prefix : String? = nil
    @@queue_prefix_mutex = Mutex.new

    def self.queue_name_prefix : String?
      @@queue_prefix_mutex.synchronize { @@queue_name_prefix }
    end

    def self.queue_name_prefix=(value : String?) : Nil
      normalized = value.try(&.strip)
      normalized = nil if normalized.try(&.empty?)
      @@queue_prefix_mutex.synchronize { @@queue_name_prefix = normalized }
    end

    def self.reset_queue_name_prefix! : Nil
      self.queue_name_prefix = nil
    end

    # Prefixes `name` once (safe to call on an already-prefixed queue).
    def self.prefixed_queue(name : String) : String
      prefix = queue_name_prefix
      return name if prefix.nil?
      name.starts_with?(prefix) ? name : prefix + name
    end

    # Rails 8.1-style opt-in for the DB adapter. See
    # `Saci::Job::Db.configure(enqueue_after_transaction_commit:)`.
    def self.enqueue_after_transaction_commit? : Bool
      Db.enqueue_after_transaction_commit?
    end

    def self.enqueue_after_transaction_commit=(value : Bool) : Nil
      Db.enqueue_after_transaction_commit = value
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

    # Recorded enqueues while the `:test` adapter is active. `queue` and
    # `priority` reflect `queue_as`/prefix/`set(...)` selectors; `wait_until`
    # is the resolved run time (nil means immediately).
    alias Enqueued = NamedTuple(
      job: String, payload: String, queue: String, priority: Int32, wait_until: Time?)

    @@enqueued = [] of Enqueued
    @@enqueued_mutex = Mutex.new

    def self.enqueued_jobs(queue : String? = nil) : Array(Enqueued)
      @@enqueued_mutex.synchronize do
        queue ? @@enqueued.select { |entry| entry[:queue] == queue } : @@enqueued.dup
      end
    end

    def self.clear_enqueued! : Nil
      @@enqueued_mutex.synchronize { @@enqueued.clear }
    end

    private def self.record_enqueued(job : String, payload : String, queue : String,
                                     priority : Int32, run_at : Time) : Nil
      @@enqueued_mutex.synchronize do
        @@enqueued << {job: job, payload: payload, queue: queue,
                       priority: priority, wait_until: run_at}
      end
    end

    # Enqueues one job. `wait` and `wait_until` are resolved to an absolute
    # run time (wait_until wins when both are present). `queue` overrides the
    # class's `queue_as`; `priority` overrides `queue_with_priority`.
    def self.enqueue(job_class : Base.class, payload_json : String,
                     wait : Time::Span? = nil,
                     queue : String? = nil,
                     priority : Int32? = nil,
                     wait_until : Time? = nil,
                     batch_id : String? = nil,
                     unique_mode : Symbol? = nil,
                     unique_key : String? = nil) : Nil
      mode = unique_mode || job_class.__saci_unique_mode
      if mode && !UNIQUE_MODES.includes?(mode)
        raise ArgumentError.new("Unknown job uniqueness mode #{mode.inspect} (expected #{UNIQUE_MODES.join(", ")})")
      end
      key = unique_key || (mode ? job_class.__saci_unique_key(payload_json) : nil)
      queue_name = prefixed_queue(queue || job_class.queue_name)
      priority_value = priority || job_class.priority
      run_at = wait_until || (wait ? Time.utc + wait : Time.utc)
      payload = JSON.parse(payload_json)
      instance = job_class.new
      instance.__saci_set_payload(payload)

      accepted = false
      middleware.run(instance, -> {
        accepted = instance.__saci_run_enqueue(-> {
          dispatch_enqueue(job_class, payload_json, queue_name, priority_value,
            run_at, wait, batch_id, mode, key)
        })
      })
      accepted
    end

    # Enqueues a mixed list in one call (a thin loop; adapters may optimize
    # later without changing this API).
    def self.enqueue_all(requests : Array(EnqueueRequest)) : Nil
      requests.each do |request|
        enqueue(request.job_class, request.payload_json,
          wait: request.wait, queue: request.queue, priority: request.priority,
          wait_until: request.wait_until)
      end
    end

    private def self.dispatch_enqueue(job_class : Base.class, payload_json : String,
                                      queue_name : String, priority : Int32, run_at : Time,
                                      wait : Time::Span?, batch_id : String?,
                                      unique_mode : Symbol?, unique_key : String?) : Bool
      adapter = queue_adapter
      case adapter
      when :inline
        return false unless reserve_in_memory_unique(unique_mode, unique_key)
        begin
          Saci::Job.execute(job_class, payload_json)
          Batch.__job_finished(batch_id, false) if batch_id
        rescue ex
          Batch.__job_finished(batch_id, true) if batch_id
          raise ex
        end
        true
      when :async
        return false unless reserve_in_memory_unique(unique_mode, unique_key)
        delay = run_at - Time.utc
        spawn do
          begin
            sleep delay if delay > Time::Span.zero
            Saci::Job.execute(job_class, payload_json)
            Batch.__job_finished(batch_id, false) if batch_id
          rescue
            Batch.__job_finished(batch_id, true) if batch_id
          end
        end
        true
      when :test
        return false unless reserve_in_memory_unique(unique_mode, unique_key)
        record_enqueued(job_class.name, payload_json, queue_name, priority, run_at)
        true
      when :db
        # Dedupe is enforced atomically by the DB adapter (unique index on
        # the held lock). A return of 0 means "duplicate dropped"; -1 means
        # "deferred until the surrounding transaction commits".
        id = Db.enqueue(job_class.name, queue_name, payload_json, run_at,
          priority: priority, unique_mode: unique_mode, unique_key: unique_key,
          batch_id: batch_id)
        id != 0
      else
        return false unless reserve_in_memory_unique(unique_mode, unique_key)
        handler = @@adapter_mutex.synchronize { @@custom_adapters[adapter]? }
        unless handler
          raise ArgumentError.new("Queue adapter #{adapter.inspect} is not registered")
        end
        handler.call(job_class, payload_json, wait, queue_name, priority, run_at, batch_id)
        true
      end
    end

    private def self.reserve_in_memory_unique(mode : Symbol?, key : String?) : Bool
      return true if mode.nil? || key.nil?
      Uniqueness.reserve(mode.not_nil!, key.not_nil!)
    end

    # Optional observers used by the testing shelf and instrumentation to
    # record logical executions without reopening this method. Observers run
    # once per `execute`/`perform_now`, not on internal retries.
    @@perform_observers = [] of Proc(Base.class, String, Int32, Nil)

    def self.add_perform_observer(observer : Proc(Base.class, String, Int32, Nil)) : Nil
      @@perform_observers << observer unless @@perform_observers.includes?(observer)
    end

    def self.perform_observer=(observer : Proc(Base.class, String, Int32, Nil)?) : Nil
      @@perform_observers.clear
      @@perform_observers << observer if observer
    end

    def self.perform_observers : Array(Proc(Base.class, String, Int32, Nil))
      @@perform_observers.dup
    end

    private def self.notify_perform_observers(job_class : Base.class, payload_json : String, attempt : Int32) : Nil
      @@perform_observers.each { |observer| observer.call(job_class, payload_json, attempt) }
    end

    # Runs one job with its uniqueness guard, retry/discard rules,
    # callbacks, middleware and continuation checkpoint. `attempt` starts
    # at 1; each `retry_on` rule decides against its own limit.
    #
    # `checkpoint`/`checkpoint_sink` are supplied by the DB adapter. Other
    # adapters pass nil, which means continuations run every step each
    # execution (the documented inline/test behavior).
    def self.execute(job_class : Base.class, payload_json : String, attempt : Int32 = 1,
                     checkpoint : Array(String)? = nil,
                     checkpoint_sink : Proc(Array(String), Nil)? = nil,
                     enforce_in_memory_unique : Bool = true) : Nil
      notify_perform_observers(job_class, payload_json, attempt)
      if enforce_in_memory_unique && (mode = job_class.__saci_unique_mode)
        key = job_class.__saci_unique_key(payload_json)
        return unless Uniqueness.try_start(mode, key)
        begin
          execute_with_limit(job_class, payload_json, attempt, checkpoint, checkpoint_sink)
        ensure
          Uniqueness.finish(mode, key)
        end
      else
        execute_with_limit(job_class, payload_json, attempt, checkpoint, checkpoint_sink)
      end
    end

    private def self.execute_with_limit(job_class : Base.class, payload_json : String,
                                        attempt : Int32, checkpoint : Array(String)?,
                                        checkpoint_sink : Proc(Array(String), Nil)?) : Nil
      if limit = job_class.__saci_concurrency_limit
        key = job_class.__saci_concurrency_key
        return unless concurrency_try_acquire(key, limit)
        begin
          execute_guarded(job_class, payload_json, attempt, checkpoint, checkpoint_sink)
        ensure
          concurrency_release(key)
        end
      else
        execute_guarded(job_class, payload_json, attempt, checkpoint, checkpoint_sink)
      end
    end

    private def self.execute_guarded(job_class : Base.class, payload_json : String,
                                     attempt : Int32, checkpoint : Array(String)?,
                                     checkpoint_sink : Proc(Array(String), Nil)?) : Nil
      payload = JSON.parse(payload_json)
      instance = job_class.new
      instance.__saci_set_payload(payload)
      instance.__saci_set_checkpoint(checkpoint)
      instance.__saci_set_checkpoint_sink(checkpoint_sink)
      begin
        middleware.run(instance, -> {
          instance.__saci_run_perform(-> { instance.perform(payload) })
        })
      rescue ex
        case job_class.__saci_handle_error(ex, attempt)
        when :retry
          next_checkpoint = checkpoint_sink ? instance.__saci_completed_steps : checkpoint
          execute_guarded(job_class, payload_json, attempt + 1, next_checkpoint, checkpoint_sink)
        when :discard
          report_error(job_class.name, ex)
        else
          unless instance.__saci_rescue_from(ex)
            report_error(job_class.name, ex)
            raise ex
          end
        end
      end
    end

    # `perform_now` path: always runs (bypasses concurrency limits and
    # uniqueness reservation, matching the existing contract) but still
    # applies callbacks, middleware, rescue handlers and retry rules.
    def self.perform_now(job_class : Base.class, payload_json : String) : Nil
      notify_perform_observers(job_class, payload_json, 1)
      execute_guarded(job_class, payload_json, 1, nil, nil)
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

    # In-memory uniqueness registry for adapters other than `:db`.
    #
    # * `:until_executed` — held from enqueue until the execution finishes
    #   (including all retries).
    # * `:until_executing` — held until execution starts, then released so
    #   another copy may be queued while the first runs.
    # * `:while_executing` — never blocks enqueue; only one copy executes at
    #   a time (the later copy skips).
    module Uniqueness
      @@mutex = Mutex.new
      @@queued = Set(String).new
      @@executing = Set(String).new

      def self.reserve(mode : Symbol, key : String) : Bool
        case mode
        when :while_executing
          true
        else
          @@mutex.synchronize do
            return false if @@queued.includes?(key)
            @@queued << key
            true
          end
        end
      end

      def self.try_start(mode : Symbol, key : String) : Bool
        case mode
        when :until_executing
          @@mutex.synchronize { @@queued.delete(key) }
          true
        when :while_executing
          @@mutex.synchronize do
            return false if @@executing.includes?(key)
            @@executing << key
            true
          end
        else
          true
        end
      end

      def self.finish(mode : Symbol, key : String) : Nil
        case mode
        when :until_executed
          @@mutex.synchronize { @@queued.delete(key) }
        when :while_executing
          @@mutex.synchronize { @@executing.delete(key) }
        end
      end

      def self.queued?(key : String) : Bool
        @@mutex.synchronize { @@queued.includes?(key) }
      end

      def self.executing?(key : String) : Bool
        @@mutex.synchronize { @@executing.includes?(key) }
      end

      def self.clear! : Nil
        @@mutex.synchronize do
          @@queued.clear
          @@executing.clear
        end
      end
    end

    # Clears in-memory uniqueness guards (spec isolation and test adapter
    # housekeeping).
    def self.reset_uniqueness! : Nil
      Uniqueness.clear!
    end

    class Base
      macro inherited
        # Self-register for the durable adapter (which persists only the
        # class name — Crystal has no runtime constantize). Runs at class
        # definition time, alongside the callback/continuation chain stubs.
        Saci::Job.register({{@type.name.stringify}}, self)

        def self.__saci_handle_error(ex : Exception, attempt : Int32) : Symbol
          super
        end

        # Callback chain stubs. The callback macros below use `previous_def`
        # to append to these, preserving declaration order across classes.
        def __saci_run_before_enqueue : Nil
          super
        end

        def __saci_run_after_enqueue : Nil
          super
        end

        def __saci_run_before_perform : Nil
          super
        end

        def __saci_run_after_perform : Nil
          super
        end

        def __saci_run_around_enqueue(next_cb : Proc(Nil)) : Nil
          super
        end

        def __saci_run_around_perform(next_cb : Proc(Nil)) : Nil
          super
        end

        def __saci_rescue_from(ex : Exception) : Bool
          super
        end

        def self.__saci_steps : Array(String)
          super
        end

        def __saci_run_step(name : String) : Nil
          super
        end
      end

      # Default retry decision: re-raise. `retry_on`/`discard_on` override
      # this with `previous_def` chains (see the inherited stubs above).
      def self.__saci_handle_error(ex : Exception, attempt : Int32) : Symbol
        :raise
      end

      @__saci_payload : JSON::Any = JSON::Any.new(nil)
      @__saci_completed_steps : Array(String) = [] of String
      @__saci_checkpoint_sink : Proc(Array(String), Nil)? = nil

      def __saci_run_before_enqueue : Nil
      end

      def __saci_run_after_enqueue : Nil
      end

      def __saci_run_before_perform : Nil
      end

      def __saci_run_after_perform : Nil
      end

      def __saci_run_around_enqueue(next_cb : Proc(Nil)) : Nil
        next_cb.call
      end

      def __saci_run_around_perform(next_cb : Proc(Nil)) : Nil
        next_cb.call
      end

      def __saci_rescue_from(ex : Exception) : Bool
        false
      end

      # Enqueue: around -> before -> adapter -> after -> around return.
      # Perform: around -> before -> perform -> after -> around return.
      # `before_enqueue` may raise `Saci::Job::Abort` to cancel silently.
      def __saci_run_enqueue(block : Proc(Bool)) : Bool
        accepted = false
        __saci_run_around_enqueue(-> {
          aborted = false
          begin
            __saci_run_before_enqueue
          rescue Abort
            aborted = true
          end
          unless aborted
            accepted = block.call
            __saci_run_after_enqueue if accepted
          end
        })
        accepted
      end

      def __saci_run_perform(block : Proc(Nil)) : Nil
        __saci_run_around_perform(-> {
          __saci_run_before_perform
          block.call
          __saci_run_after_perform
        })
      end

      # Method names are plain instance methods:
      #
      # ```
      # before_enqueue :audit
      # around_perform :timing
      #
      # def audit; end
      #
      # def timing(&block : -> Nil)
      #   block.call
      # end
      # ```
      #
      # `before_*` callbacks run in declaration order. `after_*` callbacks
      # run in reverse declaration order (Rails semantics). Around callbacks
      # nest first-declared outermost.
      macro before_enqueue(method)
        def __saci_run_before_enqueue : Nil
          previous_def
          {{method.id}}
        end
      end

      macro after_enqueue(method)
        def __saci_run_after_enqueue : Nil
          {{method.id}}
          previous_def
        end
      end

      macro before_perform(method)
        def __saci_run_before_perform : Nil
          previous_def
          {{method.id}}
        end
      end

      macro after_perform(method)
        def __saci_run_after_perform : Nil
          {{method.id}}
          previous_def
        end
      end

      macro around_enqueue(method)
        def __saci_run_around_enqueue(next_cb : Proc(Nil)) : Nil
          previous_def(-> { {{method.id}} { next_cb.call } })
        end
      end

      macro around_perform(method)
        def __saci_run_around_perform(next_cb : Proc(Nil)) : Nil
          previous_def(-> { {{method.id}} { next_cb.call } })
        end
      end

      # Handles `error` instead of letting it fail/discard the job. The
      # handler receives the exception and runs on the job instance:
      #
      # ```
      # rescue_from IO::Error, with: :log_io
      #
      # def log_io(ex : Exception); end
      # ```
      #
      # Handlers are checked in reverse declaration order; `retry_on` and
      # `discard_on` take precedence because they are evaluated first.
      macro rescue_from(error, **options)
        {% handler = nil %}
        {% for key in options.keys %}
          {% if ["with", "handler"].includes?(key.id.stringify) %}
            {% handler = options[key] %}
          {% end %}
        {% end %}
        {% if handler.nil? || handler.is_a?(NilLiteral) %}
          {% raise "rescue_from requires a handler: `rescue_from Error, with: :method`" %}
        {% end %}
        def __saci_rescue_from(ex : Exception) : Bool
          if ex.is_a?({{error}})
            {{handler.id}}(ex)
            true
          else
            previous_def
          end
        end
      end

      def __saci_set_payload(payload : JSON::Any) : Nil
        @__saci_payload = payload
      end

      # Parsed JSON arguments, available to callbacks and steps.
      def arguments : JSON::Any
        @__saci_payload
      end

      def __saci_set_checkpoint(steps : Array(String)?) : Nil
        @__saci_completed_steps = steps ? steps.dup : [] of String
      end

      def __saci_completed_steps : Array(String)
        @__saci_completed_steps.dup
      end

      def __saci_set_checkpoint_sink(sink : Proc(Array(String), Nil)?) : Nil
        @__saci_checkpoint_sink = sink
      end

      # Records `name` as completed. The DB adapter persists the array in
      # `saci_jobs.checkpoint`; other adapters keep it only for the current
      # execution. Idempotent.
      def checkpoint!(name : String) : Nil
        unless @__saci_completed_steps.includes?(name)
          @__saci_completed_steps << name
        end
        if sink = @__saci_checkpoint_sink
          sink.call(@__saci_completed_steps.dup)
        end
      end

      # Override in subclasses (`continuable` + `step` does this for you).
      def perform(payload : JSON::Any) : Nil
        raise "Define #{self.class}#perform(payload : JSON::Any)"
      end

      macro queue_as(name)
        {% qname = name.is_a?(SymbolLiteral) ? name.id.stringify : name %}
        def self.queue_name : String
          Saci::Job.prefixed_queue({{qname}})
        end
      end

      def self.queue_name : String
        Saci::Job.prefixed_queue("default")
      end

      # `MyJob.queue_name_prefix = "app_"` is equivalent to setting the
      # module-level prefix (Rails exposes it on the job base class).
      def self.queue_name_prefix : String?
        Saci::Job.queue_name_prefix
      end

      def self.queue_name_prefix=(value : String?) : Nil
        Saci::Job.queue_name_prefix = value
      end

      # Class-level default priority (higher runs first in the DB adapter).
      macro queue_with_priority(value)
        def self.priority : Int32
          ({{value}}).to_i32
        end
      end

      def self.priority : Int32
        0
      end

      # ```
      # class SyncJob < Saci::Job::Base
      #   unique :until_executed               # same class+payload deduped
      #   unique :while_executing, key: "sync" # one runner, duplicates queue
      # end
      # ```
      #
      # The default key is the class name plus the serialized payload; pass
      # a String/Symbol for a static key, or override
      # `self.__saci_unique_key(payload_json)` for a dynamic key.
      #
      # `:db` enforces uniqueness atomically through a unique index on the
      # held lock; other adapters use an in-memory registry (per-process).
      macro unique(mode = :until_executed, key = nil)
        {% mode_name = mode.is_a?(SymbolLiteral) ? mode.id.stringify : "" %}
        {% unless ["until_executed", "until_executing", "while_executing"].includes?(mode_name) %}
          {% raise "unique expects :until_executed, :until_executing or :while_executing" %}
        {% end %}
        def self.__saci_unique_mode : Symbol?
          {{mode}}
        end

        def self.__saci_unique_key(payload_json : String) : String
          {% if key.is_a?(NilLiteral) %}
            "#{self.name}:#{payload_json}"
          {% elsif key.is_a?(StringLiteral) %}
            {{key}}
          {% elsif key.is_a?(SymbolLiteral) %}
            {{key.id.stringify}}
          {% else %}
            ({{key}}).to_s
          {% end %}
        end
      end

      def self.__saci_unique_mode : Symbol?
        nil
      end

      def self.__saci_unique_key(payload_json : String) : String
        "#{name}:#{payload_json}"
      end

      # ```
      # class ImportJob < Saci::Job::Base
      #   continuable
      #   step :download
      #   step :parse
      #   step :persist
      #
      #   def download; end
      #
      #   def parse; end
      #
      #   def persist; end
      # end
      # ```
      #
      # Steps are no-argument instance methods; the parsed job arguments are
      # available through `arguments`. Completed step names are stored in the
      # job row by the DB adapter and skipped on the next attempt after a
      # retry or worker crash. `:inline`/`:async`/`:test` have no durable
      # checkpoint, so every execution runs all steps (inline/async retries
      # also re-run them).
      macro continuable
        def perform(payload : JSON::Any) : Nil
          __saci_run_steps(payload)
        end
      end

      macro step(name)
        {% unless name.is_a?(SymbolLiteral) %}
          {% raise "step expects a symbol method name, e.g. `step :fetch`" %}
        {% end %}
        def self.__saci_steps : Array(String)
          previous_def + [{{name.id.stringify}}]
        end

        def __saci_run_step(name : String) : Nil
          if name == {{name.id.stringify}}
            {{name.id}}
          else
            previous_def
          end
        end
      end

      def self.__saci_steps : Array(String)
        [] of String
      end

      def __saci_run_step(name : String) : Nil
        raise "Unknown continuation step #{name.inspect} for #{self.class.name}"
      end

      def __saci_run_steps(payload : JSON::Any) : Nil
        @__saci_payload = payload
        self.class.__saci_steps.each do |step_name|
          next if @__saci_completed_steps.includes?(step_name)
          __saci_run_step(step_name)
          checkpoint!(step_name)
        end
      end

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

      def self.middleware : MiddlewareChain
        Saci::Job.middleware
      end

      def self.set(wait : Time::Span? = nil,
                   queue : String | Symbol | Nil = nil,
                   priority : Int32? = nil,
                   wait_until : Time? = nil) : Setter
        Setter.new(self, wait, queue.try(&.to_s), priority, wait_until)
      end

      def self.wait_until(time : Time) : Setter
        set(wait_until: time)
      end

      def self.perform_later(payload) : Nil
        Saci::Job.enqueue(self, Saci::Job.encode(payload).to_json)
      end

      # Enqueues each payload with this class's queue/priority defaults.
      def self.perform_all_later(payloads : Array) : Nil
        payloads.each { |payload| perform_later(payload) }
      end

      def self.enqueue_all(payloads : Array) : Nil
        perform_all_later(payloads)
      end

      def self.perform_now(payload) : Nil
        execute_now(payload)
      end

      def self.execute_now(payload) : Nil
        json = payload.is_a?(String) ? JSON.parse(payload).to_json : Saci::Job.encode(payload).to_json
        Saci::Job.perform_now(self, json)
      end
    end

    # `MyJob.set(wait: 5.minutes, queue: :high, priority: 10).perform_later(args)`
    struct Setter
      def initialize(@klass : Base.class, @wait : Time::Span? = nil,
                     @queue : String? = nil, @priority : Int32? = nil,
                     @wait_until : Time? = nil)
      end

      def perform_later(payload) : Nil
        Saci::Job.enqueue(@klass, Saci::Job.encode(payload).to_json,
          wait: @wait, queue: @queue, priority: @priority, wait_until: @wait_until)
      end

      def perform_all_later(payloads : Array) : Nil
        payloads.each { |payload| perform_later(payload) }
      end

      def enqueue_all(payloads : Array) : Nil
        perform_all_later(payloads)
      end

      def perform_now(payload) : Nil
        @klass.execute_now(payload)
      end
    end

    # One item for `Saci::Job.enqueue_all` (mixed job classes/options).
    struct EnqueueRequest
      getter job_class : Base.class
      getter payload_json : String
      getter queue : String?
      getter priority : Int32?
      getter wait : Time::Span?
      getter wait_until : Time?

      def initialize(@job_class : Base.class, payload,
                     @queue : String? = nil, @priority : Int32? = nil,
                     @wait : Time::Span? = nil, @wait_until : Time? = nil)
        @payload_json = Saci::Job.encode(payload).to_json
      end
    end
  end
end
