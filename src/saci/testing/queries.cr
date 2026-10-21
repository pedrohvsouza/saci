module Saci
  module Testing
    # Fiber-local SQL statement counter used by `assert_queries` /
    # `assert_no_queries`.
    #
    # Every ORM statement flows through `Record.exec_compat`,
    # `Record.query_compat` or `Record.scalar_compat`; those are wrapped
    # below (see `record_hooks.cr`) so the counter sees the same SQL a
    # driver would receive. Counter state is keyed by fiber, matching the
    # rest of Saci's per-fiber transaction handling: a query issued in a
    # spawned fiber does not pollute the example that spawned it.
    module Queries
      @@counts = {} of UInt64 => Int32
      @@mutex = Mutex.new

      # Starts a fresh count for the current fiber (nesting is supported by
      # starting from zero each time; the outer count is restored below).
      def self.start : Int32
        @@mutex.synchronize { @@counts[Fiber.current.object_id] = 0 }
      end

      def self.finish : Int32
        @@mutex.synchronize do
          @@counts.delete(Fiber.current.object_id) || 0
        end
      end

      def self.record(sql : String) : Nil
        key = Fiber.current.object_id
        @@mutex.synchronize do
          if count = @@counts[key]?
            @@counts[key] = count + 1
          end
        end
      end

      # Records a statement and returns whether any assertion is currently
      # counting in this fiber (lets the hot path stay cheap).
      def self.counting? : Bool
        @@mutex.synchronize { @@counts.has_key?(Fiber.current.object_id) }
      end

      # Runs the block with a fresh counter, returning `{value, count}`.
      def self.measure(& : -> T) : Tuple(T, Int32) forall T
        # Save and restore the outer counter so nested helper calls do not
        # steal statements from an enclosing `assert_queries`.
        key = Fiber.current.object_id
        previous = @@mutex.synchronize { @@counts[key]? }
        @@mutex.synchronize { @@counts[key] = 0 }
        begin
          value = yield
          count = @@mutex.synchronize { @@counts[key]? || 0 }
          {value, count}
        ensure
          @@mutex.synchronize do
            if before = previous
              @@counts[key] = before
            else
              @@counts.delete(key)
            end
          end
        end
      end

      def self.reset! : Nil
        @@mutex.synchronize { @@counts.delete(Fiber.current.object_id) }
      end
    end
  end
end
