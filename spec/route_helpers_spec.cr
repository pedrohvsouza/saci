require "spec"
require "../src/saci"

class RouteHelpersHomeController < Saci::Controller
  def index
    render text: "home"
  end
end

class RouteHelpersPostsController < Saci::Controller
  def index
    render text: "posts"
  end

  def show
    render text: "post #{params["id"]?}"
  end

  def new
    render text: "new"
  end

  def edit
    render text: "edit"
  end

  def create
    render text: "create", status: :created
  end

  def update
    render text: "update"
  end

  def destroy
    head :no_content
  end

  def upvote
    render text: "upvote"
  end

  def flag
    render text: "flag"
  end

  def search
    render text: "search"
  end
end

class RouteHelpersCommentsController < Saci::Controller
  def index
    render text: "comments"
  end

  def show
    render text: "comment"
  end
end

class RouteHelpersRepliesController < Saci::Controller
  def index
    render text: "replies"
  end
end

class RouteHelpersProfilesController < Saci::Controller
  def show
    render text: "profile"
  end
end

class RouteHelpersAdminPostsController < Saci::Controller
  def index
    render text: "admin posts"
  end
end

class RouteHelpersLinksController < Saci::Controller
  def show
    render text: path_for(:post, params["id"]?)
  end
end

class RouteHelpersAbsoluteController < Saci::Controller
  def show
    render text: full_url_for(:post, params["id"]?)
  end
end

module RouteHelpersAdmin
  class PostsController < Saci::Controller
    def index
      render text: "namespaced"
    end
  end
end

# Plain domain objects used by polymorphic/DOM helpers. They intentionally
# mimic the `id` + `persisted?` contract of Saci::Record without a database.
class Post
  getter id : Int64?

  def initialize(@id : Int64? = nil)
  end

  def persisted? : Bool
    !@id.nil?
  end
end

class Comment
  getter id : Int64?

  def initialize(@id : Int64? = nil)
  end

  def persisted? : Bool
    !@id.nil?
  end
end

Saci::Routes.define do |r|
  r.get "/one", RouteHelpersHomeController, :index, as: :one
end

Saci::Routes.define RouteHelpersApp do |r|
  r.root RouteHelpersHomeController, :index
  r.get "/health", RouteHelpersHomeController, :index, as: :health
  r.resources "posts", RouteHelpersPostsController do |s|
    s.member do |m|
      m.post :upvote
      m.post :flag, action: :flag, as: :mark
    end
    s.collection do |c|
      c.get :search
    end
    s.resources "comments", RouteHelpersCommentsController do |c|
      c.member do |m|
        m.post :approve, as: :ok
      end
    end
  end
  r.resource "profile", RouteHelpersProfilesController
  r.resources "authors", RouteHelpersProfilesController do |s|
    s.shallow do |sh|
      sh.resources "books", RouteHelpersRepliesController
    end
  end
  r.namespace :admin do |a|
    a.resources "posts", RouteHelpersAdminPostsController
  end
  r.direct(:status) { |_params| "/statusz" }
end

def route_helpers_router : Saci::Router
  Saci::Router.new.draw do |r|
    r.root RouteHelpersHomeController, :index
    r.resources "posts", RouteHelpersPostsController do |s|
      s.member do |m|
        m.post :upvote
        m.post :flag, action: :flag, as: :mark
      end
      s.collection do |c|
        c.get :search
      end
      s.resources "comments", RouteHelpersCommentsController, shallow: true
    end
    r.resources "posts", RouteHelpersPostsController, as: :articles, only: [:index, :show]
    r.resource "profile", RouteHelpersProfilesController
    r.namespace :admin do |a|
      a.resources "posts", RouteHelpersAdminPostsController
    end
    r.get "/links/:id", RouteHelpersLinksController, :show
    r.get "/absolute/:id", RouteHelpersAbsoluteController, :show
    r.direct(:status) { |_params| "/statusz" }
    r.direct(:tag, required: ["name"]) { |p| "/tags/#{p["name"]}" }
    r.resolve("Post", as: :post)
  end
end

describe "compile-time named route helpers (G4)" do
  it "generates Rails-style helpers for resources" do
    RouteHelpersApp.posts_path.should eq("/posts")
    RouteHelpersApp.new_post_path.should eq("/posts/new")
    RouteHelpersApp.post_path(12).should eq("/posts/12")
    RouteHelpersApp.post_path(id: 12).should eq("/posts/12")
    RouteHelpersApp.edit_post_path(12).should eq("/posts/12/edit")
    RouteHelpersApp.post_path(12, page: 2).should eq("/posts/12?page=2")
  end

  it "generates nested resource, namespace, singular and custom helpers" do
    RouteHelpersApp.post_comments_path(3).should eq("/posts/3/comments")
    RouteHelpersApp.post_comment_path(3, 9).should eq("/posts/3/comments/9")
    RouteHelpersApp.new_post_comment_path(3).should eq("/posts/3/comments/new")
    RouteHelpersApp.edit_post_comment_path(3, 9).should eq("/posts/3/comments/9/edit")
    RouteHelpersApp.upvote_post_path(4).should eq("/posts/4/upvote")
    RouteHelpersApp.mark_path(4).should eq("/posts/4/flag")
    RouteHelpersApp.ok_path(3, 9).should eq("/posts/3/comments/9/approve")
    RouteHelpersApp.search_posts_path.should eq("/posts/search")
    RouteHelpersApp.profile_path.should eq("/profile")
    RouteHelpersApp.new_profile_path.should eq("/profile/new")
    RouteHelpersApp.edit_profile_path.should eq("/profile/edit")
    RouteHelpersApp.admin_posts_path.should eq("/admin/posts")
    RouteHelpersApp.admin_post_path(5).should eq("/admin/posts/5")
    RouteHelpersApp.new_admin_post_path.should eq("/admin/posts/new")
    RouteHelpersApp.edit_admin_post_path(5).should eq("/admin/posts/5/edit")
    RouteHelpersApp.author_books_path(2).should eq("/authors/2/books")
    RouteHelpersApp.book_path(8).should eq("/books/8")
    RouteHelpersApp.edit_book_path(8).should eq("/books/8/edit")
    RouteHelpersApp.new_author_book_path(2).should eq("/authors/2/books/new")
    RouteHelpersApp.root_path.should eq("/")
    RouteHelpersApp.health_path.should eq("/health")
    RouteHelpersApp.status_path.should eq("/statusz")
  end

  it "supports the default generated module and extra direct names" do
    Saci::Routes::Generated.one_path.should eq("/one")
    Saci::Routes::Generated.path_for("one").should eq("/one")
  end

  it "exposes the generated router and runtime delegation" do
    RouteHelpersApp.router.find("GET", "/posts").should_not be_nil
    RouteHelpersApp.path_for("post", 7).should eq("/posts/7")
    RouteHelpersApp.router.recognize_path("/posts/7").not_nil!.action.should eq(:show)
    RouteHelpersApp.draw.find("GET", "/admin/posts").should_not be_nil
  end

  it "raises a clear error for missing or unknown helpers" do
    expect_raises(Saci::RouteHelpers::MissingRouteParam) { RouteHelpersApp.post_path }
    expect_raises(Saci::RouteHelpers::UnknownRoute) { RouteHelpersApp.path_for("nope") }
  end
end

describe "runtime named routes (G4)" do
  it "builds paths positionally, by name, and with a query string" do
    router = route_helpers_router
    router.path_for(:root).should eq("/")
    router.path_for("post", 7).should eq("/posts/7")
    router.path_for(:post, id: 7).should eq("/posts/7")
    router.path_for(:post, 7, page: 2).should eq("/posts/7?page=2")
    router.path_for(:post, 7, q: "a b", tags: ["x", "y"])
      .should eq("/posts/7?q=a+b&tags%5B%5D=x&tags%5B%5D=y")
    router.path_for(:edit_post, 7).should eq("/posts/7/edit")
    router.path_for(:new_post).should eq("/posts/new")
  end

  it "supports aliases, singular resources, namespaces and custom names" do
    router = route_helpers_router
    router.path_for(:articles).should eq("/posts")
    router.path_for(:article, 3).should eq("/posts/3")
    router.path_for(:profile).should eq("/profile")
    router.path_for(:edit_profile).should eq("/profile/edit")
    router.path_for(:admin_posts).should eq("/admin/posts")
    router.path_for(:admin_post, 3).should eq("/admin/posts/3")
    router.path_for(:new_admin_post).should eq("/admin/posts/new")
    router.path_for(:edit_admin_post, 3).should eq("/admin/posts/3/edit")
    router.path_for(:upvote_post, 3).should eq("/posts/3/upvote")
    router.path_for(:mark, 3).should eq("/posts/3/flag")
    router.path_for(:search_posts).should eq("/posts/search")
    router.path_for(:status).should eq("/statusz")
    router.path_for(:tag, "ruby").should eq("/tags/ruby")
    router.path_for(:tag, name: "crystal").should eq("/tags/crystal")
    expect_raises(Saci::RouteHelpers::MissingRouteParam) { router.path_for(:tag) }
  end

  it "supports nested resources and shallow member routes" do
    router = route_helpers_router
    router.path_for(:post_comments, 3).should eq("/posts/3/comments")
    router.path_for(:new_post_comment, 3).should eq("/posts/3/comments/new")
    router.path_for(:comment, 9).should eq("/comments/9")
    router.path_for(:edit_comment, 9).should eq("/comments/9/edit")
    router.find("GET", "/comments/9").should_not be_nil
    router.find("GET", "/posts/3/comments/9").should be_nil
  end

  it "builds URLs from controller/action pairs" do
    router = route_helpers_router
    router.url_for(controller: RouteHelpersPostsController, action: :index).should eq("/posts")
    router.url_for(controller: RouteHelpersPostsController, action: :show, id: 8).should eq("/posts/8")
    router.url_for(controller: RouteHelpersPostsController, action: :edit, id: 8).should eq("/posts/8/edit")
    router.url_for(controller: RouteHelpersPostsController, action: :new).should eq("/posts/new")
  end

  it "builds absolute URLs with default_url_options and script_name" do
    router = route_helpers_router
    router.default_url_options["host"] = "example.test"
    router.default_url_options["protocol"] = "https"
    router.full_url_for(:post, 5).should eq("https://example.test/posts/5")

    router.default_url_options["script_name"] = "/app"
    router.path_for(:posts).should eq("/app/posts")
    router.full_url_for(:posts).should eq("https://example.test/app/posts")
  ensure
    router.try(&.default_url_options.clear)
  end
end

describe "route mapper depth (G255)" do
  it "supports scope module/as, shallow blocks, path overrides and nested singular resources" do
    router = Saci::Router.new.draw do |r|
      r.scope(path: "admin", module: "Admin", as: :admin) do |s|
        s.get "/stats", RouteHelpersHomeController, :index, as: :stats
      end
      r.resources "posts", RouteHelpersPostsController, path: "articles", only: [:index] do |s|
        s.shallow do |sh|
          sh.resources "comments", RouteHelpersCommentsController
        end
      end
      r.resources "accounts", RouteHelpersPostsController, only: [:show] do |s|
        s.resource "profile", RouteHelpersProfilesController
      end
    end
    router.path_for(:admin_stats).should eq("/admin/stats")
    router.path_for(:posts).should eq("/articles")
    router.path_for(:post_comments, 3).should eq("/articles/3/comments")
    router.path_for(:comment, 9).should eq("/comments/9")
    router.path_for(:account_profile, 2).should eq("/accounts/2/profile")
    router.path_for(:edit_account_profile, 2).should eq("/accounts/2/profile/edit")
  end

  it "mounts a router at a prefix and prefixes its helper names" do
    blog = Saci::Router.new.draw do |r|
      r.resources "articles", RouteHelpersPostsController
    end
    app = Saci::Router.new.draw do |r|
      r.mount blog, at: "/blog", as: :blog
    end
    app.find("GET", "/blog/articles").should_not be_nil
    app.find("GET", "/blog/articles/3").should_not be_nil
    app.path_for(:blog_articles).should eq("/blog/articles")
    app.path_for(:blog_article, 3).should eq("/blog/articles/3")
    app.mounted_routers.size.should eq(1)
    Saci::TestSession.serve(app) do |client|
      client.get("/blog/articles").body.should eq("posts")
    end
  end

  it "applies concerns and scope constraints/defaults" do
    router = Saci::Router.new
    router.concern(:commentable) do |s|
      s.member { |m| m.post :comment }
      s.collection { |c| c.get :latest }
    end
    router.draw do |r|
      r.constraints({"id" => /[0-9]+/}) do |c|
        c.resources "posts", RouteHelpersPostsController do |s|
          s.concerns :commentable
        end
      end
    end
    router.find("POST", "/posts/3/comment").should_not be_nil
    router.find("GET", "/posts/latest").should_not be_nil
    router.find("GET", "/posts/abc").should be_nil
    router.path_for(:comment_post, 3).should eq("/posts/3/comment")
    router.path_for(:latest_posts).should eq("/posts/latest")
  end

  it "supports defaults and named constraints blocks" do
    router = Saci::Router.new.draw do |r|
      r.defaults({"format" => "json"}) do |d|
        d.get "/data", RouteHelpersHomeController, :index, as: :data
      end
    end
    router.find("GET", "/data").not_nil![1]["format"].should eq("json")
  end
end

describe "route introspection (G256)" do
  it "recognizes paths with the HTTP method" do
    router = route_helpers_router
    recognized = router.recognize_path("/posts/9", method: "GET").not_nil!
    recognized.action.should eq(:show)
    recognized.controller.should eq(RouteHelpersPostsController)
    recognized.params["id"].should eq("9")
    recognized.name.should eq("post")
    router.recognize_path("/posts", method: "DELETE").should be_nil
  end

  it "exposes structured routes, helper names and inspect output" do
    router = route_helpers_router
    route = router.routes.find { |r| r.name == "post" && r.http_method == "GET" }.not_nil!
    route.path.should eq("/posts/:id")
    route.controller.should eq(RouteHelpersPostsController)
    route.action.should eq(:show)
    router.named_routes.has_key?("posts").should be_true
    router.helper_names.should contain("posts")
    router.url_helpers.path_for(:post, 4).should eq("/posts/4")
    router.routes_table.join("\n").should contain("posts")
    router.routes_table_expanded.join("\n").should contain("RouteHelpersPostsController#show")
    router.inspect.should contain("Saci::Router")
  end
end

describe "request/URL helpers (G253/G257/G258)" do
  it "reads domain, subdomain, port and SSL state" do
    req = HTTP::Request.new("GET", "/", HTTP::Headers{
      "Host"              => "api.example.com:8443",
      "X-Forwarded-Proto" => "https",
    })
    req.domain.should eq("example.com")
    req.subdomain.should eq("api")
    req.port.should eq(8443)
    req.host_with_port.should eq("api.example.com:8443")
    req.ssl?.should be_true
    req.protocol.should eq("https")

    plain = HTTP::Request.new("GET", "/", HTTP::Headers{"Host" => "www.example.com"})
    plain.domain.should eq("example.com")
    plain.subdomain.should eq("")
    plain.port.should eq(80)
    plain.host_with_port.should eq("www.example.com")
    plain.ssl?.should be_false
  end

  it "builds absolute URLs with script_name" do
    req = HTTP::Request.new("GET", "/", HTTP::Headers{
      "Host"              => "api.example.com",
      "X-Forwarded-Proto" => "https",
    })
    Saci::RouteHelpers.full_url("/posts", req).should eq("https://api.example.com/posts")
    Saci::RouteHelpers.full_url("/posts", req, {"script_name" => "/app"})
      .should eq("https://api.example.com/app/posts")
  end

  it "derives model names and DOM identifiers" do
    model = Saci::RouteHelpers.model_name(Post)
    model.route_key.should eq("posts")
    model.singular_route_key.should eq("post")
    model.param_key.should eq("post")
    Saci::RouteHelpers.model_name(Post.new).route_key.should eq("posts")

    Saci::RouteHelpers.dom_class(Post).should eq("post")
    Saci::RouteHelpers.dom_id(Post.new(5)).should eq("post_5")
    Saci::RouteHelpers.dom_id(Post.new).should eq("new_post")
    Saci::RouteHelpers.dom_id(Post.new(5), "edit").should eq("edit_post_5")
  end

  it "builds polymorphic paths and URLs" do
    router = route_helpers_router
    post = Post.new(12)
    new_post = Post.new

    router.polymorphic_path(post).should eq("/posts/12")
    router.polymorphic_path(post, page: 2).should eq("/posts/12?page=2")
    router.edit_polymorphic_path(post).should eq("/posts/12/edit")
    router.polymorphic_path(new_post).should eq("/posts/new")
    router.polymorphic_path([post, Comment.new(7)]).should eq("/posts/12/comments/7")
    router.polymorphic_path([post, Comment.new]).should eq("/posts/12/comments/new")

    router.default_url_options["host"] = "example.test"
    router.polymorphic_url(post).should eq("http://example.test/posts/12")
  ensure
    router.try(&.default_url_options.clear)
  end

  it "uses resolve to override a model's route key" do
    router = Saci::Router.new.draw do |r|
      r.resources "articles", RouteHelpersPostsController
      r.resolve("Post", as: :article)
    end
    router.polymorphic_path(Post.new(4)).should eq("/articles/4")
    router.polymorphic_path(Post.new).should eq("/articles/new")
  end
end

describe "controller/view helper integration" do
  it "lets controller actions call path_for with the current router" do
    router = route_helpers_router
    Saci::TestSession.serve(router) do |app|
      app.get("/links/6").body.should eq("/posts/6")
    end
  end

  it "builds absolute URLs from the live request host in controllers" do
    router = Saci::TestSession.serve(route_helpers_router) do |app|
      body = app.get("/absolute/4").body
      body.should start_with("http://127.0.0.1:")
      body.should end_with("/posts/4")
      body
    end
    # The block form returns nil; assertion happens inside.
    router.should be_nil
  end

  it "exposes module-level view helpers" do
    Saci::Routes.current_router = RouteHelpersApp.router
    Saci::Views.path_for(:post, 2).should eq("/posts/2")
    Saci::Views.dom_id(Post.new(2)).should eq("post_2")
    Saci::Views.model_name(Post).route_key.should eq("posts")
  end
end
