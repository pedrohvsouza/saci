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

record TestSessionUser, id : Int64, email : String, session_token : String = "tok-1"

class TestSessionAuthController < Saci::Controller
  before_action :require_login
  allow_unauthenticated_access only: [:sign_out_user]

  memoize_current_user TestSessionUser

  private def find_current_user(id : Int64) : TestSessionUser?
    TestSessionUser.new(id, "u#{id}@example.com") if id == 7
  end

  def me
    render json: {email: current_user.try(&.email)}
  end

  def sign_out_user
    logout
    head :no_content
  end
end

def auth_demo_router : Saci::Router
  Saci::Router.new.draw do |r|
    r.get "/me", TestSessionAuthController, :me
    r.delete "/session", TestSessionAuthController, :sign_out_user
  end
end

describe "Saci::TestSession#sign_in_as" do
  it "logs the user in for the following requests" do
    Saci::TestSession.serve(auth_demo_router) do |app|
      app.get("/me").status_code.should eq(302)
      app.sign_in_as(TestSessionUser.new(7_i64, "u7@example.com"))
      app.track_cookies?.should be_true
      resp = app.get("/me")
      resp.status_code.should eq(200)
      JSON.parse(resp.body)["email"].should eq("u7@example.com")
      app.get("/me").status_code.should eq(200)
    end
  end

  it "rejects a session whose token the record rotated" do
    Saci::TestSession.serve(auth_demo_router) do |app|
      app.sign_in_as(TestSessionUser.new(7_i64, "u7@example.com", session_token: "old"))
      app.get("/me").status_code.should eq(302)
    end
  end

  it "keeps the cookies the app sets, so a logout sticks" do
    Saci::TestSession.serve(auth_demo_router) do |app|
      app.sign_in_as(TestSessionUser.new(7_i64, "u7@example.com"))
      app.delete("/session").status_code.should eq(204)
      app.get("/me").status_code.should eq(302)
    end
  end

  it "forgets the session on sign_out" do
    Saci::TestSession.serve(auth_demo_router) do |app|
      app.sign_in_as(TestSessionUser.new(7_i64, "u7@example.com"))
      app.sign_out
      app.get("/me").status_code.should eq(302)
    end
  end

  it "leaves an explicit Cookie header alone" do
    Saci::TestSession.serve(auth_demo_router) do |app|
      app.sign_in_as(TestSessionUser.new(7_i64, "u7@example.com"))
      app.get("/me", HTTP::Headers{"Cookie" => "other=1"}).status_code.should eq(302)
    end
  end
end
