require "db"
require "db/version"

# Fix for a multithreading race in crystal-db 0.14's `DB::Pool#checkout`.
#
# When the pool grows, `checkout` releases the pool mutex (`unsync`) and calls
# `build_resource`, which appends the new connection to `@idle` *and* releases
# the mutex again before `checkout` re-takes it and removes it from `@idle`.
# In that window another thread's `checkout` can `pick_available` the same
# connection, so two fibers end up sharing one `DB::Connection` (for PG: a
# desynchronized protocol, wrong rows, and memory corruption under
# -Dexecution_context).
#
# The patched `checkout` registers a connection created for itself only in
# `@total`: it is never visible as idle until it is released. Everything else
# is upstream's logic unchanged. Remove this file once crystal-db ships a fix.
{% if compare_versions(DB::VERSION, "0.15.0") < 0 %}
  class DB::Pool(T)
    def checkout : T
      res = sync do
        resource = nil

        until resource
          resource = if @idle.empty?
                       if can_increase_pool?
                         @inflight += 1
                         begin
                           unsync { __saci_build_checked_out_resource }
                         ensure
                           @inflight -= 1
                         end
                       else
                         unsync { wait_for_available }
                         pick_available
                       end
                     else
                       pick_available
                     end
        end

        @idle.delete resource

        resource
      end

      if res.responds_to?(:before_checkout)
        res.before_checkout
      end
      res
    end

    private def __saci_build_checked_out_resource : T
      resource = @factory.call
      sync { @total << resource }
      resource
    end
  end
{% end %}
