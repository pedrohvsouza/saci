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

# -- framework web upgrades (constraints, member/collection, redirects,
#    optional segments, format, rescue/after/respond_to, nested params) ----

class SpecWidgetError < Exception
end

class SpecStoriesController < SpecAppController
  def echo
    render json: {
      tag:      params["tag"]?,
      id:       params["id"]?,
      length:   params["length"]?,
      page:     params["page"]?,
      format:   params["format"]?,
      story_id: params["story_id"]?,
    }
  end

  def upvote
    render json: {id: params["id"]? || "?", upvoted: true}
  end

  def flag
    render json: {id: params["id"]? || "?", flagged: true}
  end

  def search
    render json: {q: params["q"]? || ""}
  end

  def preview
    render json: {preview: true}
  end
end

class SpecSuggestionsController < SpecAppController
  def new
    render json: {story_id: params["story_id"]? || "?"}
  end

  def create
    render json: {story_id: params["story_id"]? || "?"}, status: :created
  end
end

module SpecMod
  class StatsController < SpecAppController
    def index
      render json: {mod: true}
    end
  end
end

class SpecRescueController < SpecAppController
  rescue_from SpecWidgetError do
    render json: {error: "widget broke"}, status: :not_found
  end

  rescue_from ArgumentError do |ex|
    render plain: "bad arg: #{ex.message}", status: :bad_request
  end

  def explode
    raise SpecWidgetError.new("boom")
  end

  def bad_arg
    raise ArgumentError.new("nope")
  end

  def fine
    render json: {ok: true}
  end

  def unhandled
    raise "kaboom"
  end

  def not_found_route
    raise Saci::RoutingError.new("Not Found: widget")
  end
end

class SpecChildRescueController < SpecRescueController
  rescue_from SpecWidgetError do
    render json: {error: "child handled"}, status: 418
  end

  def explode
    raise SpecWidgetError.new("boom")
  end
end

class SpecAfterController < SpecAppController
  before_action :halt_sometimes
  after_action :stamp
  after_action only: [:index] do
    response.headers["X-Block-After"] = "yes"
  end

  def index
    render json: {ok: true}
  end

  def stopped
    render json: {ok: true}
  end

  private def halt_sometimes
    if action_name == :stopped
      render json: {halted: true}
    end
  end

  private def stamp
    response.headers["X-After"] = "ran"
  end
end

class SpecSkipController < SpecAfterController
  skip_after_action :stamp, only: [:index]

  def index
    render json: {ok: true}
  end
end

# Regression: a before filter that renders/redirects must halt the
# remaining filters of the same controller too (Rails semantics).
class SpecHaltController < SpecAppController
  before_action :first_halts
  before_action :second_runs

  def index
    render json: {ok: true}
  end

  private def first_halts
    render json: {halted: true}
  end

  private def second_runs
    raise "second filter must not run after halt"
  end
end

class SpecFormatController < SpecAppController
  def show
    respond_to do |f|
      f.html { render html: "<h1>story</h1>" }
      f.json { render json: {title: "story"} }
      f.rss { render xml: "<rss>stories</rss>" }
    end
  end

  def flexible
    respond_to do |f|
      f.json { render json: {title: "story"} }
      f.any { render text: "anything" }
    end
  end

  def strict
    respond_to do |f|
      f.json { render json: {title: "story"} }
    end
  end

  def xml_demo
    render xml: "<story><title>Hi</title></story>"
  end
end

class SpecStatusController < SpecAppController
  def oops
    render_template(:oops, status: 422)
  end
end

class SpecFallbackController < SpecAppController
  def missing
    render text: "fallback!", status: :not_found
  end
end

def spec_upgrade_router : Saci::Router
  Saci::Router.new.draw do |r|
    r.resources "stories", SpecStoriesController do |s|
      s.member do |m|
        m.post :upvote
        m.post :flag
      end
      s.collection do |c|
        c.get :search
        c.post :preview
      end
      s.resources "suggestions", SpecSuggestionsController, only: [:new, :create]
    end
    r.get "/t/:tag", SpecStoriesController, :echo, constraints: {"tag" => /[^,.\/]+/}
    r.constraints({"id" => /[0-9]+/}) do |c|
      c.get "/nums/:id", SpecStoriesController, :echo
    end
    r.redirect("/old", to: "/new")
    r.redirect("/u/:username", to: "/~%{username}", status: 301)
    r.get "/top(/:length(/page/:page))", SpecStoriesController, :echo
    r.get "/items/:id(.:format)", SpecStoriesController, :echo
    r.get "/rss", SpecStoriesController, :echo, defaults: {"format" => "rss"}
    r.namespace(:mod, mod: "SpecMod") do |m|
      m.get "/stats", SpecMod::StatsController, :index
    end
    r.get "/rescue-explode", SpecRescueController, :explode
    r.get "/rescue-arg", SpecRescueController, :bad_arg
    r.get "/rescue-fine", SpecRescueController, :fine
    r.get "/rescue-unhandled", SpecRescueController, :unhandled
    r.get "/rescue-not-found", SpecRescueController, :not_found_route
    r.get "/child-explode", SpecChildRescueController, :explode
    r.get "/after", SpecAfterController, :index
    r.get "/after-stopped", SpecAfterController, :stopped
    r.get "/skip", SpecSkipController, :index
    r.get "/skip-stopped", SpecSkipController, :stopped
    r.get "/halt-filters", SpecHaltController, :index
    r.get "/fmt", SpecFormatController, :show
    r.get "/flex", SpecFormatController, :flexible
    r.get "/strict", SpecFormatController, :strict
    r.get "/xml", SpecFormatController, :xml_demo
    r.get "/oops", SpecStatusController, :oops
    r.fallback SpecFallbackController, :missing
  end
end

describe "router upgrades" do
  it "constrains segments with a per-route regex" do
    router = spec_upgrade_router
    _route, path_params = router.find("GET", "/t/ruby").not_nil!
    path_params["tag"].should eq("ruby")
    router.find("GET", "/t/a,b").should be_nil
    router.find("GET", "/t/a.json").should be_nil
  end

  it "scopes constraints to a block" do
    router = spec_upgrade_router
    _route, path_params = router.find("GET", "/nums/42").not_nil!
    path_params["id"].should eq("42")
    router.find("GET", "/nums/abc").should be_nil
  end

  it "adds member routes inside resources" do
    router = spec_upgrade_router
    router.find("POST", "/stories/7/upvote").should_not be_nil
    router.find("POST", "/stories/7/flag").should_not be_nil
    router.find("GET", "/stories/7/upvote").should be_nil
  end

  it "adds collection routes inside resources (winning over :id)" do
    router = spec_upgrade_router
    router.find("GET", "/stories/search").should_not be_nil
    router.find("POST", "/stories/preview").should_not be_nil
  end

  it "nests resources with a parent id param" do
    router = spec_upgrade_router
    _route, path_params = router.find("POST", "/stories/7/suggestions").not_nil!
    path_params["story_id"].should eq("7")
    router.find("GET", "/stories/7/suggestions/new").should_not be_nil
  end

  it "expands optional segments" do
    router = spec_upgrade_router
    router.find("GET", "/top").should_not be_nil
    _route, path_params = router.find("GET", "/top/week").not_nil!
    path_params["length"].should eq("week")
    _route, path_params = router.find("GET", "/top/week/page/2").not_nil!
    path_params["page"].should eq("2")
    router.find("GET", "/top/week/page").should be_nil
  end

  it "supports .:format and route defaults" do
    router = spec_upgrade_router
    _route, path_params = router.find("GET", "/items/5").not_nil!
    path_params["id"].should eq("5")
    path_params["format"]?.should be_nil
    _route, path_params = router.find("GET", "/items/5.json").not_nil!
    path_params["id"].should eq("5")
    path_params["format"].should eq("json")
    _route, path_params = router.find("GET", "/rss").not_nil!
    path_params["format"].should eq("rss")
  end

  it "namespaces module controllers" do
    router = spec_upgrade_router
    router.find("GET", "/mod/stats").should_not be_nil
  end
end

describe "router upgrade integration" do
  it "dispatches member, collection and nested routes" do
    Saci::TestSession.serve(spec_upgrade_router) do |app|
      resp = app.post("/stories/7/upvote")
      resp.status_code.should eq(200)
      JSON.parse(resp.body)["upvoted"].should be_true

      resp = app.get("/stories/search?q=x")
      resp.status_code.should eq(200)
      JSON.parse(resp.body)["q"].should eq("x")

      resp = app.post("/stories/preview")
      JSON.parse(resp.body)["preview"].should be_true

      resp = app.post("/stories/7/suggestions")
      resp.status_code.should eq(201)
      JSON.parse(resp.body)["story_id"].should eq("7")
    end
  end

  it "serves constrained, optional and format routes" do
    Saci::TestSession.serve(spec_upgrade_router) do |app|
      resp = app.get("/t/ruby")
      JSON.parse(resp.body)["tag"].should eq("ruby")
      app.get("/t/a,b").status_code.should eq(404)

      resp = app.get("/top/week/page/2")
      body = JSON.parse(resp.body)
      body["length"].should eq("week")
      body["page"].should eq("2")

      resp = app.get("/items/5.json")
      body = JSON.parse(resp.body)
      body["id"].should eq("5")
      body["format"].should eq("json")

      resp = app.get("/rss")
      JSON.parse(resp.body)["format"].should eq("rss")

      resp = app.get("/mod/stats")
      JSON.parse(resp.body)["mod"].should be_true
    end
  end

  it "redirects static and interpolated targets" do
    Saci::TestSession.serve(spec_upgrade_router) do |app|
      resp = app.get("/old")
      resp.status_code.should eq(302)
      resp.headers["Location"].should eq("/new")

      resp = app.get("/u/bob")
      resp.status_code.should eq(301)
      resp.headers["Location"].should eq("/~bob")
    end
  end

  it "falls back for unmatched paths" do
    Saci::TestSession.serve(spec_upgrade_router) do |app|
      resp = app.get("/nothing-here")
      resp.status_code.should eq(404)
      resp.body.should eq("fallback!")
    end
  end

  it "rescues per-controller exceptions" do
    Saci::TestSession.serve(spec_upgrade_router) do |app|
      resp = app.get("/rescue-explode")
      resp.status_code.should eq(404)
      JSON.parse(resp.body)["error"].should eq("widget broke")

      resp = app.get("/rescue-arg")
      resp.status_code.should eq(400)
      resp.body.should contain("bad arg: nope")

      resp = app.get("/rescue-fine")
      resp.status_code.should eq(200)

      resp = app.get("/rescue-unhandled")
      resp.status_code.should eq(500)

      resp = app.get("/child-explode")
      resp.status_code.should eq(418)
      JSON.parse(resp.body)["error"].should eq("child handled")
    end
  end

  it "renders Saci::RoutingError (not_found!) as 404, not 500" do
    Saci::TestSession.serve(spec_upgrade_router) do |app|
      resp = app.get("/rescue-not-found")
      resp.status_code.should eq(404)
      JSON.parse(resp.body)["error"].should eq("Not Found")
    end
  end

  it "runs after_action filters (even when halted) and honors skips" do
    Saci::TestSession.serve(spec_upgrade_router) do |app|
      resp = app.get("/after")
      resp.status_code.should eq(200)
      resp.headers["X-After"].should eq("ran")
      resp.headers["X-Block-After"].should eq("yes")

      resp = app.get("/after-stopped")
      JSON.parse(resp.body)["halted"].should be_true
      resp.headers["X-After"].should eq("ran")

      resp = app.get("/skip")
      resp.headers["X-After"]?.should be_nil
      resp.headers["X-Block-After"].should eq("yes")

      resp = app.get("/skip-stopped")
      JSON.parse(resp.body)["halted"].should be_true
      resp.headers["X-After"].should eq("ran")
    end
  end

  it "halts the remaining before filters when one renders or redirects" do
    Saci::TestSession.serve(spec_upgrade_router) do |app|
      resp = app.get("/halt-filters")
      resp.status_code.should eq(200)
      JSON.parse(resp.body)["halted"].should be_true
    end
  end

  it "negotiates content with respond_to" do
    Saci::TestSession.serve(spec_upgrade_router) do |app|
      resp = app.get("/fmt?format=json")
      resp.headers["Content-Type"].should contain("application/json")
      JSON.parse(resp.body)["title"].should eq("story")

      resp = app.get("/fmt", HTTP::Headers{"Accept" => "application/rss+xml"})
      resp.headers["Content-Type"].should contain("application/xml")
      resp.body.should contain("<rss>")

      resp = app.get("/fmt")
      resp.headers["Content-Type"].should contain("text/html")

      resp = app.get("/flex", HTTP::Headers{"Accept" => "text/html"})
      resp.body.should eq("anything")

      resp = app.get("/strict", HTTP::Headers{"Accept" => "text/html"})
      resp.status_code.should eq(406)
    end
  end

  it "renders xml and templates with a status" do
    Saci::TestSession.serve(spec_upgrade_router) do |app|
      resp = app.get("/xml")
      resp.headers["Content-Type"].should contain("application/xml")
      resp.body.should contain("<title>Hi</title>")

      resp = app.get("/oops")
      resp.status_code.should eq(422)
      resp.body.should contain("<html>")
      resp.body.should contain("<p>oops</p>")
    end
  end
end

describe "params upgrades" do
  it "parses nested query hashes and arrays" do
    req = HTTP::Request.new("GET", "/?story[title]=Hi&story[tags][]=a&story[tags][]=b&n=1")
    params = Saci::Params.build(req, {} of String => String)
    params["n"].should eq("1")
    ps = params.require(:story).permit(:title, tags: [] of String)
    ps["title"].as_s.should eq("Hi")
    ps["tags"].as_a.map(&.as_s).should eq(["a", "b"])
  end

  it "parses nested JSON bodies" do
    headers = HTTP::Headers{"Content-Type" => "application/json"}
    req = HTTP::Request.new("POST", "/", headers, %({"story":{"title":"J","tags":["x","y"]}}))
    params = Saci::Params.build(req, {} of String => String)
    ps = params.require(:story).permit(:title, tags: [] of String)
    ps["title"].as_s.should eq("J")
    ps["tags"].as_a.map(&.as_s).should eq(["x", "y"])
  end

  it "requires scalars and raises when blank" do
    params = Saci::Params.new({"n" => "1", "blank" => ""})
    (params.require("n") == "1").should be_true
    params.require("n").as_s.should eq("1")
    expect_raises(Saci::ParameterMissing) { params.require("missing") }
    expect_raises(Saci::ParameterMissing) { params.require("blank") }
  end

  it "drops nested values under plain permit keys" do
    headers = HTTP::Headers{"Content-Type" => "application/json"}
    req = HTTP::Request.new("POST", "/", headers, %({"story":{"title":"x","meta":{"a":1}}}))
    params = Saci::Params.build(req, {} of String => String)
    ps = params.require(:story).permit(:title, :meta)
    ps.has_key?("title").should be_true
    ps.has_key?("meta").should be_false
  end

  it "digs nested values" do
    req = HTTP::Request.new("GET", "/?story[title]=Hi&story[tags][]=a")
    params = Saci::Params.build(req, {} of String => String)
    params.dig(:story, :title).try(&.as_s).should eq("Hi")
    params.dig(:story, :nope).should be_nil
    params.dig(:missing, :deep).should be_nil
  end

  it "reads arrays with #array" do
    req = HTTP::Request.new("GET", "/?tags[]=a&tags[]=b")
    params = Saci::Params.build(req, {} of String => String)
    params.array("tags").should eq(["a", "b"])
    params.array("missing").should eq([] of String)

    req = HTTP::Request.new("GET", "/?story[tags][]=x")
    params = Saci::Params.build(req, {} of String => String)
    params.array("story", "tags").should eq(["x"])
  end

  it "parses multipart fields and files" do
    body = "--TESTBOUND\r\nContent-Disposition: form-data; name=\"title\"\r\n\r\nHello\r\n" +
      "--TESTBOUND\r\nContent-Disposition: form-data; name=\"avatar\"; filename=\"a.png\"\r\nContent-Type: image/png\r\n\r\nPNGDATA\r\n" +
      "--TESTBOUND--\r\n"
    headers = HTTP::Headers{"Content-Type" => "multipart/form-data; boundary=TESTBOUND"}
    req = HTTP::Request.new("POST", "/upload", headers, body)
    params = Saci::Params.build(req, {} of String => String)
    params["title"].should eq("Hello")
    file = params.file("avatar").not_nil!
    file.filename.should eq("a.png")
    file.content_type.should eq("image/png")
    file.read.should eq("PNGDATA")
    file.bytes.should eq("PNGDATA".to_slice)
    params.file("missing").should be_nil
  end

  it "keeps the last file when a field repeats (pinned gap)" do
    body = "--B\r\nContent-Disposition: form-data; name=\"pic\"; filename=\"one.png\"\r\nContent-Type: image/png\r\n\r\nONE\r\n" +
      "--B\r\nContent-Disposition: form-data; name=\"pic\"; filename=\"two.png\"\r\nContent-Type: image/png\r\n\r\nTWO\r\n" +
      "--B--\r\n"
    headers = HTTP::Headers{"Content-Type" => "multipart/form-data; boundary=B"}
    req = HTTP::Request.new("POST", "/upload", headers, body)
    params = Saci::Params.build(req, {} of String => String)
    params.file("pic").not_nil!.filename.should eq("two.png")
  end
end

# -- router static prefix/suffix params (Lobsters-style tilde/at/avatar) ---

class SpecTildeController < SpecAppController
  def show
    render json: {username: params["username"]?, size: params["username_size"]?}
  end

  def stories
    render json: {username: params["username"]?}
  end
end

def spec_tilde_router : Saci::Router
  Saci::Router.new.draw do |r|
    r.get "/~:username", SpecTildeController, :show
    r.get "/~:username/stories", SpecTildeController, :stories
    r.redirect("/@:username", to: "/~%{username}", status: 301)
    r.get "/avatars/:username_size.png", SpecTildeController, :show
  end
end

describe "router static prefix/suffix params" do
  it "matches /~:username with a tilde prefix" do
    _route, path_params = spec_tilde_router.find("GET", "/~bob").not_nil!
    path_params["username"].should eq("bob")
    spec_tilde_router.find("GET", "/~bob/extra").should be_nil
  end

  it "matches /~:username/stories nested under the prefix" do
    _route, path_params = spec_tilde_router.find("GET", "/~alice/stories").not_nil!
    path_params["username"].should eq("alice")
  end

  it "matches /@:username redirect route with an at prefix" do
    _route, path_params = spec_tilde_router.find("GET", "/@carol").not_nil!
    path_params["username"].should eq("carol")
  end

  it "matches /avatars/:username_size.png with a suffix literal" do
    _route, path_params = spec_tilde_router.find("GET", "/avatars/bob_32.png").not_nil!
    path_params["username_size"].should eq("bob_32")
    _route, path_params = spec_tilde_router.find("GET", "/avatars/alice.png").not_nil!
    path_params["username_size"].should eq("alice")
    spec_tilde_router.find("GET", "/avatars/bob_32.jpg").should be_nil
  end

  it "dispatches prefix/suffix routes and redirects @ to ~" do
    Saci::TestSession.serve(spec_tilde_router) do |app|
      resp = app.get("/~bob")
      JSON.parse(resp.body)["username"].should eq("bob")

      resp = app.get("/~bob/stories")
      JSON.parse(resp.body)["username"].should eq("bob")

      resp = app.get("/avatars/bob_32.png")
      JSON.parse(resp.body)["size"].should eq("bob_32")

      resp = app.get("/@carol")
      resp.status_code.should eq(301)
      resp.headers["Location"].should eq("/~carol")
    end
  end
end
