require "spec"
require "../src/saci"

class CspDemoController < Saci::Controller
  skip_csp only: [:embed]

  def index
    render text: "ok"
  end

  def embed
    render text: "embed"
  end
end

class CspOffController < Saci::Controller
  csp false

  def index
    render text: "off"
  end
end

class CspCustomController < Saci::Controller
  csp "default-src 'none'"

  def index
    render text: "custom"
  end
end

class CspManualController < Saci::Controller
  def index
    response.headers["Content-Security-Policy"] = "script-src 'self'"
    render text: "manual"
  end
end

def csp_router : Saci::Router
  Saci::Router.new.draw do |r|
    r.get "/demo", CspDemoController, :index
    r.get "/embed", CspDemoController, :embed
    r.get "/off", CspOffController, :index
    r.get "/custom", CspCustomController, :index
    r.get "/manual", CspManualController, :index
  end
end

describe "Content-Security-Policy" do
  after_each do
    Saci::SecureHeaders.reset!
  end

  it "is applied by default alongside the other secure headers" do
    Saci::SecureHeaders.headers["Content-Security-Policy"].should eq("default-src 'self'")
    Saci::TestSession.serve(csp_router) do |app|
      resp = app.get("/demo")
      resp.headers["Content-Security-Policy"].should eq("default-src 'self'")
      resp.headers["X-Frame-Options"].should eq("SAMEORIGIN")
    end
  end

  it "skips only the listed actions with skip_csp" do
    Saci::TestSession.serve(csp_router) do |app|
      embed = app.get("/embed")
      embed.headers.has_key?("Content-Security-Policy").should be_false
      embed.headers["X-Frame-Options"].should eq("SAMEORIGIN")

      index = app.get("/demo")
      index.headers["Content-Security-Policy"].should eq("default-src 'self'")
    end
  end

  it "disables CSP for the whole controller with csp false" do
    Saci::TestSession.serve(csp_router) do |app|
      resp = app.get("/off")
      resp.headers.has_key?("Content-Security-Policy").should be_false
      resp.headers["X-Content-Type-Options"].should eq("nosniff")
    end
  end

  it "applies a custom policy with csp \"...\"" do
    Saci::TestSession.serve(csp_router) do |app|
      app.get("/custom").headers["Content-Security-Policy"].should eq("default-src 'none'")
    end
  end

  it "still lets actions override the header directly" do
    Saci::TestSession.serve(csp_router) do |app|
      app.get("/manual").headers["Content-Security-Policy"].should eq("script-src 'self'")
    end
  end

  it "is configurable and resettable" do
    begin
      Saci::SecureHeaders.configure { |h| h["Content-Security-Policy"] = "default-src https:" }
      Saci::SecureHeaders.headers["Content-Security-Policy"].should eq("default-src https:")
    ensure
      Saci::SecureHeaders.reset!
    end
    Saci::SecureHeaders.headers["Content-Security-Policy"].should eq("default-src 'self'")
  end
end
