require "spec"
require "../src/saci"

class ThrottleDemoController < Saci::Controller
  def index
    render text: "ok"
  end
end

def throttle_router : Saci::Router
  Saci::Router.new.draw do |r|
    r.get "/limited", ThrottleDemoController, :index
    r.get "/open", ThrottleDemoController, :index
  end
end

describe Saci::Throttle do
  before_each do
    Saci::Throttle.reset!
    Saci::Throttle.throttle("demo/ip", limit: 2, period: 60.seconds) do |ctx|
      ctx.request.path == "/limited" ? Saci::Throttle.client_ip(ctx) : nil
    end
  end

  after_each do
    Saci::Throttle.reset!
  end

  it "allows under the limit and throttles above it" do
    Saci::TestSession.serve(throttle_router) do |app|
      app.get("/limited").status_code.should eq(200)
      app.get("/limited").status_code.should eq(200)
      third = app.get("/limited")
      third.status_code.should eq(429)
      third.headers["Retry-After"]?.should_not be_nil
      JSON.parse(third.body)["error"].as_s.should contain("Too many")
    end
  end

  it "skips routes the discriminator ignores" do
    Saci::TestSession.serve(throttle_router) do |app|
      4.times { app.get("/open").status_code.should eq(200) }
    end
  end

  it "honors safelists" do
    Saci::Throttle.safelist { |ctx| Saci::Throttle.client_ip(ctx) == "127.0.0.1" }
    Saci::TestSession.serve(throttle_router) do |app|
      4.times { app.get("/limited").status_code.should eq(200) }
    end
  end

  it "blocks blocklisted requests with 403" do
    Saci::Throttle.blocklist { |ctx| (ctx.request.path || "") == "/limited" }
    Saci::TestSession.serve(throttle_router) do |app|
      app.get("/limited").status_code.should eq(403)
      app.get("/open").status_code.should eq(200)
    end
  end

  it "resets windows after the period" do
    Saci::Throttle.reset!
    Saci::Throttle.throttle("fast/ip", limit: 1, period: 1.second) do |ctx|
      ctx.request.path == "/limited" ? "k" : nil
    end
    Saci::TestSession.serve(throttle_router) do |app|
      app.get("/limited").status_code.should eq(200)
      app.get("/limited").status_code.should eq(429)
      sleep 1.1.seconds
      app.get("/limited").status_code.should eq(200)
    end
  end

  it "multi enforces the tightest window" do
    Saci::Throttle.reset!
    Saci::Throttle.multi("stacked", windows: [
      {limit: 5, period: 60.seconds},
      {limit: 2, period: 60.seconds},
    ]) do |ctx|
      ctx.request.path == "/limited" ? Saci::Throttle.client_ip(ctx) : nil
    end
    Saci::TestSession.serve(throttle_router) do |app|
      app.get("/limited").status_code.should eq(200)
      app.get("/limited").status_code.should eq(200)
      third = app.get("/limited")
      third.status_code.should eq(429)
      third.headers["Retry-After"]?.should_not be_nil
    end
  end

  it "multi isolates each window (1s vs 1m)" do
    Saci::Throttle.reset!
    Saci::Throttle.multi("mixed", windows: [
      {limit: 1, period: 1.second},
      {limit: 10, period: 60.seconds},
    ]) do |ctx|
      ctx.request.path == "/limited" ? "k" : nil
    end
    Saci::TestSession.serve(throttle_router) do |app|
      app.get("/limited").status_code.should eq(200)
      app.get("/limited").status_code.should eq(429)
      sleep 1.1.seconds
      app.get("/limited").status_code.should eq(200)
    end
  end

  it "throttle_login only counts POST /login*" do
    Saci::Throttle.reset!
    Saci::Throttle.throttle_login(limit: 1, period: 60.seconds)
    Saci::TestSession.serve(throttle_router) do |app|
      # non-login paths are ignored by the discriminator
      2.times { app.get("/limited").status_code.should eq(200) }
      2.times { app.get("/open").status_code.should eq(200) }
    end

    Saci::Throttle.reset!
    Saci::Throttle.throttle_login(limit: 1, period: 60.seconds)
    router = Saci::Router.new.draw do |r|
      r.post "/login", ThrottleDemoController, :index
      r.get "/open", ThrottleDemoController, :index
    end
    Saci::TestSession.serve(router) do |app|
      app.post("/login", HTTP::Headers.new, "").status_code.should eq(200)
      over = app.post("/login", HTTP::Headers.new, "")
      over.status_code.should eq(429)
      over.headers["Retry-After"]?.should_not be_nil
      # GETs still pass under a login-only throttle
      app.get("/open").status_code.should eq(200)
    end
  end
end
