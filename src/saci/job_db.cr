module Saci
  module Job
    # Durable queue state. `Job.register`/`lookup` map persisted class names
    # back to classes (Crystal has no runtime constantize, so every job
    # subclass self-registers through `Base.inherited`).
    @@registry = {} of String => Base.class
    @@registry_mutex = Mutex.new

    def self.register(name : String, klass : Base.class) : Nil
      @@registry_mutex.synchronize { @@registry[name] = klass }
    end

    def self.lookup(name : String)
      @@registry_mutex.synchronize { @@registry[name]? }
    end

    def self.registered_jobs : Array(String)
      @@registry_mutex.synchronize { @@registry.keys.sort }
    end

    # Database-backed durable queue (`queue_adapter = :db`).
    #
    # ```
    # Saci::Job.queue_adapter = :db
    # Saci::Job::Db.ensure_schema!          # CREATE TABLE IF NOT EXISTS
    # WelcomeJob.perform_later({user_id: 1}) # INSERT, survives restarts
    # Saci::Job::Db.drain                   # run everything due, inline
    #
    # # …or supervise in your server process (entrypoint):
    # spawn do
    #   loop do
    #     Saci::Job::Db.work_once
    #     sleep 1.second
    #   end
    # end
    # ```
    #
    # Semantics: at-least-once. Claims are arbitrated by a conditional
    # UPDATE (correct on SQLite/PostgreSQL/MySQL without row locks); crashed
    # workers' rows are reclaimed after `lock_timeout`, so jobs MUST be
    # idempotent — same contract as every other queue. Retries reuse the
    # job's own `retry_on` rules (sleeps happen in the job's fiber, bounded
    # by `concurrency`); final failures land in `saci_dead_jobs` with their
    # error, and are reported through `Job.on_error` exactly once.
    module Db
      JOBS_TABLE = "saci_jobs"
      DEAD_TABLE = "saci_dead_jobs"

      @@db : DB::Database? = nil
      @@concurrency : Int32 = 5
      @@lock_timeout : Time::Span = 10.minutes
      @@running : Int32 = 0
      @@mutex = Mutex.new
      @@worker_id : String? = nil

      # Explicit database (defaults to `Record.connection`, i.e. primary).
      def self.configure(db : DB::Database? = nil, concurrency : Int32 = 5, lock_timeout : Time::Span = 10.minutes) : Nil
        @@mutex.synchronize do
          @@db = db
          @@concurrency = concurrency
          @@lock_timeout = lock_timeout
        end
      end

      def self.target_db : DB::Database
        @@mutex.synchronize { @@db } || Record.connection.as(DB::Database)
      end

      def self.concurrency : Int32
        @@mutex.synchronize { @@concurrency }
      end

      def self.lock_timeout : Time::Span
        @@mutex.synchronize { @@lock_timeout }
      end

      def self.worker_id : String
        @@mutex.synchronize { @@worker_id ||= Random::Secure.hex(8) }
      end

      # Creates the queue tables when missing. Safe to call at boot and
      # before every enqueue (which does so itself).
      def self.ensure_schema!(db : DB::Database = target_db) : Nil
        ad = Record.adapter_of(db)
        q = ->(name : String) { Record.quote(name, ad) }
        id_def = case ad
                 when :postgres then "#{q.call("id")} BIGSERIAL PRIMARY KEY"
                 when :mysql    then "#{q.call("id")} BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY"
                 else                "#{q.call("id")} INTEGER PRIMARY KEY AUTOINCREMENT"
                 end
        ts = Record.db_type(:datetime, ad)
        big = Record.db_type(:bigint, ad)
        Record.exec_compat(db, <<-SQL)
          CREATE TABLE IF NOT EXISTS #{q.call(JOBS_TABLE)} (
            #{id_def},
            #{q.call("job_class")} VARCHAR(255) NOT NULL,
            #{q.call("payload")} TEXT NOT NULL,
            #{q.call("queue")} VARCHAR(255) NOT NULL DEFAULT 'default',
            #{q.call("run_at")} #{ts} NOT NULL,
            #{q.call("attempts")} #{big} NOT NULL DEFAULT 0,
            #{q.call("locked_by")} VARCHAR(255),
            #{q.call("locked_at")} #{ts},
            #{q.call("last_error")} TEXT,
            #{q.call("created_at")} #{ts} NOT NULL
          )
          SQL
        Record.exec_compat(db, <<-SQL)
          CREATE TABLE IF NOT EXISTS #{q.call(DEAD_TABLE)} (
            #{id_def},
            #{q.call("job_class")} VARCHAR(255) NOT NULL,
            #{q.call("payload")} TEXT NOT NULL,
            #{q.call("queue")} VARCHAR(255) NOT NULL DEFAULT 'default',
            #{q.call("attempts")} #{big} NOT NULL DEFAULT 0,
            #{q.call("error")} TEXT NOT NULL,
            #{q.call("failed_at")} #{ts} NOT NULL
          )
          SQL
      end

      struct Row
        getter id : Int64
        getter class_name : String
        getter payload : String
        getter queue : String
        getter attempts : Int64

        def initialize(@id, @class_name, @payload, @queue, @attempts)
        end
      end

      # Persists one job for execution at `run_at`. Returns the row id.
      def self.enqueue(class_name : String, queue : String, payload_json : String, run_at : Time = Time.utc) : Int64
        db = target_db
        ensure_schema!(db)
        ad = Record.adapter_of(db)
        now = Time.utc
        if ad == :postgres
          new_id = [] of Int64
          Record.query_compat(db,
            "INSERT INTO #{Record.quote(JOBS_TABLE, ad)} " \
            "(#{Record.quote("job_class", ad)}, #{Record.quote("payload", ad)}, #{Record.quote("queue", ad)}, " \
            "#{Record.quote("run_at", ad)}, #{Record.quote("attempts", ad)}, #{Record.quote("created_at", ad)}) " \
            "VALUES (?, ?, ?, ?, ?, ?) RETURNING #{Record.quote("id", ad)}",
            [class_name, payload_json, queue,
             ts(run_at, ad), 0_i64, ts(now, ad)] of Saci::Record::Value) do |rs|
            rs.each { new_id << rs.read(Int64) }
          end
          new_id.first
        else
          res = Record.exec_compat(db,
            "INSERT INTO #{Record.quote(JOBS_TABLE, ad)} " \
            "(#{Record.quote("job_class", ad)}, #{Record.quote("payload", ad)}, #{Record.quote("queue", ad)}, " \
            "#{Record.quote("run_at", ad)}, #{Record.quote("attempts", ad)}, #{Record.quote("created_at", ad)}) " \
            "VALUES (?, ?, ?, ?, ?, ?)",
            [class_name, payload_json, queue,
             ts(run_at, ad), 0_i64, ts(now, ad)] of Saci::Record::Value)
          res.last_insert_id
        end
      end

      # Claims due jobs (up to free concurrency slots) and runs each in its
      # own fiber. Returns the number claimed. Non-blocking.
      def self.work_once(db : DB::Database = target_db) : Int32
        slots = concurrency - running_count
        return 0 if slots <= 0
        claimed = 0
        slots.times do
          row = claim_one(db)
          break unless row
          claimed += 1
          running_increment
          spawn do
            begin
              run_claimed(db, row)
            rescue ex
              # run_claimed dead-letters internally; this is last-resort.
              Job.report_error(row.class_name, ex)
            ensure
              running_decrement
            end
          end
        end
        claimed
      end

      # Claims due jobs and runs them inline until none remain. Returns the
      # number completed. Deterministic — the spec- and script-friendly path.
      def self.drain(db : DB::Database = target_db) : Int32
        done = 0
        while row = claim_one(db)
          run_claimed(db, row)
          done += 1
        end
        done
      end

      def self.pending_count(db : DB::Database = target_db) : Int64
        ad = Record.adapter_of(db)
        Record.scalar_compat(db, "SELECT COUNT(*) FROM #{Record.quote(JOBS_TABLE, ad)}").as(Int64)
      end

      def self.dead_count(db : DB::Database = target_db) : Int64
        ad = Record.adapter_of(db)
        Record.scalar_compat(db, "SELECT COUNT(*) FROM #{Record.quote(DEAD_TABLE, ad)}").as(Int64)
      end

      # Newest-first dead-letter listing for ops inspection.
      def self.dead_jobs(db : DB::Database = target_db, limit : Int32 = 50) : Array(NamedTuple(id: Int64, job: String, attempts: Int64, error: String))
        ad = Record.adapter_of(db)
        rows = [] of NamedTuple(id: Int64, job: String, attempts: Int64, error: String)
        Record.query_compat(db,
          "SELECT #{Record.quote("id", ad)}, #{Record.quote("job_class", ad)}, " \
          "#{Record.quote("attempts", ad)}, #{Record.quote("error", ad)} " \
          "FROM #{Record.quote(DEAD_TABLE, ad)} ORDER BY #{Record.quote("id", ad)} DESC LIMIT #{limit.to_i}") do |rs|
          rs.each do
            rows << {id: rs.read(Int64), job: rs.read(String), attempts: rs.read(Int64), error: rs.read(String)}
          end
        end
        rows
      end

      # Requeues a dead job for immediate execution. Returns false when missing.
      def self.retry_dead(id : Int64, db : DB::Database = target_db) : Bool
        ad = Record.adapter_of(db)
        found = [] of NamedTuple(class_name: String, payload: String, queue: String)
        Record.query_compat(db,
          "SELECT #{Record.quote("job_class", ad)}, #{Record.quote("payload", ad)}, #{Record.quote("queue", ad)} " \
          "FROM #{Record.quote(DEAD_TABLE, ad)} WHERE #{Record.quote("id", ad)} = ?",
          [id] of Saci::Record::Value) do |rs|
          rs.each { found << {class_name: rs.read(String), payload: rs.read(String), queue: rs.read(String)} }
        end
        return false if found.empty?
        row = found.first
        enqueue(row[:class_name], row[:queue], row[:payload], Time.utc)
        Record.exec_compat(db,
          "DELETE FROM #{Record.quote(DEAD_TABLE, ad)} WHERE #{Record.quote("id", ad)} = ?", [id] of Saci::Record::Value)
        true
      end

      # Drops a dead job without running it. Returns false when missing.
      def self.drop_dead(id : Int64, db : DB::Database = target_db) : Bool
        ad = Record.adapter_of(db)
        res = Record.exec_compat(db,
          "DELETE FROM #{Record.quote(DEAD_TABLE, ad)} WHERE #{Record.quote("id", ad)} = ?", [id] of Saci::Record::Value)
        res.rows_affected > 0
      end

      # Empties both tables (spec isolation).
      def self.clear_all!(db : DB::Database = target_db) : Nil
        ad = Record.adapter_of(db)
        ensure_schema!(db)
        Record.exec_compat(db, "DELETE FROM #{Record.quote(JOBS_TABLE, ad)}")
        Record.exec_compat(db, "DELETE FROM #{Record.quote(DEAD_TABLE, ad)}")
      end

      private def self.running_count : Int32
        @@mutex.synchronize { @@running }
      end

      private def self.running_increment : Nil
        @@mutex.synchronize { @@running += 1 }
      end

      private def self.running_decrement : Nil
        @@mutex.synchronize { @@running -= 1 }
      end

      # Timestamp bind with full precision. SQLite stores text, so whole
      # seconds would erase sub-second scheduling/lock margins — fixed-width
      # fractional RFC3339 keeps lexicographic order exact. Native drivers
      # bind Time objects directly.
      private def self.ts(time : Time, adapter : Saci::Record::Adapter) : Saci::Record::Value
        adapter == :sqlite ? time.to_rfc3339(fraction_digits: 9) : Record.to_db(time, adapter)
      end

      # Atomically claims the oldest due, unlocked (or stale-locked) row.
      # The conditional UPDATE is the arbiter, so concurrent workers —
      # even across processes — never double-claim.
      private def self.claim_one(db : DB::Database) : Row?
        ad = Record.adapter_of(db)
        now = Time.utc
        cutoff = now - lock_timeout
        ids = [] of Int64
        Record.query_compat(db,
          "SELECT #{Record.quote("id", ad)} FROM #{Record.quote(JOBS_TABLE, ad)} " \
          "WHERE (#{Record.quote("locked_by", ad)} IS NULL OR #{Record.quote("locked_at", ad)} < ?) " \
          "AND #{Record.quote("run_at", ad)} <= ? " \
          "ORDER BY #{Record.quote("run_at", ad)} ASC, #{Record.quote("id", ad)} ASC LIMIT 1",
          [ts(cutoff, ad), ts(now, ad)] of Saci::Record::Value) do |rs|
          rs.each { ids << rs.read(Int64) }
        end
        return nil if ids.empty?
        id = ids.first
        claimed = Record.exec_compat(db,
          "UPDATE #{Record.quote(JOBS_TABLE, ad)} " \
          "SET #{Record.quote("locked_by", ad)} = ?, #{Record.quote("locked_at", ad)} = ? " \
          "WHERE #{Record.quote("id", ad)} = ? " \
          "AND (#{Record.quote("locked_by", ad)} IS NULL OR #{Record.quote("locked_at", ad)} < ?)",
          [worker_id, ts(now, ad), id, ts(cutoff, ad)] of Saci::Record::Value)
        return nil if claimed.rows_affected == 0
        class_name = ""
        payload = ""
        queue = "default"
        attempts = 0_i64
        Record.query_compat(db,
          "SELECT #{Record.quote("job_class", ad)}, #{Record.quote("payload", ad)}, " \
          "#{Record.quote("queue", ad)}, #{Record.quote("attempts", ad)} " \
          "FROM #{Record.quote(JOBS_TABLE, ad)} WHERE #{Record.quote("id", ad)} = ?",
          [id] of Saci::Record::Value) do |rs|
          rs.each do
            class_name = rs.read(String)
            payload = rs.read(String)
            queue = rs.read(String)
            attempts = rs.read(Int64)
          end
        end
        attempt = attempts + 1
        Record.exec_compat(db,
          "UPDATE #{Record.quote(JOBS_TABLE, ad)} SET #{Record.quote("attempts", ad)} = ? " \
          "WHERE #{Record.quote("id", ad)} = ?", [attempt, id] of Saci::Record::Value)
        Row.new(id, class_name, payload, queue, attempt)
      end

      # Runs one claimed row to a terminal state. Never raises: success and
      # discards delete the row, final failures dead-letter it. (`execute`
      # already reports discards and final failures through `on_error`.)
      private def self.run_claimed(db : DB::Database, row : Row) : Nil
        klass = Job.lookup(row.class_name)
        unless klass
          dead_letter(db, row, "unknown job class #{row.class_name.inspect}")
          Job.report_error(row.class_name, Exception.new("unknown job class"))
          return
        end
        begin
          Job.execute(klass, row.payload, row.attempts.to_i32)
          delete_row(db, row.id)
        rescue ex
          dead_letter(db, row, "#{ex.class}: #{ex.message}")
        end
      rescue ex
        begin
          dead_letter(db, row, "#{ex.class}: #{ex.message}")
        rescue
          # The row stays locked for `lock_timeout`, then is reclaimed.
        end
      end

      private def self.delete_row(target : DB::Database | DB::Connection, id : Int64) : Nil
        ad = Record.adapter_of(target)
        Record.exec_compat(target,
          "DELETE FROM #{Record.quote(JOBS_TABLE, ad)} WHERE #{Record.quote("id", ad)} = ?", [id] of Saci::Record::Value)
      end

      private def self.dead_letter(db : DB::Database, row : Row, error : String) : Nil
        ad = Record.adapter_of(db)
        Record.transaction_on(db) do |conn|
          Record.exec_compat(conn,
            "INSERT INTO #{Record.quote(DEAD_TABLE, ad)} " \
            "(#{Record.quote("job_class", ad)}, #{Record.quote("payload", ad)}, #{Record.quote("queue", ad)}, " \
            "#{Record.quote("attempts", ad)}, #{Record.quote("error", ad)}, #{Record.quote("failed_at", ad)}) " \
            "VALUES (?, ?, ?, ?, ?, ?)",
            [row.class_name, row.payload, row.queue, row.attempts,
             error, ts(Time.utc, ad)] of Saci::Record::Value)
          delete_row(conn, row.id)
        end
      end
    end
  end
end
