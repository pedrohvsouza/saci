require "spec"
require "file_utils"
require "../src/saci"
require "../src/saci/job_dashboard"

JOB_DASHBOARD_DB_PATH = "/tmp/opencode/saci_job_dashboard_test.db"

class DashboardProbeJob < Saci::Job::Base
  queue_as :probes

  def perform(payload : JSON::Any) : Nil
  end
end

class DashboardMailJob < Saci::Job::Base
  queue_as :mailers

  def perform(payload : JSON::Any) : Nil
  end
end

class DashboardDoomedJob < Saci::Job::Base
  def perform(payload : JSON::Any) : Nil
    raise "dashboard doom"
  end
end

def job_dashboard_router : Saci::Router
  Saci::Router.new.draw do |r|
    r.get "/saci/jobs", Saci::Job::DashboardController, :index
    r.get "/saci/jobs/dead", Saci::Job::DashboardController, :dead
    r.post "/saci/jobs/dead/:id/retry", Saci::Job::DashboardController, :retry_dead
    r.post "/saci/jobs/dead/:id/drop", Saci::Job::DashboardController, :drop_dead
  end
end

module JobDashboardSpecState
  class_property old_adapter : Symbol = :async
  class_property prior_db : (DB::Database | DB::Connection)? = nil
end

describe Saci::Job::Dashboard do
  before_all do
    begin
      JobDashboardSpecState.prior_db = Saci::Record.connection
    rescue
      JobDashboardSpecState.prior_db = nil
    end
    File.delete(JOB_DASHBOARD_DB_PATH) if File.exists?(JOB_DASHBOARD_DB_PATH)
    Saci::Record.connection = DB.open("sqlite3://#{JOB_DASHBOARD_DB_PATH}")
    Saci::Job::Db.ensure_schema!
  end

  after_all do
    begin
      db = Saci::Record.database("primary").as(DB::Database)
      ad = Saci::Record.adapter_of(db)
      Saci::Record.exec_compat(db, "DROP TABLE IF EXISTS #{Saci::Record.quote(Saci::Job::Db::JOBS_TABLE, ad)}")
      Saci::Record.exec_compat(db, "DROP TABLE IF EXISTS #{Saci::Record.quote(Saci::Job::Db::DEAD_TABLE, ad)}")
      db.close
    rescue
    end
    restored = false
    if prior = JobDashboardSpecState.prior_db
      begin
        Saci::Record.connection = prior.as(DB::Database)
        restored = true
      rescue
      end
    end
    unless restored
      begin
        Saci::Record.connection = DB.open("sqlite3::memory:")
      rescue
      end
    end
    {"#{JOB_DASHBOARD_DB_PATH}", "#{JOB_DASHBOARD_DB_PATH}-wal", "#{JOB_DASHBOARD_DB_PATH}-shm"}.each do |path|
      File.delete(path) if File.exists?(path)
    end
  end

  before_each do
    Saci::Job::Dashboard.reset!
    Saci::Job::Dashboard.enabled = true
    JobDashboardSpecState.old_adapter = Saci::Job.queue_adapter
    Saci::Job.queue_adapter = :db
    Saci::Job::Db.clear_all!
  end

  after_each do
    Saci::Job::Dashboard.reset!
    Saci::Job.queue_adapter = JobDashboardSpecState.old_adapter
    Saci::Job.reset_error_handler!
  end

  it "indexes pending counts with by-queue and by-class breakdowns" do
    Saci::Job::Db.enqueue("DashboardProbeJob", "probes", %({"id":1}))
    Saci::Job::Db.enqueue("DashboardProbeJob", "probes", %({"id":2}))
    Saci::Job::Db.enqueue("DashboardMailJob", "mailers", %({}))
    stats = Saci::Job::Dashboard.stats
    stats[:db_adapter].should be_true
    stats[:pending].should eq(3)
    stats[:by_class].should eq({"DashboardProbeJob" => 2_i64, "DashboardMailJob" => 1_i64})
    stats[:by_queue].should eq({"probes" => 2_i64, "mailers" => 1_i64})
    Saci::TestSession.serve(job_dashboard_router) do |app|
      resp = app.get("/saci/jobs")
      resp.status_code.should eq(200)
      resp.headers["Content-Type"].should contain("text/html")
      resp.body.should contain("DashboardProbeJob")
      resp.body.should contain("DashboardMailJob")
      resp.body.should contain("probes")
      resp.body.should contain("mailers")
    end
  end

  it "reports oldest pending age and dead count" do
    Saci::Job::Db.enqueue("DashboardProbeJob", "probes", %({}))
    stats = Saci::Job::Dashboard.stats
    stats[:oldest_pending_age].should_not be_nil
    stats[:oldest_pending_age].not_nil!.total_seconds.should be >= 0
    stats[:dead].should eq(0)
    Saci::TestSession.serve(job_dashboard_router) do |app|
      body = app.get("/saci/jobs").body
      body.should contain("Oldest pending")
      body.should contain("/saci/jobs/dead")
    end
  end

  it "lists dead jobs with error and attempts" do
    Saci::Job::Db.enqueue("DashboardDoomedJob", "default", %({}))
    Saci::Job::Db.drain
    Saci::Job::Dashboard.stats[:dead].should eq(1)
    Saci::TestSession.serve(job_dashboard_router) do |app|
      resp = app.get("/saci/jobs/dead")
      resp.status_code.should eq(200)
      resp.body.should contain("DashboardDoomedJob")
      resp.body.should contain("dashboard doom")
      resp.body.should contain("/retry")
      resp.body.should contain("/drop")
    end
  end

  it "retries a dead job back into pending" do
    Saci::Job::Db.enqueue("DashboardDoomedJob", "default", %({}))
    Saci::Job::Db.drain
    id = Saci::Job::Db.dead_jobs.first[:id]
    Saci::TestSession.serve(job_dashboard_router) do |app|
      resp = app.post("/saci/jobs/dead/#{id}/retry")
      resp.status_code.should eq(302)
      resp.headers["Location"].should eq("/saci/jobs/dead")
    end
    Saci::Job::Db.pending_count.should eq(1)
    Saci::Job::Db.dead_count.should eq(0)
  end

  it "drops a dead job without running it" do
    Saci::Job::Db.enqueue("DashboardDoomedJob", "default", %({}))
    Saci::Job::Db.drain
    id = Saci::Job::Db.dead_jobs.first[:id]
    Saci::TestSession.serve(job_dashboard_router) do |app|
      resp = app.post("/saci/jobs/dead/#{id}/drop")
      resp.status_code.should eq(302)
      resp.headers["Location"].should eq("/saci/jobs/dead")
    end
    Saci::Job::Db.dead_count.should eq(0)
    Saci::Job::Db.pending_count.should eq(0)
  end

  it "404s retry/drop for missing dead jobs" do
    Saci::TestSession.serve(job_dashboard_router) do |app|
      app.post("/saci/jobs/dead/999999/retry").status_code.should eq(404)
      app.post("/saci/jobs/dead/999999/drop").status_code.should eq(404)
    end
  end

  it "404s every action when disabled" do
    Saci::Job::Dashboard.enabled = false
    Saci::TestSession.serve(job_dashboard_router) do |app|
      app.get("/saci/jobs").status_code.should eq(404)
      app.get("/saci/jobs/dead").status_code.should eq(404)
      app.post("/saci/jobs/dead/1/retry").status_code.should eq(404)
      app.post("/saci/jobs/dead/1/drop").status_code.should eq(404)
    end
  end

  it "is disabled by default in production" do
    old = ENV["APP_ENV"]?
    begin
      ENV["APP_ENV"] = "production"
      Saci::Job::Dashboard.reset!
      Saci::Job::Dashboard.enabled.should be_false
    ensure
      if old.nil?
        ENV.delete("APP_ENV")
      else
        ENV["APP_ENV"] = old
      end
      Saci::Job::Dashboard.reset!
      Saci::Job::Dashboard.enabled = true
    end
  end

  it "renders an empty state instead of 500 when the adapter isn't :db" do
    Saci::Job.queue_adapter = :async
    stats = Saci::Job::Dashboard.stats
    stats[:db_adapter].should be_false
    stats[:pending].should be_nil
    Saci::TestSession.serve(job_dashboard_router) do |app|
      index = app.get("/saci/jobs")
      index.status_code.should eq(200)
      index.body.should contain(":db")
      dead = app.get("/saci/jobs/dead")
      dead.status_code.should eq(200)
      dead.body.should contain(":db")
      retry_resp = app.post("/saci/jobs/dead/1/retry")
      (retry_resp.status_code == 302 || retry_resp.status_code == 404).should be_true
    end
  end
end
