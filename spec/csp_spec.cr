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

class CspInlineController < Saci::Controller
  def index
    render html: %(<html><head><link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Inter"><style>p{}</style></head>) +
                 %(<body><p style="--orb:red">hi</p><script>go()</script></body></html>)
  end
end

describe "CSP development warnings" do
  it "lists what the default policy blocks" do
    html = %(<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Inter">) +
           %(<style>p{}</style><p style="color:red" onclick="x()">x</p>) +
           %(<script>go()</script><script src="https://cdn.example.com/a.js"></script>) +
           %(<img src="https://img.example.com/a.png"><img src="/local.png">)
    problems = Saci::SecureHeaders.csp_violations("default-src 'self'", html)
    problems.any?(&.includes?("inline <style>")).should be_true
    problems.any?(&.includes?("https://fonts.googleapis.com, blocked by default-src 'self'")).should be_true
    problems.any?(&.includes?("https://fonts.gstatic.com")).should be_true
    problems.any?(&.includes?("style=\"...\" attributes")).should be_true
    problems.any?(&.includes?("inline event handlers")).should be_true
    problems.any?(&.includes?("inline <script>")).should be_true
    problems.any?(&.includes?("https://cdn.example.com")).should be_true
    problems.any?(&.includes?("https://img.example.com")).should be_true
    problems.none?(&.includes?("/local.png")).should be_true
  end

  it "is silent once the policy allows the markup" do
    policy = "default-src 'self'; style-src 'self' 'nonce-abc' https://fonts.googleapis.com; " \
             "style-src-attr 'unsafe-inline'; font-src https://fonts.gstatic.com; script-src 'self' 'nonce-abc' https://*.example.com; " \
             "script-src-attr 'unsafe-inline'; img-src * data:"
    html = %(<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Inter">) +
           %(<style nonce="abc">p{}</style><p style="color:red" onclick="x()">x</p>) +
           %(<script nonce="abc">go()</script><script src="https://cdn.example.com/a.js"></script>) +
           %(<script type="application/json">{"data":1}</script><img src="https://img.example.com/a.png">)
    Saci::SecureHeaders.csp_violations(policy, html).should be_empty
  end

  it "flags a nonce that does not match and 'unsafe-inline' disabled by a nonce" do
    policy = "style-src 'self' 'nonce-abc' 'unsafe-inline'"
    Saci::SecureHeaders.csp_violations(policy, %(<style nonce="zzz">p{}</style>)).size.should eq(1)
    Saci::SecureHeaders.csp_violations(policy, %(<p style="x">a</p>)).size.should eq(1)
    Saci::SecureHeaders.csp_violations("style-src 'unsafe-inline'", %(<style>p{}</style><p style="x">a</p>)).should be_empty
  end

  it "logs each problem once per path when enabled" do
    backend = ::Log::MemoryBackend.new
    previous = Saci.logger
    Saci.logger = ::Log.new("csp", backend, ::Log::Severity::Debug)
    Saci::SecureHeaders.csp_warnings = true
    Saci::SecureHeaders.reset_csp_warnings!
    router = Saci::Router.new.draw { |r| r.get "/inline", CspInlineController, :index }
    begin
      Saci::TestSession.serve(router) do |app|
        app.get("/inline").status_code.should eq(200)
        app.get("/inline").status_code.should eq(200)
      end
      messages = backend.entries.map(&.message).select(&.starts_with?("CSP: GET /inline"))
      messages.size.should eq(messages.uniq.size)
      messages.any?(&.includes?("inline <style>")).should be_true
      messages.any?(&.includes?("fonts.googleapis.com")).should be_true
      messages.any?(&.includes?("style=\"...\"")).should be_true
      messages.any?(&.includes?("inline <script>")).should be_true
    ensure
      Saci::SecureHeaders.csp_warnings = nil
      Saci::SecureHeaders.reset_csp_warnings!
      Saci.logger = previous
    end
  end

  it "is off outside development by default" do
    Saci::SecureHeaders.csp_warnings = nil
    with_csp_env("production") { Saci::SecureHeaders.csp_warnings?.should be_false }
    with_csp_env("development") { Saci::SecureHeaders.csp_warnings?.should be_true }
  end
end

private def with_csp_env(value : String, &) : Nil
  previous = ENV["APP_ENV"]?
  ENV["APP_ENV"] = value
  begin
    yield
  ensure
    previous ? (ENV["APP_ENV"] = previous) : ENV.delete("APP_ENV")
  end
end
