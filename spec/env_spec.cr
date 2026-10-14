require "spec"
require "../src/saci"

class EnvBoomController < Saci::Controller
  def index
    render text: "fine"
  end

  def explode
    raise "kaboom-detail-123"
  end
end

def env_router : Saci::Router
  Saci::Router.new.draw do |r|
    r.get "/", EnvBoomController, :index
    r.get "/boom", EnvBoomController, :explode
  end
end

describe "environments" do
  around_each do |example|
    old_env = ENV["APP_ENV"]?
    old_level = Saci.log_level
    old_ssl = Saci.force_ssl
    old_detailed = nil
    begin
      example.run
    ensure
      if restored = old_env
        ENV["APP_ENV"] = restored
      else
        ENV.delete("APP_ENV")
      end
      Saci.log_level = old_level
      Saci.force_ssl = old_ssl
    end
  end

  it "reads the environment with predicates" do
    ENV.delete("APP_ENV")
    Saci.env.should eq("development")
    Saci.development?.should be_true
    ENV["APP_ENV"] = "production"
    Saci.env.should eq("production")
    Saci.production?.should be_true
    Saci.test?.should be_false
  end

  it "configures log levels" do
    Saci.log_level = :warn
    Saci.log_level.should eq(:warn)
    expect_raises(ArgumentError) { Saci.log_level = :verbose }
  end

  it "passes plain requests through without force_ssl" do
    Saci.force_ssl = false
    Saci::TestSession.serve(env_router) do |app|
      app.get("/").status_code.should eq(200)
    end
  end

  it "redirects plain HTTP to HTTPS when forced" do
    Saci.force_ssl = true
    Saci::TestSession.serve(env_router) do |app|
      plain = app.get("/", HTTP::Headers{"Host" => "example.com"})
      plain.status_code.should eq(301)
      plain.headers["Location"].should start_with("https://example.com/")

      tls = app.get("/", HTTP::Headers{"Host" => "example.com", "X-Forwarded-Proto" => "https"})
      tls.status_code.should eq(200)

      local = app.get("/")
      local.status_code.should eq(200)
    end
  end

  it "renders detailed errors outside production" do
    Saci.show_detailed_exceptions = true
    begin
      Saci::TestSession.serve(env_router) do |app|
        resp = app.get("/boom")
        resp.status_code.should eq(500)
        resp.headers["Content-Type"].should contain("text/html")
        resp.body.should contain("kaboom-detail-123")
      end
    ensure
      Saci.show_detailed_exceptions = nil
    end
  end

  it "renders generic errors when details are off" do
    Saci.show_detailed_exceptions = false
    begin
      Saci::TestSession.serve(env_router) do |app|
        resp = app.get("/boom")
        resp.status_code.should eq(500)
        resp.body.should_not contain("kaboom-detail-123")
        JSON.parse(resp.body)["error"].as_s.should contain("Internal Server Error")
      end
    ensure
      Saci.show_detailed_exceptions = nil
    end
  end
end
