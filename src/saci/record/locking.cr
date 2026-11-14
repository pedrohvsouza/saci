module Saci
  module Record
    # Raised by `lock!` / `with_lock` when no transaction is open (Rails:
    # `ActiveRecord::TransactionRequired`). Row locks only live for the
    # duration of a transaction, so acquiring one outside is meaningless.
    class TransactionRequired < Exception
    end

    # Raised by optimistic locking (G20) when a `lock_version` row was
    # changed by someone else between load and write.
    class StaleObjectError < Exception
    end

    # Isolation levels accepted by `Base.transaction(isolation:)` (G21).
    ISOLATION_SQL = {
      serializable:     "SERIALIZABLE",
      repeatable_read:  "REPEATABLE READ",
      read_committed:   "READ COMMITTED",
      read_uncommitted: "READ UNCOMMITTED",
    }

    # SQL used to open a transaction at a given isolation level, or nil for
    # adapters with no per-transaction isolation (SQLite is always
    # serializable). Public so applications (and the spec suite) can assert
    # the statement without a live PostgreSQL/MySQL server.
    def self.isolation_sql(adapter : Adapter, isolation : Symbol) : String?
      level = ISOLATION_SQL[isolation]? || raise ArgumentError.new(
        "Unknown transaction isolation #{isolation.inspect} (expected :serializable, :repeatable_read, :read_committed or :read_uncommitted)")
      case adapter
      when :postgres then "BEGIN ISOLATION LEVEL #{level}"
      when :mysql    then "SET TRANSACTION ISOLATION LEVEL #{level}"
      else                nil
      end
    end

    # Locking clause appended to SELECTs, or nil when the adapter has no row
    # locks. SQLite documents `FOR UPDATE` as unavailable; it is omitted so
    # the statement stays valid (the transaction still serializes writers).
    def self.locking_clause(adapter : Adapter, clause : String = "FOR UPDATE") : String?
      case adapter
      when :postgres, :mysql then clause
      else                        nil
      end
    end

    # True while the current fiber is inside a transaction.
    def self.transaction_open? : Bool
      connection.is_a?(DB::Connection)
    end

    # Fiber-local `no_touching` nesting depth (G238). `touch` and
    # `belongs_to touch:` writes are suppressed while this is non-zero.
    @@no_touching = {} of UInt64 => Int32
    @@no_touching_mutex = Mutex.new

    def self.no_touching? : Bool
      @@no_touching_mutex.synchronize { (@@no_touching[Fiber.current.object_id]? || 0) > 0 }
    end

    # `Saci::Record.no_touching { ... }` — suppresses `updated_at` bumps
    # caused by `touch`/`belongs_to touch:` inside the block. Normal saves
    # still maintain their own timestamps (Rails semantics). Nestable.
    def self.no_touching(&block : -> T) : T forall T
      key = Fiber.current.object_id
      @@no_touching_mutex.synchronize { @@no_touching[key] = (@@no_touching[key]? || 0) + 1 }
      begin
        yield
      ensure
        @@no_touching_mutex.synchronize do
          count = (@@no_touching[key]? || 1) - 1
          if count <= 0
            @@no_touching.delete(key)
          else
            @@no_touching[key] = count
          end
        end
      end
    end

    # Fiber-local stack of model names whose `default_scope` is off
    # (`Model.unscoped { ... }`).
    @@unscoped_models = {} of UInt64 => Array(String)
    @@unscoped_mutex = Mutex.new

    def self.default_scope_skipped?(model : String) : Bool
      @@unscoped_mutex.synchronize do
        @@unscoped_models[Fiber.current.object_id]?.try(&.includes?(model)) || false
      end
    end

    def self.without_default_scope(model : String, &block : -> T) : T forall T
      key = Fiber.current.object_id
      @@unscoped_mutex.synchronize { (@@unscoped_models[key] ||= [] of String) << model }
      begin
        yield
      ensure
        @@unscoped_mutex.synchronize do
          if stack = @@unscoped_models[key]?
            stack.pop?
            @@unscoped_models.delete(key) if stack.empty?
          end
        end
      end
    end

    # `Base.transaction(isolation:)` implementation.
    #
    # Nested calls join the open transaction (isolation is ignored, matching
    # Rails). For a fresh transaction, the BEGIN statement is written
    # manually so PostgreSQL/MySQL receive their isolation syntax; the
    # connection is registered in the fiber's transaction stack exactly like
    # `transaction_on`, so model queries and deferred `after_commit` hooks
    # see it.
    def self.transaction_with_isolation(db : DB::Database | DB::Connection, isolation : Symbol, &block : DB::Connection -> T) : T? forall T
      level_sql = ISOLATION_SQL[isolation]? || raise ArgumentError.new(
        "Unknown transaction isolation #{isolation.inspect} (expected :serializable, :repeatable_read, :read_committed or :read_uncommitted)")
      # Already inside a transaction (or handed a transaction connection):
      # join it — SQL does not allow changing isolation mid-transaction.
      if db.is_a?(DB::Connection)
        return block.call(db)
      end
      if current = tx_for_database(db)
        return block.call(current)
      end
      ad = adapter_of(db)
      # SQLite supports one isolation level (serializable). Fall back to the
      # normal driver transaction; callers can still rely on serializability.
      if ad == :sqlite
        return transaction_on(db) { |conn| block.call(conn) }
      end

      conn = db.checkout
      committed = false
      result : T? = nil
      begin
        case ad
        when :postgres
          conn.exec("BEGIN ISOLATION LEVEL #{level_sql}")
        when :mysql
          conn.exec("SET TRANSACTION ISOLATION LEVEL #{level_sql}")
          conn.exec("BEGIN")
        else
          conn.exec("BEGIN")
        end
        tx_push(db, conn)
        begin
          result = block.call(conn)
          committed = true
        ensure
          tx_pop
        end
        conn.exec("COMMIT")
        run_after_commit(db)
        result
      rescue ex : DB::Rollback
        begin
          conn.exec("ROLLBACK")
        rescue
        end
        discard_after_commit(db)
        nil
      rescue ex
        begin
          conn.exec("ROLLBACK")
        rescue
        end
        discard_after_commit(db)
        raise ex
      ensure
        conn.release
      end
    end
  end

  class Record::Base
    # True when the current save/fiber runs inside a transaction (G21).
    def self.in_transaction? : Bool
      Saci::Record.transaction_open?
    end

    def in_transaction? : Bool
      Saci::Record.transaction_open?
    end

    # Reloads the row under `SELECT … FOR UPDATE` (G21). Must be called
    # inside a transaction; on SQLite the lock clause is omitted (observable
    # no-op) but the reload still happens.
    def lock! : self
      unless Saci::Record.transaction_open?
        raise Saci::Record::TransactionRequired.new("lock! requires an open transaction (use with_lock)")
      end
      pk = self.class.__saci_primary_key
      pk_val = __saci_get_attr(pk)
      raise Saci::Record::RecordNotFound.new("Cannot lock a new #{self.class} record") if pk_val.nil?
      ad = Saci::Record.adapter_of(self.class.connection)
      fresh = self.class
        .where(Saci::Record.quote(pk, ad) + " = ?", pk_val)
        .lock("FOR UPDATE")
        .first
      raise Saci::Record::RecordNotFound.new("Couldn't find #{self.class} with '#{pk}'=#{pk_val}") if fresh.nil?
      self.class.__saci_column_names.each do |(name, _)|
        __saci_set_attr(name, fresh.__saci_get_attr(name))
      end
      @new_record = false
      @destroyed = false
      __saci_dirty_reset!
      self
    end

    # `record.with_lock { |locked| ... }` — opens a transaction, takes the
    # row lock, yields, and commits (or rolls back on an exception).
    def with_lock(&block : self -> T) : T? forall T
      self.class.transaction do |_conn|
        lock!
        block.call(self)
      end
    end
  end
end
