require "spec"
require "../src/saci"

class RecurringProbeJob < Saci::Job::Base
  def perform(payload : JSON::Any) : Nil
  end
end

describe Saci::Recurring do
  before_each do
    Saci::Recurring.reset!
    Saci::Cache.reset!
    Saci::Job.queue_adapter = :test
    Saci::Job.clear_enqueued!
    Saci::Job.on_error { |_, _| }
  end

  after_each do
    Saci::Recurring.reset!
    Saci::Cache.reset!
    Saci::Job.queue_adapter = :async
    Saci::Job.reset_error_handler!
  end

  it "schedules interval first run one interval out" do
    before = Time.utc
    entry = Saci::Recurring.every(5.minutes, "ribbons") { }
    entry.next_due.should be >= before + 5.minutes
    entry.next_due.should be <= Time.utc + 5.minutes
    entry.last_run.should be_nil
  end

  it "collapses missed interval ticks to one catch-up run" do
    runs = 0
    entry = Saci::Recurring.every(1.minute, "catchup") { runs += 1 }
    entry.next_due = Time.utc - 10.minutes
    Saci::Recurring.run_due.should eq(1)
    runs.should eq(1)
    entry.next_due.should be > Time.utc
    entry.last_run.should_not be_nil
  end

  it "computes cron next-due times" do
    Saci::Recurring.next_after("*/5 * * * *", Time.utc(2026, 1, 1, 10, 3)).should eq(Time.utc(2026, 1, 1, 10, 5))
    Saci::Recurring.next_after("0 9 * * *", Time.utc(2026, 1, 1, 10, 0)).should eq(Time.utc(2026, 1, 2, 9, 0))
    Saci::Recurring.next_after("0 0 1 * *", Time.utc(2026, 1, 15, 12, 0)).should eq(Time.utc(2026, 2, 1, 0, 0))
    # Step over range + list.
    Saci::Recurring.next_after("0-30/15 8 * * *", Time.utc(2026, 1, 1, 8, 1)).should eq(Time.utc(2026, 1, 1, 8, 15))
    Saci::Recurring.next_after("10,20 * * * *", Time.utc(2026, 1, 1, 8, 11)).should eq(Time.utc(2026, 1, 1, 8, 20))
  end

  it "matches either dom or dow when both are restricted" do
    # 2026-01-04 is a Sunday; dom 15 does not match, dow 0 does.
    Saci::Recurring.next_after("0 0 15 * 0", Time.utc(2026, 1, 4, 0, 1)).should eq(Time.utc(2026, 1, 11, 0, 0))
    # DOW 7 is Sunday too.
    Saci::Recurring.next_after("0 0 * * 7", Time.utc(2026, 1, 5, 0, 1)).should eq(Time.utc(2026, 1, 11, 0, 0))
    # Names resolve (JAN, MON).
    Saci::Recurring.next_after("0 0 * JAN MON", Time.utc(2026, 1, 5, 0, 1)).should eq(Time.utc(2026, 1, 12, 0, 0))
  end

  it "rejects unsupported cron syntax" do
    expect_raises(ArgumentError) { Saci::Recurring.cron("L * * * *", "l") { } }
    expect_raises(ArgumentError) { Saci::Recurring.cron("*/a * * * *", "a") { } }
    expect_raises(ArgumentError) { Saci::Recurring.cron("* * * *", "four") { } }
    expect_raises(ArgumentError) { Saci::Recurring.cron("* * * * * *", "six") { } }
    expect_raises(ArgumentError) { Saci::Recurring.cron("61 * * * *", "range") { } }
    expect_raises(ArgumentError) { Saci::Recurring.cron("? * * * *", "q") { } }
    expect_raises(ArgumentError) { Saci::Recurring.cron("0 0 30 2 *", "never") { } }
    expect_raises(ArgumentError) { Saci::Recurring.cron("0 0 * * #", "hash") { } }
  end

  it "rejects duplicate names and bad spans" do
    Saci::Recurring.every(1.minute, "dup") { }
    expect_raises(ArgumentError) { Saci::Recurring.every(1.minute, "dup") { } }
    expect_raises(ArgumentError) { Saci::Recurring.every(0.seconds, "zero") { } }
    expect_raises(ArgumentError) { Saci::Recurring.start(0.seconds) }
    Saci::Recurring.remove("missing").should be_false
    Saci::Recurring.remove("dup").should be_true
    Saci::Recurring.size.should eq(0)
  end

  it "never overlaps a running key (single-flight)" do
    runs = 0
    entry = Saci::Recurring.every(1.minute, "slow") do
      sleep 100.milliseconds
      runs += 1
    end
    entry.next_due = Time.utc - 1.second
    done = Channel(Nil).new(2)
    2.times do
      spawn do
        Saci::Recurring.run_due
        done.send(nil)
      end
    end
    2.times { done.receive }
    runs.should eq(1)
  end

  it "tolerates misfires: errors report, other entries still fire, guard releases" do
    errors = [] of Tuple(String, Exception)
    Saci::Job.on_error { |job, ex| errors << {job, ex} }
    good = 0
    bad = Saci::Recurring.every(1.minute, "bad") { raise IO::Error.new("boom") }
    Saci::Recurring.every(1.minute, "good") { good += 1 }
    bad.next_due = Time.utc - 1.second
    Saci::Recurring.find("good").not_nil!.next_due = Time.utc - 1.second
    Saci::Recurring.run_due.should eq(2)
    good.should eq(1)
    errors.size.should eq(1)
    errors.first[0].should eq("recurring:bad")
    # Guard released: forcing due again fires again (and reports again).
    bad.next_due = Time.utc - 1.second
    Saci::Recurring.run_due.should eq(1)
    errors.size.should eq(2)
  end

  it "enqueues jobs through the public Job API" do
    entry = Saci::Recurring.every(1.minute, "probe") do
      RecurringProbeJob.perform_later({tick: 1})
    end
    entry.next_due = Time.utc - 1.second
    Saci::Recurring.run_due.should eq(1)
    jobs = Saci::Job.enqueued_jobs
    jobs.size.should eq(1)
    jobs.first[:job].should eq("RecurringProbeJob")
  end

  it "runs the supervised loop with start/stop" do
    runs = 0
    Saci::Recurring.every(50.milliseconds, "fast") { runs += 1 }
    Saci::Recurring.running?.should be_false
    Saci::Recurring.start(10.milliseconds)
    Saci::Recurring.start(10.milliseconds) # idempotent
    Saci::Recurring.running?.should be_true
    deadline = Time.utc + 5.seconds
    while runs == 0 && Time.utc < deadline
      sleep 10.milliseconds
    end
    runs.should be > 0
    Saci::Recurring.stop
    Saci::Recurring.running?.should be_false
    settled = runs
    sleep 50.milliseconds
    runs.should eq(settled)
  end

  it "keeps looping past a raising entry" do
    errors = [] of Tuple(String, Exception)
    Saci::Job.on_error { |job, ex| errors << {job, ex} }
    good = 0
    Saci::Recurring.every(20.milliseconds, "loop-bad") { raise IO::Error.new("tick") }
    Saci::Recurring.every(20.milliseconds, "loop-good") { good += 1 }
    Saci::Recurring.start(10.milliseconds)
    deadline = Time.utc + 5.seconds
    while good == 0 && Time.utc < deadline
      sleep 10.milliseconds
    end
    Saci::Recurring.stop
    good.should be > 0
    errors.size.should be > 0
  end

  it "skips fires claimed in Cache when dedup is on" do
    runs = 0
    Saci::Recurring.cache_dedup = true
    entry = Saci::Recurring.cron("* * * * *", "deduped") { runs += 1 }
    slot = entry.next_due
    Saci::Cache.write(Saci::Recurring.claim_key("deduped", slot), "1", expires_in: 1.hour)
    Saci::Recurring.run_due(Time.utc).should eq(0)
    runs.should eq(0)
    # Without a prior claim the fire goes through and leaves a claim.
    Saci::Cache.clear
    entry.next_due = Time.utc - 1.second
    due_slot = entry.next_due
    Saci::Recurring.run_due(Time.utc).should eq(1)
    runs.should eq(1)
    Saci::Cache.exist?(Saci::Recurring.claim_key("deduped", due_slot)).should be_true
  end
end
