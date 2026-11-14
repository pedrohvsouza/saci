require "spec"
require "file_utils"
require "../src/saci"

JOB_EXTRAS_DB_PATH = "/tmp/opencode/saci_job_extras_test.db"

class JobExtrasUser < Saci::Record::Base
  column id : Int64, primary: true
  column name : String
end

class ExtrasCallbackJob < Saci::Job::Base
  @@log = [] of String
  @@mutex = Mutex.new

  def self.log(entry : String) : Nil
    @@mutex.synchronize { @@log << entry }
  end

  def self.entries : Array(String)
    @@mutex.synchronize { @@log.dup }
  end

  def self.reset! : Nil
    @@mutex.synchronize { @@log.clear }
  end

  before_enqueue :on_before_enqueue
  after_enqueue :on_after_enqueue
  around_enqueue :on_around_enqueue
  before_perform :on_before_perform
  after_perform :on_after_perform
  around_perform :on_around_perform

  def on_before_enqueue : Nil
    ExtrasCallbackJob.log("before_enqueue")
  end

  def on_after_enqueue : Nil
    ExtrasCallbackJob.log("after_enqueue")
  end

  def on_around_enqueue(&block : -> Nil) : Nil
    ExtrasCallbackJob.log("around_enqueue:before")
    block.call
    ExtrasCallbackJob.log("around_enqueue:after")
  end

  def on_before_perform : Nil
    ExtrasCallbackJob.log("before_perform")
  end

  def on_after_perform : Nil
    ExtrasCallbackJob.log("after_perform")
  end

  def on_around_perform(&block : -> Nil) : Nil
    ExtrasCallbackJob.log("around_perform:before")
    block.call
    ExtrasCallbackJob.log("around_perform:after")
  end

  def perform(payload : JSON::Any) : Nil
    ExtrasCallbackJob.log("perform")
  end
end

class ExtrasLogMiddleware < Saci::Job::Middleware
  def call(job : Saci::Job::Base, &block : -> Nil) : Nil
    ExtrasCallbackJob.log("middleware:before:#{job.class.name}")
    block.call
    ExtrasCallbackJob.log("middleware:after")
  end
end

class ExtrasBoomMiddleware < Saci::Job::Middleware
  def call(job : Saci::Job::Base, &block : -> Nil) : Nil
    raise "middleware boom"
  end
end

class ExtrasAbortJob < Saci::Job::Base
  @@runs = 0
  @@mutex = Mutex.new

  def self.runs : Int32
    @@mutex.synchronize { @@runs }
  end

  def self.reset! : Nil
    @@mutex.synchronize { @@runs = 0 }
  end

  before_enqueue :cancel

  def cancel : Nil
    raise Saci::Job::Abort.new("nope")
  end

  def perform(payload : JSON::Any) : Nil
    @@mutex.synchronize { @@runs += 1 }
  end
end

class ExtrasRescueJob < Saci::Job::Base
  @@handled = 0
  @@runs = 0
  @@mutex = Mutex.new

  def self.handled : Int32
    @@mutex.synchronize { @@handled }
  end

  def self.runs : Int32
    @@mutex.synchronize { @@runs }
  end

  def self.reset! : Nil
    @@mutex.synchronize do
      @@handled = 0
      @@runs = 0
    end
  end

  rescue_from ArgumentError, with: :on_bad_argument

  def on_bad_argument(ex : Exception) : Nil
    @@mutex.synchronize { @@handled += 1 }
  end

  def perform(payload : JSON::Any) : Nil
    @@mutex.synchronize { @@runs += 1 }
    raise ArgumentError.new("bad argument")
  end
end

class ExtrasUnhandledJob < Saci::Job::Base
  def perform(payload : JSON::Any) : Nil
    raise ArgumentError.new("unhandled")
  end
end

class ExtrasRetryRescueJob < Saci::Job::Base
  @@runs = 0
  @@handled = 0
  @@mutex = Mutex.new

  def self.runs : Int32
    @@mutex.synchronize { @@runs }
  end

  def self.handled : Int32
    @@mutex.synchronize { @@handled }
  end

  def self.reset! : Nil
    @@mutex.synchronize do
      @@runs = 0
      @@handled = 0
    end
  end

  retry_on IO::Error, attempts: 2
  rescue_from IO::Error, with: :on_io

  def on_io(ex : Exception) : Nil
    @@mutex.synchronize { @@handled += 1 }
  end

  def perform(payload : JSON::Any) : Nil
    @@mutex.synchronize { @@runs += 1 }
    raise IO::Error.new("io")
  end
end

class ExtrasUniqueJob < Saci::Job::Base
  unique :until_executed

  @@runs = 0
  @@mutex = Mutex.new

  def self.runs : Int32
    @@mutex.synchronize { @@runs }
  end

  def self.reset! : Nil
    @@mutex.synchronize { @@runs = 0 }
  end

  def perform(payload : JSON::Any) : Nil
    @@mutex.synchronize { @@runs += 1 }
  end
end

class ExtrasUniqueExecutingJob < Saci::Job::Base
  unique :until_executing

  @@runs = 0
  @@mutex = Mutex.new

  def self.runs : Int32
    @@mutex.synchronize { @@runs }
  end

  def self.reset! : Nil
    @@mutex.synchronize { @@runs = 0 }
  end

  def perform(payload : JSON::Any) : Nil
    @@mutex.synchronize { @@runs += 1 }
    sleep 0.3.seconds
  end
end

class ExtrasUniqueWhileJob < Saci::Job::Base
  unique :while_executing

  @@runs = 0
  @@mutex = Mutex.new

  def self.runs : Int32
    @@mutex.synchronize { @@runs }
  end

  def self.reset! : Nil
    @@mutex.synchronize { @@runs = 0 }
  end

  def perform(payload : JSON::Any) : Nil
    @@mutex.synchronize { @@runs += 1 }
    sleep 0.3.seconds
  end
end

class ExtrasPriorityJob < Saci::Job::Base
  @@ran = [] of String
  @@mutex = Mutex.new

  def self.ran : Array(String)
    @@mutex.synchronize { @@ran.dup }
  end

  def self.reset! : Nil
    @@mutex.synchronize { @@ran.clear }
  end

  def perform(payload : JSON::Any) : Nil
    id = payload["id"].as_s
    @@mutex.synchronize { @@ran << id }
  end
end

class ExtrasQueuedJob < Saci::Job::Base
  queue_as :high

  def perform(payload : JSON::Any) : Nil
  end
end

class ExtrasPrioritizedJob < Saci::Job::Base
  queue_with_priority 7

  def perform(payload : JSON::Any) : Nil
  end
end

class ExtrasBatchJob < Saci::Job::Base
  @@runs = 0
  @@mutex = Mutex.new

  def self.runs : Int32
    @@mutex.synchronize { @@runs }
  end

  def self.reset! : Nil
    @@mutex.synchronize { @@runs = 0 }
  end

  def perform(payload : JSON::Any) : Nil
    @@mutex.synchronize { @@runs += 1 }
  end
end

class ExtrasGidJob < Saci::Job::Base
  @@names = [] of String
  @@mutex = Mutex.new

  def self.names : Array(String)
    @@mutex.synchronize { @@names.dup }
  end

  def self.reset! : Nil
    @@mutex.synchronize { @@names.clear }
  end

  def perform(payload : JSON::Any) : Nil
    user = Saci::Job::GlobalID.load(payload["user"]).as(JobExtrasUser)
    @@mutex.synchronize { @@names << user.name.to_s }
  end
end

class ExtrasContinuationJob < Saci::Job::Base
  continuable
  step :one
  step :two
  step :three

  @@runs = [] of String
  @@mutex = Mutex.new

  def self.runs : Array(String)
    @@mutex.synchronize { @@runs.dup }
  end

  def self.reset! : Nil
    @@mutex.synchronize { @@runs.clear }
  end

  def self.log(entry : String) : Nil
    @@mutex.synchronize { @@runs << entry }
  end

  def one : Nil
    ExtrasContinuationJob.log("one")
  end

  def two : Nil
    ExtrasContinuationJob.log("two")
  end

  def three : Nil
    ExtrasContinuationJob.log("three")
  end
end

class ExtrasFlakyStepJob < Saci::Job::Base
  continuable
  step :first
  step :second
  retry_on IO::Error, attempts: 2

  @@runs = [] of String
  @@fails = 1
  @@mutex = Mutex.new

  def self.runs : Array(String)
    @@mutex.synchronize { @@runs.dup }
  end

  def self.reset! : Nil
    @@mutex.synchronize do
      @@runs.clear
      @@fails = 1
    end
  end

  def first : Nil
    @@mutex.synchronize { @@runs << "first" }
  end

  def second : Nil
    @@mutex.synchronize do
      @@runs << "second"
      if @@fails > 0
        @@fails -= 1
        raise IO::Error.new("flaky step")
      end
    end
  end
end

class ExtrasDoomedJob < Saci::Job::Base
  def perform(payload : JSON::Any) : Nil
    raise "always doomed"
  end
end

def extras_db : DB::Database
  Saci::Record.database("primary").as(DB::Database)
end

def extras_wait(deadline_seconds : Float64 = 5.0, &block : -> Bool) : Bool
  deadline = Time.instant + deadline_seconds.seconds
  until yield || Time.instant > deadline
    sleep 0.02.seconds
  end
  yield
end

describe "job extras" do
  before_all do
    File.delete(JOB_EXTRAS_DB_PATH) if File.exists?(JOB_EXTRAS_DB_PATH)
    Saci::Record.connection = DB.open("sqlite3://#{JOB_EXTRAS_DB_PATH}")
    Saci::Job::Db.ensure_schema!
    Saci::Record.exec_compat(extras_db, <<-SQL)
      CREATE TABLE IF NOT EXISTS job_extras_users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name VARCHAR(255) NOT NULL
      )
      SQL
  end

  after_all do
    extras_db.close
  end

  before_each do
    Saci::Job.queue_adapter = :test
    Saci::Job.clear_enqueued!
    Saci::Job.reset_uniqueness!
    Saci::Job.reset_concurrency!
    Saci::Job.reset_error_handler!
    Saci::Job.reset_queue_name_prefix!
    Saci::Job.middleware.clear!
    Saci::Job::Batch.reset!
    Saci::Job::Db.configure(enqueue_after_transaction_commit: false)
    Saci::Job::Db.clear_all!
    ExtrasCallbackJob.reset!
    ExtrasAbortJob.reset!
    ExtrasRescueJob.reset!
    ExtrasRetryRescueJob.reset!
    ExtrasUniqueJob.reset!
    ExtrasUniqueExecutingJob.reset!
    ExtrasUniqueWhileJob.reset!
    ExtrasPriorityJob.reset!
    ExtrasBatchJob.reset!
    ExtrasGidJob.reset!
    ExtrasContinuationJob.reset!
    ExtrasFlakyStepJob.reset!
    Saci::Record.exec_compat(extras_db, "DELETE FROM job_extras_users")
  end

  after_each do
    Saci::Job.queue_adapter = :async
  end

  describe "callbacks and middleware" do
    it "runs enqueue/perform callbacks in order around middleware" do
      Saci::Job.middleware.use(ExtrasLogMiddleware.new)
      Saci::Job.with_adapter(:inline) { ExtrasCallbackJob.perform_later({x: 1}) }
      ExtrasCallbackJob.entries.should eq([
        "middleware:before:ExtrasCallbackJob",
        "around_enqueue:before",
        "before_enqueue",
        # Inline perform goes through middleware a second time.
        "middleware:before:ExtrasCallbackJob",
        "around_perform:before",
        "before_perform",
        "perform",
        "after_perform",
        "around_perform:after",
        "middleware:after",
        "after_enqueue",
        "around_enqueue:after",
        "middleware:after",
      ])
    end

    it "runs enqueue callbacks (but not perform callbacks) for the test adapter" do
      Saci::Job.middleware.use(ExtrasLogMiddleware.new)
      ExtrasCallbackJob.perform_later({x: 1})
      ExtrasCallbackJob.entries.should eq([
        "middleware:before:ExtrasCallbackJob",
        "around_enqueue:before",
        "before_enqueue",
        "after_enqueue",
        "around_enqueue:after",
        "middleware:after",
      ])
    end

    it "runs enqueue and perform callbacks through the DB adapter" do
      Saci::Job.with_adapter(:db) do
        ExtrasCallbackJob.perform_later({x: 1})
        Saci::Job::Db.drain.should eq(1)
      end
      ExtrasCallbackJob.entries.should eq([
        "around_enqueue:before",
        "before_enqueue",
        "after_enqueue",
        "around_enqueue:after",
        "around_perform:before",
        "before_perform",
        "perform",
        "after_perform",
        "around_perform:after",
      ])
    end

    it "runs around callbacks first-declared outermost and after callbacks in reverse" do
      Saci::Job.middleware.add("functional") do |job, nxt|
        ExtrasCallbackJob.log("functional:before")
        nxt.call
        ExtrasCallbackJob.log("functional:after")
      end
      Saci::Job.middleware.names.should eq(["functional"])
      Saci::Job.with_adapter(:inline) { ExtrasCallbackJob.perform_later({} of String => Int32) }
      entries = ExtrasCallbackJob.entries
      entries.first.should eq("functional:before")
      entries.last.should eq("functional:after")
      entries.index("around_enqueue:before").not_nil!.should be < entries.index("before_enqueue").not_nil!
      entries.index("around_perform:before").not_nil!.should be < entries.index("before_perform").not_nil!
      entries.index("after_perform").not_nil!.should be < entries.index("around_perform:after").not_nil!
      Saci::Job.middleware.remove("functional").should be_true
      Saci::Job.middleware.empty?.should be_true
    end

    it "cancels the enqueue when before_enqueue aborts" do
      Saci::Job.with_adapter(:inline) { ExtrasAbortJob.perform_later({} of String => Int32) }
      ExtrasAbortJob.runs.should eq(0)
      Saci::Job.with_adapter(:test) { ExtrasAbortJob.perform_later({} of String => Int32) }
      Saci::Job.enqueued_jobs.should be_empty
    end

    it "lets rescue_from swallow handled errors" do
      Saci::Job.with_adapter(:inline) { ExtrasRescueJob.perform_later({} of String => Int32) }
      ExtrasRescueJob.runs.should eq(1)
      ExtrasRescueJob.handled.should eq(1)
    end

    it "re-raises unhandled errors" do
      expect_raises(ArgumentError, "unhandled") do
        Saci::Job.with_adapter(:inline) { ExtrasUnhandledJob.perform_later({} of String => Int32) }
      end
    end

    it "evaluates retry_on before rescue_from" do
      Saci::Job.with_adapter(:inline) { ExtrasRetryRescueJob.perform_later({} of String => Int32) }
      ExtrasRetryRescueJob.runs.should eq(2)
      ExtrasRetryRescueJob.handled.should eq(1)
    end

    it "propagates middleware errors and skips the job" do
      Saci::Job.middleware.use(ExtrasBoomMiddleware.new)
      expect_raises(Exception, "middleware boom") do
        Saci::Job.with_adapter(:inline) { ExtrasCallbackJob.perform_later({} of String => Int32) }
      end
      ExtrasCallbackJob.entries.should be_empty
    end
  end

  describe "queue selectors and priorities" do
    it "resolves queue_as, prefix and per-enqueue overrides" do
      ExtrasQueuedJob.queue_name.should eq("high")
      ExtrasQueuedJob.queue_name_prefix = "app_"
      Saci::Job.queue_name_prefix.should eq("app_")
      ExtrasQueuedJob.queue_name.should eq("app_high")
      ExtrasQueuedJob.perform_later({} of String => Int32)
      ExtrasQueuedJob.set(queue: :critical, priority: 3).perform_later({} of String => Int32)
      jobs = Saci::Job.enqueued_jobs
      jobs.size.should eq(2)
      jobs[0][:queue].should eq("app_high")
      jobs[0][:priority].should eq(0)
      jobs[1][:queue].should eq("app_critical")
      jobs[1][:priority].should eq(3)
    end

    it "uses the class priority default" do
      ExtrasPrioritizedJob.priority.should eq(7)
      ExtrasPrioritizedJob.perform_later({} of String => Int32)
      Saci::Job.enqueued_jobs.first[:priority].should eq(7)
    end

    it "accepts :immediate as an alias for :inline" do
      Saci::Job.queue_adapter = :immediate
      Saci::Job.queue_adapter.should eq(:inline)
    end

    it "claims the highest priority first in the DB adapter" do
      Saci::Job.with_adapter(:db) do
        ExtrasPriorityJob.set(priority: 1).perform_later({id: "low"})
        ExtrasPriorityJob.set(priority: 10).perform_later({id: "high"})
        ExtrasPriorityJob.set(priority: 5).perform_later({id: "mid"})
        Saci::Job::Db.drain.should eq(3)
      end
      ExtrasPriorityJob.ran.should eq(["high", "mid", "low"])
    end

    it "filters drains by queue and honors configured queues" do
      Saci::Job.with_adapter(:db) do
        ExtrasPriorityJob.set(queue: "a").perform_later({id: "a1"})
        ExtrasPriorityJob.set(queue: "b").perform_later({id: "b1"})
        Saci::Job::Db.pending_count(queue: "a").should eq(1)
        Saci::Job::Db.drain(queue: "a").should eq(1)
        ExtrasPriorityJob.ran.should eq(["a1"])
        Saci::Job::Db.pending_count.should eq(1)
        Saci::Job::Db.drain.should eq(1)
        ExtrasPriorityJob.ran.should eq(["a1", "b1"])
      end

      Saci::Job.with_adapter(:db) do
        ExtrasPriorityJob.set(queue: "a").perform_later({id: "a2"})
        ExtrasPriorityJob.set(queue: "b").perform_later({id: "b2"})
        Saci::Job::Db.configure(queues: ["a"])
        Saci::Job::Db.drain.should eq(1)
        ExtrasPriorityJob.ran.last.should eq("a2")
        Saci::Job::Db.configure(queues: nil)
        Saci::Job::Db.drain.should eq(1)
      end
    end

    it "generates FOR UPDATE SKIP LOCKED only for PostgreSQL/MySQL" do
      Saci::Job::Db.claim_sql(:postgres).should contain("FOR UPDATE SKIP LOCKED")
      Saci::Job::Db.claim_sql(:mysql).should contain("FOR UPDATE SKIP LOCKED")
      Saci::Job::Db.claim_sql(:sqlite).should_not contain("FOR UPDATE")
      Saci::Job::Db.claim_sql(:postgres).should contain("DESC")
      Saci::Job::Db.claim_sql(:postgres, queue: "high").should contain("= ?")
    end
  end

  describe "adapter registry" do
    it "registers and uses custom adapters" do
      received = [] of String
      Saci::Job.register_adapter(:extras_memory) do |job_class, payload_json, wait, queue, priority, wait_until, batch_id|
        received << "#{job_class.name}|#{queue}|#{priority}"
      end
      Saci::Job.adapters.should contain(:extras_memory)
      Saci::Job.with_adapter(:extras_memory) { ExtrasQueuedJob.perform_later({} of String => Int32) }
      received.should eq(["ExtrasQueuedJob|high|0"])
      Saci::Job.unregister_adapter(:extras_memory).should be_true
      Saci::Job.adapters.should_not contain(:extras_memory)
    end

    it "rejects unknown adapters" do
      expect_raises(ArgumentError, /Unknown queue adapter/) { Saci::Job.queue_adapter = :sidekiq }
    end
  end

  describe "unique jobs" do
    it "dedupes in memory for non-DB adapters" do
      ExtrasUniqueJob.perform_later({id: 1})
      ExtrasUniqueJob.perform_later({id: 1})
      ExtrasUniqueJob.perform_later({id: 2})
      Saci::Job.enqueued_jobs.size.should eq(2)
      Saci::Job::Uniqueness.queued?(ExtrasUniqueJob.__saci_unique_key(%({"id":1}))).should be_true
    end

    it "dedupes atomically in the DB adapter until executed" do
      Saci::Job.with_adapter(:db) do
        ExtrasUniqueJob.perform_later({id: 1})
        ExtrasUniqueJob.perform_later({id: 1})
        Saci::Job::Db.pending_count.should eq(1)
        Saci::Job::Db.drain.should eq(1)
        ExtrasUniqueJob.runs.should eq(1)
        ExtrasUniqueJob.perform_later({id: 1})
        Saci::Job::Db.pending_count.should eq(1)
        Saci::Job::Db.drain.should eq(1)
        ExtrasUniqueJob.runs.should eq(2)
      end
    end

    it "releases :until_executing when the job starts" do
      Saci::Job.with_adapter(:db) do
        ExtrasUniqueExecutingJob.perform_later({id: 1})
        ExtrasUniqueExecutingJob.perform_later({id: 1})
        Saci::Job::Db.pending_count.should eq(1)
        Saci::Job::Db.work_once.should eq(1)
        extras_wait { ExtrasUniqueExecutingJob.runs == 1 }
        # The running copy released the lock at claim time, so a new copy is
        # accepted while the first still runs.
        ExtrasUniqueExecutingJob.perform_later({id: 1})
        # The running first copy is still a row; the newly accepted copy is
        # the second one.
        Saci::Job::Db.pending_count.should eq(2)
        extras_wait { Saci::Job::Db.pending_count == 1 }
        Saci::Job::Db.drain.should eq(1)
        extras_wait { ExtrasUniqueExecutingJob.runs == 2 }
        ExtrasUniqueExecutingJob.runs.should eq(2)
      end
    end

    it "allows queued duplicates but runs one at a time for :while_executing" do
      Saci::Job.with_adapter(:db) do
        ExtrasUniqueWhileJob.perform_later({id: 1})
        ExtrasUniqueWhileJob.perform_later({id: 1})
        Saci::Job::Db.pending_count.should eq(2)
        # The second row is skipped while the first holds the executing lock.
        Saci::Job::Db.work_once.should eq(1)
        extras_wait { ExtrasUniqueWhileJob.runs == 1 }
        sleep 0.4.seconds
        Saci::Job::Db.pending_count.should eq(1)
        Saci::Job::Db.drain.should eq(1)
        ExtrasUniqueWhileJob.runs.should eq(2)
      end
    end
  end

  describe "batches" do
    it "tracks completion and runs the callback (inline)" do
      events = [] of String
      batch = Saci::Job::Batch.new("extras-inline", total: 2) do |b|
        events << "done:#{b.completed}/#{b.total}"
      end
      Saci::Job.with_adapter(:inline) do
        batch.enqueue(ExtrasBatchJob, {id: 1})
        batch.enqueue(ExtrasBatchJob, {id: 2})
      end
      ExtrasBatchJob.runs.should eq(2)
      events.should eq(["done:2/2"])
    end

    it "tracks completion across a DB drain" do
      events = [] of String
      batch = Saci::Job::Batch.new("extras-db") do |b|
        events << "done:#{b.total}"
      end
      Saci::Job.with_adapter(:db) do
        batch.enqueue(ExtrasBatchJob, {id: 1})
        batch.enqueue(ExtrasBatchJob, {id: 2})
      end
      batch.close
      events.should be_empty
      Saci::Job::Db.drain.should eq(2)
      events.should eq(["done:2"])
      ExtrasBatchJob.runs.should eq(2)
    end

    it "supports perform_all_later/enqueue_all" do
      ExtrasBatchJob.perform_all_later([{id: 1}, {id: 2}])
      Saci::Job.enqueued_jobs.size.should eq(2)
      Saci::Job.clear_enqueued!
      Saci::Job.enqueue_all([
        Saci::Job::EnqueueRequest.new(ExtrasBatchJob, {id: 3}),
        Saci::Job::EnqueueRequest.new(ExtrasQueuedJob, {} of String => Int32, queue: "critical"),
      ])
      jobs = Saci::Job.enqueued_jobs
      jobs.size.should eq(2)
      jobs[1][:queue].should eq("critical")
    end
  end

  describe "GlobalID arguments" do
    it "serializes and resolves records inside nested arguments" do
      user = JobExtrasUser.create!(name: "Ada")
      payload = Saci::Job.encode({user: user, ids: [1, 2], label: "x"})
      reference = payload["user"]
      reference["_saci_record"].as_s.should eq("JobExtrasUser")
      reference["id"].as_i64.should eq(user.id.not_nil!)
      round_tripped = JSON.parse(payload.to_json)
      loaded = Saci::Job::GlobalID.load(round_tripped["user"]).as(JobExtrasUser)
      loaded.name.should eq("Ada")
      Saci::Job::GlobalID.record?(round_tripped["user"]).should be_true
    end

    it "accepts gid-shaped references" do
      user = JobExtrasUser.create!(name: "Grace")
      loaded = Saci::Job::GlobalID.load(JSON.parse(%({"gid": "JobExtrasUser/#{user.id}"}))).as(JobExtrasUser)
      loaded.name.should eq("Grace")
      loaded = Saci::Job::GlobalID.load(JSON.parse(%({"gid": "gid://saci/JobExtrasUser/#{user.id}"}))).as(JobExtrasUser)
      loaded.name.should eq("Grace")
    end

    it "raises RecordNotFound for dangling references" do
      expect_raises(Saci::Record::RecordNotFound) do
        Saci::Job::GlobalID.load(JSON.parse(%({"gid": "JobExtrasUser/999999"})))
      end
    end

    it "rejects unsupported argument classes and unsaved records" do
      expect_raises(ArgumentError, /unsupported job argument/) do
        Saci::Job.encode({io: STDOUT})
      end
      expect_raises(ArgumentError, /unsaved/) do
        Saci::Job.encode(JobExtrasUser.new)
      end
    end

    it "delivers a record through the durable adapter" do
      user = JobExtrasUser.create!(name: "Durable")
      Saci::Job.with_adapter(:db) do
        ExtrasGidJob.perform_later({user: user})
        Saci::Job::Db.drain.should eq(1)
      end
      ExtrasGidJob.names.should eq(["Durable"])
    end
  end

  describe "continuations" do
    it "runs steps in declaration order" do
      ExtrasContinuationJob.__saci_steps.should eq(["one", "two", "three"])
      Saci::Job.with_adapter(:inline) { ExtrasContinuationJob.perform_later({} of String => Int32) }
      ExtrasContinuationJob.runs.should eq(["one", "two", "three"])
    end

    it "resumes from a persisted checkpoint in the DB adapter" do
      Saci::Job.with_adapter(:db) do
        Saci::Job::Db.enqueue("ExtrasContinuationJob", "default", %({}))
        Saci::Record.exec_compat(extras_db,
          "UPDATE saci_jobs SET checkpoint = ?",
          [%( ["one"] )] of Saci::Record::Value)
        Saci::Job::Db.drain.should eq(1)
      end
      ExtrasContinuationJob.runs.should eq(["two", "three"])
    end

    it "resumes after retry in the DB adapter" do
      Saci::Job.with_adapter(:db) do
        ExtrasFlakyStepJob.perform_later({} of String => Int32)
        Saci::Job::Db.drain.should eq(1)
      end
      ExtrasFlakyStepJob.runs.should eq(["first", "second", "second"])
    end
  end

  describe "DB depth" do
    it "records process metadata and heartbeats" do
      Saci::Job::Db.configure(worker_id: "extras-worker")
      Saci::Job::Db.register_process!
      processes = Saci::Job::Db.processes
      processes.map(&.[:worker_id]).should contain("extras-worker")
      Saci::Job::Db.stop_process!.should be_true
      Saci::Job::Db.processes.map(&.[:worker_id]).should_not contain("extras-worker")
    end

    it "prunes stale process rows" do
      Saci::Job::Db.configure(worker_id: "extras-stale")
      Saci::Job::Db.heartbeat!
      Saci::Job::Db.prune_processes!(older_than: -1.second).should be >= 1
      Saci::Job::Db.processes.should be_empty
    end

    it "prunes failed jobs" do
      Saci::Job.with_adapter(:db) do
        ExtrasDoomedJob.perform_later({} of String => Int32)
        Saci::Job::Db.drain.should eq(1)
      end
      Saci::Job::Db.dead_count.should eq(1)
      Saci::Record.exec_compat(extras_db,
        "UPDATE saci_dead_jobs SET failed_at = ?",
        [(Time.utc - 1.hour).to_rfc3339(fraction_digits: 9)] of Saci::Record::Value)
      Saci::Job::Db.prune_dead(older_than: 1.minute).should eq(1)
      Saci::Job::Db.dead_count.should eq(0)
    end

    it "defers DB enqueues until the surrounding transaction commits" do
      Saci::Job::Db.configure(enqueue_after_transaction_commit: true)
      Saci::Job.with_adapter(:db) do
        Saci::Record.transaction do |_conn|
          ExtrasBatchJob.perform_later({id: 1})
          Saci::Job::Db.pending_count.should eq(0)
        end
        Saci::Job::Db.pending_count.should eq(1)
      end
      Saci::Job::Db.drain.should eq(1)
      ExtrasBatchJob.runs.should eq(1)
    end

    it "drops deferred enqueues on rollback" do
      Saci::Job::Db.configure(enqueue_after_transaction_commit: true)
      Saci::Job.with_adapter(:db) do
        Saci::Record.transaction do |_conn|
          ExtrasBatchJob.perform_later({id: 1})
          raise DB::Rollback.new
        end
        Saci::Job::Db.pending_count.should eq(0)
      end
    end
  end
end
