require "spec"
require "http/client"
require "../src/saci"

# -- test controllers -------------------------------------------------------

class SpecAppController < Saci::Controller
  before_action :set_default_header

  private def set_default_header
    response.headers["X-Saci"] = "true"
  end
end

class SpecHomeController < SpecAppController
  def index
    render json: {message: "Welcome to Saci", version: Saci::VERSION}
  end

  def redirect_demo
    redirect_to "/"
  end
end

class SpecPostsController < SpecAppController
  before_action :log_write, except: [:index]

  def index
    render json: [{id: 1, title: "Hello Saci"}]
  end

  def show
    render json: {id: params["id"]? || "?", title: "Post"}
  end

  def create
    title = params["title"]? || "Untitled"
    render json: {id: 2, title: title}, status: :created
  end

  def update
    render json: {id: params["id"]? || "?", title: params["title"]? || "Updated"}
  end

  def destroy
    head :no_content
  end

  private def log_write
    response.headers["X-Filtered"] = "yes"
  end
end

class SpecUsersController < SpecAppController
  before_action :require_token, only: [:show]

  def show
    render json: {id: params["id"]? || "none"}
  end

  private def require_token
    unless params.has_key?("token")
      render json: {error: "unauthorized"}, status: :unauthorized
    end
  end
end

module SpecAdmin
  class BaseController < SpecAppController
    before_action :check_admin

    private def check_admin
      response.headers["X-Admin"] = "1"
    end
  end

  class DashboardController < BaseController
    def index
      render text: "admin dashboard"
    end
  end
end

def spec_router : Saci::Router
  Saci::Router.new.draw do |r|
    r.root SpecHomeController, :index
    r.get "/go-home", SpecHomeController, :redirect_demo
    r.resources "posts", SpecPostsController
    r.get "/users/:id", SpecUsersController, :show
    r.namespace("/api") do |api|
      api.get "/hello", SpecHomeController, :index
    end
    r.namespace("/admin") do |admin|
      admin.get "/dashboard", SpecAdmin::DashboardController, :index
    end
    r.get("/ping") { |ctx, _params| ctx.response.print("pong") }
  end
end

describe Saci::Router do
  it "matches a static route" do
    spec_router.find("GET", "/ping").should_not be_nil
  end

  it "extracts path params" do
    _route, path_params = spec_router.find("GET", "/users/42").not_nil!
    path_params["id"].should eq("42")
  end

  it "returns nil for unknown routes" do
    spec_router.find("GET", "/nope").should be_nil
  end

  it "generates REST routes via resources" do
    router = spec_router
    table = router.routes_table.join("\n")
    table.should contain("GET    /posts")
    table.should contain("POST   /posts")
    table.should contain("DELETE /posts/:id")
    router.find("GET", "/posts").should_not be_nil
    router.find("GET", "/posts/1").should_not be_nil
    router.find("POST", "/posts").should_not be_nil
    router.find("PUT", "/posts/1").should_not be_nil
    router.find("PATCH", "/posts/1").should_not be_nil
    router.find("DELETE", "/posts/9").should_not be_nil
  end

  it "supports only:/except: on resources" do
    router = Saci::Router.new
    router.draw do |r|
      r.resources "posts", SpecPostsController, only: [:index, :show]
    end
    router.find("GET", "/posts").should_not be_nil
    router.find("POST", "/posts").should be_nil
  end

  it "supports namespace prefixing" do
    router = spec_router
    router.find("GET", "/api/hello").should_not be_nil
    router.find("GET", "/hello").should be_nil
  end
end

describe Saci::Params do
  it "reads values" do
    p = Saci::Params.new({"id" => "5"})
    p["id"].should eq("5")
    p[:id].should eq("5")
    p["missing"]?.should be_nil
  end

  it "require raises when missing" do
    p = Saci::Params.new
    expect_raises(Saci::ParameterMissing) { p.require("user") }
  end

  it "permit filters keys" do
    p = Saci::Params.new({"a" => "1", "b" => "2"})
    p.permit(:a).should eq({"a" => "1"})
  end
end

describe "Saci integration" do
  port = 41239
  server = HTTP::Server.new([Saci::Handler.new(spec_router)])
  client = HTTP::Client.new("127.0.0.1", port)

  before_all do
    server.bind_tcp("127.0.0.1", port)
    spawn { server.listen }
    # Give the server a moment to boot
    sleep 0.2.seconds
  end

  after_all do
    server.close
  end

  it "serves root as JSON" do
    resp = client.get("/")
    resp.status_code.should eq(200)
    resp.headers["Content-Type"].should contain("application/json")
    resp.headers["X-Saci"].should eq("true")
    JSON.parse(resp.body)["message"].should eq("Welcome to Saci")
  end

  it "serves resource index" do
    resp = client.get("/posts")
    resp.status_code.should eq(200)
    JSON.parse(resp.body).as_a.size.should eq(1)
    # index is excluded from log_write filter
    resp.headers["X-Filtered"]?.should be_nil
  end

  it "serves show with path params and runs except-filter" do
    resp = client.get("/posts/5")
    resp.status_code.should eq(200)
    JSON.parse(resp.body)["id"].should eq("5")
    resp.headers["X-Filtered"].should eq("yes")
  end

  it "creates with JSON body params" do
    headers = HTTP::Headers{"Content-Type" => "application/json"}
    resp = client.post("/posts", headers, %({"title":"Hi"}))
    resp.status_code.should eq(201)
    JSON.parse(resp.body)["title"].should eq("Hi")
  end

  it "updates and destroys" do
    headers = HTTP::Headers{"Content-Type" => "application/json"}
    resp = client.put("/posts/3", headers, %({"title":"New"}))
    resp.status_code.should eq(200)
    JSON.parse(resp.body)["id"].should eq("3")

    resp = client.delete("/posts/3")
    resp.status_code.should eq(204)
  end

  it "halts on failing before_action" do
    resp = client.get("/users/1")
    resp.status_code.should eq(401)
    JSON.parse(resp.body)["error"].should eq("unauthorized")
  end

  it "passes with token param" do
    resp = client.get("/users/1?token=abc")
    resp.status_code.should eq(200)
    JSON.parse(resp.body)["id"].should eq("1")
  end

  it "serves namespaced + inherited controller with admin filter chain" do
    resp = client.get("/admin/dashboard")
    resp.status_code.should eq(200)
    resp.body.should eq("admin dashboard")
    resp.headers["X-Admin"].should eq("1")
    resp.headers["X-Saci"].should eq("true")
  end

  it "redirects" do
    resp = client.get("/go-home")
    resp.status_code.should eq(302)
    resp.headers["Location"].should eq("/")
  end

  it "serves block routes" do
    resp = client.get("/ping")
    resp.status_code.should eq(200)
    resp.body.should eq("pong")
  end

  it "returns JSON 404 for unknown routes" do
    resp = client.get("/missing-thing")
    resp.status_code.should eq(404)
    JSON.parse(resp.body)["error"].as_s.should contain("Not Found")
  end
end
