require "spec"
require "../src/saci"

class JobsFlakyJob < Saci::Job::Base
  retry_on IO::Error, attempts: 5

  @@runs = 0
  @@runs_mutex = Mutex.new

  def self.runs : Int32
    @@runs_mutex.synchronize { @@runs }
  end

  def self.reset_runs! : Nil
    @@runs_mutex.synchronize { @@runs = 0 }
  end

  def perform(payload : JSON::Any) : Nil
    n = @@runs_mutex.synchronize { @@runs += 1 }
    raise IO::Error.new("boom") if n < 3
  end
end

class JobsGivingUpJob < Saci::Job::Base
  retry_on IO::Error, attempts: 2

  def perform(payload : JSON::Any) : Nil
    raise IO::Error.new("always")
  end
end

class JobsDropItJob < Saci::Job::Base
  discard_on ArgumentError

  def perform(payload : JSON::Any) : Nil
    raise ArgumentError.new("nope")
  end
end

class JobsRecordJob < Saci::Job::Base
  queue_as :mailers

  def perform(payload : JSON::Any) : Nil
  end
end

describe Saci::Job do
  before_each do
    Saci::Job.queue_adapter = :test
    Saci::Job.clear_enqueued!
    Saci::Job.on_error { |_, _| }
  end

  after_each do
    Saci::Job.queue_adapter = :async
    Saci::Job.reset_error_handler!
  end

  it "runs inline immediately" do
    JobsFlakyJob.reset_runs!
    Saci::Job.with_adapter(:inline) do
      JobsFlakyJob.perform_later({x: 1})
    end
    JobsFlakyJob.runs.should eq(3)
  end

  it "retries with attempts limit then reports and raises" do
    errors = [] of Tuple(String, Exception)
    Saci::Job.on_error { |job, ex| errors << {job, ex} }
    expect_raises(IO::Error) do
      Saci::Job.with_adapter(:inline) do
        JobsGivingUpJob.perform_later({x: 1})
      end
    end
    errors.size.should eq(1)
    errors.first[0].should eq("JobsGivingUpJob")
  end

  it "discards without raising" do
    Saci::Job.with_adapter(:inline) do
      JobsDropItJob.perform_later({x: 1})
    end
  end

  it "records enqueues with the test adapter" do
    JobsRecordJob.perform_later({hello: "world"})
    JobsRecordJob.set(wait: 5.minutes).perform_later({hello: "again"})
    jobs = Saci::Job.enqueued_jobs
    jobs.size.should eq(2)
    jobs.first[:job].should eq("JobsRecordJob")
    JSON.parse(jobs.first[:payload])["hello"].as_s.should eq("world")
    JobsRecordJob.queue_name.should eq("mailers")
  end

  it "restores the adapter after with_adapter" do
    Saci::Job.with_adapter(:inline) { }
    Saci::Job.queue_adapter.should eq(:test)
  end

  it "rejects unknown adapters" do
    expect_raises(ArgumentError) { Saci::Job.queue_adapter = :redis }
  end

  it "runs perform_now directly" do
    JobsRecordJob.perform_now({x: 1})
  end
end
