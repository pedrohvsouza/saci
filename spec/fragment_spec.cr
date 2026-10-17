require "spec"
require "../src/saci"

class FragWidget < Saci::Record::Base
  table "frag_widgets"

  column id : Int64, primary: true
  column updated_at : Time
end

# A store that is always down (fail-open specs).
class FragDownStore < Saci::Cache::Store
  def read(key : String) : String?
    raise Saci::Cache::RedisDown.new("down")
  end

  def read_value(key : String) : Saci::Cache::Value
    raise Saci::Cache::RedisDown.new("down")
  end

  def write(key : String, value : String | Int | Float | Bool | Time | Nil, expires_in : Time::Span? = nil) : Bool
    raise Saci::Cache::RedisDown.new("down")
  end

  def delete(key : String) : Bool
    raise Saci::Cache::RedisDown.new("down")
  end

  def exist?(key : String) : Bool
    raise Saci::Cache::RedisDown.new("down")
  end

  def clear : Nil
    raise Saci::Cache::RedisDown.new("down")
  end

  def increment(key : String, by : Int = 1) : Int64
    raise Saci::Cache::RedisDown.new("down")
  end

  def fetch(key : String, expires_in : Time::Span? = nil, &block : -> String) : String
    raise Saci::Cache::RedisDown.new("down")
  end

  def fetch_value(key : String, expires_in : Time::Span? = nil, &block : -> Saci::Cache::Value) : Saci::Cache::Value
    raise Saci::Cache::RedisDown.new("down")
  end
end

class FragPartsController < Saci::Controller
  def stamped_list
    stamp = params["stamp"]? || "none"
    render html: cache("frag/stamped-list") { stamp + render_partial("spec_parts/comment", collection: ["one", "two"]) }
  end

  def nested
    render html: cache("frag/outer") { "OUTER[" + cache("frag/inner") { render_partial("spec_parts/greet", name: "Ada") } + "]" }
  end
end

def frag_router : Saci::Router
  Saci::Router.new.draw do |r|
    r.get "/stamped-list", FragPartsController, :stamped_list
    r.get "/nested", FragPartsController, :nested
  end
end

describe "fragment caching (Saci::Views.cache)" do
  before_each do
    Saci::Cache.reset!
  end

  after_each do
    Saci::Cache.reset!
  end

  it "renders on miss and serves the stored String on hit (block runs once)" do
    calls = 0
    first = Saci::Views.cache("frag/a") { calls += 1; "rendered-#{calls}" }
    second = Saci::Views.cache("frag/a") { calls += 1; "rendered-#{calls}" }
    first.should eq("rendered-1")
    second.should eq("rendered-1")
    calls.should eq(1)
    Saci::Cache.read("frag/a").should eq("rendered-1")
  end

  it "expires entries (block re-runs after expiry)" do
    calls = 0
    Saci::Views.cache("frag/exp", expires_in: 100.milliseconds) { calls += 1; "v#{calls}" }.should eq("v1")
    sleep 150.milliseconds
    Saci::Views.cache("frag/exp", expires_in: 100.milliseconds) { calls += 1; "v#{calls}" }.should eq("v2")
    calls.should eq(2)
  end

  it "keeps versioned keys separate (:vN suffix, spec-pinned)" do
    Saci::Views.cache_key("frag/v").should eq("frag/v")
    Saci::Views.cache_key("frag/v", version: 2).should eq("frag/v:v2")
    Saci::Views.cache_key("frag/v", version: 1).should_not eq(Saci::Views.cache_key("frag/v", version: 2))

    Saci::Views.cache("frag/v", version: 1) { "one" }.should eq("one")
    Saci::Views.cache("frag/v", version: 2) { "two" }.should eq("two")
    Saci::Views.cache("frag/v", version: 1) { "one-again" }.should eq("one")
    Saci::Views.cache("frag/v") { "plain" }.should eq("plain")
  end

  it "fails open when the store is down (renders uncached, block runs every call)" do
    Saci::Cache.store = FragDownStore.new
    begin
      calls = 0
      Saci::Views.cache("frag/down") { calls += 1; "live-#{calls}" }.should eq("live-1")
      Saci::Views.cache("frag/down") { calls += 1; "live-#{calls}" }.should eq("live-2")
      calls.should eq(2)
    ensure
      Saci::Cache.reset!
    end
  end
end

describe "Saci::Views.cache_key" do
  it "keys records as table/id-updated_at (stale? etag logic)" do
    rec = FragWidget.new(id: 5_i64, updated_at: Time.unix(1000))
    Saci::Views.cache_key(rec).should eq("frag_widgets/5-1000")
    Saci::Views.cache_key(rec, version: 2).should eq("frag_widgets/5-1000:v2")
  end

  it "keys records without updated_at as table/id" do
    rec = FragWidget.new(id: 5_i64)
    Saci::Views.cache_key(rec).should eq("frag_widgets/5")
  end

  it "keys collections as table/count-max_updated_at" do
    a = FragWidget.new(id: 1_i64, updated_at: Time.unix(1000))
    b = FragWidget.new(id: 2_i64, updated_at: Time.unix(2000))
    Saci::Views.cache_key([a, b]).should eq("frag_widgets/collection-2-2000")
    Saci::Views.cache_key([a, b], version: 3).should eq("frag_widgets/collection-2-2000:v3")
  end

  it "changes the collection key when rows are added or touched" do
    a = FragWidget.new(id: 1_i64, updated_at: Time.unix(1000))
    b = FragWidget.new(id: 2_i64, updated_at: Time.unix(2000))
    before = Saci::Views.cache_key([a, b])
    c = FragWidget.new(id: 3_i64, updated_at: Time.unix(500))
    Saci::Views.cache_key([a, b, c]).should_not eq(before)
    b2 = FragWidget.new(id: 2_i64, updated_at: Time.unix(3000))
    Saci::Views.cache_key([a, b2]).should_not eq(before)
  end

  it "keys empty collections deterministically" do
    Saci::Views.cache_key([] of FragWidget).should eq("collection/empty")
  end

  it "expands mixed arrays as composite keys" do
    rec = FragWidget.new(id: 5_i64, updated_at: Time.unix(1000))
    Saci::Views.expand_fragment_key(["v1", rec]).should eq("v1/frag_widgets/5-1000")
    Saci::Views.expand_fragment_key("plain").should eq("plain")
    Saci::Views.expand_fragment_key(:sym).should eq("sym")
    Saci::Views.expand_fragment_key(rec).should eq("frag_widgets/5-1000")
  end
end

describe "russian-doll fragments" do
  before_each do
    Saci::Cache.reset!
  end

  after_each do
    Saci::Cache.reset!
  end

  it "reuses the inner hit inside an outer miss, then serves the outer hit" do
    inner_calls = 0
    outer_calls = 0
    render = -> {
      Saci::Views.cache("frag/doll-outer") do
        outer_calls += 1
        "O[" + Saci::Views.cache("frag/doll-inner") { inner_calls += 1; "I" } + "]"
      end
    }
    render.call.should eq("O[I]")
    render.call.should eq("O[I]")
    inner_calls.should eq(1)
    outer_calls.should eq(1)

    # Bust the outer entry only: the outer miss re-renders around the inner hit.
    Saci::Cache.delete("frag/doll-outer").should be_true
    render.call.should eq("O[I]")
    outer_calls.should eq(2)
    inner_calls.should eq(1)

    # Bust both: everything re-renders.
    Saci::Cache.delete("frag/doll-inner").should be_true
    Saci::Cache.delete("frag/doll-outer").should be_true
    render.call.should eq("O[I]")
    outer_calls.should eq(3)
    inner_calls.should eq(2)
  end

  it "documents the stale-outer caveat (inner delete alone does not expire the outer entry)" do
    Saci::Views.cache("frag/cave-outer") { "O[" + Saci::Views.cache("frag/cave-inner") { "I1" } + "]" }.should eq("O[I1]")
    Saci::Cache.delete("frag/cave-inner")
    # Outer hit still embeds the old inner HTML.
    Saci::Views.cache("frag/cave-outer") { "O[" + Saci::Views.cache("frag/cave-inner") { "I2" } + "]" }.should eq("O[I1]")
    # A version bump expires the outer entry and picks up the fresh inner HTML.
    Saci::Views.cache("frag/cave-outer", version: 2) { "O[" + Saci::Views.cache("frag/cave-inner") { "I2" } + "]" }.should eq("O[I2]")
  end
end

describe "fragment caching in ECR (render_partial collections)" do
  before_each do
    Saci::Cache.reset!
  end

  after_each do
    Saci::Cache.reset!
  end

  it "caches render_partial collection output across requests" do
    Saci::TestSession.serve(frag_router) do |app|
      first = app.get("/stamped-list?stamp=A")
      first.status_code.should eq(200)
      first.body.should contain("A")
      first.body.should contain(%(<div class="comment">one</div>))
      first.body.should contain(%(<div class="comment">two</div>))

      # Same cache key with a new stamp still serves the first render (hit).
      second = app.get("/stamped-list?stamp=B")
      second.body.should contain("A")
      second.body.should_not contain("B")

      # Explicit expiry re-renders with the new stamp.
      Saci::Cache.delete("frag/stamped-list").should be_true
      third = app.get("/stamped-list?stamp=B")
      third.body.should contain("B")
      third.body.should contain(%(<div class="comment">two</div>))
    end
  end

  it "renders nested fragments in templates" do
    Saci::TestSession.serve(frag_router) do |app|
      expected = "OUTER[<span>Hello, Ada!</span>"
      app.get("/nested").body.should contain(expected)
      app.get("/nested").body.should contain(expected)
      Saci::Cache.read("frag/outer").should_not be_nil
      Saci::Cache.read("frag/inner").should_not be_nil
    end
  end
end
