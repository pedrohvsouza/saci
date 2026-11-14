require "spec"
require "../src/saci"

class RedisProbeJob < Saci::Job::Base
  queue_as :probes

  @@ran = [] of String
  @@mutex = Mutex.new

  def self.ran : Array(String)
    @@mutex.synchronize { @@ran.dup }
  end

  def self.reset! : Nil
    @@mutex.synchronize { @@ran.clear }
  end

  def perform(payload : JSON::Any) : Nil
    id = payload["id"]?.try(&.as_i?) || -1
    @@mutex.synchronize { @@ran << "probe-#{id}" }
  end
end

class RedisFlakyJob < Saci::Job::Base
  retry_on IO::Error, attempts: 3

  @@tries = 0
  @@mutex = Mutex.new

  def self.tries : Int32
    @@mutex.synchronize { @@tries }
  end

  def self.reset! : Nil
    @@mutex.synchronize { @@tries = 0 }
  end

  def perform(payload : JSON::Any) : Nil
    @@mutex.synchronize { @@tries += 1 }
    raise IO::Error.new("boom") if self.class.tries < 2
  end
end

class RedisDoomedJob < Saci::Job::Base
  def perform(payload : JSON::Any) : Nil
    raise "always fails"
  end
end

class RedisDiscardedJob < Saci::Job::Base
  discard_on ArgumentError

  def perform(payload : JSON::Any) : Nil
    raise ArgumentError.new("nope")
  end
end

class RedisUniqueJob < Saci::Job::Base
  unique :until_executed

  def perform(payload : JSON::Any) : Nil
    RedisProbeJob.new.perform(payload)
  end
end

class RedisUniqueExecutingJob < Saci::Job::Base
  unique :until_executing

  def perform(payload : JSON::Any) : Nil
    RedisProbeJob.new.perform(payload)
  end
end

class RedisContinuationJob < Saci::Job::Base
  continuable
  step :one
  step :two
  step :three

  @@runs = [] of String
  @@fail_on_two = false
  @@mutex = Mutex.new

  def self.runs : Array(String)
    @@mutex.synchronize { @@runs.dup }
  end

  def self.reset!(fail_on_two : Bool = false) : Nil
    @@mutex.synchronize do
      @@runs.clear
      @@fail_on_two = fail_on_two
    end
  end

  def self.log(entry : String) : Nil
    @@mutex.synchronize { @@runs << entry }
  end

  def self.fail_on_two? : Bool
    @@mutex.synchronize { @@fail_on_two }
  end

  def one : Nil
    RedisContinuationJob.log("one")
  end

  def two : Nil
    RedisContinuationJob.log("two")
    raise "two failed" if RedisContinuationJob.fail_on_two?
  end

  def three : Nil
    RedisContinuationJob.log("three")
  end
end

private def redis_jobs_url : String
  pending!("set REDIS_URL to run live redis specs (e.g. REDIS_URL=redis://127.0.0.1:63979)") if ENV["REDIS_URL"]?.nil?
  ENV["REDIS_URL"].not_nil!
end

private def with_redis_jobs(lock_timeout : Time::Span = 10.minutes, &) : Nil
  Saci::Job::Redis.configure(url: redis_jobs_url, prefix: "saci:jobs:spec:#{Random::Secure.hex(4)}",
    lock_timeout: lock_timeout)
  Saci::Job::Redis.clear_all!
  RedisProbeJob.reset!
  RedisFlakyJob.reset!
  RedisContinuationJob.reset!
  Saci::Job.reset_error_handler!
  Saci::Job.on_error { |_name, _ex| }
  begin
    Saci::Job.with_adapter(:redis) { yield }
  ensure
    Saci::Job::Redis.clear_all!
    Saci::Job::Redis.configure
    Saci::Job.reset_error_handler!
  end
end

describe Saci::Job::Redis do
  it "is a built-in adapter" do
    Saci::Job.adapters.should contain(:redis)
    Saci::Job.with_adapter(:redis) { Saci::Job.queue_adapter.should eq(:redis) }
  end

  it "orders ready scores by priority, then run time" do
    now = Time.utc
    high = Saci::Job::Redis.ready_score(now + 1.hour, 10)
    low = Saci::Job::Redis.ready_score(now, 0)
    earlier = Saci::Job::Redis.ready_score(now - 1.minute, 0)
    high.should be < low
    earlier.should be < low
    Saci::Job::Redis.ready_score(now, 5000).should eq(Saci::Job::Redis.ready_score(now, Saci::Job::Redis::PRIORITY_LIMIT))
    extreme = Saci::Job::Redis.ready_score(now, -Saci::Job::Redis::PRIORITY_LIMIT)
    extreme.abs.should be < 2_i64 ** 53
  end

  it "pads member ids so ties sort by enqueue order" do
    Saci::Job::Redis.member_id(9).should be < Saci::Job::Redis.member_id(10)
    Saci::Job::Redis.member_id(42).to_i64.should eq(42)
  end

  it "raises Down when Redis is unreachable" do
    Saci::Job::Redis.configure(url: "redis://127.0.0.1:1", prefix: "saci:jobs:spec:down")
    begin
      expect_raises(Saci::Job::Redis::Down) { Saci::Job::Redis.dead_count }
    ensure
      Saci::Job::Redis.configure
    end
  end

  it "persists enqueues and drains them in order" do
    with_redis_jobs do
      RedisProbeJob.perform_later({id: 1})
      RedisProbeJob.perform_later({id: 2})
      Saci::Job::Redis.pending_count.should eq(2)
      Saci::Job::Redis.pending_count("probes").should eq(2)
      Saci::Job::Redis.pending_count("other").should eq(0)
      Saci::Job::Redis.drain.should eq(2)
      RedisProbeJob.ran.should eq(["probe-1", "probe-2"])
      Saci::Job::Redis.pending_count.should eq(0)
    end
  end

  it "runs higher priorities first" do
    with_redis_jobs do
      RedisProbeJob.perform_later({id: 1})
      RedisProbeJob.set(priority: 5).perform_later({id: 2})
      RedisProbeJob.set(priority: -5).perform_later({id: 3})
      RedisProbeJob.set(priority: 5).perform_later({id: 4})
      Saci::Job::Redis.drain.should eq(4)
      RedisProbeJob.ran.should eq(["probe-2", "probe-4", "probe-1", "probe-3"])
    end
  end

  it "picks the best job across queues and honors queue selectors" do
    with_redis_jobs do
      RedisProbeJob.set(queue: :low).perform_later({id: 1})
      RedisProbeJob.set(queue: :high, priority: 3).perform_later({id: 2})
      Saci::Job::Redis.drain("low").should eq(1)
      RedisProbeJob.ran.should eq(["probe-1"])
      RedisProbeJob.set(queue: :low).perform_later({id: 3})
      Saci::Job::Redis.drain.should eq(2)
      RedisProbeJob.ran.should eq(["probe-1", "probe-2", "probe-3"])
    end
  end

  it "holds scheduled jobs until they are due" do
    with_redis_jobs do
      RedisProbeJob.set(wait: 1.hour).perform_later({id: 9})
      RedisProbeJob.set(wait_until: Time.utc + 300.milliseconds).perform_later({id: 10})
      Saci::Job::Redis.pending_count.should eq(2)
      Saci::Job::Redis.drain.should eq(0)
      sleep 0.4.seconds
      Saci::Job::Redis.drain.should eq(1)
      RedisProbeJob.ran.should eq(["probe-10"])
      Saci::Job::Redis.pending_count.should eq(1)
    end
  end

  it "retries flaky jobs to success" do
    with_redis_jobs do
      RedisFlakyJob.perform_later({} of String => Int32)
      Saci::Job::Redis.drain.should eq(1)
      RedisFlakyJob.tries.should eq(2)
      Saci::Job::Redis.pending_count.should eq(0)
      Saci::Job::Redis.dead_count.should eq(0)
    end
  end

  it "dead-letters final failures and reports once" do
    with_redis_jobs do
      seen = [] of String
      Saci::Job.on_error { |name, ex| seen << "#{name}:#{ex.message}" }
      RedisDoomedJob.perform_later({} of String => Int32)
      Saci::Job::Redis.drain.should eq(1)
      Saci::Job::Redis.pending_count.should eq(0)
      Saci::Job::Redis.dead_count.should eq(1)
      dead = Saci::Job::Redis.dead_jobs.first
      dead[:job].should eq("RedisDoomedJob")
      dead[:attempts].should eq(1)
      dead[:error].should contain("always fails")
      seen.size.should eq(1)
    end
  end

  it "discards without dead-lettering" do
    with_redis_jobs do
      seen = [] of String
      Saci::Job.on_error { |name, _ex| seen << name }
      RedisDiscardedJob.perform_later({} of String => Int32)
      Saci::Job::Redis.drain.should eq(1)
      Saci::Job::Redis.dead_count.should eq(0)
      seen.should eq(["RedisDiscardedJob"])
    end
  end

  it "dead-letters unknown job classes" do
    with_redis_jobs do
      Saci::Job::Redis.enqueue("GoneJob_xyz", "default", %({}))
      Saci::Job::Redis.drain.should eq(1)
      Saci::Job::Redis.dead_jobs.first[:error].should contain("unknown job class")
    end
  end

  it "retries, drops and prunes dead jobs" do
    with_redis_jobs do
      RedisDoomedJob.perform_later({} of String => Int32)
      Saci::Job::Redis.drain
      id = Saci::Job::Redis.dead_jobs.first[:id]
      Saci::Job::Redis.retry_dead(999_999_i64).should be_false
      Saci::Job::Redis.retry_dead(id).should be_true
      Saci::Job::Redis.retry_dead(id).should be_false
      Saci::Job::Redis.pending_count.should eq(1)
      Saci::Job::Redis.dead_count.should eq(0)
      Saci::Job::Redis.drain
      Saci::Job::Redis.dead_count.should eq(1)
      Saci::Job::Redis.dead_jobs.first[:attempts].should eq(1)
      Saci::Job::Redis.drop_dead(id + 1000).should be_false
      Saci::Job::Redis.drop_dead(id).should be_true
      Saci::Job::Redis.dead_count.should eq(0)

      RedisDoomedJob.perform_later({} of String => Int32)
      Saci::Job::Redis.drain
      Saci::Job::Redis.prune_dead(1.hour).should eq(0)
      Saci::Job::Redis.prune_dead_before(Time.utc + 1.second).should eq(1)
      Saci::Job::Redis.dead_count.should eq(0)
    end
  end

  it "reclaims jobs whose worker vanished after the lock timeout" do
    with_redis_jobs(lock_timeout: 300.milliseconds) do
      RedisProbeJob.perform_later({id: 5})
      claim = Saci::Job::Redis.claim_one.should_not be_nil
      claim.attempts.should eq(1)
      Saci::Job::Redis.drain.should eq(0)
      sleep 0.4.seconds
      Saci::Job::Redis.drain.should eq(1)
      RedisProbeJob.ran.should eq(["probe-5"])
      Saci::Job::Redis.pending_count.should eq(0)
    end
  end

  it "claims without blocking via work_once" do
    with_redis_jobs do
      RedisProbeJob.perform_later({id: 11})
      RedisProbeJob.perform_later({id: 12})
      Saci::Job::Redis.work_once.should eq(2)
      deadline = Time.instant + 5.seconds
      until RedisProbeJob.ran.size == 2 || Time.instant > deadline
        sleep 0.05.seconds
      end
      RedisProbeJob.ran.sort.should eq(["probe-11", "probe-12"])
      deadline = Time.instant + 5.seconds
      until Saci::Job::Redis.pending_count == 0 || Time.instant > deadline
        sleep 0.05.seconds
      end
      Saci::Job::Redis.pending_count.should eq(0)
    end
  end

  it "keeps until_executed jobs unique until they finish" do
    with_redis_jobs do
      RedisUniqueJob.perform_later({id: 1})
      RedisUniqueJob.perform_later({id: 1})
      RedisUniqueJob.perform_later({id: 2})
      Saci::Job::Redis.pending_count.should eq(2)
      Saci::Job::Redis.drain.should eq(2)
      RedisProbeJob.ran.should eq(["probe-1", "probe-2"])
      RedisUniqueJob.perform_later({id: 1})
      Saci::Job::Redis.pending_count.should eq(1)
    end
  end

  it "releases until_executing locks when the job is claimed" do
    with_redis_jobs do
      RedisUniqueExecutingJob.perform_later({id: 1})
      RedisUniqueExecutingJob.perform_later({id: 1})
      Saci::Job::Redis.pending_count.should eq(1)
      claim = Saci::Job::Redis.claim_one.should_not be_nil
      RedisUniqueExecutingJob.perform_later({id: 1})
      Saci::Job::Redis.pending_count.should eq(2)
      Saci::Job::Redis.run_claimed(claim)
      Saci::Job::Redis.drain.should eq(1)
      RedisProbeJob.ran.should eq(["probe-1", "probe-1"])
    end
  end

  it "stores continuation checkpoints and resumes from them" do
    with_redis_jobs do
      conn = Saci::Cable::RedisWire::Conn.new(Saci::Cable::RedisWire.parse_url(redis_jobs_url))
      begin
        RedisContinuationJob.reset!(fail_on_two: true)
        RedisContinuationJob.perform_later({} of String => Int32)
        Saci::Job::Redis.drain.should eq(1)
        id = Saci::Job::Redis.dead_jobs.first[:id]
        job_key = "#{Saci::Job::Redis.prefix}:job:#{Saci::Job::Redis.member_id(id)}"
        conn.call("HGET", job_key, "checkpoint").should eq(%(["one"]))

        RedisContinuationJob.reset!
        Saci::Job::Redis.enqueue("RedisContinuationJob", "default", %({}))
        fresh = Saci::Job::Redis.member_id(id + 1)
        conn.call("HSET", "#{Saci::Job::Redis.prefix}:job:#{fresh}", "checkpoint", %(["one"]))
        Saci::Job::Redis.drain.should eq(1)
        RedisContinuationJob.runs.should eq(["two", "three"])
      ensure
        conn.close
      end
    end
  end

  it "survives a reconnect: jobs outlive connections" do
    with_redis_jobs do
      RedisProbeJob.perform_later({id: 7})
      Saci::Job::Redis.disconnect!
      Saci::Job::Redis.drain.should eq(1)
      RedisProbeJob.ran.should eq(["probe-7"])
    end
  end

  it "delivers mail on a custom queue through the adapter" do
    with_redis_jobs do
      Saci::Mailer.delivery_adapter = :test
      Saci::Mailer.clear_deliveries!
      Saci::Mailer::Mail.new(["a@b.c"], "noreply@example.com", "Redis mail", "hi").deliver_later(queue: "urgent")
      Saci::Job::Redis.pending_count("urgent").should eq(1)
      Saci::Job::Redis.drain.should eq(1)
      Saci::Mailer.deliveries.map(&.subject).should eq(["Redis mail"])
    end
  end
end
