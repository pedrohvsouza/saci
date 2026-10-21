require "spec"
require "file"
require "../src/saci"
require "../src/saci/serializer"
require "../src/saci/audit"
require "../src/saci/policy"
require "../src/saci/policy_controller"
require "../src/saci/search"
require "../src/saci/openapi"

# -- schema -----------------------------------------------------------------

class CreateExtrasSchema < Saci::Record::Migration
  def change
    create_table :extras_users do |t|
      t.string :name, null: false
      t.string :email
      t.timestamps
    end

    create_table :extras_posts do |t|
      t.string :title, null: false
      t.string :body
      t.string :status, default: "draft"
      t.integer :views, default: 0
      t.integer :user_id
      t.datetime :published_at
      t.timestamps
    end

    create_table :extras_comments do |t|
      t.integer :post_id, null: false
      t.string :body, null: false
      t.timestamps
    end

    Saci::Audit.create_table(self)
  end
end

# -- models -----------------------------------------------------------------

class ExtrasUser < Saci::Record::Base
  table "extras_users"

  column id : Int64, primary: true
  column name : String
  column email : String
  timestamps
end

class ExtrasPost < Saci::Record::Base
  table "extras_posts"

  column id : Int64, primary: true
  column title : String
  column body : String
  column status : String, default: "draft"
  column views : Int64, default: 0_i64
  column user_id : Int64
  column published_at : Time
  timestamps

  belongs_to :author, class_name: "ExtrasUser", foreign_key: "user_id"
  has_many :comments, class_name: "ExtrasComment", foreign_key: "post_id"

  audited only: [:title, :status]
  searchable_attributes :title, :status, :views, :published_at, :created_at
end

class ExtrasComment < Saci::Record::Base
  table "extras_comments"

  column id : Int64, primary: true
  column post_id : Int64
  column body : String
  timestamps
end

# -- serializers ------------------------------------------------------------

class ExtrasUserSerializer < Saci::Serializer(ExtrasUser)
  attributes :id, :name
end

class ExtrasCommentSerializer < Saci::Serializer(ExtrasComment)
  attributes :id, :body
end

class ExtrasPostSerializer < Saci::Serializer(ExtrasPost)
  attributes :id, :title, :status, :created_at
  attribute(:headline) { object.title.to_s.upcase }
  has_many :comments, serializer: ExtrasCommentSerializer
  has_one :author, serializer: ExtrasUserSerializer
end

class ExtrasPostPlainSerializer < Saci::Serializer(ExtrasPost)
  attributes :id
  has_many :comments
end

class ExtrasRootedSerializer < Saci::Serializer(ExtrasPost)
  attributes :id, :created_at
  root "post"
  key_transform :camel
end

# -- policy -----------------------------------------------------------------

class ExtrasPostPolicy < Saci::Policy
  resource ExtrasPost

  allow :read, :publish

  role :admin do
    can :manage, :all
  end

  role :editor do
    can :update, ExtrasPost
    can :read, :all
  end

  scope do
    scope.where(status: "published")
  end
end

class ExtrasPostsController < Saci::Controller
  def index
    render json: {ok: true}
  end

  def show
    render json: {id: params["id"]?}
  end

  def serialized
    render json: ExtrasPostSerializer.new(ExtrasPost.first.not_nil!, only: [:id, :title])
  end
end

# -- helpers ----------------------------------------------------------------

EXTRAS_DB_PATH = "/tmp/opencode/saci_extras_test.db"

def extras_controller : ExtrasPostsController
  request = HTTP::Request.new("GET", "/extras/posts")
  response = HTTP::Server::Response.new(IO::Memory.new)
  context = HTTP::Server::Context.new(request, response)
  params = Saci::Params.build(request, {} of String => String)
  ExtrasPostsController.new(context, params, :index)
end

def create_extras_post(title : String, status : String = "draft", views : Int64 = 0_i64, published_at : Time? = nil, user : ExtrasUser? = nil) : ExtrasPost
  ExtrasPost.create!(
    title: title,
    status: status,
    views: views,
    published_at: published_at,
    user_id: user.try(&.id),
  )
end

# -- specs ------------------------------------------------------------------

describe "Saci::Serializer" do
  before_all do
    File.delete(EXTRAS_DB_PATH) if File.exists?(EXTRAS_DB_PATH)
    Saci::Record::Base.connection = DB.open("sqlite3://#{EXTRAS_DB_PATH}")
    Saci::Record::Migrator.migrate(
      Saci::Record::Base.connection.as(DB::Database),
      [CreateExtrasSchema] of Saci::Record::Migration.class
    )
  end

  after_all do
    Saci::Record::Base.connection.as(DB::Database).close
  end

  before_each do
    Saci::Record.clean_database!
    Saci::Audit.clear_context!
    Saci::Authorization.clear_context!
  end

  it "renders attributes, computed attributes and nested associations" do
    user = ExtrasUser.create!(name: "Ada")
    post = ExtrasPost.create!(title: "Hello", status: "draft", user_id: user.id)
    ExtrasComment.create!(post_id: post.id, body: "First")
    ExtrasComment.create!(post_id: post.id, body: "Second")

    json = ExtrasPostSerializer.new(post.reload).as_json
    json["id"].as_i64.should eq(post.id)
    json["title"].as_s.should eq("Hello")
    json["headline"].as_s.should eq("HELLO")
    json["comments"].as_a.map(&.["body"].as_s).should eq(["First", "Second"])
    json["author"]["name"].as_s.should eq("Ada")
    json["created_at"].as_s.should_not be_empty

    plain = ExtrasPostPlainSerializer.new(post.reload).as_json
    plain["comments"].as_a.map(&.["body"].as_s).should eq(["First", "Second"])

    orphan = ExtrasPost.create!(title: "Orphan")
    ExtrasPostSerializer.new(orphan).as_json["author"].raw.should be_nil

    rooted_default = ExtrasRootedSerializer.new(post).as_json
    rooted_default.has_key?("post").should be_true
    rooted_default["post"]["id"].as_i64.should eq(post.id)
    rooted_default["post"].as_h.has_key?("createdAt").should be_true
  end

  it "supports only/except/include, roots and key transforms" do
    post = ExtrasPost.create!(title: "Hello")
    ExtrasComment.create!(post_id: post.id, body: "First")

    only = ExtrasPostSerializer.new(post, only: [:id, :title]).as_json
    only.keys.should eq(["id", "title"])

    except = ExtrasPostSerializer.new(post, except: [:status, :headline, :comments, :author]).as_json
    except.has_key?("status").should be_false
    except.has_key?("title").should be_true

    included = ExtrasPostSerializer.new(post, include: [:comments]).as_json
    included.has_key?("author").should be_false
    included.has_key?("comments").should be_true

    rooted = ExtrasPostSerializer.new(post, root: "post", only: [:id]).as_json
    rooted["post"]["id"].as_i64.should eq(post.id)

    derived_root = ExtrasPostSerializer.new(post, root: true, only: [:id]).as_json
    derived_root["extras_post"]["id"].as_i64.should eq(post.id)

    camel = ExtrasPostSerializer.new(post, only: [:id, :title], key_transform: :camel).as_json
    camel.has_key?("id").should be_true
    camel.has_key?("title").should be_true
  end

  it "serializes collections and exposes to_json for render json:" do
    ExtrasPost.create!(title: "One")
    ExtrasPost.create!(title: "Two")
    collection = ExtrasPostSerializer.collection(ExtrasPost.all.order(:id), only: [:id, :title], root: true)
    parsed = JSON.parse(collection.to_json)
    parsed["extras_posts"].as_a.size.should eq(2)
    ExtrasPostSerializer.new(ExtrasPost.first.not_nil!).to_json.should contain("\"title\"")
    ExtrasPost.first.not_nil!.to_json.should contain("\"title\"")

    io = IO::Memory.new
    request = HTTP::Request.new("GET", "/extras/posts/serialized")
    response = HTTP::Server::Response.new(io)
    context = HTTP::Server::Context.new(request, response)
    controller = ExtrasPostsController.new(context, Saci::Params.build(request, {} of String => String), :serialized)
    controller.serialized
    response.close
    io.to_s.should contain("\"title\"")
  end
end

describe "Saci::Audit" do
  before_all do
    File.delete(EXTRAS_DB_PATH) if File.exists?(EXTRAS_DB_PATH)
    Saci::Record::Base.connection = DB.open("sqlite3://#{EXTRAS_DB_PATH}")
    Saci::Record::Migrator.migrate(
      Saci::Record::Base.connection.as(DB::Database),
      [CreateExtrasSchema] of Saci::Record::Migration.class
    )
  end

  after_all do
    Saci::Record::Base.connection.as(DB::Database).close
  end

  before_each do
    Saci::Record.clean_database!
    Saci::Audit.clear_context!
  end

  it "records create, update and destroy with user/tenant context" do
    user = ExtrasUser.create!(name: "Ada")
    Saci::Audit.ensure_schema!
    metadata = {"source" => JSON::Any.new("spec")} of String => JSON::Any
    Saci::Audit.with_context(user: user, tenant_id: 7_i64, metadata: metadata) do
      Saci::Audit.current_user.should eq(user)
      Saci::Audit.current_user_id.should eq(user.id)
      Saci::Audit.current_tenant_id.should eq(7_i64)
      post = ExtrasPost.create!(title: "Hello", status: "draft", views: 1_i64)
      post.audits.size.should eq(1)
      created = post.audits.first
      created.create?.should be_true
      created.user_id.should eq(user.id)
      created.tenant_id.should eq(7_i64)
      created.metadata["source"].as_s.should eq("spec")
      created.changes["title"]["after"].as_s.should eq("Hello")
      created.changes["title"]["before"].raw.should be_nil
      created.changes.has_key?("views").should be_false

      post.update!(title: "Hello again")
      post.audits.size.should eq(2)
      updated = post.latest_audit.not_nil!
      updated.update?.should be_true
      updated.field_before("title").not_nil!.as_s.should eq("Hello")
      updated.field_after("title").not_nil!.as_s.should eq("Hello again")
      post.audit_changes.has_key?("title").should be_true
      updated.to_json.should contain("\"update\"")

      # A save with no audited-column change writes nothing.
      post.update!(views: 9_i64)
      post.audits.size.should eq(2)

      post.destroy.should be_true
      post.audits.size.should eq(3)
      Saci::Audit.count_for(post).should eq(3_i64)
      Saci::Audit.for_record("ExtrasPost", post.id.not_nil!).size.should eq(3)
      destroyed = post.latest_audit.not_nil!
      destroyed.destroy?.should be_true
      destroyed.field_before("title").not_nil!.as_s.should eq("Hello again")
      destroyed.field_after("title").not_nil!.raw.should be_nil
    end
  end

  it "restores the before side of an update" do
    post = ExtrasPost.create!(title: "Original")
    entry = post.update!(title: "Changed") ? post.latest_audit.not_nil! : raise "update failed"
    post.restore_from!(entry).should be_true
    post.reload.title.should eq("Original")
  end
end

describe "Saci::Policy" do
  before_all do
    File.delete(EXTRAS_DB_PATH) if File.exists?(EXTRAS_DB_PATH)
    Saci::Record::Base.connection = DB.open("sqlite3://#{EXTRAS_DB_PATH}")
    Saci::Record::Migrator.migrate(
      Saci::Record::Base.connection.as(DB::Database),
      [CreateExtrasSchema] of Saci::Record::Migration.class
    )
  end

  after_all do
    Saci::Record::Base.connection.as(DB::Database).close
  end

  before_each do
    Saci::Record.clean_database!
    Saci::Authorization.clear_context!
  end

  it "evaluates role matrices and authorize!" do
    post = ExtrasPost.create!(title: "Hello")

    Saci::Authorization.with_context(roles: [:admin]) do
      policy = ExtrasPostPolicy.new
      policy.can?(:destroy, post).should be_true
      policy.can?(:anything, :all).should be_true
      policy.authorize!(:destroy, post).should be_true
    end

    Saci::Authorization.with_context(roles: ["editor"]) do
      policy = ExtrasPostPolicy.new
      policy.can?(:update, post).should be_true
      policy.can?(:update).should be_true
      policy.can?(:read, ExtrasPost).should be_true
      policy.can?(:read, "ExtrasPost").should be_true
      policy.can?(:destroy, post).should be_false
      policy.role?(:editor).should be_true
      Saci::Authorization.policy_for(ExtrasPost).should be_a(ExtrasPostPolicy)
      expect_raises(Saci::Authorization::NotAuthorizedError) do
        policy.authorize!(:destroy, post)
      end
    end

    Saci::Authorization.with_context(roles: [] of String) do
      policy = ExtrasPostPolicy.new
      policy.can?(:read, post).should be_true
      policy.can?(:publish, post).should be_true
      policy.can?(:update, post).should be_false
    end
  end

  it "resolves scopes through the controller helper" do
    create_extras_post("Published", status: "published")
    create_extras_post("Draft", status: "draft")

    Saci::Authorization.with_context(roles: [:admin]) do
      controller = extras_controller
      controller.policy_scope(ExtrasPost.all).to_a.map(&.title).should eq(["Published"])
      controller.policy_scope(ExtrasPost).to_a.map(&.title).should eq(["Published"])
      controller.authorize!(:update, ExtrasPost.first.not_nil!).should be_true
    end

    Saci::Authorization.with_context(roles: [] of String) do
      controller = extras_controller
      expect_raises(Saci::Authorization::NotAuthorizedError) do
        controller.authorize!(:update, ExtrasPost.first.not_nil!)
      end
    end
  end
end

describe "Saci::Search" do
  before_all do
    File.delete(EXTRAS_DB_PATH) if File.exists?(EXTRAS_DB_PATH)
    Saci::Record::Base.connection = DB.open("sqlite3://#{EXTRAS_DB_PATH}")
    Saci::Record::Migrator.migrate(
      Saci::Record::Base.connection.as(DB::Database),
      [CreateExtrasSchema] of Saci::Record::Migration.class
    )
  end

  after_all do
    Saci::Record::Base.connection.as(DB::Database).close
  end

  before_each do
    Saci::Record.clean_database!
  end

  it "applies predicates, whitelisting and sort" do
    now = Time.utc
    one = create_extras_post("Crystal basics", "published", 10_i64, now)
    two = create_extras_post("Crystal advanced", "draft", 20_i64)
    three = create_extras_post("Ruby basics", "published", 30_i64, now)
    four = create_extras_post("Crystal performance", "archived", 40_i64)
    five = create_extras_post("Other", "published", 50_i64, now)

    search = Saci::Search.new(ExtrasPost, {
      "q[title_cont]" => "Crystal",
      "q[s]"          => "views desc",
    })
    search.result.to_a.map(&.title).should eq(["Crystal performance", "Crystal advanced", "Crystal basics"])

    Saci::Search.new(ExtrasPost, {"q[status_eq]" => "draft"}).result.to_a.map(&.title).should eq(["Crystal advanced"])
    Saci::Search.new(ExtrasPost, {"q[views_gteq]" => "30"}).result.to_a.map(&.title).should eq(["Ruby basics", "Crystal performance", "Other"])
    Saci::Search.new(ExtrasPost, {"q[views_lt]" => "30"}).result.to_a.map(&.title).should eq(["Crystal basics", "Crystal advanced"])
    Saci::Search.new(ExtrasPost, {"q[views_lteq]" => "10"}).result.to_a.map(&.title).should eq(["Crystal basics"])
    Saci::Search.new(ExtrasPost, {"q[views_gt]" => "40"}).result.to_a.map(&.title).should eq(["Other"])
    Saci::Search.new(ExtrasPost, {"q[id_in]" => "#{one.id},#{three.id}"}).result.to_a.map(&.title).should eq(["Crystal basics", "Ruby basics"])
    Saci::Search.new(ExtrasPost, {"q[published_at_null]" => "1"}).result.to_a.map(&.title).should eq(["Crystal advanced", "Crystal performance"])
    Saci::Search.new(ExtrasPost, {"q[published_at_present]" => "1"}).result.to_a.map(&.title).should eq(["Crystal basics", "Ruby basics", "Other"])
    Saci::Search.new(ExtrasPost, {"q[title_start]" => "Crystal"}).result.to_a.size.should eq(3)
    Saci::Search.new(ExtrasPost, {"q[title_end]" => "basics"}).result.to_a.map(&.title).should eq(["Crystal basics", "Ruby basics"])
    Saci::Search.new(ExtrasPost, {"q[title_matches]" => "crystal"}).result.to_a.size.should eq(3)
    Saci::Search.new(ExtrasPost, {"q[title_does_not_match]" => "crystal"}).result.to_a.map(&.title).should eq(["Ruby basics", "Other"])
    Saci::Search.new(ExtrasPost, {"q[title_not_eq]" => "Ruby basics"}).result.to_a.size.should eq(4)

    # `body` is not whitelisted, and `s` does not allow ordering by it.
    Saci::Search.new(ExtrasPost, {"q[body_cont]" => "nothing"}).result.to_a.size.should eq(5)
    Saci::Search.new(ExtrasPost, {"q[s]" => "body desc"}).result.to_a.map(&.title).should eq(
      ["Crystal basics", "Crystal advanced", "Ruby basics", "Crystal performance", "Other"]
    )
  end

  it "integrates pagination and Saci::Params" do
    3.times do |i|
      create_extras_post("Crystal #{i}", "published", (i + 1).to_i64)
    end
    create_extras_post("Draft", "draft", 99_i64)

    request = HTTP::Request.new("GET", "/extras/posts?q%5Btitle_cont%5D=Crystal&q%5Bs%5D=views%20desc&per_page=2")
    params = Saci::Params.build(request, {} of String => String)
    page = ExtrasPost.search(params).page
    page.total_count.should eq(3_i64)
    page.total_pages.should eq(2)
    page.records.map(&.title).should eq(["Crystal 2", "Crystal 1"])

    explicit = Saci::Search.new(ExtrasPost, {"q[status_eq]" => "published"}, ExtrasPost.all)
    explicit.page(2, 2).records.map(&.title).should eq(["Crystal 2"])

    json_params = JSON.parse(%({"q": {"title_cont": "Crystal", "s": "views desc"}}))
    Saci::Search.new(ExtrasPost, json_params).result.to_a.map(&.title).should eq(["Crystal 2", "Crystal 1", "Crystal 0"])

    filtered = ExtrasPost.filter({"q[status_eq]" => "published"})
    filtered.result.to_a.size.should eq(3)
    filtered.sort(:title, :desc).result.to_a.first.title.should eq("Crystal 2")
  end
end

describe "Saci::OpenAPI" do
  it "derives path templates and operations from router routes" do
    router = Saci::Router.new.draw do |r|
      r.get "/extras/posts", ExtrasPostsController, :index
      r.get "/extras/posts/:id", ExtrasPostsController, :show
      r.post "/extras/posts", ExtrasPostsController, :index
    end

    doc = Saci::OpenAPI.document(router, title: "Extras API")
    doc["openapi"].as_s.should eq("3.0.3")
    paths = doc["paths"].as_h
    paths.has_key?("/extras/posts/{id}").should be_true
    show = paths["/extras/posts/{id}"]["get"]
    show["parameters"].as_a.first["name"].as_s.should eq("id")
    show["operationId"].as_s.should eq("get_extras_posts_id")
    JSON.parse(Saci::OpenAPI.json(router))["info"]["title"].as_s.should eq("Saci API")
  end
end
