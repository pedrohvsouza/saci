require "db"
require "sqlite3"
require "json"
require "./record/inflector"
require "./record/errors"
require "./record/query"
require "./record/base"
require "./record/migration"
require "./record/schema"
require "./record/fts"
require "./record/secure_token"

module Saci
  # ActiveRecord-equivalent ORM (crystal-db: SQLite, PostgreSQL, MySQL).
  #
  # SQLite works out of the box. PostgreSQL/MySQL need their driver shard
  # in YOUR app (the framework never requires drivers itself — see below):
  #
  # ```yaml
  # # shard.yml
  # dependencies:
  #   pg:
  #     github: will/crystal-pg
  #     version: "~> 0.30.0"
  # ```
  #
  # ```crystal
  # require "pg" # or require "mysql"
  # Saci::Record.connect("postgres://localhost/myapp")
  # ```
  #
  # Why app-owned? `DB.open` resolves the driver through a virtual dispatch
  # that links EVERY registered driver's connect path — including pg's
  # `Digest`-based auth, which cannot link on systems with OpenSSL ≥ 3.2
  # (removed `EVP_MD_*` symbols; same reason Saci vendors its GCM binding).
  # Requiring drivers in the framework would break linking for all users
  # on modern systems, including pure-SQLite ones.
  #
  # ```
  # Saci::Record.connection = DB.open("sqlite3://./app.db")
  # #
  # # class ApplicationRecord < Saci::Record::Base
  # end
  #
  # class Post < ApplicationRecord
  #   column id : Int64, primary: true
  #   column title : String
  #   column published : Bool
  #   timestamps
  #
  #   validates :title, presence: true, max_length: 200
  #
  #   belongs_to :user
  # end
  #
  # Post.where(published: true).order(title: :asc).limit(10).to_a
  # ```
  #
  # Adapter notes (SQLite is the reference implementation):
  # * Placeholders are written `?` everywhere; PostgreSQL queries are
  #   rewritten to `$1, $2, …` at execution. MySQL uses `?` natively.
  # * Identifiers are double-quoted on SQLite/PostgreSQL and backticked on
  #   MySQL (`Record.quote`).
  # * `Time`/`Bool` bind natively on PostgreSQL/MySQL; on SQLite they are
  #   stored as RFC3339 text / `0`/`1` (`Record.to_db`).
  # * Auto-increment PKs: `AUTOINCREMENT` (SQLite), `BIGSERIAL` (PostgreSQL),
  #   `BIGINT AUTO_INCREMENT` (MySQL). Inserts use `RETURNING` on PostgreSQL
  #   (`last_insert_id` is unsupported by crystal-pg).
  module Record
    # Every value a column, condition or assignment may carry.
    alias Value = String | Int32 | Int64 | Float32 | Float64 | Bool | Time | Bytes | Nil

    # Database adapters, detected from the connection URL scheme
    # (`sqlite3://` → `:sqlite`, `postgres(ql)://` → `:postgres`,
    # `mysql://` → `:mysql`).
    alias Adapter = Symbol

    class RecordNotFound < Exception
    end

    class RecordNotSaved < Exception
    end

    # Raised by `dependent: :restrict_with_exception` when a record still
    # has dependent children at destroy time (Rails-compatible).
    class DeleteRestrictionError < Exception
    end

    class UnknownAttributeError < Exception
    end

    class IrreversibleMigration < Exception
    end

    class RecordInvalid < Exception
      getter record_errors : Errors

      def initialize(@record_errors : Errors)
        super("Validation failed: #{@record_errors.full_messages.join(", ")}")
      end
    end

    # NOTE: connection state lives here (module level), not on `Base`,
    # because Crystal class variables are per-class — a `@@connection`
    # assigned on `Base` would be invisible to subclasses.
    @@connection : DB::Database? = nil

    # Open transactions: (database, connection) pairs keyed by fiber, so
    # concurrent fibers never share one and nested blocks reuse the right
    # database's transaction. Entries push/pop symmetrically — no leaks.
    @@tx_stacks = {} of UInt64 => Array(Tuple(DB::Database, DB::Connection))
    @@tx_mutex = Mutex.new

    # Named databases. `"primary"` is the default; `connection=` assigns it.
    # Additional databases (other SQLite files, …) are registered explicitly:
    #
    # ```
    # Saci::Record.establish_connection("analytics", "sqlite3://./db/analytics.db")
    # ```
    @@databases = {} of String => DB::Database
    @@databases_mutex = Mutex.new

    # Connection URLs per database name (adapter detection; see
    # `adapter_for_url`). `connection=` records the URL when given it.
    @@database_urls = {} of String => String
    @@database_urls_mutex = Mutex.new

    # Detects the adapter from a connection URL scheme. Raises on unknown
    # schemes (fail fast on typos like `postgress://`).
    def self.adapter_for_url(url : String) : Adapter
      case url.split("://", 2)[0].downcase
      when "sqlite3"                  then :sqlite
      when "postgres", "postgresql"   then :postgres
      when "mysql"                    then :mysql
      else                                 raise ArgumentError.new("Unknown database adapter in URL #{url.inspect} (expected sqlite3://, postgres:// or mysql://)")
      end
    end

    # Adapter of a named database (`:sqlite` when no URL was recorded —
    # e.g. `connection=` without one — preserving single-DB behavior).
    def self.adapter_for_name(name : String) : Adapter
      url = @@database_urls_mutex.synchronize { @@database_urls[name]? }
      url ? adapter_for_url(url) : :sqlite
    end

    # Adapter behind a live handle (transaction connections resolve to
    # their owning database via this fiber's transaction stack).
    def self.adapter_of(db : DB::Database | DB::Connection) : Adapter
      if db.is_a?(DB::Database)
        found_name = @@databases_mutex.synchronize do
          @@databases.each_key.find { |name| @@databases[name]? == db }
        end
        found_name ? adapter_for_name(found_name) : :sqlite
      else
        owner = @@tx_mutex.synchronize do
          @@tx_stacks[Fiber.current.object_id]?.try do |stack|
            stack.find { |(_, conn)| conn == db }.try(&.[0])
          end
        end
        owner ? adapter_of(owner) : adapter_for_name(current_database_name)
      end
    end

    # Quotes an identifier for the adapter (`"x"` on SQLite/PostgreSQL,
    # `` `x` `` on MySQL).
    def self.quote(name : String | Symbol, adapter : Adapter = :sqlite) : String
      adapter == :mysql ? "`#{name}`" : "\"#{name}\""
    end

    # Rewrites `?` placeholders to `$1, $2, …` for PostgreSQL; all other
    # adapters use `?` natively. Only applies to SQL text — bound values
    # are never touched. `?` inside single-quoted literals is left alone.
    def self.apply_placeholders(sql : String, adapter : Adapter) : String
      return sql unless adapter == :postgres
      n = 0
      in_string = false
      String.build do |io|
        chars = sql.chars
        i = 0
        while i < chars.size
          char = chars[i]
          if in_string
            io << char
            if char == '\''
              if chars[i + 1]? == '\''
                io << chars[i + 1]
                i += 1
              else
                in_string = false
              end
            end
          elsif char == '\''
            in_string = true
            io << char
          elsif char == '?'
            n += 1
            io << "$" << n
          else
            io << char
          end
          i += 1
        end
      end
    end

    # Execution choke points: every query flows through these so
    # placeholders (and only placeholders) adapt per database.
    def self.exec_compat(db : DB::Database | DB::Connection, sql : String, args : Array(Value) = [] of Value) : DB::ExecResult
      db.exec(apply_placeholders(sql, adapter_of(db)), args: args)
    end

    def self.query_compat(db : DB::Database | DB::Connection, sql : String, args : Array(Value) = [] of Value, & : DB::ResultSet ->) : Nil
      db.query(apply_placeholders(sql, adapter_of(db)), args: args) { |rs| yield rs }
    end

    def self.scalar_compat(db : DB::Database | DB::Connection, sql : String, args : Array(Value) = [] of Value)
      db.scalar(apply_placeholders(sql, adapter_of(db)), args: args)
    end

    # Fiber-local default-database override (`connected_to`).
    @@connected_db = {} of UInt64 => String
    @@connected_mutex = Mutex.new

    def self.establish_connection(name : String, url : String) : DB::Database
      adapter = adapter_for_url(url) # fail fast on unknown schemes
      db = DB.open(url)
      apply_sqlite_tuning(db) if adapter == :sqlite
      @@databases_mutex.synchronize { @@databases[name] = db }
      @@database_urls_mutex.synchronize { @@database_urls[name] = url }
      db
    end

    def self.database(name : String) : DB::Database
      @@databases_mutex.synchronize do
        @@databases[name]? || raise "Unknown database #{name.inspect} (known: #{@@databases.keys.inspect}). Register it with Saci::Record.establish_connection."
      end
    end

    def self.configuration_names : Array(String)
      @@databases_mutex.synchronize { @@databases.keys }
    end

    def self.connection=(db : DB::Database) : Nil
      @@connection = db
      apply_sqlite_tuning(db) if adapter_for_name("primary") == :sqlite
      @@databases_mutex.synchronize { @@databases["primary"] = db }
    end

    # Opens a URL and assigns it as the primary database, recording the URL
    # so the adapter is detected (unlike `connection=`, which keeps the
    # SQLite default for backward compatibility).
    def self.connect(url : String) : DB::Database
      db = establish_connection("primary", url)
      @@connection = db
      db
    end

    def self.connection : DB::Database | DB::Connection
      name = current_database_name
      db = begin
        database(name)
      rescue ex
        raise ex if name != "primary"
        raise "Saci::Record.connection is not set. Assign a DB::Database first, e.g. Saci::Record.connection = DB.open(\"sqlite3://./app.db\")"
      end
      tx_for_database(db) || db
    end

    # Runs the block with another database as the default (models with an
    # explicit `connects_to` keep theirs). Nestable.
    def self.connected_to(database : String, & : -> T) : T forall T
      self.database(database) # fail fast on typos
      key = Fiber.current.object_id
      prev = @@connected_mutex.synchronize { @@connected_db[key]? }
      @@connected_mutex.synchronize { @@connected_db[key] = database }
      begin
        yield
      ensure
        @@connected_mutex.synchronize do
          if before = prev
            @@connected_db[key] = before
          else
            @@connected_db.delete(key)
          end
        end
      end
    end

    def self.current_database_name : String
      @@connected_mutex.synchronize { @@connected_db[Fiber.current.object_id]? } || "primary"
    end

    # Connection for a named database, joining its open transaction when
    # nested (used by `connects_to` models).
    def self.connection_for(name : String) : DB::Database | DB::Connection
      db = database(name)
      tx_for_database(db) || db
    end

    private def self.apply_sqlite_tuning(db : DB::Database) : Nil
      # SQLite tuning for web workloads, applied to every pooled connection
      # (existing and future): WAL lets readers proceed during writes,
      # busy_timeout makes concurrent writers wait instead of failing.
      db.setup_connection do |conn|
        conn.exec("PRAGMA journal_mode=WAL")
        conn.exec("PRAGMA busy_timeout=5000")
      end
    end

    # Block runs inside a transaction (reuses the current one for the same
    # database if nested in the same fiber). Raise to roll back
    # (`DB::Rollback` rolls back silently and returns nil, like
    # ActiveRecord::Rollback). No atomicity across databases.
    # `after_commit` model callbacks registered inside the block are
    # deferred: they run after the outermost commit and are discarded on
    # rollback.
    def self.transaction(&block : DB::Connection -> T) : T? forall T
      transaction_on(connection, &block)
    end

    def self.transaction_on(db : DB::Database | DB::Connection, &block : DB::Connection -> T) : T? forall T
      if db.is_a?(DB::Connection)
        block.call(db)
      elsif current = tx_for_database(db)
        block.call(current)
      else
        committed = false
        result : T? = nil
        begin
          result = db.transaction do |t|
            tx_push(db, t.connection)
            begin
              r = block.call(t.connection)
              committed = true
              r
            ensure
              tx_pop
            end
          end
        rescue ex : Exception
          discard_after_commit(db)
          raise ex
        end
        if committed
          run_after_commit(db)
        else
          discard_after_commit(db)
        end
        result
      end
    end

    private def self.tx_for_database(db : DB::Database?) : DB::Connection?
      @@tx_mutex.synchronize do
        if stack = @@tx_stacks[Fiber.current.object_id]?
          found = nil
          stack.reverse_each do |entry_db, conn|
            if db.nil? || entry_db == db
              found = conn
              break
            end
          end
          found
        end
      end
    end

    private def self.tx_push(db : DB::Database, conn : DB::Connection) : Nil
      @@tx_mutex.synchronize do
        stack = @@tx_stacks[Fiber.current.object_id] ||= [] of Tuple(DB::Database, DB::Connection)
        stack << {db, conn}
      end
    end

    private def self.tx_pop : Nil
      @@tx_mutex.synchronize do
        if stack = @@tx_stacks[Fiber.current.object_id]?
          stack.pop if stack.any?
          @@tx_stacks.delete(Fiber.current.object_id) if stack.empty?
        end
      end
    end

    # Owning database behind a transaction connection (`nil` when the
    # connection is not part of this fiber's transaction stack).
    def self.tx_database_for(conn : DB::Connection) : DB::Database?
      @@tx_mutex.synchronize do
        @@tx_stacks[Fiber.current.object_id]?.try do |stack|
          stack.find { |(_, c)| c == conn }.try(&.[0])
        end
      end
    end

    # Deferred `after_commit` hooks, keyed by fiber. Each entry records the
    # database it belongs to so per-database commits/rollbacks only affect
    # their own hooks.
    @@after_commit_hooks = {} of UInt64 => Array(Tuple(UInt64, Proc(Nil)))

    # Registers a hook to run when the current outermost transaction on
    # `db` commits (call only while inside that transaction).
    def self.defer_after_commit(db : DB::Database, &block : -> Nil) : Nil
      key = Fiber.current.object_id
      @@tx_mutex.synchronize do
        (@@after_commit_hooks[key] ||= [] of Tuple(UInt64, Proc(Nil))) << {db.object_id, block}
      end
    end

    private def self.take_after_commit(db : DB::Database) : Array(Proc(Nil))
      key = Fiber.current.object_id
      @@tx_mutex.synchronize do
        if arr = @@after_commit_hooks[key]?
          mine = arr.select { |(id, _)| id == db.object_id }.map(&.[1])
          rest = arr.reject { |(id, _)| id == db.object_id }
          if rest.empty?
            @@after_commit_hooks.delete(key)
          else
            @@after_commit_hooks[key] = rest
          end
          mine
        else
          [] of Proc(Nil)
        end
      end
    end

    # Runs hooks deferred on `db` (outermost commit path).
    def self.run_after_commit(db : DB::Database) : Nil
      take_after_commit(db).each(&.call)
    end

    # Discards hooks deferred on `db` (rollback path).
    def self.discard_after_commit(db : DB::Database) : Nil
      take_after_commit(db)
    end

    def self.to_i64(v : Value) : Int64?
      case v
      when Nil    then nil
      when Number then v.to_i64
      when String then v.to_i64?
      when Bool   then v ? 1_i64 : 0_i64
      when Time   then v.to_unix
      else             nil
      end
    end

    def self.to_i32(v : Value) : Int32?
      case v
      when Nil    then nil
      when Number then v.to_i32
      when String then v.to_i32?
      when Bool   then v ? 1 : 0
      when Time   then v.to_unix.to_i32
      else             nil
      end
    end

    def self.to_f64(v : Value) : Float64?
      case v
      when Nil    then nil
      when Number then v.to_f64
      when String then v.to_f64?
      when Bool   then v ? 1.0 : 0.0
      else             nil
      end
    end

    def self.to_bool(v : Value) : Bool?
      case v
      when Nil    then nil
      when Bool   then v
      when Number then v != 0
      when String
        !{"false", "f", "no", "n", "0", ""}.includes?(v.strip.downcase)
      when Time then true
      else           nil
      end
    end

    # Converts user input into a DB-safe bind value. SQLite stores `Bool`
    # as `0`/`1` and `Time` as RFC3339 text; PostgreSQL/MySQL bind both
    # natively through their drivers.
    def self.to_db(v : Object, adapter : Adapter = :sqlite) : Value
      case v
      when Nil    then nil
      when Bool   then adapter == :sqlite ? (v ? 1_i64 : 0_i64) : v
      when Time   then adapter == :sqlite ? v.to_rfc3339 : v
      when String, Int32, Int64, Float32, Float64, Bytes then v
      else
        raise ArgumentError.new("Unsupported query value: #{v.inspect} (#{v.class})")
      end
    end

    # Rails-like blank? for validation gating (`allow_blank`): nil, false
    # and empty/whitespace strings (or empty blobs) are blank.
    def self.blank?(v : Value) : Bool
      case v
      when Nil    then true
      when Bool   then !v
      when String then v.strip.empty?
      when Bytes  then v.empty?
      else             false
      end
    end

    def self.parse_time(s : String?) : Time?
      return nil if s.nil? || s.empty?
      str = s.as(String)
      begin
        Time.parse_rfc3339(str)
      rescue Time::Format::Error
        begin
          Time.parse(str, "%Y-%m-%d", Time::Location::UTC)
        rescue Time::Format::Error
          nil
        end
      end
    end

    # Renders a column DEFAULT clause value (nil = no default).
    def self.column_default_sql(default : Value, adapter : Adapter = :sqlite) : String?
      case default
      when Nil    then nil
      when Bool   then adapter == :postgres ? (default ? "TRUE" : "FALSE") : (default ? "1" : "0")
      when Number then default.to_s
      when String then "'#{default.gsub("'", "''")}'"
      when Time   then "'#{default.to_rfc3339}'"
      else             nil
      end
    end

    # Logical column types (migration DSL) per adapter.
    def self.db_type(logical : Symbol, adapter : Adapter) : String
      case logical
      when :string   then "VARCHAR(255)"
      when :text     then "TEXT"
      when :integer  then "INTEGER"
      when :bigint   then adapter == :sqlite ? "INTEGER" : "BIGINT"
      when :float    then adapter == :sqlite ? "REAL" : (adapter == :postgres ? "DOUBLE PRECISION" : "DOUBLE")
      when :decimal  then adapter == :sqlite ? "REAL" : (adapter == :postgres ? "DOUBLE PRECISION" : "DOUBLE")
      when :date     then adapter == :sqlite ? "TEXT" : "DATE"
      # crystal-mysql cannot decode the native JSON column type
      # (MYSQL_TYPE_JSON), so JSON is stored as TEXT on MySQL (the JSON
      # content itself is unchanged — String-backed round-trip).
      when :json     then adapter == :postgres ? "JSONB" : "TEXT"
      when :boolean  then adapter == :sqlite ? "INTEGER" : "BOOLEAN"
      when :datetime then adapter == :sqlite ? "TEXT" : (adapter == :postgres ? "TIMESTAMP" : "DATETIME")
      when :serial   then adapter == :postgres ? "BIGSERIAL" : (adapter == :mysql ? "BIGINT" : "INTEGER")
      else                raise ArgumentError.new("Unknown column type #{logical}")
      end
    end

    # Deletes every row from every table except `schema_migrations`.
    # Test helper — call in `before_each` for a clean slate.
    def self.clean_database! : Nil
      db = connection
      adapter = adapter_of(db)
      list_sql = case adapter
                 when :postgres then "SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND tablename != 'schema_migrations'"
                 when :mysql    then "SELECT table_name FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name != 'schema_migrations'"
                 else                "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name != 'schema_migrations'"
                 end
      tables = [] of String
      query_compat(db, list_sql) do |rs|
        rs.each { tables << rs.read(String) }
      end
      tables.each { |t| exec_compat(db, "DELETE FROM #{quote(t, adapter)}") }
    end

    # Atomically adjusts an integer counter column (`counter_cache`).
    def self.update_counter(db : DB::Database | DB::Connection, table : String, pk : String, id : Value, column : String, delta : Int64) : Nil
      return if id.nil?
      ad = adapter_of(db)
      exec_compat(db,
        "UPDATE #{quote(table, ad)} SET #{quote(column, ad)} = COALESCE(#{quote(column, ad)}, 0) + (#{delta}) WHERE #{quote(pk, ad)} = ?",
        [to_db(id, ad)] of Value)
    end

    # Bumps timestamp columns directly (`belongs_to touch:`).
    def self.touch_row(db : DB::Database | DB::Connection, table : String, pk : String, id : Value, columns : Array(String)) : Nil
      return if id.nil? || columns.empty?
      ad = adapter_of(db)
      now = to_db(Time.utc, ad)
      sets = columns.map { |c| "#{quote(c, ad)} = ?" }.join(", ")
      vals = columns.map { now } + [to_db(id, ad)] of Value
      exec_compat(db, "UPDATE #{quote(table, ad)} SET #{sets} WHERE #{quote(pk, ad)} = ?", vals)
    end

    # -- polymorphic registry ---------------------------------------------
    # `belongs_to ... polymorphic: true` stores `<name>_type` (class name)
    # + `<name>_id` and resolves through these batch fetchers. Every model
    # auto-registers itself via `Base.inherited` (full name + demodulized
    # short name), so `has_many ... as: :notifiable` targets resolve
    # without extra wiring. Custom type strings can be registered manually:
    #
    # ```
    # Saci::Record.register_polymorphic("Comment") { |ids| Comment.where(...).to_a.map(&.as(Base)) }
    # ```
    @@poly_fetchers = {} of String => Proc(Array(Value), Array(Base))
    @@poly_mutex = Mutex.new

    def self.register_polymorphic(name : String, &fetcher : Array(Value) -> Array(Base)) : Nil
      @@poly_mutex.synchronize do
        @@poly_fetchers[name] = fetcher
        short = name.split("::").last
        @@poly_fetchers[short] = fetcher unless @@poly_fetchers.has_key?(short)
      end
    end

    def self.polymorphic_fetcher(type : String) : Proc(Array(Value), Array(Base))?
      @@poly_mutex.synchronize { @@poly_fetchers[type]? || @@poly_fetchers[type.split("::").last]? }
    end

    # Single-record polymorphic load (nil id/type → nil; unknown type or
    # missing row raises `RecordNotFound`, like a dangling `belongs_to`).
    def self.resolve_polymorphic(type : String | Value, id : Value) : Base?
      return nil if type.nil? || id.nil?
      t = type.to_s
      fetcher = polymorphic_fetcher(t) || raise RecordNotFound.new("Unknown polymorphic type '#{t}'")
      found = fetcher.call([id] of Value)
      found.first? || raise RecordNotFound.new("Couldn't find polymorphic #{t} with id=#{id}")
    end

    # Batch polymorphic load (`WHERE id IN (...)`, one query per type).
    # Returns `{id_value => record}` for cache assignment.
    def self.resolve_polymorphic_many(type : String, ids : Array(Value)) : Hash(Value, Base)
      h = {} of Value => Base
      return h if ids.empty?
      fetcher = polymorphic_fetcher(type) || raise ArgumentError.new("Unknown polymorphic type '#{type}' for includes")
      uniq_ids = ids.uniq
      return h if uniq_ids.empty?
      fetcher.call(uniq_ids).each do |rec|
        pk = rec.class.__saci_primary_key
        h[rec.__saci_get_attr(pk)] = rec
      end
      h
    end

    # Reads one result column of unknown type (raw `select` expressions,
    # aggregates, group keys) into a `Value`. Anything the drivers return
    # outside `Value` (e.g. PG numerics) degrades to its string form.
    # crystal-pg decodes `json`/`jsonb` as `JSON::PullParser` — consume it
    # to its raw source text (not `to_s`, which is the parser's inspect).
    def self.read_generic(rs : DB::ResultSet) : Value
      case v = rs.read
      when Value
        v
      when JSON::PullParser
        v.read_raw
      else
        v.to_s
      end
    end

    # Reads one column from a result set given the declared column type.
    # Native drivers return native values (real booleans/timestamps/ints);
    # SQLite returns the text/int encodings `to_db` produced.
    #
    # String-backed columns (`String`, `JSON`) on PostgreSQL are read
    # untyped: `json`/`jsonb` arrive as `JSON::PullParser` (which
    # `read(String?)` rejects), so convert here instead.
    def self.read_typed(rs : DB::ResultSet, col_type : String, adapter : Adapter = :sqlite) : Value
      case col_type
      when "Bool"
        adapter == :sqlite ? rs.read(Int64?).try { |v| v != 0 } : rs.read(Bool?)
      when "Time"
        adapter == :sqlite ? parse_time(rs.read(String?)) : rs.read(Time?)
      when "Int64" then rs.read(Int64?)
      when "Int32"
        adapter == :sqlite ? rs.read(Int64?) : rs.read(Int32?)
      when "Float64" then rs.read(Float64?)
      when "String"
        if adapter == :postgres
          case v = rs.read
          when Nil              then nil
          when String           then v
          when Bytes            then String.new(v)
          when JSON::PullParser then v.read_raw
          else                       v.to_s
          end
        else
          rs.read(String?)
        end
      when "Bytes"   then rs.read(Bytes?)
      else                rs.read(String?)
      end
    end
  end
end
