module Saci
  module Job
    # MissionControl-lite job dashboard (read-only stats + dead-letter ops).
    #
    # ```
    # router = Saci::Router.new.draw do |r|
    #   r.get "/saci/jobs", Saci::Job::DashboardController, :index
    #   r.get "/saci/jobs/dead", Saci::Job::DashboardController, :dead
    #   r.post "/saci/jobs/dead/:id/retry", Saci::Job::DashboardController, :retry_dead
    #   r.post "/saci/jobs/dead/:id/drop", Saci::Job::DashboardController, :drop_dead
    # end
    # ```
    #
    # Enabled by default outside production (`Dashboard.enabled = Saci.env
    # != "production"`); every action 404s when disabled. No auth is
    # built-in — mount behind an admin gate if you enable it outside
    # development (same contract as `Saci::Mailer::Preview`).
    #
    # Built only on public API (`Db.pending_count`/`dead_count`/`dead_jobs`/
    # `retry_dead`/`drop_dead` plus `Record.query_compat` for the
    # class/queue breakdown, aggregated in Ruby — no new tables). Works
    # with the `:db` adapter; any other adapter renders an empty state
    # (never a 500).
    module Dashboard
      @@mutex = Mutex.new
      @@enabled_override : Bool? = nil

      # Live env-derived default (`Saci.env != "production"`) unless
      # overridden; assign explicitly to force on/off.
      def self.enabled : Bool
        @@mutex.synchronize do
          override = @@enabled_override
          override.nil? ? Saci.env != "production" : override
        end
      end

      def self.enabled=(value : Bool) : Nil
        @@mutex.synchronize { @@enabled_override = value }
      end

      # Spec isolation: restores the env-derived `enabled` default.
      def self.reset! : Nil
        @@mutex.synchronize { @@enabled_override = nil }
      end

      def self.db_adapter? : Bool
        Job.queue_adapter == :db
      end

      alias Stats = NamedTuple(
        db_adapter: Bool,
        pending: Int64?,
        dead: Int64?,
        by_class: Hash(String, Int64),
        by_queue: Hash(String, Int64),
        oldest_pending_age: Time::Span?)

      def self.empty_stats(adapter : Bool) : Stats
        {
          db_adapter:         adapter,
          pending:            nil.as(Int64?),
          dead:               nil.as(Int64?),
          by_class:           {} of String => Int64,
          by_queue:           {} of String => Int64,
          oldest_pending_age: nil.as(Time::Span?),
        }
      end

      # Read-only snapshot. Empty state when the adapter isn't `:db`;
      # degraded (`nil` counts, empty breakdowns) rather than raising when
      # the queue tables are missing or the database is unreachable.
      def self.stats : Stats
        return empty_stats(false) unless db_adapter?
        pending = Db.pending_count
        dead = Db.dead_count
        by_class = {} of String => Int64
        by_queue = {} of String => Int64
        oldest : Time? = nil
        db = Db.target_db
        ad = Record.adapter_of(db)
        q = ->(name : String) { Record.quote(name, ad) }
        Record.query_compat(db,
          "SELECT #{q.call("job_class")}, #{q.call("queue")}, #{q.call("created_at")} " \
          "FROM #{q.call(Db::JOBS_TABLE)}") do |rs|
          rs.each do
            cls = rs.read(String)
            queue = rs.read(String)
            created = ad == :sqlite ? Record.parse_time(rs.read(String?)) : rs.read(Time?)
            by_class[cls] = (by_class[cls]? || 0_i64) + 1
            by_queue[queue] = (by_queue[queue]? || 0_i64) + 1
            if created
              o = oldest
              oldest = created if o.nil? || created < o
            end
          end
        end
        age = oldest.try { |t| Time.utc - t }
        {
          db_adapter:         true,
          pending:            pending,
          dead:               dead,
          by_class:           by_class,
          by_queue:           by_queue,
          oldest_pending_age: age,
        }
      rescue
        empty_stats(true)
      end

      def self.format_age(span : Time::Span?) : String
        return "—" if span.nil?
        total = span.total_seconds.to_i
        total = 0 if total < 0
        return "#{total}s" if total < 60
        minutes, secs = total.divmod(60)
        return "#{minutes}m #{secs}s" if minutes < 60
        hours, mins = minutes.divmod(60)
        "#{hours}h #{mins}m"
      end

      def self.empty_state_page : String
        "<!doctype html><html><head><meta charset=\"utf-8\">" \
        "<title>Job dashboard</title></head><body>" \
        "<h1>Job dashboard</h1>" \
        "<p>The job dashboard needs the <code>:db</code> queue adapter " \
        "(current: <code>#{HTML.escape(Job.queue_adapter.to_s)}</code>). " \
        "Nothing to show — set <code>Saci::Job.queue_adapter = :db</code> " \
        "to persist jobs in <code>saci_jobs</code>.</p></body></html>"
      end

      def self.index_page(s : Stats) : String
        return empty_state_page unless s[:db_adapter]
        String.build do |io|
          io << "<!doctype html><html><head><meta charset=\"utf-8\">" \
                "<title>Job dashboard</title></head><body>"
          io << "<h1>Job dashboard</h1>"
          io << "<p>Pending: <strong>" << (s[:pending]?.try(&.to_s) || "unavailable") << "</strong>"
          io << " · Dead: <strong><a href=\"/saci/jobs/dead\">" << (s[:dead]?.try(&.to_s) || "unavailable") << "</a></strong>"
          io << " · Oldest pending: " << HTML.escape(format_age(s[:oldest_pending_age]?)) << "</p>"
          io << "<h2>Pending by queue</h2>"
          io << breakdown_table(s[:by_queue])
          io << "<h2>Pending by class</h2>"
          io << breakdown_table(s[:by_class])
          io << "</body></html>"
        end
      end

      def self.dead_page(rows : Array(NamedTuple(id: Int64, job: String, attempts: Int64, error: String))) : String
        String.build do |io|
          io << "<!doctype html><html><head><meta charset=\"utf-8\">" \
                "<title>Dead jobs</title></head><body>"
          io << "<h1>Dead jobs</h1>"
          io << "<p><a href=\"/saci/jobs\">Back to dashboard</a></p>"
          if rows.empty?
            io << "<p>No dead jobs.</p>"
          else
            io << "<table><thead><tr><th>id</th><th>class</th><th>attempts</th><th>error</th><th></th><th></th></tr></thead><tbody>"
            rows.each do |row|
              io << "<tr><td>" << row[:id] << "</td>"
              io << "<td>" << HTML.escape(row[:job]) << "</td>"
              io << "<td>" << row[:attempts] << "</td>"
              io << "<td>" << HTML.escape(row[:error]) << "</td>"
              io << "<td><form method=\"post\" action=\"/saci/jobs/dead/" << row[:id] << "/retry\">" \
                    "<button type=\"submit\">Retry</button></form></td>"
              io << "<td><form method=\"post\" action=\"/saci/jobs/dead/" << row[:id] << "/drop\">" \
                    "<button type=\"submit\">Drop</button></form></td></tr>"
            end
            io << "</tbody></table>"
          end
          io << "</body></html>"
        end
      end

      private def self.breakdown_table(counts : Hash(String, Int64)) : String
        return "<p>None.</p>" if counts.empty?
        String.build do |io|
          io << "<table><thead><tr><th>name</th><th>pending</th></tr></thead><tbody>"
          counts.to_a.sort_by(&.[0]).each do |(name, count)|
            io << "<tr><td>" << HTML.escape(name) << "</td><td>" << count << "</td></tr>"
          end
          io << "</tbody></table>"
        end
      end
    end

    # Mountable dashboard UI (see `Dashboard` for routes). `index` shows
    # pending/dead counts, oldest pending age and per-queue/per-class
    # breakdowns; `dead` lists the dead-letter table; `retry_dead`/
    # `drop_dead` requeue or discard one dead row (redirecting back to
    # `dead`). All four 404 when `Dashboard.enabled` is false.
    class DashboardController < Saci::Controller
      def index
        unless Dashboard.enabled
          render text: "Not found", status: :not_found
          return
        end
        render html: Dashboard.index_page(Dashboard.stats)
      end

      def dead
        unless Dashboard.enabled
          render text: "Not found", status: :not_found
          return
        end
        unless Dashboard.db_adapter?
          render html: Dashboard.empty_state_page
          return
        end
        rows = Db.dead_jobs rescue [] of NamedTuple(id: Int64, job: String, attempts: Int64, error: String)
        render html: Dashboard.dead_page(rows)
      end

      def retry_dead
        unless Dashboard.enabled
          render text: "Not found", status: :not_found
          return
        end
        id = params["id"]?.try(&.to_i64?)
        ok = !id.nil? && Dashboard.db_adapter? && ((Db.retry_dead(id.not_nil!) rescue false))
        unless ok
          if Dashboard.db_adapter?
            render text: "No such dead job", status: :not_found
          else
            redirect_to "/saci/jobs/dead"
          end
          return
        end
        redirect_to "/saci/jobs/dead"
      end

      def drop_dead
        unless Dashboard.enabled
          render text: "Not found", status: :not_found
          return
        end
        id = params["id"]?.try(&.to_i64?)
        ok = !id.nil? && Dashboard.db_adapter? && ((Db.drop_dead(id.not_nil!) rescue false))
        unless ok
          if Dashboard.db_adapter?
            render text: "No such dead job", status: :not_found
          else
            redirect_to "/saci/jobs/dead"
          end
          return
        end
        redirect_to "/saci/jobs/dead"
      end
    end
  end
end
