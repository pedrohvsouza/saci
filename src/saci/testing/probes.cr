module Saci
  module Testing
    # Records job executions and cable broadcasts for the assertion helpers.
    # `Saci::Job` / `Saci::Cable` are reopened below with `previous_def` so
    # the production paths are unchanged.
    module Probes
      @@performed = [] of NamedTuple(job: String, payload: String)
      @@performed_mutex = Mutex.new

      @@broadcasts = [] of NamedTuple(stream: String, payload: String)
      @@broadcasts_mutex = Mutex.new

      def self.record_performed(job : String, payload : String) : Nil
        @@performed_mutex.synchronize { @@performed << {job: job, payload: payload} }
      end

      def self.performed_jobs : Array(NamedTuple(job: String, payload: String))
        @@performed_mutex.synchronize { @@performed.dup }
      end

      def self.clear_performed! : Nil
        @@performed_mutex.synchronize { @@performed.clear }
      end

      def self.record_broadcast(stream : String, payload) : Nil
        @@broadcasts_mutex.synchronize { @@broadcasts << {stream: stream, payload: encode(payload)} }
      end

      def self.broadcasts : Array(NamedTuple(stream: String, payload: String))
        @@broadcasts_mutex.synchronize { @@broadcasts.dup }
      end

      def self.clear_broadcasts! : Nil
        @@broadcasts_mutex.synchronize { @@broadcasts.clear }
      end

      def self.encode(payload) : String
        payload.to_json
      rescue
        payload.to_s
      end

      def self.reset! : Nil
        clear_performed!
        clear_broadcasts!
      end
    end
  end
end

module Saci
  module Job
    # Count one logical execution. Retries inside `execute_guarded` do not
    # reach the observer again, so a job that retries still counts once.
    # (`Saci::Job.execute` binds internally before this shelf is loaded, so a
    # `previous_def` reopen would not see inline runs; the observer hook is
    # the supported integration point.)
    Saci::Job.perform_observer = ->(job_class : Saci::Job::Base.class, payload : String, attempt : Int32) do
      Saci::Testing::Probes.record_performed(job_class.name, payload)
      nil
    end
  end
end

class Saci::Job::Base
  # `perform_now` records through `Saci::Job.perform_observer` (see above);
  # no reopen needed here.
end

class Saci::Cable::Server
  def broadcast(stream : String, payload) : Nil
    Saci::Testing::Probes.record_broadcast(stream, payload)
    previous_def
  end

  # Names of streams with at least one active subscriber (used by
  # `assert_has_stream`).
  def stream_names : Array(String)
    @mutex.synchronize do
      @streams.select { |_, subscriptions| !subscriptions.empty? }.keys.sort
    end
  end

  def has_stream?(stream : String) : Bool
    @mutex.synchronize do
      subscriptions = @streams[stream]?
      subscriptions ? !subscriptions.empty? : false
    end
  end
end

class Saci::Cable::RedisServer
  # `RedisServer` overrides `broadcast`; record before its local+remote
  # fan-out so `assert_broadcasts` sees one entry per call.
  def broadcast(stream : String, payload) : Nil
    Saci::Testing::Probes.record_broadcast(stream, payload)
    previous_def
  end
end
