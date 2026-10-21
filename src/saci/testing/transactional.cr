module Saci
  module Testing
    # Raised internally to roll back the outermost test transaction without
    # letting the signal escape the helper.
    class RollbackSignal < Exception
    end

    @@savepoint_counter = 0
    @@savepoint_mutex = Mutex.new

    # Wraps the block in a database transaction and always rolls it back.
    #
    # ```
    # Saci::Testing.transactional do
    #   User.create!(name: "temporary")
    #   User.count # => includes the new row
    # end
    # # row was rolled back
    # ```
    #
    # Nested calls use SQLite/PostgreSQL/MySQL `SAVEPOINT`s (SQLite support
    # is native), so an inner block can be rolled back while the outer
    # transaction continues.
    #
    # `after_commit` caveats: Saci defers `after_commit` callbacks until the
    # outermost transaction commits. Because the test transaction is always
    # rolled back, those callbacks never run (and are discarded). Use
    # `Saci::Testing.flush_after_commit!` when an example needs to observe
    # them explicitly:
    #
    # ```
    # Saci::Testing.transactional do
    #   User.create!(name: "x")
    #   Saci::Testing.flush_after_commit! # runs deferred callbacks now
    # end
    # ```
    #
    # For the same reason, tests of real commit behavior should not use
    # this helper — use `Saci::Testing.clean_database!` between examples.
    def self.transactional(&block : -> T) : T forall T
      conn = Record.connection
      if conn.is_a?(DB::Connection)
        db = Record.tx_database_for(conn)
        unless db
          raise "Saci::Testing.transactional found a transaction connection outside the ORM's transaction stack; use Record.transaction instead"
        end
        transactional_savepoint(db, conn, &block)
      else
        transactional_outer(conn, &block)
      end
    end

    # Runs deferred `after_commit` callbacks for the current fiber's active
    # transaction (simulates a commit without committing).
    def self.flush_after_commit! : Nil
      conn = Record.connection
      if conn.is_a?(DB::Connection)
        if db = Record.tx_database_for(conn)
          Record.run_after_commit(db)
        end
      end
    end

    # Non-transactional fallback: deletes every row from every table except
    # `schema_migrations`. Call from `before_each` when transactional tests
    # are not enabled.
    def self.clean_database! : Nil
      Record.clean_database!
      Fixtures.clear_rows!
    end

    # `true` when the current fiber is inside a transaction (including one
    # opened by `transactional`).
    def self.in_transaction? : Bool
      conn = Record.connection
      conn.is_a?(DB::Connection) && !Record.tx_database_for(conn).nil?
    end

    private def self.transactional_outer(db : DB::Database, &block : -> T) : T forall T
      # `Array(T)#first` returns a `T` without a cast, which keeps this
      # helper compilable even for `T = NoReturn` blocks (a block that only
      # raises).
      values = [] of T
      begin
        Record.transaction_on(db) do |_conn|
          values << block.call
          raise RollbackSignal.new
        end
      rescue RollbackSignal
        # Expected: the exception is the rollback mechanism.
      end
      values.first
    end

    private def self.transactional_savepoint(db : DB::Database, conn : DB::Connection, &block : -> T) : T forall T
      name = next_savepoint_name
      conn.exec("SAVEPOINT #{name}")

      # Keep hooks that were pending before this savepoint; discard only
      # the ones the block adds (they belong to work we roll back).
      saved_hooks = Record.__saci_testing_extract_after_commit(db)

      values = [] of T
      begin
        values << block.call
        conn.exec("ROLLBACK TO SAVEPOINT #{name}")
        conn.exec("RELEASE SAVEPOINT #{name}")
        Record.discard_after_commit(db)
        values.first
      rescue ex
        begin
          conn.exec("ROLLBACK TO SAVEPOINT #{name}")
          conn.exec("RELEASE SAVEPOINT #{name}")
        rescue
          # The transaction may already be aborted; the outer transaction's
          # rollback path handles cleanup.
        end
        Record.discard_after_commit(db)
        raise ex
      ensure
        Record.__saci_testing_restore_after_commit(db, saved_hooks)
      end
    end

    private def self.next_savepoint_name : String
      @@savepoint_mutex.synchronize do
        @@savepoint_counter += 1
        "saci_test_sp_#{@@savepoint_counter}"
      end
    end

    module TransactionalDSL
      # Use inside a `describe` block:
      #
      # ```
      # describe "models" do
      #   transactional_tests
      #   it "rolls back" { ... }
      # end
      # ```
      macro transactional_tests
        around_each do |__example|
          Saci::Testing.transactional { __example.run }
        end
      end
    end
  end
end
