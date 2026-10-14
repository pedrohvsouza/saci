require "spec"
require "../src/saci"

class TestSessionDemoController < Saci::Controller
  def index
    render json: {ok: true}
  end

  def echo
    render json: {got: params["msg"]? || "?"}, status: :created
  end
end

def demo_router : Saci::Router
  Saci::Router.new.draw do |r|
    r.get "/demo", TestSessionDemoController, :index
    r.post "/demo/echo", TestSessionDemoController, :echo
  end
end

describe Saci::TestSession do
  it "serves GET requests over real HTTP" do
    Saci::TestSession.serve(demo_router) do |app|
      app.port.should be > 0
      resp = app.get("/demo")
      resp.status_code.should eq(200)
      JSON.parse(resp.body)["ok"].should be_true
    end
  end

  it "serves POST requests with bodies and statuses" do
    Saci::TestSession.serve(demo_router) do |app|
      headers = HTTP::Headers{"Content-Type" => "application/json"}
      resp = app.post("/demo/echo", headers, %({"msg":"hi"}))
      resp.status_code.should eq(201)
      JSON.parse(resp.body)["got"].should eq("hi")
    end
  end

  it "surfaces 404s" do
    Saci::TestSession.serve(demo_router) do |app|
      app.get("/missing").status_code.should eq(404)
    end
  end

  it "uses ephemeral ports per session" do
    Saci::TestSession.serve(demo_router) do |a|
      Saci::TestSession.serve(demo_router) do |b|
        (a.port != b.port).should be_true
      end
    end
  end
end
