# Forem Lite — a DEV.to-inspired validation app for the Saci framework.
#
# A miniature Forem (users, articles, comments, reactions, page views) that
# exercises every Saci subsystem end to end: routing, controllers + filters,
# ORM (validations, associations, transactions, migrations), ECR views,
# HTTP caching, CSRF/secure headers/sessions, rate limiting, disk storage,
# background jobs, mailers, websockets, I18n, logging, credentials and
# multidatabase. See `examples/forem_lite_app.cr` (runnable server) and
# `spec/forem_lite_spec.cr` (full validation suite).
require "../src/saci"

class LiteCreatePrimary < Record::Migration
  def change
    create_table :lite_users do |t|
      t.string :username, null: false
      t.string :email, null: false
      t.string :password_digest
      t.boolean :admin, default: false
      t.timestamps
    end
    add_index :lite_users, :username, unique: true
    add_index :lite_users, :email, unique: true
    create_table :lite_articles do |t|
      t.integer :user_id
      t.string :title, null: false
      t.text :body
      t.string :cover_key
      t.integer :score, default: 0
      t.timestamps
    end
    create_table :lite_comments do |t|
      t.integer :article_id
      t.integer :user_id
      t.text :body, null: false
      t.timestamps
    end
    create_table :lite_reactions do |t|
      t.integer :article_id
      t.integer :user_id
      t.string :category, default: "like"
      t.timestamps
    end
  end
end

class LiteCreateAnalytics < Record::Migration
  def change
    create_table :lite_page_views do |t|
      t.integer :article_id
      t.string :ip
      t.timestamps
    end
  end
end

class LiteUser < Record::Base
  column id : Int64, primary: true
  column username : String
  column email : String
  column password_digest : String
  column admin : Bool, default: false
  timestamps

  validates :username, presence: true, min_length: 3, max_length: 30
  validates :email, presence: true, format: /@/, uniqueness: true

  has_secure_password
  has_many :articles, class_name: LiteArticle, foreign_key: user_id
end

class LiteArticle < Record::Base
  column id : Int64, primary: true
  column user_id : Int64
  column title : String
  column body : String
  column cover_key : String
  column score : Int64, default: 0
  timestamps

  validates :title, presence: true, min_length: 5, max_length: 120
  validates :body, presence: true

  belongs_to :user, class_name: LiteUser, foreign_key: user_id
  has_many :comments, class_name: LiteComment, foreign_key: article_id
  has_many :reactions, class_name: LiteReaction, foreign_key: article_id
end

class LiteComment < Record::Base
  column id : Int64, primary: true
  column article_id : Int64
  column user_id : Int64
  column body : String
  timestamps

  validates :body, presence: true, max_length: 500

  belongs_to :article, class_name: LiteArticle, foreign_key: article_id
  belongs_to :user, class_name: LiteUser, foreign_key: user_id
end

class LiteReaction < Record::Base
  column id : Int64, primary: true
  column article_id : Int64
  column user_id : Int64
  column category : String, default: "like"
  timestamps

  validates :category, presence: true
end

class LitePageView < Record::Base
  connects_to database: "analytics"

  column id : Int64, primary: true
  column article_id : Int64
  column ip : String
  timestamps
end

class LiteScoreJob < Job::Base
  queue_as :scores
  discard_on Record::RecordNotFound

  def perform(payload : JSON::Any) : Nil
    article_id = payload["article_id"]?.try(&.as_i64?)
    return unless article_id
    article = LiteArticle.find_by(id: article_id)
    return unless article
    score = LiteReaction.where(article_id: article_id).count * 5 +
            LiteComment.where(article_id: article_id).count * 3
    article.update!(score: score)
  end
end

class LiteUserMailer < Mailer::Base
  default_from "hello@forem-lite.example"

  def self.welcome(email : String, username : String) : Mailer::Mail
    mail(to: email, subject: "Welcome to Forem Lite, #{username}!") do |format|
      format.text { "Hi #{username}, welcome to Forem Lite!" }
      format.html { "<h1>Hi #{username}</h1><p>Welcome to Forem Lite!</p>" }
    end
  end
end

class LiteCommentsChannel < Cable::Channel
  def subscribed
    stream_from "lite_article_#{params["article_id"]?.try(&.as_s?) || "lobby"}"
  end

  def receive(data)
    Cable.broadcast(
      "lite_article_#{params["article_id"]?.try(&.as_s?) || "lobby"}",
      {echo: data["text"]? || data}
    )
  end
end

class LiteApplicationController < Controller
  protect_from_forgery
  before_action :set_lite_locale

  private def set_lite_locale : Nil
    if raw = params["locale"]?
      I18n.locale = I18n.parse_locale(raw)
    else
      I18n.locale = I18n.locale_from_header(request.headers["Accept-Language"]?)
    end
  end

  private def current_lite_user : LiteUser?
    id = session.int(:user_id)
    id ? LiteUser.find_by(id: id) : nil
  end

  private def require_lite_login : LiteUser?
    user = current_lite_user
    render(json: {error: "login required"}, status: :unauthorized) unless user
    user
  end
end

# Plain JSON presenter (keeps actions readable; top-level so it never
# collides with dispatcher codegen, which only scans controller methods).
def lite_article_json(a : LiteArticle)
  {id: a.id, title: a.title, body: a.body, score: a.score,
   user_id: a.user_id, cover_key: a.cover_key}
end

class LiteArticlesController < LiteApplicationController
  def index
    articles = LiteArticle.order(id: :desc).limit(20).to_a
    render_template(:index)
  end

  def show
    article = LiteArticle.find_by(id: params["id"]? || "")
    unless article
      render json: {error: "not found"}, status: :not_found
      return
    end
    LitePageView.create(article_id: article.id, ip: params["ip"]? || "direct")
    return unless stale?(article)
    comments = article.comments.order(id: :asc).to_a
    render_template(:show)
  end

  def create
    user = require_lite_login
    return unless user
    article = LiteArticle.new(
      title: params["title"]? || "",
      body: params["body"]? || "",
      cover_key: params["cover_key"]?,
      user_id: user.id
    )
    if article.save
      render json: lite_article_json(article), status: :created
    else
      render json: {errors: article.errors.full_messages}, status: :unprocessable_entity
    end
  end

  def update
    user = require_lite_login
    return unless user
    article = LiteArticle.find_by(id: params["id"]? || "")
    unless article
      render json: {error: "not found"}, status: :not_found
      return
    end
    unless article.user_id == user.id
      render json: {error: "forbidden"}, status: :forbidden
      return
    end
    article.title = params["title"]? if params.has_key?("title")
    article.body = params["body"]? if params.has_key?("body")
    article.cover_key = params["cover_key"]? if params.has_key?("cover_key")
    if article.save
      render json: lite_article_json(article)
    else
      render json: {errors: article.errors.full_messages}, status: :unprocessable_entity
    end
  end

  def destroy
    user = require_lite_login
    return unless user
    article = LiteArticle.find_by(id: params["id"]? || "")
    unless article
      render json: {error: "not found"}, status: :not_found
      return
    end
    unless article.user_id == user.id
      render json: {error: "forbidden"}, status: :forbidden
      return
    end
    article.destroy
    head :no_content
  end
end

class LiteUsersController < LiteApplicationController
  def create
    user = LiteUser.new(
      username: params["username"]? || "",
      email: params["email"]? || "",
      password: params["password"]?,
      password_confirmation: params["password_confirmation"]?
    )
    if user.save
      reset_session
      session[:user_id] = user.id.to_s
      LiteUserMailer.welcome(user.email.not_nil!, user.username.not_nil!).deliver_later
      render json: {id: user.id, username: user.username}, status: :created
    else
      render json: {errors: user.errors.full_messages}, status: :unprocessable_entity
    end
  end

  def show
    user = LiteUser.find_by(id: params["id"]? || "")
    unless user
      render json: {error: "not found"}, status: :not_found
      return
    end
    render json: {id: user.id, username: user.username, articles: user.articles.count}
  end
end

class LiteSessionsController < LiteApplicationController
  def create
    user = LiteUser.find_by(username: params.require("username").as_s)
    if user && user.authenticate(params.require("password").as_s)
      reset_session
      session[:user_id] = user.id.to_s
      render json: {id: user.id, username: user.username}
    else
      render json: {error: "invalid credentials"}, status: :unauthorized
    end
  end

  def destroy
    reset_session
    render json: {logged_out: true}
  end
end

class LiteCommentsController < LiteApplicationController
  def create
    user = require_lite_login
    return unless user
    article = LiteArticle.find_by(id: params["article_id"]? || "")
    unless article
      render json: {error: "not found"}, status: :not_found
      return
    end
    comment = LiteComment.new(
      article_id: article.id,
      user_id: user.id,
      body: params.require("body").as_s
    )
    if comment.save
      Cable.broadcast("lite_article_#{article.id}",
        {event: "comment", id: comment.id, body: comment.body})
      render json: {id: comment.id, body: comment.body}, status: :created
    else
      render json: {errors: comment.errors.full_messages}, status: :unprocessable_entity
    end
  end
end

class LiteReactionsController < LiteApplicationController
  def create
    user = require_lite_login
    return unless user
    article = LiteArticle.find_by(id: params["article_id"]? || "")
    unless article
      render json: {error: "not found"}, status: :not_found
      return
    end
    reaction = LiteReaction.new(
      article_id: article.id,
      user_id: user.id,
      category: params["category"]? || "like"
    )
    if reaction.save
      LiteScoreJob.perform_later({article_id: article.id})
      render json: {ok: true}, status: :created
    else
      render json: {errors: reaction.errors.full_messages}, status: :unprocessable_entity
    end
  end
end

class LiteUploadsController < LiteApplicationController
  def create
    user = require_lite_login
    return unless user
    data = params.require("data").as_s
    filename = params["filename"]? || "upload.bin"
    content_type = params["content_type"]? || "application/octet-stream"
    key = Storage.upload(data, filename: filename, content_type: content_type)
    render json: {key: key, url: Storage.signed_url(key, base: "/lite_files")}, status: :created
  end
end

class LiteHealthController < LiteApplicationController
  def index
    render json: {
      app:      "forem-lite",
      version:  Saci::VERSION,
      greeting: t("lite.welcome", name: params["name"]? || "dev"),
      locale:   I18n.locale,
      # JSON clients have no form to read the CSRF token from, so the
      # bootstrap endpoint hands it out (and sets the matching cookie).
      csrf_token: form_authenticity_token,
    }
  end
end

def forem_lite_router : Router
  Router.new.draw do |r|
    r.root LiteArticlesController, :index
    r.get "/lite_health", LiteHealthController, :index
    r.resources "lite_articles", LiteArticlesController
    r.post "/lite_users", LiteUsersController, :create
    r.get "/lite_users/:id", LiteUsersController, :show
    r.post "/lite_login", LiteSessionsController, :create
    r.delete "/lite_login", LiteSessionsController, :destroy
    r.post "/lite_articles/:article_id/comments", LiteCommentsController, :create
    r.post "/lite_articles/:article_id/reactions", LiteReactionsController, :create
    r.post "/lite_uploads", LiteUploadsController, :create
    r.get "/lite_files/*key", Storage::FilesController, :show
    r.cable "/lite_cable", LiteCommentsChannel
  end
end

def forem_lite_clean! : Nil
  Record.clean_database!
  Record.connected_to("analytics") { Record.clean_database! }
end

module ForemLite
  LOCALES_GLOB = "examples/forem_lite/locales/*.yml"

  def self.setup(primary_path : String, analytics_path : String, storage_root : String) : Nil
    Record.connection = DB.open("sqlite3://#{primary_path}")
    Record.establish_connection("analytics", "sqlite3://#{analytics_path}")
    Record::Migrator.migrate(
      Record.database("primary"),
      [LiteCreatePrimary] of Record::Migration.class)
    Record::Migrator.migrate(
      Record.database("analytics"),
      [LiteCreateAnalytics] of Record::Migration.class)
    Storage.service = Storage::DiskService.new(storage_root)
    unless I18n.load_path.includes?(LOCALES_GLOB)
      I18n.load_path << LOCALES_GLOB
    end
    I18n.reload!
    configure_throttle!
    Record.bcrypt_min_cost = true
    Saci.filter_parameters = ["password"]
    Saci.log_requests = true
  end

  def self.configure_throttle!(limit : Int32 = 5) : Nil
    Throttle.reset!
    Throttle.throttle("lite_login/ip", limit: limit, period: 1.minute) do |ctx|
      ctx.request.path == "/lite_login" ? Throttle.client_ip(ctx) : nil
    end
  end

  def self.seed_demo! : Nil
    forem_lite_clean!
    alice = LiteUser.create!(username: "alice", email: "alice@example.com",
      password: "secret123", password_confirmation: "secret123")
    bob = LiteUser.create!(username: "bob", email: "bob@example.com",
      password: "secret123", password_confirmation: "secret123")
    a1 = LiteArticle.create!(title: "Hello from Forem Lite",
      body: "First post on our DEV-style community.", user_id: alice.id)
    LiteArticle.create!(title: "Crystal web frameworks",
      body: "Comparing Saci with Rails conventions.", user_id: bob.id)
    LiteComment.create!(article_id: a1.id, user_id: bob.id, body: "Great first post!")
    LiteReaction.create!(article_id: a1.id, user_id: bob.id, category: "like")
    Job.with_adapter(:inline) { LiteScoreJob.perform_later({article_id: a1.id}) }
    LitePageView.create!(article_id: a1.id, ip: "127.0.0.1")
    LiteUserMailer.welcome("alice@example.com", "alice").deliver_now
    puts "seeded: #{LiteUser.count} users, #{LiteArticle.count} articles, " \
         "#{LiteComment.count} comments, #{LiteReaction.count} reactions, " \
         "#{LitePageView.count} page views"
  end
end
