require "base64"
require "db"
require "json"
require "./record"

module Saci
  module Cache
    # Database-backed cache (Rails/Solid Cache equivalent, G145/G163).
    #
    # A `DbStore` keeps every entry in one portable table and therefore
    # needs no Redis (or any other extra service) in production. Values use
    # the *same* type-tagged text encoding as `MemoryStore`/`RedisStore`
    # (`"S:<raw>"`, `"I:<n>"`, …), so swapping stores never changes what
    # `read_value` returns. The value column is `TEXT`; drivers that hand
    # BLOBs back as `Bytes` are normalized to text before decoding.
    #
    # ```
    # # Use the primary application database:
    # Saci::Cache.use_database!(Saci::Record.connection)
    #
    # # …or a dedicated cache database (SQLite/PostgreSQL/MySQL):
    # Saci::Cache.store = Saci::Cache::DbStore.new(
    #   url: ENV.fetch("CACHE_DATABASE_URL", "sqlite3://./db/cache.db"),
    #   max_entries: 100_000,
    #   max_bytes: 256_i64 * 1024 * 1024)
    #
    # # A named database registered with `Saci::Record.establish_connection`:
    # Saci::Cache.store = Saci::Cache::DbStore.new(database: "cache")
    # ```
    #
    # Schema (created automatically by `ensure_schema!`, which the
    # constructors call by default):
    #
    # ```
    # CREATE TABLE saci_cache_entries (
    #   key        VARCHAR(512) PRIMARY KEY,
    #   value      TEXT NOT NULL,
    #   expires_at BIGINT,              -- epoch milliseconds, NULL = forever
    #   created_at BIGINT NOT NULL,     -- epoch milliseconds (portable)
    #   updated_at BIGINT NOT NULL
    # )
    # ```
    #
    # `created_at`/`expires_at` are epoch milliseconds rather than native
    # timestamps so comparisons, pruning and `trim` are identical on every
    # adapter. Timestamps are UTC.
    #
    # Migration equivalent (the raw helper above is adapter-aware and is
    # what `ensure_schema!` runs; either form works):
    #
    # ```
    # class CreateSaciCacheEntries < Saci::Record::Migration
    #   def change
    #     create_table :saci_cache_entries, id: false do |t|
    #       t.column :key, :string, null: false, primary_key: true
    #       t.text :value, null: false
    #       t.bigint :expires_at
    #       t.bigint :created_at, null: false
    #       t.bigint :updated_at, null: false
    #       t.index :expires_at
    #     end
    #   end
    # end
    #
    # # …or simply:
    # # Saci::Cache::DbStore.ensure_schema!(Saci::Record.connection)
    # ```
    #
    # Per-environment configuration (`db/cache` in Rails terms):
    #
    # ```
    # # config/environments/development.cr
    # Saci::Cache.store = Saci::Cache::DbStore.new(url: "sqlite3://./db/cache_development.db")
    #
    # # config/environments/production.cr
    # Saci::Cache.store = Saci::Cache::DbStore.new(
    #   url: ENV.fetch("CACHE_DATABASE_URL"),
    #   namespace: "myapp:production",
    #   max_entries: 1_000_000,
    #   max_bytes: 1_073_741_824_i64) # 1 GiB
    # ```
    #
    # Operational notes:
    # * Expiry is lazy: reads/exists/increment treat expired rows as misses.
    #   Call `prune_expired` (or `prune`) periodically — e.g. from a
    #   recurring job — to reclaim space. `trim` enforces `max_entries` /
    #   `max_bytes` (oldest `updated_at` first) and runs after writes when a
    #   limit is configured.
    # * `increment`/`decrement` are a single SQL `UPDATE` with the arithmetic
    #   in the database (SQLite/PostgreSQL use `RETURNING`); concurrent
    #   increments never lose an update. The first increment for a key falls
    #   back to an `INSERT`, retrying the update when another process wins
    #   the race.
    # * `delete_matched` uses `GLOB` on SQLite and `LIKE` on
    #   PostgreSQL/MySQL. `*` and `?` are supported; `%`/`_` are literal on
    #   PostgreSQL/MySQL.
    # * Keys longer than the column (`VARCHAR(512)`, bytes after namespace)
    #   are not supported by PostgreSQL/MySQL; hash long keys in the caller
    #   (the same limit Rails documents for cache keys).
    # * A `url:` store owns its `DB::Database`; call `close` when discarding
    #   it. A connection/primary/named store is owned by `Saci::Record`.
    class DbStore < Store
      TABLE               = "saci_cache_entries"
      MAX_KEY_BYTES       = 512
      DEFAULT_PRUNE_BATCH = 500

      getter db : DB::Database | DB::Connection
      getter table : String

      @adapter : Symbol?
      @owns_db : Bool
      @max_entries : Int32?
      @max_bytes : Int64?

      # Wraps an existing handle (the primary connection, a transaction
      # connection, or any `DB::Database` the caller owns). `adapter:` is
      # only needed for handles that are not registered with `Saci::Record`
      # (for example a raw `DB.open("postgres://…")`).
      def initialize(db : DB::Database | DB::Connection,
                     *,
                     @table : String = TABLE,
                     namespace : String = "",
                     @adapter : Symbol? = nil,
                     @max_entries : Int32? = nil,
                     @max_bytes : Int64? = nil,
                     auto_schema : Bool = true)
        @db = db
        @owns_db = false
        self.namespace = namespace
        validate_table!
        clamp_limits!
        ensure_schema! if auto_schema
      end

      # Opens (and owns) a dedicated database. Adapter detection comes from
      # the URL scheme (`sqlite3://`, `postgres://`, `mysql://`); SQLite
      # connections get WAL + a busy timeout so concurrent cache writers
      # wait instead of failing.
      def initialize(*, url : String,
                     table : String = TABLE,
                     namespace : String = "",
                     adapter : Symbol? = nil,
                     max_entries : Int32? = nil,
                     max_bytes : Int64? = nil,
                     auto_schema : Bool = true)
        resolved = adapter || Record.adapter_for_url(url)
        db = DB.open(url)
        if resolved == :sqlite
          begin
            db.setup_connection do |conn|
              conn.exec("PRAGMA busy_timeout=5000")
              conn.exec("PRAGMA journal_mode=WAL")
            end
          rescue
            # Best effort (e.g. read-only or in-memory databases).
          end
        end
        @db = db
        @owns_db = true
        @table = table
        self.namespace = namespace
        @adapter = resolved
        @max_entries = max_entries
        @max_bytes = max_bytes
        validate_table!
        clamp_limits!
        ensure_schema! if auto_schema
      end

      # Uses a database registered with
      # `Saci::Record.establish_connection(name, url)`.
      def initialize(*, database : String,
                     table : String = TABLE,
                     namespace : String = "",
                     adapter : Symbol? = nil,
                     max_entries : Int32? = nil,
                     max_bytes : Int64? = nil,
                     auto_schema : Bool = true)
        @db = Record.database(database)
        @owns_db = false
        @table = table
        self.namespace = namespace
        @adapter = adapter
        @max_entries = max_entries
        @max_bytes = max_bytes
        validate_table!
        clamp_limits!
        ensure_schema! if auto_schema
      end

      # Creates the cache table (and a best-effort `expires_at` index) on a
      # handle without constructing a store. Safe to call at boot and from a
      # migration:
      #
      # ```
      # Saci::Cache::DbStore.ensure_schema!(Saci::Record.connection)
      # ```
      def self.ensure_schema!(db : DB::Database | DB::Connection,
                              *,
                              table : String = TABLE,
                              adapter : Symbol? = nil) : Nil
        new(db, table: table, adapter: adapter, auto_schema: false).ensure_schema!
      end

      # Adapter used for identifier quoting/placeholders.
      def adapter : Symbol
        @adapter || Record.adapter_of(@db)
      end

      # Configured limits (`nil` = unlimited). `trim` enforces them.
      def max_entries : Int32?
        @max_entries
      end

      def max_bytes : Int64?
        @max_bytes
      end

      # Creates the table/index. Rerunnable.
      def ensure_schema! : Nil
        ad = adapter
        q = ->(name : String) { Record.quote(name, ad) }
        big = Record.db_type(:bigint, ad)
        exec(<<-SQL)
          CREATE TABLE IF NOT EXISTS #{q.call(@table)} (
            #{q.call("key")} VARCHAR(#{MAX_KEY_BYTES}) PRIMARY KEY,
            #{q.call("value")} TEXT NOT NULL,
            #{q.call("expires_at")} #{big},
            #{q.call("created_at")} #{big} NOT NULL,
            #{q.call("updated_at")} #{big} NOT NULL
          )
          SQL
        # MySQL has no `CREATE INDEX IF NOT EXISTS`; a duplicate-index error
        # on boot is harmless.
        if ad == :mysql
          begin
            exec("CREATE INDEX #{q.call("idx_#{@table}_expires_at")} " \
                 "ON #{q.call(@table)} (#{q.call("expires_at")})")
          rescue
            # Index already exists; the table remains usable (pruning scans).
          end
        else
          begin
            exec("CREATE INDEX IF NOT EXISTS #{q.call("idx_#{@table}_expires_at")} " \
                 "ON #{q.call(@table)} (#{q.call("expires_at")})")
          rescue
            # Older engines: the table remains usable (pruning scans).
          end
        end
      end

      # Closes a database opened by `new(url:)`. No-op for handles owned by
      # `Saci::Record` or by the caller.
      def close : Nil
        return unless @owns_db
        if database = @db.as?(DB::Database)
          database.close
        end
      end

      def read(key : String) : String?
        found, value = lookup(key)
        return nil unless found
        value.is_a?(String) ? value : nil
      end

      def read_value(key : String) : Value
        _, value = lookup(key)
        value
      end

      def write(key : String, value : String | Int | Float | Bool | Time | Nil, expires_in : Time::Span? = nil) : Bool
        write_encoded(key, encode(normalize(value)), expires_in)
      end

      # Stores binary data (base64 in the same text column). Read it back
      # with `read_bytes`; `read_value` sees the base64 payload.
      def write_bytes(key : String, bytes : Bytes, expires_in : Time::Span? = nil) : Bool
        write_encoded(key, "Y:#{Base64.strict_encode(bytes)}", expires_in)
      end

      # Convenience overload for callers that hold binary data directly.
      def write(key : String, value : Bytes, expires_in : Time::Span? = nil) : Bool
        write_bytes(key, value, expires_in)
      end

      def read_bytes(key : String) : Bytes?
        found, value = lookup(key)
        return nil unless found
        raw = value.as?(String)
        return nil unless raw && raw.starts_with?("Y:")
        begin
          Base64.decode(raw[2..])
        rescue Base64::Error
          nil
        end
      end

      # JSON helpers (the caller keeps the same String round-trip as with
      # `MemoryStore`/`RedisStore`; this is just sugar).
      def write_json(key : String, value : JSON::Any, expires_in : Time::Span? = nil) : Bool
        write(key, value.to_json, expires_in)
      end

      # Convenience overload for callers that hold a parsed JSON value.
      def write(key : String, value : JSON::Any, expires_in : Time::Span? = nil) : Bool
        write_json(key, value, expires_in)
      end

      def read_json(key : String) : JSON::Any?
        raw = read(key)
        raw ? JSON.parse(raw) : nil
      rescue JSON::ParseException
        nil
      end

      def delete(key : String) : Bool
        exec("DELETE FROM #{table_sql} WHERE #{key_sql} = ?", [namespaced(key)] of Record::Value).rows_affected > 0
      end

      def exist?(key : String) : Bool
        found = scalar(
          "SELECT 1 FROM #{table_sql} " \
          "WHERE #{key_sql} = ? AND (#{expires_at_sql} IS NULL OR #{expires_at_sql} > ?) LIMIT 1",
          [namespaced(key), now_ms] of Record::Value
        )
        !found.nil?
      end

      def clear : Nil
        exec("DELETE FROM #{table_sql}")
        nil
      end

      def increment(key : String, by : Int = 1) : Int64
        delta = by.to_i64
        full = namespaced(key)
        attempts = 0
        loop do
          attempts += 1
          now = now_ms
          if raw = increment_update(full, delta, now)
            return counter_value(raw)
          end

          row = select_row(full)
          if row.nil?
            begin
              insert_counter(full, delta)
              return delta
            rescue ex
              # Another process inserted the key between our UPDATE and
              # INSERT: retry the atomic UPDATE (it will now match).
              if duplicate_key_error?(ex) && attempts < 8
                next
              end
              raise ex
            end
          end

          raw, expires_at = row
          if expires_at && expires_at <= now
            # The row expired between UPDATE and SELECT; MemoryStore resets
            # expired counters to the delta (without an expiry).
            write_encoded(full, "I:#{delta}", nil)
            return delta
          end

          # The UPDATE did not match: either the value is not numeric, or
          # MySQL reported 0 changed rows (e.g. `by: 0`). Handle the
          # numeric/delta-zero case without losing the update.
          case decoded = decode(raw)
          when Int
            current = decoded.to_i64
            total = current + delta
            if total != current
              write_counter_preserving_expiry(full, "I:#{total}", expires_at, now)
            end
            return total
          when String
            if current = decoded.to_i64?
              total = current + delta
              if total != current
                payload = raw.starts_with?("S:") ? "S:#{total}" : "I:#{total}"
                write_counter_preserving_expiry(full, payload, expires_at, now)
              end
              return total
            end
            raise ArgumentError.new("cache: cannot increment non-numeric value for #{key.inspect}")
          else
            raise ArgumentError.new("cache: cannot increment non-numeric value for #{key.inspect}")
          end
        end
      end

      def decrement(key : String, by : Int = 1) : Int64
        increment(key, -by)
      end

      def fetch(key : String, expires_in : Time::Span? = nil, &block : -> String) : String
        fetch_string(key, expires_in) { block.call }
      end

      def fetch_value(key : String, expires_in : Time::Span? = nil, &block : -> Value) : Value
        fetch_value_impl(key, expires_in) { block.call }
      end

      # `race_condition_ttl` is accepted for API parity with `MemoryStore`
      # but ignored: expired rows are gone from the read path, so there is
      # no stale value to serve.
      def fetch(key : String, expires_in : Time::Span? = nil, race_condition_ttl : Time::Span? = nil, &block : -> String) : String
        fetch_string(key, expires_in) { block.call }
      end

      def fetch_value(key : String, expires_in : Time::Span? = nil, race_condition_ttl : Time::Span? = nil, &block : -> Value) : Value
        fetch_value_impl(key, expires_in) { block.call }
      end

      # Removes every key matching `pattern` (`*` = any run, `?` = one
      # character). Returns the number of rows deleted. Matching is done by
      # the database, so the whole operation is one statement.
      def delete_matched(pattern : String) : Int64
        full = namespaced(pattern)
        sql = if adapter == :sqlite
                "DELETE FROM #{table_sql} WHERE #{key_sql} GLOB ?"
              else
                # MySQL treats backslash as a string escape, so its ESCAPE
                # clause needs a doubled backslash in the SQL text; SQLite
                # and PostgreSQL need one.
                escape = adapter == :mysql ? "ESCAPE '\\\\'" : "ESCAPE '\\'"
                "DELETE FROM #{table_sql} WHERE #{key_sql} LIKE ? #{escape}"
              end
        exec(sql, [adapter == :sqlite ? full : like_pattern(full)] of Record::Value).rows_affected
      end

      # Deletes rows whose `expires_at` is at or before `now`. Returns the
      # number of rows removed. Run periodically (a recurring job is ideal);
      # reads already ignore expired rows.
      def prune_expired(now : Time = Time.utc) : Int64
        exec("DELETE FROM #{table_sql} WHERE #{expires_at_sql} IS NOT NULL AND #{expires_at_sql} <= ?",
          [now.to_unix_ms] of Record::Value).rows_affected
      end

      # Alias kept for Rails/Solid Cache vocabulary.
      def prune(now : Time = Time.utc) : Int64
        prune_expired(now)
      end

      # Enforces `max_entries`/`max_bytes`, deleting the oldest
      # (`updated_at ASC`) rows first. Returns the number of rows deleted.
      def trim : Int64
        removed = 0_i64

        if max = @max_entries
          excess = count - max
          while excess > 0
            batch = excess > DEFAULT_PRUNE_BATCH ? DEFAULT_PRUNE_BATCH.to_i64 : excess
            deleted = delete_oldest(batch)
            break if deleted == 0
            removed += deleted
            excess -= deleted
          end
        end

        if max = @max_bytes
          while total_bytes > max
            deleted = delete_oldest(DEFAULT_PRUNE_BATCH.to_i64)
            break if deleted == 0
            removed += deleted
          end
        end

        removed
      end

      # Rows currently stored (expired rows included until pruned).
      def count : Int64
        scalar_i64(scalar("SELECT COUNT(*) FROM #{table_sql}"))
      end

      def size : Int64
        count
      end

      # Sum of `LENGTH(value)` across the table (encoded bytes).
      def total_bytes : Int64
        scalar_i64(scalar("SELECT COALESCE(SUM(LENGTH(#{value_sql})), 0) FROM #{table_sql}"))
      end

      # One-query implementation of the Store default.
      def read_multi(keys : Enumerable(String)) : Hash(String, Value)
        requested = keys.to_a
        result = {} of String => Value
        return result if requested.empty?

        originals = {} of String => String
        requested.each { |key| originals[namespaced(key)] = key }
        placeholders = (["?"] * originals.size).join(", ")
        args = originals.keys.map { |key| key.as(Record::Value) }
        args << now_ms

        query(
          "SELECT #{key_sql}, #{value_sql} FROM #{table_sql} " \
          "WHERE #{key_sql} IN (#{placeholders}) " \
          "AND (#{expires_at_sql} IS NULL OR #{expires_at_sql} > ?)",
          args
        ) do |rs|
          rs.each do
            full = db_text(rs.read)
            raw = db_text(rs.read)
            if key = originals[full]?
              result[key] = decode(raw)
            end
          end
        end
        result
      end

      # One-statement implementation of the Store default.
      def delete_multi(keys : Enumerable(String)) : Int64
        requested = keys.to_a
        return 0_i64 if requested.empty?
        placeholders = (["?"] * requested.size).join(", ")
        args = requested.map { |key| namespaced(key).as(Record::Value) }
        exec("DELETE FROM #{table_sql} WHERE #{key_sql} IN (#{placeholders})", args).rows_affected
      end

      # -- SQL helpers ------------------------------------------------------

      private def lookup(key : String) : Tuple(Bool, Value)
        raw = scalar(
          "SELECT #{value_sql} FROM #{table_sql} " \
          "WHERE #{key_sql} = ? AND (#{expires_at_sql} IS NULL OR #{expires_at_sql} > ?) LIMIT 1",
          [namespaced(key), now_ms] of Record::Value
        )
        return {false, nil} if raw.nil?
        {true, decode(db_text(raw))}
      end

      private def select_row(full : String) : Tuple(String, Int64?)?
        result = nil
        query(
          "SELECT #{value_sql}, #{expires_at_sql} FROM #{table_sql} WHERE #{key_sql} = ? LIMIT 1",
          [full] of Record::Value
        ) do |rs|
          rs.each do
            result = {db_text(rs.read), rs.read(Int64?)}
          end
        end
        result
      end

      private def write_encoded(key : String, payload : String, expires_in : Time::Span?) : Bool
        now = now_ms
        exp = expires_at_ms(expires_in, now)
        exec(write_sql,
          [namespaced(key), payload, exp, now, now] of Record::Value)
        trim if @max_entries || @max_bytes
        true
      end

      # Fallback write used by the rare non-atomic increment path; keeps the
      # original expiry (used for MySQL's zero-changed-rows case).
      private def write_counter_preserving_expiry(full : String, payload : String, expires_at : Int64?, now : Int64) : Nil
        ttl = expires_at ? (expires_at > now ? (expires_at - now).milliseconds : nil) : nil
        write_encoded(full, payload, ttl)
      end

      private def insert_counter(full : String, delta : Int64) : Nil
        now = now_ms
        # Plain INSERT (not an upsert): losing the race must raise a
        # duplicate-key error so the caller retries the atomic UPDATE
        # instead of overwriting another process's increment.
        exec(
          "INSERT INTO #{table_sql} (#{key_sql}, #{value_sql}, #{expires_at_sql}, #{created_at_sql}, #{updated_at_sql}) " \
          "VALUES (?, ?, NULL, ?, ?)",
          [full, "I:#{delta}", now, now] of Record::Value
        )
      end

      # Executes the single-statement atomic increment. SQLite/PostgreSQL
      # return the new encoded value directly (`RETURNING`); MySQL reports
      # changed rows and the caller re-reads.
      private def increment_update(full : String, delta : Int64, now : Int64) : String?
        args = increment_args(full, delta, now)
        if adapter == :mysql
          result = exec(increment_sql, args)
          return nil unless result.rows_affected > 0
          raw = scalar("SELECT #{value_sql} FROM #{table_sql} WHERE #{key_sql} = ? LIMIT 1", [full] of Record::Value)
          raw ? db_text(raw) : nil
        else
          found : String? = nil
          query("#{increment_sql} RETURNING #{value_sql}", args) do |rs|
            rs.each { found = db_text(rs.read) }
          end
          found
        end
      end

      private def increment_args(full : String, delta : Int64, now : Int64) : Array(Record::Value)
        [now, "I:#{delta}", delta, delta, now, now, full, now] of Record::Value
      end

      # The CASE leaves non-numeric values untouched and the WHERE clause
      # only matches expired or numeric rows, so `rows_affected == 0` means
      # "missing or non-numeric" (handled by `increment`).
      private def increment_sql : String
        k = key_sql
        v = value_sql
        e = expires_at_sql
        u = updated_at_sql
        t = table_sql

        case adapter
        when :mysql
          numeric = "CAST(CAST(SUBSTRING(#{v}, 3) AS SIGNED) AS CHAR) = SUBSTRING(#{v}, 3)"
          <<-SQL
            UPDATE #{t} SET
              #{v} = CASE
                WHEN #{e} IS NOT NULL AND #{e} <= ? THEN ?
                WHEN #{v} LIKE 'I:%' AND #{numeric}
                  THEN CONCAT('I:', CAST(CAST(SUBSTRING(#{v}, 3) AS SIGNED) + ? AS CHAR))
                WHEN #{v} LIKE 'S:%' AND #{numeric}
                  THEN CONCAT('S:', CAST(CAST(SUBSTRING(#{v}, 3) AS SIGNED) + ? AS CHAR))
                ELSE #{v}
              END,
              #{e} = CASE WHEN #{e} IS NOT NULL AND #{e} <= ? THEN NULL ELSE #{e} END,
              #{u} = ?
            WHERE #{k} = ? AND (
              (#{e} IS NOT NULL AND #{e} <= ?)
              OR (#{v} LIKE 'I:%' AND #{numeric})
              OR (#{v} LIKE 'S:%' AND #{numeric})
            )
            SQL
        else
          int_type = adapter == :postgres ? "BIGINT" : "INTEGER"
          numeric = "CAST(CAST(SUBSTR(#{v}, 3) AS #{int_type}) AS TEXT) = SUBSTR(#{v}, 3)"
          <<-SQL
            UPDATE #{t} SET
              #{v} = CASE
                WHEN #{e} IS NOT NULL AND #{e} <= ? THEN ?
                WHEN #{v} LIKE 'I:%' AND #{numeric}
                  THEN 'I:' || CAST(CAST(SUBSTR(#{v}, 3) AS #{int_type}) + ? AS TEXT)
                WHEN #{v} LIKE 'S:%' AND #{numeric}
                  THEN 'S:' || CAST(CAST(SUBSTR(#{v}, 3) AS #{int_type}) + ? AS TEXT)
                ELSE #{v}
              END,
              #{e} = CASE WHEN #{e} IS NOT NULL AND #{e} <= ? THEN NULL ELSE #{e} END,
              #{u} = ?
            WHERE #{k} = ? AND (
              (#{e} IS NOT NULL AND #{e} <= ?)
              OR (#{v} LIKE 'I:%' AND #{numeric})
              OR (#{v} LIKE 'S:%' AND #{numeric})
            )
            SQL
        end
      end

      private def write_sql : String
        k = key_sql
        v = value_sql
        e = expires_at_sql
        c = created_at_sql
        u = updated_at_sql
        t = table_sql
        if adapter == :mysql
          "INSERT INTO #{t} (#{k}, #{v}, #{e}, #{c}, #{u}) VALUES (?, ?, ?, ?, ?) " \
          "ON DUPLICATE KEY UPDATE #{v} = VALUES(#{v}), #{e} = VALUES(#{e}), #{u} = VALUES(#{u})"
        else
          "INSERT INTO #{t} (#{k}, #{v}, #{e}, #{c}, #{u}) VALUES (?, ?, ?, ?, ?) " \
          "ON CONFLICT (#{k}) DO UPDATE SET #{v} = excluded.#{v}, #{e} = excluded.#{e}, #{u} = excluded.#{u}"
        end
      end

      private def delete_oldest(limit : Int64) : Int64
        return 0_i64 if limit <= 0
        t = table_sql
        if adapter == :mysql
          # MySQL rejects LIMIT in an IN subquery but supports DELETE ...
          # ORDER BY ... LIMIT on a single table.
          exec("DELETE FROM #{t} ORDER BY #{updated_at_sql} ASC, #{key_sql} ASC LIMIT ?",
            [limit] of Record::Value).rows_affected
        else
          exec(
            "DELETE FROM #{t} WHERE #{key_sql} IN (" \
            "SELECT #{key_sql} FROM #{t} ORDER BY #{updated_at_sql} ASC, #{key_sql} ASC LIMIT ?)",
            [limit] of Record::Value
          ).rows_affected
        end
      end

      private def exec(sql : String, args : Array(Record::Value) = [] of Record::Value) : DB::ExecResult
        if @adapter.nil? || @adapter == Record.adapter_of(@db)
          Record.exec_compat(@db, sql, args)
        else
          # An explicit adapter for a handle `Saci::Record` does not know
          # about (raw `DB.open("postgres://…")`): apply placeholders
          # ourselves but keep the same choke point semantics.
          @db.exec(Record.apply_placeholders(sql, @adapter.not_nil!), args: args)
        end
      end

      private def query(sql : String, args : Array(Record::Value) = [] of Record::Value, &block : DB::ResultSet ->) : Nil
        if @adapter.nil? || @adapter == Record.adapter_of(@db)
          Record.query_compat(@db, sql, args) { |rs| block.call(rs) }
        else
          @db.query(Record.apply_placeholders(sql, @adapter.not_nil!), args: args) { |rs| block.call(rs) }
        end
      end

      private def scalar(sql : String, args : Array(Record::Value) = [] of Record::Value)
        if @adapter.nil? || @adapter == Record.adapter_of(@db)
          Record.scalar_compat(@db, sql, args)
        else
          @db.scalar(Record.apply_placeholders(sql, @adapter.not_nil!), args: args)
        end
      rescue DB::NoResultsError
        # `DB#scalar` raises on an empty result set; a cache miss is normal.
        nil
      end

      private def fetch_string(key : String, expires_in : Time::Span?, &block : -> String) : String
        found, value = lookup(key)
        return value if found && value.is_a?(String)
        # A live non-String entry behaves as a miss for the String API
        # (same contract as MemoryStore#fetch).
        fresh = block.call
        write(key, fresh, expires_in)
        fresh
      end

      private def fetch_value_impl(key : String, expires_in : Time::Span?, &block : -> Value) : Value
        found, value = lookup(key)
        return value if found
        fresh = block.call
        write(key, fresh, expires_in)
        fresh
      end

      private def table_sql : String
        Record.quote(@table, adapter)
      end

      private def key_sql : String
        Record.quote("key", adapter)
      end

      private def value_sql : String
        Record.quote("value", adapter)
      end

      private def expires_at_sql : String
        Record.quote("expires_at", adapter)
      end

      private def created_at_sql : String
        Record.quote("created_at", adapter)
      end

      private def updated_at_sql : String
        Record.quote("updated_at", adapter)
      end

      private def validate_table! : Nil
        unless @table =~ /\A[A-Za-z_][A-Za-z0-9_]*\z/
          raise ArgumentError.new("cache: invalid table name #{@table.inspect}")
        end
      end

      private def clamp_limits! : Nil
        if max = @max_entries
          @max_entries = max < 1 ? 1 : max
        end
        if max = @max_bytes
          @max_bytes = max < 1 ? 1_i64 : max
        end
      end

      private def normalize(value : String | Int | Float | Bool | Time | Nil) : Value
        case value
        when Int   then value.to_i64
        when Float then value.to_f64
        else            value.as(Value)
        end
      end

      private def db_text(raw) : String
        case raw
        when String then raw
        when Bytes  then String.new(raw)
        when Nil    then ""
        else             raw.to_s
        end
      end

      private def scalar_i64(value) : Int64
        case value
        when Int    then value.to_i64
        when Float  then value.to_i64
        when String then value.to_i64? || 0_i64
        when Bytes  then String.new(value).to_i64? || 0_i64
        else             0_i64
        end
      end

      private def counter_value(raw : String) : Int64
        payload = raw.size >= 2 && raw[1] == ':' ? raw[2..] : raw
        payload.to_i64? || raise ArgumentError.new("cache: non-numeric counter value #{raw.inspect}")
      end

      private def now_ms : Int64
        Time.utc.to_unix_ms
      end

      private def expires_at_ms(expires_in : Time::Span?, now : Int64) : Int64?
        return nil if expires_in.nil?
        ms = expires_in.not_nil!.total_milliseconds
        return now + 1 if ms <= 0
        now + ms.ceil.to_i64
      end

      private def like_pattern(pattern : String) : String
        String.build do |io|
          pattern.each_char do |char|
            case char
            when '\\' then io << "\\\\"
            when '%'  then io << "\\%"
            when '_'  then io << "\\_"
            when '*'  then io << '%'
            when '?'  then io << '_'
            else           io << char
            end
          end
        end
      end

      private def duplicate_key_error?(ex : Exception) : Bool
        message = ex.message || ""
        message.includes?("UNIQUE constraint failed") ||
          message.includes?("duplicate key value") ||
          message.includes?("Duplicate entry") ||
          message.includes?("constraint failed")
      end
    end

    # -- store selection helpers (reopened in this file to keep the core
    # cache implementation free of DB/ORM code) ---------------------------

    # `Saci::Cache.store = :db` / `= :memory`. `:db` uses the primary
    # `Saci::Record` connection and creates the cache table if needed.
    def self.store=(kind : Symbol) : Nil
      case kind
      when :memory
        self.store = MemoryStore.new
      when :db
        self.store = DbStore.new(Record.connection)
      else
        raise ArgumentError.new("Unknown cache store #{kind.inspect} (expected :memory or :db, or assign a Saci::Cache::Store)")
      end
    end

    # Rails-style alias for `store` / `store=`.
    def self.cache_store : Store
      store
    end

    def self.cache_store=(store : Store) : Nil
      self.store = store
    end

    def self.cache_store=(kind : Symbol) : Nil
      self.store = kind
    end

    # Switches the global cache to a DB-backed store and ensures its schema.
    # Accepts an existing handle (primary/transaction/any `DB::Database`) or
    # a connection URL:
    #
    # ```
    # Saci::Cache.use_database!(Saci::Record.connection)
    # Saci::Cache.use_database!("sqlite3://./db/cache.db", max_entries: 100_000)
    # Saci::Cache.use_database!(database: "cache")
    # ```
    def self.use_database!(target : DB::Database | DB::Connection | String,
                           *,
                           table : String = DbStore::TABLE,
                           namespace : String = "",
                           adapter : Symbol? = nil,
                           max_entries : Int32? = nil,
                           max_bytes : Int64? = nil,
                           auto_schema : Bool = true) : DbStore
      db_store = case target
                 when String
                   DbStore.new(url: target,
                     table: table,
                     namespace: namespace,
                     adapter: adapter,
                     max_entries: max_entries,
                     max_bytes: max_bytes,
                     auto_schema: auto_schema)
                 else
                   DbStore.new(target,
                     table: table,
                     namespace: namespace,
                     adapter: adapter,
                     max_entries: max_entries,
                     max_bytes: max_bytes,
                     auto_schema: auto_schema)
                 end
      self.store = db_store
      db_store
    end

    # Named-database form (`Saci::Record.establish_connection("cache", url)`).
    def self.use_database!(*, database : String,
                           table : String = DbStore::TABLE,
                           namespace : String = "",
                           adapter : Symbol? = nil,
                           max_entries : Int32? = nil,
                           max_bytes : Int64? = nil,
                           auto_schema : Bool = true) : DbStore
      db_store = DbStore.new(database: database,
        table: table,
        namespace: namespace,
        adapter: adapter,
        max_entries: max_entries,
        max_bytes: max_bytes,
        auto_schema: auto_schema)
      self.store = db_store
      db_store
    end

    # URL keyword form (`use_database!(url: "sqlite3://./db/cache.db")`).
    def self.use_database!(*, url : String,
                           table : String = DbStore::TABLE,
                           namespace : String = "",
                           adapter : Symbol? = nil,
                           max_entries : Int32? = nil,
                           max_bytes : Int64? = nil,
                           auto_schema : Bool = true) : DbStore
      use_database!(url,
        table: table,
        namespace: namespace,
        adapter: adapter,
        max_entries: max_entries,
        max_bytes: max_bytes,
        auto_schema: auto_schema)
    end

    # Multi-key helpers on the module (delegate to the current store).
    def self.read_multi(keys : Enumerable(String)) : Hash(String, Value)
      store.read_multi(keys)
    end

    def self.write_multi(values : Hash(String, T), expires_in : Time::Span? = nil) : Bool forall T
      store.write_multi(values, expires_in)
    end

    def self.delete_multi(keys : Enumerable(String)) : Int64
      store.delete_multi(keys)
    end

    def self.fetch_multi(keys : Enumerable(String), expires_in : Time::Span? = nil, &block : String -> Value) : Hash(String, Value)
      store.fetch_multi(keys, expires_in) { |key| block.call(key) }
    end
  end
end
