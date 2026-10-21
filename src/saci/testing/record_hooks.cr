require "./queries"

module Saci
  module Record
    # -- test-internal hooks -------------------------------------------------
    # These reopen `Saci::Record` instead of editing `record.cr` (the
    # coordinator owns that file). They give the testing helpers access to
    # the deferred `after_commit` queue so a rolled-back savepoint can
    # discard exactly the hooks it created without touching hooks that were
    # already pending before the savepoint opened.

    # Removes and returns the pending `after_commit` hooks for `db` in the
    # current fiber. Used by `Saci::Testing.transactional` around a nested
    # savepoint.
    def self.__saci_testing_extract_after_commit(db : DB::Database) : Array(Proc(Nil))
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

    # Puts previously extracted hooks back (after a nested savepoint ended).
    def self.__saci_testing_restore_after_commit(db : DB::Database, hooks : Array(Proc(Nil))) : Nil
      return if hooks.empty?
      key = Fiber.current.object_id
      @@tx_mutex.synchronize do
        arr = @@after_commit_hooks[key] ||= [] of Tuple(UInt64, Proc(Nil))
        hooks.each { |hook| arr << {db.object_id, hook} }
      end
    end

    # `true` when this fiber currently has pending `after_commit` hooks for
    # `db` (used by the transactional helper's documentation examples).
    def self.__saci_testing_pending_after_commit?(db : DB::Database) : Bool
      key = Fiber.current.object_id
      @@tx_mutex.synchronize do
        @@after_commit_hooks[key]?.try(&.any? { |(id, _)| id == db.object_id }) || false
      end
    end

    # -- query counter ------------------------------------------------------
    # Wrap the three execution choke points rather than every call site.
    # `previous_def` keeps the original adapter behavior (placeholder
    # rewriting, block handling, return values).
    def self.exec_compat(db : DB::Database | DB::Connection, sql : String, args : Array(Value) = [] of Value) : DB::ExecResult
      Saci::Testing::Queries.record(sql)
      previous_def
    end

    def self.query_compat(db : DB::Database | DB::Connection, sql : String, args : Array(Value) = [] of Value, &block : DB::ResultSet ->) : Nil
      Saci::Testing::Queries.record(sql)
      previous_def(db, sql, args, &block)
    end

    def self.scalar_compat(db : DB::Database | DB::Connection, sql : String, args : Array(Value) = [] of Value)
      Saci::Testing::Queries.record(sql)
      previous_def
    end

    class Migration
      # Registry used by `Saci::Testing.prepare_database!` /
      # `maintain_test_schema!`. Crystal has no runtime class discovery, so
      # migrations self-register as they are defined (and can be registered
      # explicitly with `Saci::Testing.register_migrations`).
      @@__saci_test_migrations = [] of Migration.class
      @@__saci_test_migrations_mutex = Mutex.new

      def self.register_test_migration(klass : Migration.class) : Nil
        @@__saci_test_migrations_mutex.synchronize do
          @@__saci_test_migrations << klass unless @@__saci_test_migrations.includes?(klass)
        end
      end

      def self.test_migrations : Array(Migration.class)
        @@__saci_test_migrations_mutex.synchronize { @@__saci_test_migrations.dup }
      end

      def self.reset_test_migrations! : Nil
        @@__saci_test_migrations_mutex.synchronize { @@__saci_test_migrations.clear }
      end

      # Subclasses self-register when this file is loaded before the
      # migration is defined (normal for apps that `require "saci"` first).
      macro inherited
        Saci::Record::Migration.register_test_migration(self)
      end
    end
  end
end
