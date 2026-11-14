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
    #   (default 250ms) plus DB write latency; use `RedisServer`, or
    #   `PostgresServer` with `listen_notify: true`, when sub-100ms fan-out
    #   matters;
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
        @wake = ::Channel(Nil).new(1)
        @closed = Atomic(Bool).new(false)
        spawn { poll_loop } if start_polling
      end

      # Asks the background poller to poll now instead of waiting for the
      # rest of `poll_interval`. Never blocks: wake-ups that arrive while
      # one is already pending collapse into it. The PostgreSQL
      # LISTEN/NOTIFY listener calls this; custom schedulers may too.
      def wake : Nil
        return if @closed.get
        select
        when @wake.send(nil)
        else
        end
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
          when @wake.receive
          when timeout(@poll_interval)
          end
        end
      end
    end

    alias SolidCable = DbServer

    # PostgreSQL entry point (G282).
    #
    # Without `listen_notify`, this works exactly like `DbServer`
    # (`adapter: :postgres`): every server polls the messages table every
    # `poll_interval` (default 250ms).
    #
    # With `listen_notify: true`, delivery is push-driven:
    #
    # * `#broadcast` INSERTs the row, then runs
    #   `SELECT pg_notify(notify_channel, <server id>)`. PostgreSQL sends
    #   the notification after the INSERT has committed, so a woken peer
    #   always sees the row;
    # * a listener holds one dedicated connection that has run
    #   `LISTEN notify_channel` and calls `#wake` when a peer's
    #   notification arrives, so the poller fetches right away. The
    #   server's own notifications are ignored;
    # * the poller still runs every `poll_interval` (default 5s in this
    #   mode) as a safety net for rows inserted without a NOTIFY and for
    #   notifications lost while the listener was reconnecting;
    # * when the LISTEN connection closes or fails, the listener
    #   reconnects with backoff (0.1s doubling to 5s) and wakes the
    #   poller once it is back. To catch connections that stay open but
    #   stop delivering, it also pings itself on a private channel every
    #   `listen_heartbeat` (default 10s) and reconnects after three
    #   heartbeats without a notification.
    #
    # The listener lives in an opt-in file because the framework never
    # requires the pg driver itself (see the driver note in
    # `src/saci/record.cr`). Apps on PostgreSQL already depend on `pg`:
    #
    # ```
    # require "pg"
    # require "saci/cable_pg"
    #
    # db = Saci::Record.establish_connection("cable", ENV["CABLE_DATABASE_URL"])
    # Saci::Cable.server = Saci::Cable::PostgresServer.new(db,
    #   listen_notify: true, listen_url: ENV["CABLE_DATABASE_URL"])
    # ```
    #
    # `crystal-db` does not expose a handle's URL, so the listener connects
    # to `listen_url`, falling back to `ENV["DATABASE_URL"]`. Point it at
    # PostgreSQL directly: PgBouncer in transaction pooling mode does not
    # support LISTEN. Without `require "saci/cable_pg"`,
    # `listen_notify: true` raises instead of silently falling back to
    # polling.
    class PostgresServer < DbServer
      NOTIFY_CHANNEL = "saci_cable"

      # The LISTEN side of `listen_notify`. `saci/cable_pg` provides the
      # implementation and registers it in `.listener_factory`.
      abstract class Listener
        abstract def connected? : Bool
        abstract def close : Nil
      end

      # Builds the listener for a server and its LISTEN URL. Set by
      # `require "saci/cable_pg"`.
      class_property listener_factory : Proc(PostgresServer, String, Listener)? = nil

      def self.listen_notify_supported? : Bool
        !listener_factory.nil?
      end

      # Channel that broadcasts NOTIFY and the listener LISTENs on.
      getter notify_channel : String
      # Interval between listener self-pings (see the class comment).
      getter listen_heartbeat : Time::Span
      getter listener : Listener?

      def initialize(db : DB::Database, *, listen_notify : Bool = false,
                     notify_channel : String = NOTIFY_CHANNEL,
                     listen_url : String? = nil,
                     listen_heartbeat : Time::Span = 10.seconds,
                     poll_interval : Time::Span? = nil,
                     retention : Time::Span = 1.day,
                     table : String = DbAdapter::MESSAGE_TABLE,
                     batch_size : Int32 = 500,
                     cleanup_interval : Int32 = 100,
                     start_polling : Bool = true,
                     max_connections : Int32 = 0,
                     message_buffer_size : Int32 = Connection::DEFAULT_MESSAGE_BUFFER_SIZE)
        @notify_channel = notify_channel
        @listen_heartbeat = listen_heartbeat
        @listener = nil
        factory = nil
        url = nil
        if listen_notify
          factory = self.class.listener_factory
          unless factory
            raise NotImplementedError.new(
              "Saci::Cable::PostgresServer LISTEN/NOTIFY needs the pg driver: add `require \"pg\"` and " \
              "`require \"saci/cable_pg\"` to your app. Use polling (listen_notify: false) or " \
              "Saci::Cable::RedisServer otherwise."
            )
          end
          url = listen_url || ENV["DATABASE_URL"]?
          unless url && !url.empty?
            raise ArgumentError.new(
              "Saci::Cable::PostgresServer listen_notify: true needs listen_url: (or ENV[\"DATABASE_URL\"]); " \
              "crystal-db does not expose the URL of an open database handle."
            )
          end
        end
        super(db, adapter: :postgres, poll_interval: poll_interval || (listen_notify ? 5.seconds : 250.milliseconds),
          retention: retention, table: table, batch_size: batch_size, cleanup_interval: cleanup_interval,
          start_polling: start_polling, max_connections: max_connections,
          message_buffer_size: message_buffer_size)
        if factory && url
          @listener = factory.call(self, url)
        end
      end

      def listen_notify? : Bool
        !@listener.nil?
      end

      # INSERTs the message like `DbServer#broadcast`, then NOTIFYs peers
      # when `listen_notify` is on. A failed NOTIFY is reported and the
      # message still reaches peers on their next safety-net poll.
      def broadcast(stream : String, payload) : Nil
        super
        return unless listen_notify?
        begin
          notify(@id)
        rescue ex
          Cable.report_error(ex, "pg notify")
        end
      end

      # Sends `payload` on `channel` with `pg_notify`. Raises on DB errors.
      def notify(payload : String, channel : String = @notify_channel) : Nil
        @db.exec("SELECT pg_notify($1, $2)", channel, payload)
      end

      # Stops the listener and the poller (idempotent). The DB handle stays
      # open.
      def close : Nil
        @listener.try(&.close)
        super
      end
    end
  end
end
