require "db"
require "sqlite3"
require "./record/inflector"
require "./record/errors"
require "./record/query"
require "./record/base"
require "./record/migration"

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
    def self.transaction(&block : DB::Connection -> T) : T? forall T
      transaction_on(connection, &block)
    end

    def self.transaction_on(db : DB::Database | DB::Connection, &block : DB::Connection -> T) : T? forall T
      if db.is_a?(DB::Connection)
        block.call(db)
      elsif current = tx_for_database(db)
        block.call(current)
      else
        db.transaction do |t|
          tx_push(db, t.connection)
          begin
            block.call(t.connection)
          ensure
            tx_pop
          end
        end
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

    def self.parse_time(s : String?) : Time?
      return nil if s.nil? || s.empty?
      Time.parse_rfc3339(s)
    rescue Time::Format::Error
      nil
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

    # Reads one column from a result set given the declared column type.
    # Native drivers return native values (real booleans/timestamps/ints);
    # SQLite returns the text/int encodings `to_db` produced.
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
      when "String"  then rs.read(String?)
      when "Bytes"   then rs.read(Bytes?)
      else                rs.read(String?)
      end
    end
  end
end
