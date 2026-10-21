require "digest/sha256"

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
    # Saci::Job::Db.ensure_schema!           # CREATE TABLE IF NOT EXISTS
    # WelcomeJob.perform_later({user_id: 1}) # INSERT, survives restarts
    # Saci::Job::Db.drain                    # run everything due, inline
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
    # Semantics and features:
    # * at-least-once; jobs MUST be idempotent. Claims are arbitrated by
    #   `SELECT … FOR UPDATE SKIP LOCKED` on PostgreSQL/MySQL, with the
    #   conditional-UPDATE fallback on SQLite (which serializes writers).
    # * `priority DESC, run_at ASC, id ASC` claim order. Higher priority
    #   runs first.
    # * retries reuse the job's own `retry_on` rules (sleeps happen in the
    #   job's fiber, bounded by `concurrency`); final failures land in
    #   `saci_dead_jobs` with their error and are reported once through
    #   `Job.on_error`.
    # * `unique:` jobs are enforced atomically by a unique index on
    #   `unique_lock`; `until_executing` releases the lock on claim and
    #   `while_executing` sets it on claim.
    # * continuation checkpoints are persisted in `checkpoint` (JSON array)
    #   after every completed step, so a retry/crashed worker resumes at the
    #   next step.
    # * process supervision rows (`saci_job_processes`) record worker id,
    #   host, pid, queues and a heartbeat; `prune_processes!` removes stale
    #   workers.
    module Db
      JOBS_TABLE    = "saci_jobs"
      DEAD_TABLE    = "saci_dead_jobs"
      PROCESS_TABLE = "saci_job_processes"

      @@db : DB::Database? = nil
      @@concurrency : Int32 = 5
      @@lock_timeout : Time::Span = 10.minutes
      @@running : Int32 = 0
      @@mutex = Mutex.new
      @@worker_id : String? = nil
      @@queues : Array(String)? = nil
      @@enqueue_after_commit : Bool = false

      # Explicit database (defaults to `Record.connection`, i.e. primary).
      # `queues:` restricts `drain`/`work_once` to those queue names when no
      # per-call queue selector is given. `enqueue_after_transaction_commit:`
      # defers DB enqueues until the surrounding `Record.transaction` commits.
      def self.configure(db : DB::Database? = nil,
                         concurrency : Int32 = 5,
                         lock_timeout : Time::Span = 10.minutes,
                         worker_id : String? = nil,
                         queues : Array(String)? = nil,
                         enqueue_after_transaction_commit : Bool? = nil) : Nil
        @@mutex.synchronize do
          @@db = db
          @@concurrency = concurrency
          @@lock_timeout = lock_timeout
          @@worker_id = worker_id if worker_id
          @@queues = queues
          @@enqueue_after_commit = enqueue_after_transaction_commit unless enqueue_after_transaction_commit.nil?
        end
      end

      def self.target_db : DB::Database
        configured = @@mutex.synchronize { @@db }
        return configured if configured
        connection = Record.connection
        if connection.is_a?(DB::Connection)
          # Inside a `Record.transaction`, `Record.connection` is the
          # transaction handle; queue writes must use its owning database.
          Record.tx_database_for(connection) || Record.database(Record.current_database_name)
        else
          connection
        end
      end

      def self.concurrency : Int32
        @@mutex.synchronize { @@concurrency }
      end

      def self.lock_timeout : Time::Span
        @@mutex.synchronize { @@lock_timeout }
      end

      def self.queues : Array(String)?
        @@mutex.synchronize { @@queues }
      end

      def self.enqueue_after_transaction_commit? : Bool
        @@mutex.synchronize { @@enqueue_after_commit }
      end

      def self.enqueue_after_transaction_commit=(value : Bool) : Nil
        @@mutex.synchronize { @@enqueue_after_commit = value }
      end

      def self.worker_id : String
        @@mutex.synchronize { @@worker_id ||= Random::Secure.hex(8) }
      end

      def self.worker_id=(value : String) : Nil
        @@mutex.synchronize { @@worker_id = value }
      end

      # Creates the queue tables (and adds columns/indexes to older queue
      # schemas). Safe to call at boot and before every enqueue (which does
      # so itself).
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
            #{q.call("priority")} #{big} NOT NULL DEFAULT 0,
            #{q.call("locked_by")} VARCHAR(255),
            #{q.call("locked_at")} #{ts},
            #{q.call("last_error")} TEXT,
            #{q.call("unique_mode")} VARCHAR(32),
            #{q.call("unique_key")} VARCHAR(64),
            #{q.call("unique_lock")} VARCHAR(64),
            #{q.call("checkpoint")} TEXT,
            #{q.call("batch_id")} VARCHAR(255),
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
        ensure_process_schema!(db)

        # Upgrade queues created by older Saci versions.
        ensure_column!(db, JOBS_TABLE, "priority", "#{big} NOT NULL DEFAULT 0", ad)
        ensure_column!(db, JOBS_TABLE, "unique_mode", "VARCHAR(32)", ad)
        ensure_column!(db, JOBS_TABLE, "unique_key", "VARCHAR(64)", ad)
        ensure_column!(db, JOBS_TABLE, "unique_lock", "VARCHAR(64)", ad)
        ensure_column!(db, JOBS_TABLE, "checkpoint", "TEXT", ad)
        ensure_column!(db, JOBS_TABLE, "batch_id", "VARCHAR(255)", ad)

        # Multiple NULLs are allowed by SQLite/PostgreSQL/MySQL unique
        # indexes, so the same index enforces all three uniqueness modes:
        # only a held lock occupies the key.
        ensure_index!(db, JOBS_TABLE, "idx_saci_jobs_unique_lock", ["unique_lock"], ad, unique: true)
        ensure_index!(db, JOBS_TABLE, "idx_saci_jobs_claim", ["priority", "run_at"], ad)
        ensure_index!(db, JOBS_TABLE, "idx_saci_jobs_queue", ["queue", "run_at"], ad)
      end

      private def self.ensure_process_schema!(db : DB::Database) : Nil
        ad = Record.adapter_of(db)
        q = ->(name : String) { Record.quote(name, ad) }
        ts = Record.db_type(:datetime, ad)
        big = Record.db_type(:bigint, ad)
        Record.exec_compat(db, <<-SQL)
          CREATE TABLE IF NOT EXISTS #{q.call(PROCESS_TABLE)} (
            #{q.call("worker_id")} VARCHAR(128) PRIMARY KEY,
            #{q.call("hostname")} VARCHAR(255) NOT NULL,
            #{q.call("pid")} #{big} NOT NULL,
            #{q.call("queues")} TEXT,
            #{q.call("started_at")} #{ts} NOT NULL,
            #{q.call("heartbeat_at")} #{ts} NOT NULL
          )
          SQL
      end

      private def self.ensure_column!(db : DB::Database, table : String, column : String,
                                      definition : String, ad : Saci::Record::Adapter) : Nil
        return if column_exists?(db, table, column, ad)
        Record.exec_compat(db,
          "ALTER TABLE #{Record.quote(table, ad)} ADD COLUMN #{Record.quote(column, ad)} #{definition}")
      end

      private def self.column_exists?(db : DB::Database, table : String, column : String,
                                      ad : Saci::Record::Adapter) : Bool
        case ad
        when :sqlite
          found = false
          Record.query_compat(db, "PRAGMA table_info(#{Record.quote(table, ad)})") do |rs|
            rs.each do
              rs.read(Int64)         # cid
              name = rs.read(String) # name
              rs.read(String)        # type
              rs.read(Int64?)        # notnull
              rs.read(String?)       # dflt_value
              rs.read(Int64?)        # pk
              found = true if name == column
            end
          end
          found
        when :postgres
          names = [] of String
          Record.query_compat(db,
            "SELECT column_name FROM information_schema.columns " \
            "WHERE table_name = ? AND table_schema = current_schema()",
            [table] of Saci::Record::Value) do |rs|
            rs.each { names << rs.read(String) }
          end
          names.includes?(column)
        else
          names = [] of String
          Record.query_compat(db,
            "SELECT column_name FROM information_schema.columns " \
            "WHERE table_name = ? AND table_schema = DATABASE()",
            [table] of Saci::Record::Value) do |rs|
            rs.each { names << rs.read(String) }
          end
          names.includes?(column)
        end
      end

      private def self.ensure_index!(db : DB::Database, table : String, name : String,
                                     columns : Array(String), ad : Saci::Record::Adapter,
                                     unique : Bool = false) : Nil
        return if index_exists?(db, table, name, ad)
        cols = columns.map { |column| Record.quote(column, ad) }.join(", ")
        kind = unique ? "UNIQUE " : ""
        Record.exec_compat(db,
          "CREATE #{kind}INDEX #{Record.quote(name, ad)} ON #{Record.quote(table, ad)} (#{cols})")
      end

      private def self.index_exists?(db : DB::Database, table : String, name : String,
                                     ad : Saci::Record::Adapter) : Bool
        sql = case ad
              when :sqlite
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND tbl_name = ? AND name = ?"
              when :postgres
                "SELECT COUNT(*) FROM pg_indexes WHERE tablename = ? AND indexname = ?"
              else
                "SELECT COUNT(*) FROM information_schema.statistics WHERE table_schema = DATABASE() AND table_name = ? AND index_name = ?"
              end
        Record.scalar_compat(db, sql, [table, name] of Saci::Record::Value).as(Int64) > 0
      end

      struct Row
        getter id : Int64
        getter class_name : String
        getter payload : String
        getter queue : String
        getter attempts : Int64
        getter checkpoint : Array(String)
        getter batch_id : String?
        getter unique_mode : String?
        getter unique_key : String?

        def initialize(@id, @class_name, @payload, @queue, @attempts,
                       @checkpoint = [] of String, @batch_id : String? = nil,
                       @unique_mode : String? = nil, @unique_key : String? = nil)
        end
      end

      # One candidate row. Kept separate from `Row` because the fields are
      # read before the claim update increments attempts.
      private struct Candidate
        getter id : Int64
        getter class_name : String
        getter payload : String
        getter queue : String
        getter attempts : Int64
        getter unique_mode : String?
        getter unique_key : String?
        getter checkpoint : String?
        getter batch_id : String?

        def initialize(@id, @class_name, @payload, @queue, @attempts,
                       @unique_mode, @unique_key, @checkpoint, @batch_id)
        end
      end

      # Persists one job for execution at `run_at`. Returns the new row id,
      # `0` when a unique lock suppressed the enqueue, or `-1` when the
      # insert was deferred until the surrounding transaction commits.
      def self.enqueue(class_name : String, queue : String, payload_json : String,
                       run_at : Time = Time.utc, priority : Int32 = 0,
                       unique_mode : Symbol? = nil, unique_key : String? = nil,
                       batch_id : String? = nil) : Int64
        db = target_db
        if defer_enqueue?(db)
          Record.defer_after_commit(db) do
            begin
              enqueue_internal(db, class_name, queue, payload_json, run_at,
                priority, unique_mode, unique_key, batch_id)
            rescue ex
              Job.report_error(class_name, ex)
            end
          end
          return -1_i64
        end
        enqueue_internal(db, class_name, queue, payload_json, run_at,
          priority, unique_mode, unique_key, batch_id)
      end

      private def self.defer_enqueue?(db : DB::Database) : Bool
        return false unless enqueue_after_transaction_commit?
        connection = begin
          Record.connection
        rescue
          return false
        end
        return false unless connection.is_a?(DB::Connection)
        Record.tx_database_for(connection) == db
      end

      private def self.enqueue_internal(db : DB::Database, class_name : String, queue : String,
                                        payload_json : String, run_at : Time, priority : Int32,
                                        unique_mode : Symbol?, unique_key : String?,
                                        batch_id : String?) : Int64
        ensure_schema!(db)
        ad = Record.adapter_of(db)
        now = Time.utc
        mode = unique_mode.try(&.to_s)
        key_hash = unique_key.try { |key| Digest::SHA256.hexdigest(key) }
        held = (mode == "until_executed" || mode == "until_executing") ? key_hash : nil
        q = ->(name : String) { Record.quote(name, ad) }
        columns = %w[job_class payload queue run_at attempts priority unique_mode unique_key unique_lock checkpoint batch_id created_at]
        column_sql = columns.map { |column| q.call(column) }.join(", ")
        placeholders = Array(String).new(columns.size, "?").join(", ")
        values = [class_name, payload_json, queue, ts(run_at, ad), 0_i64,
                  priority.to_i64, mode, key_hash, held, nil, batch_id,
                  ts(now, ad)] of Saci::Record::Value
        ignore = if held
                   ad == :sqlite ? "INSERT OR IGNORE" : (ad == :mysql ? "INSERT IGNORE" : "INSERT")
                 else
                   "INSERT"
                 end
        conflict = (ad == :postgres && held) ? " ON CONFLICT DO NOTHING" : ""

        if ad == :postgres
          ids = [] of Int64
          Record.query_compat(db,
            "#{ignore} INTO #{q.call(JOBS_TABLE)} (#{column_sql}) VALUES (#{placeholders})#{conflict} " \
            "RETURNING #{q.call("id")}", values) do |rs|
            rs.each { ids << rs.read(Int64) }
          end
          ids.first? || 0_i64
        else
          result = Record.exec_compat(db,
            "#{ignore} INTO #{q.call(JOBS_TABLE)} (#{column_sql}) VALUES (#{placeholders})", values)
          return 0_i64 if held && result.rows_affected == 0
          result.last_insert_id
        end
      end

      # Claims due jobs (up to free concurrency slots) and runs each in its
      # own fiber. Returns the number claimed. Non-blocking.
      def self.work_once(db : DB::Database = target_db, queue : String? = nil) : Int32
        ensure_schema!(db)
        heartbeat!(db)
        slots = concurrency - running_count
        return 0 if slots <= 0
        exact_queue = queue
        configured = exact_queue.nil? ? queues : nil
        claimed = 0
        slots.times do
          row = claim_one(db, exact_queue, configured)
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
      def self.drain(db : DB::Database = target_db, queue : String? = nil) : Int32
        ensure_schema!(db)
        heartbeat!(db)
        exact_queue = queue
        configured = exact_queue.nil? ? queues : nil
        done = 0
        while row = claim_one(db, exact_queue, configured)
          run_claimed(db, row)
          done += 1
        end
        done
      end

      def self.pending_count(db : DB::Database = target_db, queue : String? = nil) : Int64
        ad = Record.adapter_of(db)
        if queue
          Record.scalar_compat(db,
            "SELECT COUNT(*) FROM #{Record.quote(JOBS_TABLE, ad)} WHERE #{Record.quote("queue", ad)} = ?",
            [queue] of Saci::Record::Value).as(Int64)
        else
          Record.scalar_compat(db, "SELECT COUNT(*) FROM #{Record.quote(JOBS_TABLE, ad)}").as(Int64)
        end
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

      # Requeues a dead job for immediate execution. Returns false when
      # missing or suppressed by the job's unique lock.
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
        new_id = enqueue(row[:class_name], row[:queue], row[:payload], Time.utc)
        return false if new_id == 0
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

      # Deletes dead-letter rows older than `older_than` (default 30 days).
      # Returns the number removed.
      def self.prune_dead(older_than : Time::Span = 30.days, db : DB::Database = target_db) : Int64
        prune_dead_before(Time.utc - older_than, db)
      end

      def self.prune_dead_before(cutoff : Time, db : DB::Database = target_db) : Int64
        ad = Record.adapter_of(db)
        res = Record.exec_compat(db,
          "DELETE FROM #{Record.quote(DEAD_TABLE, ad)} WHERE #{Record.quote("failed_at", ad)} < ?",
          [ts(cutoff, ad)] of Saci::Record::Value)
        res.rows_affected.to_i64
      end

      # Empties the queue tables (spec isolation).
      def self.clear_all!(db : DB::Database = target_db) : Nil
        ad = Record.adapter_of(db)
        ensure_schema!(db)
        Record.exec_compat(db, "DELETE FROM #{Record.quote(JOBS_TABLE, ad)}")
        Record.exec_compat(db, "DELETE FROM #{Record.quote(DEAD_TABLE, ad)}")
      end

      # -- process supervision ---------------------------------------------

      alias ProcessInfo = NamedTuple(worker_id: String, hostname: String, pid: Int64,
        queues: String?, started_at: Time, heartbeat_at: Time)

      # Upserts this worker's supervision row. Best-effort: a diagnostic
      # table must never break job execution.
      def self.heartbeat!(db : DB::Database = target_db) : Nil
        ensure_process_schema!(db)
        ad = Record.adapter_of(db)
        q = ->(name : String) { Record.quote(name, ad) }
        now = Time.utc
        queues_json = queues.try(&.to_json)
        sql = if ad == :mysql
                <<-SQL
                INSERT INTO #{q.call(PROCESS_TABLE)}
                  (#{q.call("worker_id")}, #{q.call("hostname")}, #{q.call("pid")},
                   #{q.call("queues")}, #{q.call("started_at")}, #{q.call("heartbeat_at")})
                VALUES (?, ?, ?, ?, ?, ?)
                ON DUPLICATE KEY UPDATE
                  #{q.call("hostname")} = VALUES(#{q.call("hostname")}),
                  #{q.call("pid")} = VALUES(#{q.call("pid")}),
                  #{q.call("queues")} = VALUES(#{q.call("queues")}),
                  #{q.call("heartbeat_at")} = VALUES(#{q.call("heartbeat_at")})
                SQL
              else
                <<-SQL
                INSERT INTO #{q.call(PROCESS_TABLE)}
                  (#{q.call("worker_id")}, #{q.call("hostname")}, #{q.call("pid")},
                   #{q.call("queues")}, #{q.call("started_at")}, #{q.call("heartbeat_at")})
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(#{q.call("worker_id")}) DO UPDATE SET
                  #{q.call("hostname")} = excluded.#{q.call("hostname")},
                  #{q.call("pid")} = excluded.#{q.call("pid")},
                  #{q.call("queues")} = excluded.#{q.call("queues")},
                  #{q.call("heartbeat_at")} = excluded.#{q.call("heartbeat_at")}
                SQL
              end
        Record.exec_compat(db, sql, [worker_id, System.hostname, Process.pid.to_i64, queues_json,
                                     ts(now, ad), ts(now, ad)] of Saci::Record::Value)
      rescue
        # Process metadata is diagnostic only.
      end

      def self.register_process!(db : DB::Database = target_db) : Nil
        heartbeat!(db)
      end

      def self.processes(db : DB::Database = target_db) : Array(ProcessInfo)
        ensure_process_schema!(db)
        ad = Record.adapter_of(db)
        q = ->(name : String) { Record.quote(name, ad) }
        rows = [] of ProcessInfo
        Record.query_compat(db,
          "SELECT #{q.call("worker_id")}, #{q.call("hostname")}, #{q.call("pid")}, " \
          "#{q.call("queues")}, #{q.call("started_at")}, #{q.call("heartbeat_at")} " \
          "FROM #{q.call(PROCESS_TABLE)} ORDER BY #{q.call("heartbeat_at")} DESC") do |rs|
          rs.each do
            worker = rs.read(String)
            hostname = rs.read(String)
            pid = rs.read(Int64)
            worker_queues = rs.read(String?)
            started = ad == :sqlite ? Record.parse_time(rs.read(String?)) : rs.read(Time?)
            heartbeat = ad == :sqlite ? Record.parse_time(rs.read(String?)) : rs.read(Time?)
            if started && heartbeat
              rows << {worker_id: worker, hostname: hostname, pid: pid, queues: worker_queues,
                       started_at: started, heartbeat_at: heartbeat}
            end
          end
        end
        rows
      end

      # Removes supervision rows whose heartbeat is older than `older_than`.
      def self.prune_processes!(older_than : Time::Span = 5.minutes, db : DB::Database = target_db) : Int64
        ensure_process_schema!(db)
        ad = Record.adapter_of(db)
        res = Record.exec_compat(db,
          "DELETE FROM #{Record.quote(PROCESS_TABLE, ad)} WHERE #{Record.quote("heartbeat_at", ad)} < ?",
          [ts(Time.utc - older_than, ad)] of Saci::Record::Value)
        res.rows_affected.to_i64
      end

      def self.stop_process!(db : DB::Database = target_db) : Bool
        ad = Record.adapter_of(db)
        res = Record.exec_compat(db,
          "DELETE FROM #{Record.quote(PROCESS_TABLE, ad)} WHERE #{Record.quote("worker_id", ad)} = ?",
          [worker_id] of Saci::Record::Value)
        res.rows_affected > 0
      end

      # SQL used to pick a claimable row. Exposed so adapter-specific tests
      # can assert `FOR UPDATE SKIP LOCKED` without a live server.
      def self.claim_sql(adapter : Saci::Record::Adapter,
                         queue : String? = nil, queues : Array(String)? = nil) : String
        q = ->(name : String) { Record.quote(name, adapter) }
        jq = ->(name : String) { "#{q.call("j")}.#{q.call(name)}" }
        sql = String.build do |io|
          io << "SELECT " << jq.call("id")
          io << " FROM " << q.call(JOBS_TABLE) << " " << q.call("j")
          io << " WHERE (" << jq.call("locked_by") << " IS NULL OR " << jq.call("locked_at") << " < ?)"
          io << " AND " << jq.call("run_at") << " <= ?"
          if queue
            io << " AND " << jq.call("queue") << " = ?"
          elsif queues && !queues.empty?
            io << " AND " << jq.call("queue") << " IN (" << Array(String).new(queues.size, "?").join(", ") << ")"
          end
          io << " AND NOT (" << jq.call("unique_mode") << " = 'while_executing'"
          io << " AND " << jq.call("unique_lock") << " IS NULL AND " << jq.call("unique_key") << " IS NOT NULL"
          io << " AND EXISTS (SELECT 1 FROM " << q.call(JOBS_TABLE) << " " << q.call("h")
          io << " WHERE " << q.call("h") << "." << q.call("unique_lock") << " IS NOT NULL"
          io << " AND " << q.call("h") << "." << q.call("unique_key") << " = " << jq.call("unique_key") << "))"
          io << " ORDER BY " << jq.call("priority") << " DESC, " << jq.call("run_at") << " ASC, " << jq.call("id") << " ASC LIMIT 1"
          io << " FOR UPDATE SKIP LOCKED" unless adapter == :sqlite
        end
        sql
      end

      private def self.candidate_sql(ad : Saci::Record::Adapter, select_clause : String,
                                     queue : String?, queues : Array(String)?,
                                     lock : Bool) : String
        q = ->(name : String) { Record.quote(name, ad) }
        jq = ->(name : String) { "#{q.call("j")}.#{q.call(name)}" }
        String.build do |io|
          io << "SELECT " << select_clause
          io << " FROM " << q.call(JOBS_TABLE) << " " << q.call("j")
          io << " WHERE (" << jq.call("locked_by") << " IS NULL OR " << jq.call("locked_at") << " < ?)"
          io << " AND " << jq.call("run_at") << " <= ?"
          if queue
            io << " AND " << jq.call("queue") << " = ?"
          elsif queues && !queues.empty?
            io << " AND " << jq.call("queue") << " IN (" << Array(String).new(queues.size, "?").join(", ") << ")"
          end
          io << " AND NOT (" << jq.call("unique_mode") << " = 'while_executing'"
          io << " AND " << jq.call("unique_lock") << " IS NULL AND " << jq.call("unique_key") << " IS NOT NULL"
          io << " AND EXISTS (SELECT 1 FROM " << q.call(JOBS_TABLE) << " " << q.call("h")
          io << " WHERE " << q.call("h") << "." << q.call("unique_lock") << " IS NOT NULL"
          io << " AND " << q.call("h") << "." << q.call("unique_key") << " = " << jq.call("unique_key") << "))"
          io << " ORDER BY " << jq.call("priority") << " DESC, " << jq.call("run_at") << " ASC, " << jq.call("id") << " ASC LIMIT 1"
          io << " FOR UPDATE SKIP LOCKED" if lock && ad != :sqlite
        end
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

      private def self.parse_checkpoint(raw : String?) : Array(String)
        return [] of String if raw.nil? || raw.empty?
        JSON.parse(raw).as_a.map(&.as_s)
      rescue
        [] of String
      end

      private def self.claim_one(db : DB::Database, queue : String? = nil,
                                 queues : Array(String)? = nil) : Row?
        ad = Record.adapter_of(db)
        if ad == :sqlite
          if sqlite_candidate = select_candidate(db, ad, queue, queues, lock: false)
            begin
              claim_candidate(db, ad, sqlite_candidate)
            rescue ex : DB::Error
              # A `while_executing` unique-lock race leaves the row queued.
              nil
            end
          end
        else
          row : Row? = nil
          begin
            Record.transaction_on(db) do |conn|
              locked_candidate = select_candidate(conn, ad, queue, queues, lock: true)
              if locked_candidate
                row = claim_candidate(conn, ad, locked_candidate)
              end
            end
          rescue ex : DB::Error
            return nil
          end
          row
        end
      end

      private def self.select_candidate(target : DB::Database | DB::Connection,
                                        ad : Saci::Record::Adapter, queue : String?,
                                        queues : Array(String)?, lock : Bool) : Candidate?
        now = Time.utc
        cutoff = now - lock_timeout
        args = [ts(cutoff, ad), ts(now, ad)] of Saci::Record::Value
        if queue
          args << queue
        elsif queues
          queues.each { |name| args << name }
        end
        q = ->(name : String) { Record.quote(name, ad) }
        jq = ->(name : String) { "#{q.call("j")}.#{q.call(name)}" }
        select_clause = [
          "id", "job_class", "payload", "queue", "attempts",
          "unique_mode", "unique_key", "checkpoint", "batch_id",
        ].map { |column| jq.call(column) }.join(", ")
        candidate : Candidate? = nil
        Record.query_compat(target, candidate_sql(ad, select_clause, queue, queues, lock), args) do |rs|
          rs.each do
            candidate = Candidate.new(
              id: rs.read(Int64),
              class_name: rs.read(String),
              payload: rs.read(String),
              queue: rs.read(String),
              attempts: rs.read(Int64),
              unique_mode: rs.read(String?),
              unique_key: rs.read(String?),
              checkpoint: rs.read(String?),
              batch_id: rs.read(String?))
          end
        end
        candidate
      end

      # Conditional claim update. Returns nil when another worker won the
      # race (or the unique lock is held by an executing `while_executing`
      # copy).
      private def self.claim_candidate(target : DB::Database | DB::Connection,
                                       ad : Saci::Record::Adapter,
                                       candidate : Candidate) : Row?
        now = Time.utc
        cutoff = now - lock_timeout
        attempt = candidate.attempts + 1
        q = ->(name : String) { Record.quote(name, ad) }
        mode = candidate.unique_mode
        sql : String
        args : Array(Saci::Record::Value)
        if mode == "until_executing"
          sql = "UPDATE #{q.call(JOBS_TABLE)} SET #{q.call("locked_by")} = ?, " \
                "#{q.call("locked_at")} = ?, #{q.call("unique_lock")} = NULL, " \
                "#{q.call("attempts")} = ? WHERE #{q.call("id")} = ? " \
                "AND (#{q.call("locked_by")} IS NULL OR #{q.call("locked_at")} < ?)"
          args = [worker_id, ts(now, ad), attempt, candidate.id, ts(cutoff, ad)] of Saci::Record::Value
        elsif mode == "while_executing" && (lock = candidate.unique_key)
          sql = "UPDATE #{q.call(JOBS_TABLE)} SET #{q.call("locked_by")} = ?, " \
                "#{q.call("locked_at")} = ?, #{q.call("unique_lock")} = ?, " \
                "#{q.call("attempts")} = ? WHERE #{q.call("id")} = ? " \
                "AND (#{q.call("locked_by")} IS NULL OR #{q.call("locked_at")} < ?)"
          args = [worker_id, ts(now, ad), lock, attempt, candidate.id, ts(cutoff, ad)] of Saci::Record::Value
        else
          sql = "UPDATE #{q.call(JOBS_TABLE)} SET #{q.call("locked_by")} = ?, " \
                "#{q.call("locked_at")} = ?, #{q.call("attempts")} = ? " \
                "WHERE #{q.call("id")} = ? " \
                "AND (#{q.call("locked_by")} IS NULL OR #{q.call("locked_at")} < ?)"
          args = [worker_id, ts(now, ad), attempt, candidate.id, ts(cutoff, ad)] of Saci::Record::Value
        end
        result = Record.exec_compat(target, sql, args)
        return nil if result.rows_affected == 0
        Row.new(candidate.id, candidate.class_name, candidate.payload, candidate.queue,
          attempt, parse_checkpoint(candidate.checkpoint), candidate.batch_id,
          candidate.unique_mode, candidate.unique_key)
      end

      # Runs one claimed row to a terminal state. Never raises: success and
      # discards delete the row, final failures dead-letter it. (`execute`
      # already reports discards and final failures through `on_error`.)
      private def self.run_claimed(db : DB::Database, row : Row) : Nil
        klass = Job.lookup(row.class_name)
        unless klass
          dead_letter(db, row, "unknown job class #{row.class_name.inspect}")
          Batch.__job_finished(row.batch_id, true) if row.batch_id
          Job.report_error(row.class_name, Exception.new("unknown job class"))
          return
        end
        sink = ->(steps : Array(String)) do
          update_checkpoint(db, row.id, steps)
          nil
        end
        begin
          Job.execute(klass, row.payload, row.attempts.to_i32, row.checkpoint, sink,
            enforce_in_memory_unique: false)
          delete_row(db, row.id)
          Batch.__job_finished(row.batch_id, false) if row.batch_id
        rescue ex
          dead_letter(db, row, "#{ex.class}: #{ex.message}")
          Batch.__job_finished(row.batch_id, true) if row.batch_id
        end
      rescue ex
        begin
          dead_letter(db, row, "#{ex.class}: #{ex.message}")
        rescue
          # The row stays locked for `lock_timeout`, then is reclaimed.
        end
      end

      private def self.update_checkpoint(target : DB::Database | DB::Connection,
                                         id : Int64, steps : Array(String)) : Nil
        ad = Record.adapter_of(target)
        Record.exec_compat(target,
          "UPDATE #{Record.quote(JOBS_TABLE, ad)} SET #{Record.quote("checkpoint", ad)} = ? " \
          "WHERE #{Record.quote("id", ad)} = ?",
          [steps.to_json, id] of Saci::Record::Value)
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
