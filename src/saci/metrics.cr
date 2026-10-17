module Saci
  # In-process operational metrics + mountable endpoint (no dependencies).
  #
  # Counters are mutex-guarded and cheap; tracking is a no-op when
  # `Saci::Metrics.enabled = false` (one lock acquisition, no allocation
  # of note). `reset!` restores a blank slate (spec isolation).
  #
  # ```
  # class ApplicationController < Saci::Controller
  #   before_action :metrics_begin
  #   after_action :metrics_record
  #
  #   @metrics_started : Time::Instant? = nil
  #
  #   private def metrics_begin
  #     @metrics_started = Time.instant
  #   end
  #
  #   private def metrics_record
  #     if started = @metrics_started
  #       Saci::Metrics.track_request(
  #         "#{self.class}##{action_name}",
  #         response.status_code,
  #         (Time.instant - started).total_milliseconds)
  #     end
  #   end
  # end
  #
  # # Jobs (decoupled — the framework never calls this itself):
  # Saci::Job.on_error { |_, _| Saci::Metrics.job_failed! }
  # # ...and call `Saci::Metrics.job_ok!` where a job completes.
  #
  # # Cache (same deal — wire around your fetch sites):
  # if hit = Saci::Cache.read("k")
  #   Saci::Metrics.cache_hit!
  # else
  #   Saci::Metrics.cache_miss!
  # end
  #
  # router = Saci::Router.new.draw do |r|
  #   # No auth built-in — mount behind your own admin gate.
  #   r.get "/metrics", Saci::Metrics::Controller, :index
  # end
  # ```
  #
  # The endpoint renders JSON by default and Prometheus text exposition
  # when `?format=prom` or `Accept: text/plain` is sent.
  module Metrics
    @@mutex = Mutex.new
    @@enabled : Bool = true
    @@requests_total : Int64 = 0_i64
    @@status_counts = {} of Int32 => Int64
    @@route_counts = {} of String => Int64
    @@route_durations_ms = {} of String => Float64
    @@jobs_ok : Int64 = 0_i64
    @@jobs_failed : Int64 = 0_i64
    @@cache_hits : Int64 = 0_i64
    @@cache_misses : Int64 = 0_i64

    def self.enabled : Bool
      @@mutex.synchronize { @@enabled }
    end

    def self.enabled=(value : Bool) : Nil
      @@mutex.synchronize { @@enabled = value }
    end

    # Blank slate (counters + `enabled = true`) for spec isolation.
    def self.reset! : Nil
      @@mutex.synchronize do
        @@enabled = true
        @@requests_total = 0_i64
        @@status_counts.clear
        @@route_counts.clear
        @@route_durations_ms.clear
        @@jobs_ok = 0_i64
        @@jobs_failed = 0_i64
        @@cache_hits = 0_i64
        @@cache_misses = 0_i64
      end
    end

    # Records one request (`route` is `"Controller#action"`). No-op (one
    # lock) when disabled.
    def self.track_request(route : String, status : Int32, elapsed_ms : Float64) : Nil
      @@mutex.synchronize do
        return unless @@enabled
        @@requests_total += 1
        @@status_counts[status] = (@@status_counts[status]? || 0_i64) + 1
        @@route_counts[route] = (@@route_counts[route]? || 0_i64) + 1
        @@route_durations_ms[route] = (@@route_durations_ms[route]? || 0.0) + elapsed_ms
      end
    end

    # Timing helper for non-controller call sites:
    # `Saci::Metrics.time("Worker#run") { work }`.
    def self.time(route : String, status : Int32 = 200, & : -> T) : T forall T
      started = Time.instant
      result = yield
      track_request(route, status, (Time.instant - started).total_milliseconds)
      result
    end

    def self.job_ok! : Nil
      @@mutex.synchronize { @@jobs_ok += 1 if @@enabled }
    end

    def self.job_failed! : Nil
      @@mutex.synchronize { @@jobs_failed += 1 if @@enabled }
    end

    def self.cache_hit! : Nil
      @@mutex.synchronize { @@cache_hits += 1 if @@enabled }
    end

    def self.cache_miss! : Nil
      @@mutex.synchronize { @@cache_misses += 1 if @@enabled }
    end

    def self.requests_total : Int64
      @@mutex.synchronize { @@requests_total }
    end

    def self.status_counts : Hash(Int32, Int64)
      @@mutex.synchronize { @@status_counts.dup }
    end

    def self.route_counts : Hash(String, Int64)
      @@mutex.synchronize { @@route_counts.dup }
    end

    # Mean tracked duration per route (`nil` when untracked).
    def self.route_avg_ms(route : String) : Float64?
      @@mutex.synchronize do
        count = @@route_counts[route]?
        total = @@route_durations_ms[route]?
        count && total ? total / count : nil
      end
    end

    def self.jobs_ok : Int64
      @@mutex.synchronize { @@jobs_ok }
    end

    def self.jobs_failed : Int64
      @@mutex.synchronize { @@jobs_failed }
    end

    def self.cache_hits : Int64
      @@mutex.synchronize { @@cache_hits }
    end

    def self.cache_misses : Int64
      @@mutex.synchronize { @@cache_misses }
    end

    # Best-effort database gauges. Never raises: `nil` when unavailable
    # (no connection, missing queue tables, unsupported adapter, ...).
    # Pending/dead come from the durable job tables; size is the SQLite
    # file bytes, `pg_database_size` on PostgreSQL, or summed table bytes
    # on MySQL.
    def self.db_info : NamedTuple(pending: Int64?, dead: Int64?, size_bytes: Int64?)
      pending = (Job::Db.pending_count rescue nil)
      dead = (Job::Db.dead_count rescue nil)
      size = (database_size_bytes rescue nil)
      {pending: pending, dead: dead, size_bytes: size}
    end

    private def self.database_size_bytes : Int64?
      db = Record.connection
      case Record.adapter_of(db)
      when :sqlite
        sqlite_file_size(db)
      when :postgres
        case v = Record.scalar_compat(db, "SELECT pg_database_size(current_database())")
        when Int64 then v
        when Int32 then v.to_i64
        else            nil
        end
      when :mysql
        case v = Record.scalar_compat(db,
          "SELECT COALESCE(SUM(data_length + index_length), 0) " \
          "FROM information_schema.tables WHERE table_schema = DATABASE()")
        when Int64 then v
        when Int32 then v.to_i64
        when UInt64 then v.to_i64
        when Float64 then v.to_i64
        else             nil
        end
      else
        nil
      end
    rescue
      nil
    end

    private def self.sqlite_file_size(db : DB::Database | DB::Connection) : Int64?
      file = nil.as(String?)
      Record.query_compat(db, "PRAGMA database_list") do |rs|
        rs.each do
          rs.read(Int64)
          rs.read(String)
          path = rs.read(String)
          file ||= path unless path.empty?
        end
      end
      file ? File.size(file) : nil
    rescue
      nil
    end

    # Full snapshot rendered by the endpoint (JSON).
    def self.snapshot_json : String
      info = db_info
      JSON.build do |json|
        json.object do
          json.field "enabled", enabled
          json.field "requests" do
            json.object do
              json.field "total", requests_total
              json.field "by_status" do
                json.object do
                  status_counts.each do |status, count|
                    json.field status.to_s, count
                  end
                end
              end
              json.field "routes" do
                json.object do
                  route_counts.each do |route, count|
                    json.field route do
                      json.object do
                        json.field "count", count
                        json.field "avg_ms", route_avg_ms(route)
                      end
                    end
                  end
                end
              end
            end
          end
          json.field "jobs" do
            json.object do
              json.field "ok", jobs_ok
              json.field "failed", jobs_failed
              json.field "pending", info[:pending]
              json.field "dead", info[:dead]
            end
          end
          json.field "cache" do
            json.object do
              json.field "hits", cache_hits
              json.field "misses", cache_misses
            end
          end
          json.field "db" do
            json.object do
              json.field "size_bytes", info[:size_bytes]
            end
          end
        end
      end
    end

    # Prometheus text exposition (`saci_*` series).
    def self.to_prometheus : String
      info = db_info
      String.build do |io|
        io << "# HELP saci_requests_total Total HTTP requests tracked.\n"
        io << "# TYPE saci_requests_total counter\n"
        io << "saci_requests_total " << requests_total << "\n"
        io << "# HELP saci_requests_by_status_total Tracked requests by HTTP status.\n"
        io << "# TYPE saci_requests_by_status_total counter\n"
        status_counts.each do |status, count|
          io << "saci_requests_by_status_total{status=\"" << status << "\"} " << count << "\n"
        end
        io << "# HELP saci_route_requests_total Tracked requests per controller action.\n"
        io << "# TYPE saci_route_requests_total counter\n"
        route_counts.each do |route, count|
          io << "saci_route_requests_total{route=\"" << prom_label(route) << "\"} " << count << "\n"
        end
        io << "# HELP saci_request_duration_ms_sum Total tracked request time per controller action.\n"
        io << "# TYPE saci_request_duration_ms_sum counter\n"
        @@mutex.synchronize { @@route_durations_ms.dup }.each do |route, total|
          io << "saci_request_duration_ms_sum{route=\"" << prom_label(route) << "\"} " << total << "\n"
        end
        io << "# HELP saci_jobs_ok_total Jobs completed without error.\n"
        io << "# TYPE saci_jobs_ok_total counter\n"
        io << "saci_jobs_ok_total " << jobs_ok << "\n"
        io << "# HELP saci_jobs_failed_total Jobs reported through the error hook.\n"
        io << "# TYPE saci_jobs_failed_total counter\n"
        io << "saci_jobs_failed_total " << jobs_failed << "\n"
        io << "# HELP saci_cache_hits_total Cache hits.\n"
        io << "# TYPE saci_cache_hits_total counter\n"
        io << "saci_cache_hits_total " << cache_hits << "\n"
        io << "# HELP saci_cache_misses_total Cache misses.\n"
        io << "# TYPE saci_cache_misses_total counter\n"
        io << "saci_cache_misses_total " << cache_misses << "\n"
        io << "# HELP saci_db_pending_jobs Rows in the durable queue table.\n"
        io << "# TYPE saci_db_pending_jobs gauge\n"
        io << "saci_db_pending_jobs " << (info[:pending] || "NaN") << "\n"
        io << "# HELP saci_db_dead_jobs Rows in the dead-letter table.\n"
        io << "# TYPE saci_db_dead_jobs gauge\n"
        io << "saci_db_dead_jobs " << (info[:dead] || "NaN") << "\n"
        io << "# HELP saci_db_size_bytes Database size in bytes.\n"
        io << "# TYPE saci_db_size_bytes gauge\n"
        io << "saci_db_size_bytes " << (info[:size_bytes] || "NaN") << "\n"
      end
    end

    private def self.prom_label(value : String) : String
      value.gsub(/["\\]/) { |m| "\\#{m}" }
    end

    def self.prometheus_format?(format_param : String?, accept : String?) : Bool
      if f = format_param.try(&.downcase)
        return true if {"prom", "prometheus", "txt", "text"}.includes?(f)
      end
      (accept || "").includes?("text/plain")
    end

    # Mountable endpoint (no auth built-in — put it behind an admin gate):
    # `r.get "/metrics", Saci::Metrics::Controller, :index`.
    class Controller < Saci::Controller
      def index
        if Saci::Metrics.prometheus_format?(params["format"]?, request.headers["Accept"]?)
          render text: Saci::Metrics.to_prometheus, content_type: "text/plain; charset=utf-8"
        else
          render text: Saci::Metrics.snapshot_json, content_type: "application/json; charset=utf-8"
        end
      end
    end
  end
end
