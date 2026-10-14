require "spec"
require "../src/saci"

class ConcSlowJob < Saci::Job::Base
  limits_concurrency to: 1, key: "conc-slow"

  @@runs = 0
  @@mutex = Mutex.new

  def self.runs : Int32
    @@mutex.synchronize { @@runs }
  end

  def self.reset_runs! : Nil
    @@mutex.synchronize { @@runs = 0 }
  end

  def perform(payload : JSON::Any) : Nil
    @@mutex.synchronize { @@runs += 1 }
    sleep 0.3.seconds
  end
end

class ConcPairJob < Saci::Job::Base
  limits_concurrency to: 2, key: "conc-pair"

  @@runs = 0
  @@mutex = Mutex.new

  def self.runs : Int32
    @@mutex.synchronize { @@runs }
  end

  def self.reset_runs! : Nil
    @@mutex.synchronize { @@runs = 0 }
  end

  def perform(payload : JSON::Any) : Nil
    @@mutex.synchronize { @@runs += 1 }
    sleep 0.3.seconds
  end
end

class ConcFailJob < Saci::Job::Base
  limits_concurrency to: 1, key: "conc-fail"

  @@runs = 0
  @@mutex = Mutex.new

  def self.runs : Int32
    @@mutex.synchronize { @@runs }
  end

  def self.reset_runs! : Nil
    @@mutex.synchronize { @@runs = 0 }
  end

  def perform(payload : JSON::Any) : Nil
    @@mutex.synchronize { @@runs += 1 }
    raise "boom"
  end
end

class ConcPlainJob < Saci::Job::Base
  def perform(payload : JSON::Any) : Nil
  end
end

class ConcDefaultKeyJob < Saci::Job::Base
  limits_concurrency to: 1

  def perform(payload : JSON::Any) : Nil
  end
end

CONC_LIMIT_DB_PATH = "/tmp/opencode/saci_conc_test.db"

describe "Job concurrency limits" do
  before_all do
    File.delete(CONC_LIMIT_DB_PATH) if File.exists?(CONC_LIMIT_DB_PATH)
    Saci::Record.connection = DB.open("sqlite3://#{CONC_LIMIT_DB_PATH}")
    Saci::Job::Db.ensure_schema!
  end

  after_all do
    Saci::Record.database("primary").as(DB::Database).close
  end

  before_each do
    Saci::Job.reset_concurrency!
    Saci::Job.reset_error_handler!
    ConcSlowJob.reset_runs!
    ConcPairJob.reset_runs!
    ConcFailJob.reset_runs!
    Saci::Job::Db.clear_all!
  end

  it "defaults to unlimited with a class-name key fallback" do
    ConcPlainJob.__saci_concurrency_limit.should be_nil
    ConcSlowJob.__saci_concurrency_limit.should eq(1)
    ConcSlowJob.__saci_concurrency_key.should eq("conc-slow")
    ConcPairJob.__saci_concurrency_limit.should eq(2)
    ConcDefaultKeyJob.__saci_concurrency_key.should eq("ConcDefaultKeyJob")
  end

  it "skips a second run while the key is held" do
    done = Channel(Nil).new
    spawn do
      Saci::Job.execute(ConcSlowJob, "{}")
      done.send(nil)
    end
    sleep 0.05.seconds # let the first run hold the slot
    Saci::Job.execute(ConcSlowJob, "{}")
    done.receive
    ConcSlowJob.runs.should eq(1)
    # Slot released afterwards — the next run proceeds.
    Saci::Job.execute(ConcSlowJob, "{}")
    ConcSlowJob.runs.should eq(2)
  end

  it "holds two slots when to: 2" do
    done = Channel(Nil).new(2)
    2.times do
      spawn do
        Saci::Job.execute(ConcPairJob, "{}")
        done.send(nil)
      end
    end
    sleep 0.05.seconds
    Saci::Job.execute(ConcPairJob, "{}") # third run skips
    2.times { done.receive }
    ConcPairJob.runs.should eq(2)
  end

  it "releases the slot when the job raises" do
    Saci::Job.on_error { |_, _| }
    expect_raises(Exception, "boom") { Saci::Job.execute(ConcFailJob, "{}") }
    expect_raises(Exception, "boom") { Saci::Job.execute(ConcFailJob, "{}") }
    ConcFailJob.runs.should eq(2)
  end

  it "is honored by the :db adapter via skip-if-running" do
    Saci::Job::Db.enqueue("ConcSlowJob", "default", %({}))
    Saci::Job::Db.enqueue("ConcSlowJob", "default", %({}))
    Saci::Job::Db.work_once.should eq(2)
    deadline = Time.instant + 5.seconds
    until ConcSlowJob.runs == 1 || Time.instant > deadline
      sleep 0.05.seconds
    end
    # Give the skipped twin time to (not) run.
    sleep 0.5.seconds
    ConcSlowJob.runs.should eq(1)
    Saci::Job::Db.pending_count.should eq(0)
    Saci::Job::Db.dead_count.should eq(0)
  end
end
