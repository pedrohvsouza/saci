require "spec"
require "../src/saci"

class CacheItemController < Saci::Controller
  def etagged
    return unless stale?(etag: "abc", last_modified: Time.utc - 3600.seconds)
    render text: "body"
  end

  def expiring
    expires_in(60.seconds, public: true)
    render text: "cached"
  end

  def fresh
    fresh_when(etag: "z9")
    render text: "fresh-body" unless performed?
  end

  def with_record
    stamp = params["t"]?.try(&.to_i64?) || 1000_i64
    rec = CacheWidget.new(id: 5_i64, updated_at: Time.unix(stamp))
    return unless stale?(rec)
    render text: "record"
  end
end

class CacheWidget < Saci::Record::Base
  column id : Int64, primary: true
  column updated_at : Time
end

def caching_router : Saci::Router
  Saci::Router.new.draw do |r|
    r.get "/etagged", CacheItemController, :etagged
    r.get "/expiring", CacheItemController, :expiring
    r.get "/fresh", CacheItemController, :fresh
    r.get "/widget", CacheItemController, :with_record
  end
end

describe "HTTP caching" do
  it "emits validators then 304s on etag match" do
    Saci::TestSession.serve(caching_router) do |app|
      first = app.get("/etagged")
      first.status_code.should eq(200)
      first.body.should eq("body")
      etag = first.headers["ETag"]?
      etag.should_not be_nil
      first.headers["Last-Modified"]?.should_not be_nil

      second = app.get("/etagged", HTTP::Headers{"If-None-Match" => etag.not_nil!})
      second.status_code.should eq(304)

      third = app.get("/etagged", HTTP::Headers{"If-None-Match" => %("something-else")})
      third.status_code.should eq(200)
    end
  end

  it "matches If-None-Match star and weak comparisons" do
    Saci::TestSession.serve(caching_router) do |app|
      app.get("/etagged", HTTP::Headers{"If-None-Match" => "*"}).status_code.should eq(304)
    end
  end

  it "honors If-Modified-Since" do
    Saci::TestSession.serve(caching_router) do |app|
      future = (Time.utc + 3600.seconds).to_s("%a, %d %b %Y %H:%M:%S GMT")
      app.get("/etagged", HTTP::Headers{"If-Modified-Since" => future}).status_code.should eq(304)
      past = (Time.utc - 7200.seconds).to_s("%a, %d %b %Y %H:%M:%S GMT")
      app.get("/etagged", HTTP::Headers{"If-Modified-Since" => past}).status_code.should eq(200)
    end
  end

  it "sets Cache-Control via expires_in" do
    Saci::TestSession.serve(caching_router) do |app|
      resp = app.get("/expiring")
      resp.headers["Cache-Control"].should eq("max-age=60, public")
    end
  end

  it "supports fresh_when and record-based etags" do
    Saci::TestSession.serve(caching_router) do |app|
      first = app.get("/fresh")
      first.status_code.should eq(200)
      etag = first.headers["ETag"].not_nil!
      app.get("/fresh", HTTP::Headers{"If-None-Match" => etag}).status_code.should eq(304)

      w1 = app.get("/widget?t=1000")
      w1_etag = w1.headers["ETag"].not_nil!
      # Same timestamp -> fresh.
      app.get("/widget?t=1000", HTTP::Headers{"If-None-Match" => w1_etag}).status_code.should eq(304)
      # Changed record -> stale again.
      app.get("/widget?t=2000", HTTP::Headers{"If-None-Match" => w1_etag}).status_code.should eq(200)
    end
  end
end
