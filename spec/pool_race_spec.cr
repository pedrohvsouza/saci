require "spec"
require "../src/saci"

# Regression for crystal-db 0.14 `Pool#checkout`: a connection created for
# a checkout was published to `@idle` and the pool mutex released before the
# creator re-took it, so a second fiber (another thread under
# -Dexecution_context) could check out the very same connection. Two users
# of one PG connection desynchronize its protocol.
class PoolRaceResource
  getter owner = Atomic(Int64).new(0_i64)

  def before_checkout; end

  def after_release; end

  def close; end
end

describe "DB::Pool checkout under contention" do
  it "never hands one resource to two holders at once" do
    created = Atomic(Int32).new(0)
    pool = DB::Pool(PoolRaceResource).new(DB::Pool::Options.new(initial_pool_size: 0, max_pool_size: 0, max_idle_pool_size: 1)) do
      created.add(1)
      Fiber.yield # widen the window like a real TCP connect
      PoolRaceResource.new
    end

    collisions = Atomic(Int32).new(0)
    fibers = 64
    rounds = 200
    done = Channel(Nil).new(fibers)
    {% if flag?(:execution_context) %}
      ctx = Fiber::ExecutionContext::Parallel.new("pool-race", 4)
    {% end %}
    fibers.times do |i|
      work = -> do
        rounds.times do
          res = pool.checkout
          me = (i + 1).to_i64
          _, ok = res.owner.compare_and_set(0_i64, me)
          collisions.add(1) unless ok
          Fiber.yield
          res.owner.compare_and_set(me, 0_i64)
          pool.release(res)
        end
        done.send(nil)
      end
      {% if flag?(:execution_context) %}
        ctx.spawn { work.call }
      {% else %}
        spawn { work.call }
      {% end %}
    end
    fibers.times { done.receive }

    collisions.get.should eq(0)
    created.get.should be > 1
  end
end
