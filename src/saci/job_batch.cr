require "mutex"

module Saci
  module Job
    # Lightweight job batch: every job enqueued through the batch carries
    # its id, and the callback runs once all jobs have reached a terminal
    # state (success or failure).
    #
    # ```
    # batch = Saci::Job::Batch.new("import-42", total: 3) do |b|
    #   ImportReportJob.perform_later({batch: b.id})
    # end
    # 3.times { |i| batch.enqueue(ImportRowJob, {row: i}) }
    # ```
    #
    # With `total:` the batch is closed immediately; without it, call
    # `close` after the last `enqueue`.
    #
    # Tracking is **in-process**: the registry lives in the process that
    # created the Batch. That is enough for `:inline`/`:async` and for a
    # `:db` drain in the same process. A durable multi-process batch would
    # need the batch counter in the database; this intentionally stays a
    # small convenience rather than a second queue schema. If the process
    # restarts before completion the callback is not replayed.
    class Batch
      @@registry = {} of String => Batch
      @@mutex = Mutex.new

      getter id : String
      getter completed : Int32
      getter failed : Int32
      getter total : Int32

      def initialize(name : String? = nil, total : Int32? = nil, &@on_complete : Batch ->)
        @id = name || "batch-#{Random::Secure.hex(8)}"
        @total = total || 0
        @completed = 0
        @failed = 0
        @closed = !total.nil?
        if @total < 0
          raise ArgumentError.new("Saci::Job::Batch total must be >= 0")
        end
        @@mutex.synchronize do
          if @@registry.has_key?(@id)
            raise ArgumentError.new("Saci::Job::Batch #{@id.inspect} already exists")
          end
          @@registry[@id] = self
        end
      end

      # Enqueues a job as a member of this batch. Returns normally when the
      # job was accepted; duplicate suppression follows the job's own
      # `unique` rules.
      def enqueue(job_class : Base.class, payload,
                  wait : Time::Span? = nil,
                  queue : String | Symbol | Nil = nil,
                  priority : Int32? = nil,
                  wait_until : Time? = nil) : Nil
        Batch.__track_enqueue(self)
        Job.enqueue(job_class, Job.encode(payload).to_json,
          wait: wait, queue: queue.try(&.to_s), priority: priority,
          wait_until: wait_until, batch_id: @id)
      end

      # Marks a dynamic (`total:` omitted) batch complete; no more members
      # are expected. Idempotent.
      def close : Nil
        callback = Batch.__close(self)
        Batch.__run_callback(callback, self)
      end

      def closed? : Bool
        @@mutex.synchronize { @closed }
      end

      def done? : Bool
        @@mutex.synchronize { __done_locked? }
      end

      def to_s(io : IO) : Nil
        io << "#<Saci::Job::Batch " << @id << " " << @completed << "/" << @total << ">"
      end

      # Registry lookup (mainly for tests/ops).
      def self.find(id : String) : Batch?
        @@mutex.synchronize { @@registry[id]? }
      end

      def self.batches : Array(Batch)
        @@mutex.synchronize { @@registry.values.dup }
      end

      def self.reset! : Nil
        @@mutex.synchronize { @@registry.clear }
      end

      # Called by adapters after a member job reaches a terminal state.
      def self.__job_finished(batch_id : String?, failed : Bool = false) : Nil
        return if batch_id.nil?
        callback : Proc(Batch, Nil)? = nil
        batch : Batch? = nil
        @@mutex.synchronize do
          if found = @@registry[batch_id]?
            if failed
              found.__mark_failed
            else
              found.__mark_completed
            end
            if found.__done_locked?
              @@registry.delete(batch_id)
              callback = found.@on_complete
              batch = found
            end
          end
        end
        if callback && batch
          begin
            callback.call(batch)
          rescue ex
            Job.report_error("batch:#{batch_id}", ex)
          end
        end
      end

      # Adds one expected member for a dynamic batch. Fixed-size batches
      # keep their declared `total`; enqueue exactly that many members.
      protected def self.__track_enqueue(batch : Batch) : Nil
        @@mutex.synchronize do
          batch.__increment_total unless batch.@closed
        end
      end

      protected def self.__close(batch : Batch) : Proc(Batch, Nil)?
        callback : Proc(Batch, Nil)? = nil
        @@mutex.synchronize do
          batch.__mark_closed
          if batch.__done_locked? && @@registry.delete(batch.id)
            callback = batch.@on_complete
          end
        end
        callback
      end

      protected def self.__run_callback(callback : Proc(Batch, Nil)?, batch : Batch) : Nil
        return if callback.nil?
        callback.not_nil!.call(batch)
      rescue ex
        Job.report_error("batch:#{batch.id}", ex)
      end

      protected def __increment_total : Nil
        @total += 1
      end

      protected def __mark_closed : Nil
        @closed = true
      end

      protected def __mark_completed : Nil
        @completed += 1
      end

      protected def __mark_failed : Nil
        @failed += 1
      end

      protected def __done_locked? : Bool
        @closed && @completed + @failed >= @total
      end
    end
  end
end
