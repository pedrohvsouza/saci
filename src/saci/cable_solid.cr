require "db"
require "./cable"

module Saci
  module Cable
    # SQL layer for the DB-backed pub/sub adapter (G93/G164).
    #
    # Schema (portable across SQLite/PostgreSQL/MySQL):
    #
    # ```
    # CREATE TABLE saci_cable_messages (
    #   id         INTEGER/BIGSERIAL/BIGINT AUTO_INCREMENT PRIMARY KEY,
    #   stream     VARCHAR(255) NOT NULL,
    #   payload    TEXT NOT NULL,          -- marker envelope or bare message JSON
    #   created_at BIGINT NOT NULL         -- epoch milliseconds (portable)
    # )
    # ```
    #
    # `created_at` is stored as epoch milliseconds rather than a native
    # timestamp so cleanup SQL is identical on every adapter; `payload`
    # normally holds a small envelope
    # `{"__saci_cable":true,"sender":"<server>","message":<json>}` which lets
    # the poller skip its own echo without an extra column. Rows inserted by
    # other tools may store the bare message JSON instead; the poller detects
    # the marker and otherwise delivers the parsed payload as-is.
    #
    # Cleanup is caller-driven (`DbServer#poll` runs it periodically):
    # rows older than the retention window are deleted. Run at least one
    # poller per retention window or the table grows without bound.
    class DbAdapter
      MESSAGE_TABLE = "saci_cable_messages"

      getter table : String
      getter adapter : Symbol

      def initialize(@db : DB::Database, @adapter : Symbol = :sqlite, @table : String = MESSAGE_TABLE)
      end

      # Best-effort adapter detection: delegates to `Saci::Record` when the
      # ORM is loaded (it knows the URL each handle came from), otherwise
      # assumes SQLite. Pass `adapter:` explicitly when opening a
      # PostgreSQL/MySQL handle without registering it with `Saci::Record`.
      def self.detect_adapter(db : DB::Database) : Symbol
        {% if @top_level.has_constant?("Saci") && @top_level.constant("Saci").has_constant?("Record") %}
          Saci::Record.adapter_of(db)
        {% else %}
          :sqlite
        {% end %}
      end

      def quote(name : String) : String
        @adapter == :mysql ? "`#{name}`" : "\"#{name}\""
      end

      def create_table_sql : String
        id_def = case @adapter
                 when :postgres then "#{quote("id")} BIGSERIAL PRIMARY KEY"
                 when :mysql    then "#{quote("id")} BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY"
                 else                "#{quote("id")} INTEGER PRIMARY KEY AUTOINCREMENT"
                 end
        "CREATE TABLE IF NOT EXISTS #{quote(@table)} (" \
        "#{id_def}, " \
        "#{quote("stream")} VARCHAR(255) NOT NULL, " \
        "#{quote("payload")} TEXT NOT NULL, " \
        "#{quote("created_at")} BIGINT NOT NULL)"
      end

      def insert_sql : String
        "INSERT INTO #{quote(@table)} (#{quote("stream")}, #{quote("payload")}, #{quote("created_at")}) VALUES (?, ?, ?)"
      end

      def fetch_sql : String
        "SELECT #{quote("id")}, #{quote("stream")}, #{quote("payload")} FROM #{quote(@table)} " \
        "WHERE #{quote("id")} > ? ORDER BY #{quote("id")} ASC LIMIT ?"
      end

      # Creates the table (and a best-effort `created_at` index; MySQL's
      # `CREATE INDEX` has no `IF NOT EXISTS`, so it is skipped there).
      def ensure_schema! : Nil
        exec_sql(create_table_sql)
        return if @adapter == :mysql
        begin
          exec_sql("CREATE INDEX IF NOT EXISTS #{quote("idx_#{@table}_created_at")} ON #{quote(@table)} (#{quote("created_at")})")
        rescue
          # Older SQLite/MySQL variants: the table is still usable.
        end
      end

      def insert(stream : String, payload : String, created_at : Time = Time.utc) : Int64
        ms = created_at.to_unix_ms
        if @adapter == :postgres
          value = @db.scalar(adapt(insert_sql) + " RETURNING #{quote("id")}", stream, payload, ms)
          case value
          when Int then value.to_i64
          else          0_i64
          end
        else
          @db.exec(adapt(insert_sql), stream, payload, ms).last_insert_id
        end
      end

      struct Message
        getter id : Int64
        getter stream : String
        getter payload : String

        def initialize(@id : Int64, @stream : String, @payload : String)
        end
      end

      def fetch_after(id : Int64, limit : Int32 = 500) : Array(Message)
        rows = [] of Message
        @db.query(adapt(fetch_sql), id, limit) do |rs|
          rs.each do
            rows << Message.new(rs.read(Int64), rs.read(String), rs.read(String))
          end
        end
        rows
      end

      def max_id : Int64
        value = @db.scalar("SELECT COALESCE(MAX(#{quote("id")}), 0) FROM #{quote(@table)}")
        case value
        when Int then value.to_i64
        else          0_i64
        end
      end

      def cleanup_before(cutoff_ms : Int64) : Int64
        @db.exec(adapt("DELETE FROM #{quote(@table)} WHERE #{quote("created_at")} < ?"), cutoff_ms).rows_affected
      end

      # `?` -> `$1, $2, ...` for PostgreSQL; other adapters use `?`.
      def adapt(sql : String) : String
        return sql unless @adapter == :postgres
        n = 0
        String.build do |io|
          sql.each_char do |char|
            if char == '?'
              n += 1
              io << '$' << n
            else
              io << char
            end
          end
        end
      end

      private def exec_sql(sql : String) : DB::ExecResult
        @db.exec(adapt(sql))
      end
    end

    # DB-backed pub/sub (Solid Cable equivalent, G93/G164).
    #
    # ```
    # db = DB.open("sqlite3://./app.db") # or postgres://…
    # server = Saci::Cable::DbServer.new(db, adapter: :sqlite)
    # Saci::Cable.server = server
    # router = Saci::Router.new.draw { |r| r.cable "/cable", ChatChannel, server: server }
    # ```
    #
    # Model: `broadcast` delivers locally immediately, then INSERTs the
    # message; every server (including this one) polls `id > last_seen` and
    # delivers rows published by other servers. The publishing server skips
    # its own rows via the envelope's `sender` id, so each subscriber sees
    # each message exactly once per process.
    #
    # Latency/limits (documented):
    # * cross-process delivery latency is bounded by `poll_interval`
    #   (default 250ms) plus DB write latency; use `RedisServer` when
    #   sub-100ms fan-out matters;
    # * polling is one `SELECT` per interval per server, not per stream;
    # * retention defaults to 1 day and cleanup runs every
    #   `cleanup_interval` polls;
    # * the table grows with broadcast volume between cleanups.
    #
    # `close` stops the poller; the database handle is owned by the caller
    # and is never closed here.
    class DbServer < Server
      getter db : DB::Database
      getter adapter : DbAdapter
      getter id : String
      getter poll_interval : Time::Span
      getter retention : Time::Span
      getter batch_size : Int32

      @last_seen : Int64
      @poll_mutex = Mutex.new
      @poll_count = 0

      def initialize(db : DB::Database, adapter : Symbol? = nil,
                     poll_interval : Time::Span = 250.milliseconds,
                     retention : Time::Span = 1.day,
                     table : String = DbAdapter::MESSAGE_TABLE,
                     batch_size : Int32 = 500,
                     cleanup_interval : Int32 = 100,
                     start_polling : Bool = true,
                     **server_options)
        super(**server_options)
        @db = db
        @adapter = DbAdapter.new(db, adapter || DbAdapter.detect_adapter(db), table)
        @adapter.ensure_schema!
        @id = Random::Secure.hex(8)
        @poll_interval = poll_interval
        @retention = retention
        @batch_size = batch_size
        @cleanup_interval = cleanup_interval
        @last_seen = @adapter.max_id
        @stop = ::Channel(Nil).new(1)
        @closed = Atomic(Bool).new(false)
        spawn { poll_loop } if start_polling
      end

      def closed? : Bool
        @closed.get
      end

      # Creates/updates the messages table (idempotent; also run by the
      # constructor).
      def ensure_schema! : Nil
        @adapter.ensure_schema!
      end

      # Local delivery is immediate; the INSERT makes the message visible to
      # peer servers on their next poll. DB failures are reported but never
      # break local delivery (fail-open, like the Redis adapter).
      def broadcast(stream : String, payload) : Nil
        message_json = Cable.encode_payload(payload)
        record_broadcast(stream, payload, message_json)
        deliver_local(stream, payload, message_json)
        begin
          envelope = {"__saci_cable" => true, "sender" => @id, "message" => payload}
          @adapter.insert(stream, envelope.to_json)
        rescue ex
          Cable.report_error(ex, "db broadcast")
        end
      end

      # Fetches rows published by other servers and delivers them locally.
      # Returns the number of messages delivered. Public so specs and
      # custom schedulers can drive it deterministically.
      def poll : Int32
        return 0 if @closed.get
        delivered = 0
        @poll_mutex.synchronize do
          rows = @adapter.fetch_after(@last_seen, @batch_size)
          rows.each do |row|
            @last_seen = row.id if row.id > @last_seen
            begin
              parsed = JSON.parse(row.payload)
              if envelope = parsed.as_h?
                if envelope["__saci_cable"]?.try(&.as_bool?)
                  next if envelope["sender"]?.try(&.as_s?) == @id
                  deliver_local(row.stream, envelope["message"]?)
                  delivered += 1
                  next
                end
              end
              # Row written by another tool: treat the payload as the message.
              deliver_local(row.stream, parsed)
              delivered += 1
            rescue
              # Corrupt/foreign row: skip it; it must not kill the poller.
            end
          end
          @poll_count += 1
          cleanup! if @cleanup_interval > 0 && (@poll_count % @cleanup_interval == 0)
        end
        delivered
      end

      # Deletes rows older than the retention window. Returns rows removed.
      def cleanup! : Int64
        cutoff = (Time.utc - @retention).to_unix_ms
        @adapter.cleanup_before(cutoff)
      rescue ex
        Cable.report_error(ex, "db cleanup")
        0_i64
      end

      # Stops the background poller (idempotent). The DB handle stays open.
      def close : Nil
        return if @closed.swap(true)
        begin
          # Buffered wake signal; receiving from a closed channel raises in
          # Crystal 1.22, so the channel is never closed.
          @stop.send(nil)
        rescue ::Channel::ClosedError
        end
      end

      private def poll_loop : Nil
        loop do
          break if @closed.get
          begin
            poll
          rescue ex
            Cable.report_error(ex, "db poll")
          end
          select
          when @stop.receive
            break
          when timeout(@poll_interval)
          end
        end
      end
    end

    alias SolidCable = DbServer

    # PostgreSQL entry point (G282).
    #
    # Polling mode works exactly like `DbServer` (`adapter: :postgres`).
    # LISTEN/NOTIFY is *not* implemented, for two concrete reasons:
    #
    # 1. `crystal-db`'s public API exposes no async notification channel
    #    (`PG::Connection#wait_for_notify` is unreachable through
    #    `DB::Connection`), so a LISTEN loop would need to hold a raw
    #    `PG::Connection`;
    # 2. the framework deliberately does not `require "pg"` (see the
    #    driver note in `src/saci/record.cr`): linking pg's auth path
    #    breaks builds on systems with OpenSSL >= 3.2, including pure
    #    SQLite deployments.
    #
    # Passing `listen_notify: true` therefore raises with instructions
    # instead of silently degrading. Apps that already depend on pg can
    # run their own `LISTEN saci_cable` loop and call `#poll` when a
    # notification arrives; `#broadcast` can be paired with
    # `NOTIFY saci_cable` in the same transaction if desired.
    class PostgresServer < DbServer
      NOTIFY_CHANNEL = "saci_cable"

      def self.listen_notify_supported? : Bool
        false
      end

      def initialize(db : DB::Database, *, listen_notify : Bool = false,
                     notify_channel : String = NOTIFY_CHANNEL,
                     poll_interval : Time::Span = 250.milliseconds,
                     retention : Time::Span = 1.day,
                     table : String = DbAdapter::MESSAGE_TABLE,
                     batch_size : Int32 = 500,
                     cleanup_interval : Int32 = 100,
                     start_polling : Bool = true,
                     max_connections : Int32 = 0,
                     message_buffer_size : Int32 = Connection::DEFAULT_MESSAGE_BUFFER_SIZE)
        if listen_notify
          raise NotImplementedError.new(
            "Saci::Cable::PostgresServer does not implement LISTEN/NOTIFY: crystal-db exposes no async " \
            "notification API and the framework does not link the pg driver (see the class comment). " \
            "Use polling (listen_notify: false) or run your own PG::Connection LISTEN loop and call #poll. " \
            "For low-latency fan-out use Saci::Cable::RedisServer."
          )
        end
        @notify_channel = notify_channel
        super(db, adapter: :postgres, poll_interval: poll_interval, retention: retention,
          table: table, batch_size: batch_size, cleanup_interval: cleanup_interval,
          start_polling: start_polling, max_connections: max_connections,
          message_buffer_size: message_buffer_size)
      end

      # Channel a user-managed LISTEN loop should subscribe to.
      getter notify_channel : String
    end
  end
end
