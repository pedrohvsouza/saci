require "spec"
require "../src/saci"

# Enables real threads for this process when compiled with
# multithreading (`crystal spec -Dexecution_context`); without the flag
# it is a no-op and everything below still passes single-threaded.
Saci.enable_multithreading!

CONC_DB_PATH = "/tmp/opencode/saci_concurrency_test.db"

class ConcWidget < Saci::Record::Base
  column id : Int64, primary: true
  column name : String
end

class ConcHelloController < Saci::Controller
  def index
    render text: "ok-#{params["i"]? || "?"}"
  end
end

# Runs `count` fibers, always signaling completion (even on error) so a
# failure can never hang the suite waiting on the channel.
def run_fibers(count : Int32, &block : Int32 -> T) : Array(T | Exception) forall T
  done = Channel(T | Exception).new(count)
  count.times do |i|
    spawn do
      begin
        done.send(block.call(i))
      rescue ex
        done.send(ex)
      end
    end
  end
  Array(T | Exception).new(count) { done.receive }
end

describe "multithreading" do
  before_all do
    File.delete(CONC_DB_PATH) if File.exists?(CONC_DB_PATH)
    Saci::Record::Base.connection = DB.open("sqlite3://#{CONC_DB_PATH}")
    Saci::Record::Base.connection.as(DB::Database).exec(
      "CREATE TABLE \"#{ConcWidget.table_name}\" (\"id\" INTEGER PRIMARY KEY AUTOINCREMENT, \"name\" TEXT)"
    )
  end

  after_all do
    Saci::Record::Base.connection.as(DB::Database).close
  end

  it "commits concurrent transactions without cross-talk" do
    results = run_fibers(8) do |i|
      Saci::Record.transaction do
        ConcWidget.create!(name: "w-#{i}")
      end
      i
    end
    results.each { |r| r.should be_a(Int32) }
    ConcWidget.count.should eq(8)
    ConcWidget.pluck(:name).map(&.to_s).sort.should eq((0...8).map { |i| "w-#{i}" }.to_a.sort)
  end

  it "isolates rollback to the failing fiber" do
    Saci::Record.transaction { ConcWidget.create!(name: "keeper") }
    run_fibers(2) do |i|
      Saci::Record.transaction do
        ConcWidget.create!(name: "fiber-#{i}")
        raise DB::Rollback.new if i == 0
      end
      i
    end
    ConcWidget.exists?(name: "keeper").should be_true
    ConcWidget.exists?(name: "fiber-1").should be_true
    ConcWidget.exists?(name: "fiber-0").should be_false
  end

  it "reuses the outer transaction when nested in one fiber" do
    Saci::Record.transaction do |outer|
      Saci::Record.transaction do |inner|
        outer.object_id.should eq(inner.object_id)
      end
    end
  end

  it "resizes execution parallelism when multithreaded" do
    # Work distribution across threads is scheduler-heuristic (tiny fibers
    # legitimately stay local), so assert the mechanism, not the spread:
    # functional tests above prove correctness either way.
    {% if flag?(:execution_context) || flag?(:preview_mt) %}
      Fiber::ExecutionContext.default.capacity.should eq(Fiber::ExecutionContext.default_workers_count)
      Saci.multithreaded?.should be_true
    {% else %}
      Saci.multithreaded?.should be_false
    {% end %}
  end

  it "serves concurrent HTTP requests" do
    router = Saci::Router.new.draw do |r|
      r.get "/hi", ConcHelloController, :index
    end
    Saci::TestSession.serve(router) do |app|
      # One connection per fiber: HTTP::Client itself is not shareable.
      results = run_fibers(16) do |i|
        client = HTTP::Client.new(app.host, app.port)
        begin
          client.get("/hi?i=#{i}").body
        ensure
          client.close
        end
      end
      results.each_with_index do |body, i|
        body.as(String).should eq("ok-#{i}")
      end
    end
  end
end
