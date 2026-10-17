require "spec"
require "http/client"
require "../src/saci"

# Framework-agnostic user doubles: one with a rolling session_token, one
# without. Plain classes on purpose — no `Saci::Record` involved.
class AuthTestUser
  getter id : Int64
  getter session_token : String

  @@store = {} of Int64 => AuthTestUser
  @@lookups = 0
  @@rotations = 0

  def initialize(@id : Int64, @session_token : String = "token-#{@id}")
  end

  def self.create(id : Int64, token : String = "token-#{id}") : AuthTestUser
    user = new(id, token)
    @@store[id] = user
    user
  end

  # Counting lookup (what controller finders call).
  def self.find?(id : Int64) : AuthTestUser?
    @@lookups += 1
    @@store[id]?
  end

  # Non-counting accessor (test setup / login plumbing).
  def self.get(id : Int64) : AuthTestUser?
    @@store[id]?
  end

  def self.lookups : Int32
    @@lookups
  end

  def self.reset! : Nil
    @@store.clear
    @@lookups = 0
    @@rotations = 0
  end

  # Simulates a password change / "log out other sessions" rotation.
  def rotate! : Nil
    @@rotations += 1
    @session_token = "token-#{@id}-r#{@@rotations}"
    @@store[@id] = self
  end
end

class AuthSimpleUser
  getter id : Int64

  @@store = {} of Int64 => AuthSimpleUser

  def initialize(@id : Int64)
  end

  def self.create(id : Int64) : AuthSimpleUser
    user = new(id)
    @@store[id] = user
    user
  end

  def self.find?(id : Int64) : AuthSimpleUser?
    @@store[id]?
  end

  def self.get(id : Int64) : AuthSimpleUser?
    @@store[id]?
  end

  def self.reset! : Nil
    @@store.clear
  end
end

class AuthApplicationController < Saci::Controller
  before_action :require_login

  memoize_current_user AuthTestUser

  private def find_current_user(id : Int64) : AuthTestUser?
    AuthTestUser.find?(id)
  end
end

class AuthSessionsController < AuthApplicationController
  allow_unauthenticated_access only: [:new, :create]
  before_action :require_no_login, only: [:new]

  def new
    render json: {login_page: true, redirect_to: session.string(Saci::Auth.redirect_key)}
  end

  def create
    raw = params["id"]? || "1"
    wanted = (raw.to_i64 rescue 1_i64)
    if user = AuthTestUser.get(wanted)
      login(user)
      render json: {logged_in: user.id}
    else
      render json: {error: "unknown user"}, status: :not_found
    end
  end

  def destroy
    logout
    render json: {logged_out: true}
  end
end

class AuthDashboardController < AuthApplicationController
  def show
    render json: {dashboard: true, user_id: current_user.try(&.id)}
  end
end

class AuthAccountsController < AuthApplicationController
  def me
    first = current_user
    _again = current_user
    render json: {
      user_id:   first.try(&.id),
      logged_in: logged_in?,
      trap:      session.string(:trap),
      stored_id: session.int(Saci::Auth.session_key),
      legacy_id: session.int(:user_id),
    }
  end

  def transfer
    render json: {transferred: true}
  end
end

class AuthPublicController < Saci::Controller
  def seed
    session[:trap] = "planted"
    render json: {seeded: true}
  end
end

class AuthOpenController < AuthApplicationController
  allow_unauthenticated_access

  def ping
    render json: {open: true, logged_in: logged_in?, user_id: current_user.try(&.id)}
  end
end

class AuthSimpleController < Saci::Controller
  before_action :require_login

  allow_unauthenticated_access only: [:login_simple]

  memoize_current_user AuthSimpleUser

  private def find_current_user(id : Int64) : AuthSimpleUser?
    AuthSimpleUser.find?(id)
  end

  def login_simple
    if user = AuthSimpleUser.get(2_i64)
      login(user)
      render json: {logged_in: user.id}
    else
      render json: {error: "missing user"}, status: :not_found
    end
  end

  def simple_me
    render json: {user_id: current_user.try(&.id), logged_in: logged_in?}
  end
end

def auth_router : Saci::Router
  Saci::Router.new.draw do |r|
    r.get "/login", AuthSessionsController, :new
    r.post "/login", AuthSessionsController, :create
    r.post "/logout", AuthSessionsController, :destroy
    r.get "/dashboard", AuthDashboardController, :show
    r.get "/me", AuthAccountsController, :me
    r.post "/transfer", AuthAccountsController, :transfer
    r.post "/plant", AuthPublicController, :seed
    r.get "/open", AuthOpenController, :ping
    r.post "/simple_login", AuthSimpleController, :login_simple
    r.get "/simple_me", AuthSimpleController, :simple_me
  end
end

# Cookie jar driving multi-request auth flows (session cookie tracked).
class AuthCookieClient
  getter jar : Hash(String, String)

  def initialize(@app : Saci::TestSession)
    @jar = {} of String => String
  end

  def get(path : String) : HTTP::Client::Response
    headers = HTTP::Headers.new
    headers["Cookie"] = @jar.map { |k, v| "#{k}=#{v}" }.join("; ") unless @jar.empty?
    resp = @app.get(path, headers)
    track(resp)
    resp
  end

  def post(path : String, body : String? = nil) : HTTP::Client::Response
    headers = HTTP::Headers.new
    headers["Cookie"] = @jar.map { |k, v| "#{k}=#{v}" }.join("; ") unless @jar.empty?
    headers["Content-Type"] = "application/x-www-form-urlencoded" if body
    resp = @app.post(path, headers, body)
    track(resp)
    resp
  end

  private def track(resp : HTTP::Client::Response) : Nil
    return unless resp.headers.has_key?("Set-Cookie")
    resp.headers.get("Set-Cookie").each do |line|
      pair = line.split(";").first
      key, _, value = pair.partition("=")
      if value.empty? || line.downcase.includes?("expires=thu, 01 jan 1970")
        @jar.delete(key)
      else
        @jar[key] = value
      end
    end
  end
end

describe "authentication" do
  before_each do
    Saci::Auth.reset!
    AuthTestUser.reset!
    AuthSimpleUser.reset!
    AuthTestUser.create(1_i64)
    AuthTestUser.create(5_i64)
    AuthSimpleUser.create(2_i64)
  end

  after_each do
    Saci::Auth.reset!
  end

  it "login stores the user id and wipes pre-login session data (fixation-safe)" do
    Saci::TestSession.serve(auth_router) do |app|
      client = AuthCookieClient.new(app)
      client.post("/plant")
      before = client.jar[Saci::Session::COOKIE_KEY]

      resp = client.post("/login?id=1")
      resp.status_code.should eq(200)
      JSON.parse(resp.body)["logged_in"].as_i.should eq(1)

      after = client.jar[Saci::Session::COOKIE_KEY]
      after.should_not eq(before)

      me = JSON.parse(client.get("/me").body)
      me["user_id"].as_i.should eq(1)
      me["stored_id"].as_i.should eq(1)
      (me["trap"]?.try(&.raw)).should be_nil
    end
  end

  it "logout clears the session" do
    Saci::TestSession.serve(auth_router) do |app|
      client = AuthCookieClient.new(app)
      client.post("/login?id=1")
      JSON.parse(client.get("/me").body)["logged_in"].as_bool.should be_true

      gone = client.post("/logout")
      gone.status_code.should eq(200)
      JSON.parse(gone.body)["logged_out"].as_bool.should be_true

      me = JSON.parse(client.get("/open").body)
      me["logged_in"].as_bool.should be_false
      (me["user_id"]?.try(&.raw)).should be_nil
    end
  end

  it "current_user memoizes the finder lookup within a request" do
    Saci::TestSession.serve(auth_router) do |app|
      client = AuthCookieClient.new(app)
      client.post("/login?id=5")
      before = AuthTestUser.lookups
      me = JSON.parse(client.get("/me").body)
      me["user_id"].as_i.should eq(5)
      # #me calls current_user twice; the finder runs once.
      (AuthTestUser.lookups - before).should eq(1)
    end
  end

  it "current_user is nil-safe for anonymous visitors" do
    Saci::TestSession.serve(auth_router) do |app|
      client = AuthCookieClient.new(app)
      resp = client.get("/open")
      resp.status_code.should eq(200)
      body = JSON.parse(resp.body)
      body["logged_in"].as_bool.should be_false
      (body["user_id"]?.try(&.raw)).should be_nil
    end
  end

  it "require_login redirects anonymous GETs and remembers the target" do
    Saci::TestSession.serve(auth_router) do |app|
      client = AuthCookieClient.new(app)
      resp = client.get("/dashboard")
      resp.status_code.should eq(302)
      resp.headers["Location"].should eq("/login")

      form = client.get("/login")
      form.status_code.should eq(200)
      JSON.parse(form.body)["redirect_to"].as_s.should eq("/dashboard")
    end
  end

  it "require_login does not remember non-GET targets" do
    Saci::TestSession.serve(auth_router) do |app|
      client = AuthCookieClient.new(app)
      resp = client.post("/transfer")
      resp.status_code.should eq(302)
      resp.headers["Location"].should eq("/login")

      form = client.get("/login")
      (JSON.parse(form.body)["redirect_to"]?.try(&.raw)).should be_nil
    end
  end

  it "allow_unauthenticated_access exempts listed actions and open controllers" do
    Saci::TestSession.serve(auth_router) do |app|
      client = AuthCookieClient.new(app)
      login_page = client.get("/login")
      login_page.status_code.should eq(200)
      JSON.parse(login_page.body)["login_page"].as_bool.should be_true

      open = client.get("/open")
      open.status_code.should eq(200)
      JSON.parse(open.body)["open"].as_bool.should be_true
    end
  end

  it "allow_unauthenticated_access still guards non-exempt actions" do
    Saci::TestSession.serve(auth_router) do |app|
      client = AuthCookieClient.new(app)
      resp = client.post("/logout")
      resp.status_code.should eq(302)
      resp.headers["Location"].should eq("/login")
    end
  end

  it "require_no_login bounces logged-in visitors away from the login page" do
    Saci::TestSession.serve(auth_router) do |app|
      client = AuthCookieClient.new(app)
      client.post("/login?id=1")
      resp = client.get("/login")
      resp.status_code.should eq(302)
      resp.headers["Location"].should eq("/")
    end
  end

  it "rotating the session_token invalidates existing sessions" do
    Saci::TestSession.serve(auth_router) do |app|
      client = AuthCookieClient.new(app)
      client.post("/login?id=1")
      JSON.parse(client.get("/open").body)["logged_in"].as_bool.should be_true

      AuthTestUser.get(1_i64).not_nil!.rotate!

      body = JSON.parse(client.get("/open").body)
      body["logged_in"].as_bool.should be_false
      (body["user_id"]?.try(&.raw)).should be_nil
    end
  end

  it "records without a session_token log in and resolve fine" do
    Saci::TestSession.serve(auth_router) do |app|
      client = AuthCookieClient.new(app)
      resp = client.post("/simple_login")
      resp.status_code.should eq(200)

      me = JSON.parse(client.get("/simple_me").body)
      me["user_id"].as_i.should eq(2)
      me["logged_in"].as_bool.should be_true
    end
  end

  it "custom login path, session key and redirect key are respected" do
    Saci::Auth.configure do |c|
      c.login_path = "/sign_in"
      c.session_key = :account_id
      c.redirect_key = :return_to
    end
    Saci::TestSession.serve(auth_router) do |app|
      client = AuthCookieClient.new(app)
      resp = client.get("/dashboard")
      resp.status_code.should eq(302)
      resp.headers["Location"].should eq("/sign_in")

      client.post("/login?id=1")
      me = JSON.parse(client.get("/me").body)
      me["user_id"].as_i.should eq(1)
      me["stored_id"].as_i.should eq(1)
      (me["legacy_id"]?.try(&.raw)).should be_nil

      fresh = AuthCookieClient.new(app)
      fresh.get("/dashboard")
      form = fresh.get("/login")
      JSON.parse(form.body)["redirect_to"].as_s.should eq("/dashboard")
    end
  end

  it "assigning user_finder through configure raises with directions" do
    expect_raises(Exception, /find_current_user/) do
      Saci::Auth.configure do |c|
        c.user_finder = ->(id : Int64) { AuthTestUser.find?(id) }
      end
    end
  end

  it "Saci::Auth resets to defaults and the default finder resolves nobody" do
    Saci::Auth.configure do |c|
      c.login_path = "/sign_in"
      c.session_key = :account_id
    end
    Saci::Auth.reset!
    Saci::Auth.login_path.should eq("/login")
    Saci::Auth.session_key.should eq(:user_id)
    Saci::Auth.redirect_key.should eq(:redirect_to)
    Saci::Auth.token_key.should eq(:session_token)
    Saci::Auth.already_logged_in_path.should eq("/")
    Saci::Auth.user_finder.call(1_i64).should be_nil
  end
end
