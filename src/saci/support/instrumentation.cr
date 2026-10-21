require "./notifications"
require "./current_attributes"

# Framework instrumentation hooks. This file reopens framework classes so it
# must be required after `saci` itself (the coordinator adds it at the end of
# `src/saci.cr`; specs require it explicitly).
#
# Events are published manually (rather than through `Notifications.instrument`)
# around `previous_def` calls to keep Crystal's method-reopening machinery
# simple and predictable.
module Saci
  class Router
    # Wraps controller dispatch with:
    # * `process_action.saci` notifications (controller class + action),
    # * request-scoped `Current` attributes,
    # * an optional per-request zone (`X-Time-Zone` header or `time_zone`
    #   param), which is restored after the action.
    private def dispatch(controller : Controller.class, action : Symbol, ctx : HTTP::Server::Context, params : Params) : Nil
      request_id = ctx.request.headers["X-Request-Id"]?
      zone_name = ctx.request.headers["X-Time-Zone"]? || params["time_zone"]?
      zone = zone_name ? Saci::TimeZone.find?(zone_name) : nil

      payload = Saci::Notifications::Payload{
        "controller" => controller.name,
        "action"     => action.to_s,
        "method"     => ctx.request.method,
        "path"       => ctx.request.path || "/",
      }

      Saci::Current.reset
      Saci::Current.request = ctx
      Saci::Current.request_id = request_id if request_id
      Saci::Current.locale = Saci::I18n.locale
      Saci::Current.time_zone = zone.name if zone

      started = Time.instant
      begin
        if zone
          Saci::TimeZone.with_zone(zone) { previous_def }
        else
          previous_def
        end
      rescue ex
        payload["exception"] = ex.class.name
        payload["exception_message"] = ex.message
        raise ex
      ensure
        Saci::Notifications.publish("process_action.saci", payload, (Time.instant - started).total_milliseconds)
        Saci::Current.reset
      end
    end
  end

  module Job
    # `perform.saci` / `enqueue.saci` (Active Job style names with the Saci
    # suffix). Payload includes the job class and queue.
    def self.enqueue(job_class : Base.class, payload_json : String,
                     wait : Time::Span? = nil, queue : String? = nil,
                     priority : Int32? = nil, wait_until : Time? = nil,
                     batch_id : String? = nil, unique_mode : Symbol? = nil,
                     unique_key : String? = nil) : Nil
      started = Time.instant
      payload = Saci::Notifications::Payload{
        "job"   => job_class.name,
        "queue" => job_class.queue_name,
      }
      begin
        previous_def(job_class, payload_json, wait, queue, priority, wait_until,
          batch_id, unique_mode, unique_key)
      ensure
        Saci::Notifications.publish("enqueue.saci", payload, (Time.instant - started).total_milliseconds)
      end
    end

    # `perform.saci` is published through the job observer hook (calls inside
    # `job.cr` bind before reopens, so a `previous_def` override would miss
    # inline executions).
    Saci::Job.add_perform_observer ->(job_class : Base.class, payload_json : String, attempt : Int32) do
      Saci::Notifications.publish("perform.saci", Saci::Notifications::Payload{
        "job"     => job_class.name,
        "queue"   => job_class.queue_name,
        "attempt" => attempt,
      }, 0.0)
      nil
    end
  end

  module Mailer
    class Mail
      # `deliver.saci` wraps actual delivery; `deliver_later` goes through the
      # job adapter and therefore emits `enqueue.saci`/`perform.saci` too.
      def deliver_now : Nil
        started = Time.instant
        payload = Saci::Notifications::Payload{
          "mailer"  => "Saci::Mailer::Mail",
          "to"      => @to.join(","),
          "from"    => @from,
          "subject" => @subject,
        }
        begin
          previous_def
        rescue ex
          payload["exception"] = ex.class.name
          payload["exception_message"] = ex.message
          raise ex
        ensure
          Saci::Notifications.publish("deliver.saci", payload, (Time.instant - started).total_milliseconds)
        end
      end
    end
  end

  module Record
    # `sql.saci` events around writes and reads. `exec_compat`/`query_compat`
    # are the single placeholders-normalizing choke points, so wrapping them
    # covers the ORM without touching every call site.
    def self.exec_compat(db : DB::Database | DB::Connection, sql : String, args : Array(Value) = [] of Value) : DB::ExecResult
      started = Time.instant
      begin
        result = previous_def
        Saci::Notifications.publish("sql.saci", Saci::Notifications::Payload{
          "sql"     => sql,
          "adapter" => adapter_of(db).to_s,
          "binds"   => args.size,
        }, (Time.instant - started).total_milliseconds)
        result
      rescue ex
        Saci::Notifications.publish("sql.saci", Saci::Notifications::Payload{
          "sql"     => sql,
          "adapter" => adapter_of(db).to_s,
          "binds"   => args.size,
        }, (Time.instant - started).total_milliseconds)
        raise ex
      end
    end

    def self.query_compat(db : DB::Database | DB::Connection, sql : String, args : Array(Value) = [] of Value, &block : DB::ResultSet ->) : Nil
      started = Time.instant
      begin
        previous_def(db, sql, args) { |rs| block.call(rs) }
      ensure
        Saci::Notifications.publish("sql.saci", Saci::Notifications::Payload{
          "sql"     => sql,
          "adapter" => adapter_of(db).to_s,
          "binds"   => args.size,
        }, (Time.instant - started).total_milliseconds)
      end
    end
  end
end
