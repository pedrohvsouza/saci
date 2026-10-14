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
end
