require "spec"
require "file_utils"
require "../src/saci"

JOBS_DB_PATH = "/tmp/opencode/saci_jobs_db_test.db"

class DbProbeJob < Saci::Job::Base
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

class DbFlakyJob < Saci::Job::Base
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

class DbDoomedJob < Saci::Job::Base
  def perform(payload : JSON::Any) : Nil
    raise "always fails"
  end
end

class DbDiscardedJob < Saci::Job::Base
  discard_on ArgumentError

  def perform(payload : JSON::Any) : Nil
    raise ArgumentError.new("nope")
  end
end

def db_test_db : DB::Database
  Saci::Record.database("primary").as(DB::Database)
end

describe Saci::Job::Db do
  before_all do
    File.delete(JOBS_DB_PATH) if File.exists?(JOBS_DB_PATH)
    Saci::Record.connection = DB.open("sqlite3://#{JOBS_DB_PATH}")
    Saci::Job::Db.ensure_schema!
  end

  after_all do
    db_test_db.close
  end

  before_each do
    Saci::Job::Db.clear_all!
    DbProbeJob.reset!
    DbFlakyJob.reset!
    Saci::Job.reset_error_handler!
  end

  it "registers job classes by name" do
    Saci::Job.registered_jobs.should contain("DbProbeJob")
    Saci::Job.lookup("DbProbeJob").should eq(DbProbeJob)
    Saci::Job.lookup("NoSuchJob_xyz").should be_nil
  end

  it "persists enqueues and drains them in order" do
    Saci::Job::Db.enqueue("DbProbeJob", "probes", %({"id":1}))
    Saci::Job::Db.enqueue("DbProbeJob", "probes", %({"id":2}))
    Saci::Job::Db.pending_count.should eq(2)
    Saci::Job::Db.drain.should eq(2)
    DbProbeJob.ran.should eq(["probe-1", "probe-2"])
    Saci::Job::Db.pending_count.should eq(0)
  end

  it "honors scheduled run times" do
    Saci::Job.with_adapter(:db) do
      DbProbeJob.set(wait: 1.hour).perform_later({id: 9})
      Saci::Job::Db.pending_count.should eq(1)
      Saci::Job::Db.drain.should eq(0)
      DbProbeJob.ran.should be_empty
    end
  end

  it "retries flaky jobs to success" do
    Saci::Job::Db.enqueue("DbFlakyJob", "default", %({}))
    Saci::Job::Db.drain.should eq(1)
    DbFlakyJob.tries.should eq(2)
    Saci::Job::Db.pending_count.should eq(0)
    Saci::Job::Db.dead_count.should eq(0)
  end

  it "dead-letters final failures and reports once" do
    seen = [] of String
    Saci::Job.on_error { |name, ex| seen << "#{name}:#{ex.message}" }
    Saci::Job::Db.enqueue("DbDoomedJob", "default", %({}))
    Saci::Job::Db.drain.should eq(1)
    Saci::Job::Db.pending_count.should eq(0)
    Saci::Job::Db.dead_count.should eq(1)
    dead = Saci::Job::Db.dead_jobs.first
    dead[:job].should eq("DbDoomedJob")
    dead[:error].should contain("always fails")
    seen.size.should eq(1)
  end

  it "discards without dead-lettering" do
    seen = [] of String
    Saci::Job.on_error { |name, ex| seen << name }
    Saci::Job::Db.enqueue("DbDiscardedJob", "default", %({}))
    Saci::Job::Db.drain.should eq(1)
    Saci::Job::Db.dead_count.should eq(0)
    seen.should eq(["DbDiscardedJob"])
  end

  it "dead-letters unknown job classes" do
    Saci::Job::Db.enqueue("GoneJob_xyz", "default", %({}))
    Saci::Job::Db.drain.should eq(1)
    Saci::Job::Db.dead_count.should eq(1)
    Saci::Job::Db.dead_jobs.first[:error].should contain("unknown job class")
  end

  it "retries and drops dead jobs through ops calls" do
    Saci::Job::Db.enqueue("DbDoomedJob", "default", %({}))
    Saci::Job::Db.drain
    id = Saci::Job::Db.dead_jobs.first[:id]
    Saci::Job::Db.retry_dead(999999_i64).should be_false
    Saci::Job::Db.retry_dead(id).should be_true
    Saci::Job::Db.pending_count.should eq(1)
    Saci::Job::Db.dead_count.should eq(0)
    Saci::Job::Db.drain
    Saci::Job::Db.dead_count.should eq(1)
    Saci::Job::Db.drop_dead(id + 1000).should be_false
    Saci::Job::Db.drop_dead(Saci::Job::Db.dead_jobs.first[:id]).should be_true
    Saci::Job::Db.dead_count.should eq(0)
  end

  it "reclaims crashed workers' stale locks" do
    Saci::Job::Db.enqueue("DbProbeJob", "probes", %({"id":5}))
    db = db_test_db
    Saci::Record.exec_compat(db,
      "UPDATE saci_jobs SET locked_by = 'live-worker', locked_at = ?",
      [Time.utc.to_rfc3339(fraction_digits: 9)] of Saci::Record::Value)
    # Fresh locks are respected…
    Saci::Job::Db.drain.should eq(0)
    DbProbeJob.ran.should be_empty
    # …but expired ones are reclaimed.
    Saci::Job::Db.configure(lock_timeout: 1.second)
    begin
      sleep 1.1.seconds
      Saci::Job::Db.drain.should eq(1)
      DbProbeJob.ran.should eq(["probe-5"])
    ensure
      Saci::Job::Db.configure
    end
  end

  it "claims without blocking via work_once" do
    Saci::Job::Db.enqueue("DbProbeJob", "probes", %({"id":11}))
    Saci::Job::Db.enqueue("DbProbeJob", "probes", %({"id":12}))
    Saci::Job::Db.work_once.should eq(2)
    deadline = Time.instant + 5.seconds
    until DbProbeJob.ran.size == 2 || Time.instant > deadline
      sleep 0.05.seconds
    end
    DbProbeJob.ran.sort.should eq(["probe-11", "probe-12"])
    Saci::Job::Db.pending_count.should eq(0)
  end

  it "survives a restart: rows outlive connections" do
    Saci::Job::Db.enqueue("DbProbeJob", "probes", %({"id":7}))
    db_test_db.close
    Saci::Record.connection = DB.open("sqlite3://#{JOBS_DB_PATH}")
    Saci::Job::Db.drain.should eq(1)
    DbProbeJob.ran.should eq(["probe-7"])
  end

  it "delivers mail through the durable adapter" do
    Saci::Mailer.delivery_adapter = :test
    begin
      Saci::Mailer.clear_deliveries!
      Saci::Job.with_adapter(:db) do
        Saci::Mailer::Mail.new(["a@b.c"], "noreply@example.com", "Db mail", "hi").deliver_later
        Saci::Job::Db.pending_count.should eq(1)
        Saci::Job::Db.drain.should eq(1)
      end
      Saci::Mailer.deliveries.map(&.subject).should eq(["Db mail"])
    ensure
      Saci::Mailer.delivery_adapter = :test
    end
  end
end
