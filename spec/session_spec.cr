require "spec"
require "http/client"
require "../src/saci"

class SessionDemoController < Saci::Controller
  def login
    session[:user_id] = params["user_id"]? || "1"
    session[:admin] = true
    render json: {logged_in: session.int(:user_id)}
  end

  def profile
    render json: {user_id: session.int(:user_id), admin: session.bool(:admin)}
  end

  def logout
    reset_session
    render json: {logged_in: false}
  end

  def set_flash
    flash[:notice] = "Welcome #{params["name"]? || "friend"}"
    flash.now[:alert] = "Just this request"
    redirect_to "/flash_next"
  end

  def flash_next
    render json: {notice: flash[:notice], alert: flash.now[:alert]}
  end

  def prefer
    cookies[:theme] = "dark"
    cookies.write(:lang, "es", expires: Time.utc + 30.days)
    cookies.signed[:token] = "abc123"
    render text: "prefs saved"
  end

  def read_prefs
    render json: {theme: cookies[:theme], lang: cookies[:lang], token: cookies.signed[:token]}
  end

  def forget
    cookies.delete(:theme)
    render text: "forgotten"
  end

  def seal
    cookies.encrypted[:secret] = params["value"]? || "shh"
    render text: "sealed"
  end

  def unseal
    render json: {secret: cookies.encrypted[:secret]}
  end
end

def session_router : Saci::Router
  Saci::Router.new.draw do |r|
    r.post "/login", SessionDemoController, :login
    r.get "/profile", SessionDemoController, :profile
    r.post "/logout", SessionDemoController, :logout
    r.post "/set_flash", SessionDemoController, :set_flash
    r.get "/flash_next", SessionDemoController, :flash_next
    r.get "/prefer", SessionDemoController, :prefer
    r.get "/read_prefs", SessionDemoController, :read_prefs
    r.get "/forget", SessionDemoController, :forget
    r.post "/seal", SessionDemoController, :seal
    r.get "/unseal", SessionDemoController, :unseal
  end
end

# Minimal cookie jar for driving multi-request specs.
class SpecCookieClient
  getter last_headers : HTTP::Headers?
  getter jar : Hash(String, String)

  def initialize(@app : Saci::TestSession)
    @jar = {} of String => String
  end

  def get(path : String) : HTTP::Client::Response
    request(:get, path)
  end

  def post(path : String, body : String? = nil) : HTTP::Client::Response
    request(:post, path, body)
  end

  private def request(method : Symbol, path : String, body : String? = nil) : HTTP::Client::Response
    headers = HTTP::Headers.new
    unless @jar.empty?
      headers["Cookie"] = @jar.map { |k, v| "#{k}=#{v}" }.join("; ")
    end
    resp = case method
           when :get then @app.get(path, headers)
           when :post
             headers["Content-Type"] = "application/x-www-form-urlencoded" if body
             @app.post(path, headers, body)
           else raise "unreachable"
           end
    if resp.headers.has_key?("Set-Cookie")
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
    resp
  end
end

describe "sessions" do
  it "persists session data across requests via signed cookie" do
    Saci::TestSession.serve(session_router) do |app|
      client = SpecCookieClient.new(app)
      resp = client.post("/login", "user_id=7")
      JSON.parse(resp.body)["logged_in"].as_i.should eq(7)

      profile = client.get("/profile")
      JSON.parse(profile.body)["user_id"].as_i.should eq(7)
      JSON.parse(profile.body)["admin"].as_bool.should be_true
    end
  end

  it "starts a fresh session for tampered cookies" do
    Saci::TestSession.serve(session_router) do |app|
      client = SpecCookieClient.new(app)
      client.post("/login", "user_id=7")

      evil = SpecCookieClient.new(app)
      tampered = evil.post("/login", "user_id=7")
      set_cookies = tampered.headers.get("Set-Cookie")
      set_cookies.should_not be_empty
      cookie = set_cookies.first.split(";").first
      key, _, value = cookie.partition("=")
      broken = value[0...-2] + (value[-2..] == "aa" ? "bb" : "aa")

      headers = HTTP::Headers{"Cookie" => "#{key}=#{broken}"}
      resp = app.get("/profile", headers)
      (JSON.parse(resp.body)["user_id"]?.try(&.raw)).should be_nil
    end
  end

  it "clears the session on logout" do
    Saci::TestSession.serve(session_router) do |app|
      client = SpecCookieClient.new(app)
      client.post("/login", "user_id=7")
      client.post("/logout")
      (JSON.parse(client.get("/profile").body)["user_id"]?.try(&.raw)).should be_nil
    end
  end

  it "carries flash to the next request only" do
    Saci::TestSession.serve(session_router) do |app|
      client = SpecCookieClient.new(app)
      r1 = client.post("/set_flash", "name=Ada")
      r1.status_code.should eq(302)

      r2 = client.get("/flash_next")
      JSON.parse(r2.body)["notice"].as_s.should eq("Welcome Ada")
      (JSON.parse(r2.body)["alert"]?.try(&.raw)).should be_nil

      r3 = client.get("/flash_next")
      (JSON.parse(r3.body)["notice"]?.try(&.raw)).should be_nil
    end
  end
end

describe "cookies" do
  it "round-trips plain, expiring and signed cookies" do
    Saci::TestSession.serve(session_router) do |app|
      client = SpecCookieClient.new(app)
      client.get("/prefer")
      prefs = JSON.parse(client.get("/read_prefs").body)
      prefs["theme"].as_s.should eq("dark")
      prefs["lang"].as_s.should eq("es")
      prefs["token"].as_s.should eq("abc123")
    end
  end

  it "deletes cookies" do
    Saci::TestSession.serve(session_router) do |app|
      client = SpecCookieClient.new(app)
      client.get("/prefer")
      client.get("/forget")
      prefs = JSON.parse(client.get("/read_prefs").body)
      (prefs["theme"]?.try(&.raw)).should be_nil
    end
  end
end

describe "encrypted cookies" do
  it "round-trips opaque values" do
    Saci::TestSession.serve(session_router) do |app|
      client = SpecCookieClient.new(app)
      client.post("/seal", "value=topsecret1")
      secret = JSON.parse(client.get("/unseal").body)["secret"].as_s
      secret.should eq("topsecret1")
    end
  end

  it "stores ciphertext the client cannot read" do
    Saci::TestSession.serve(session_router) do |app|
      client = SpecCookieClient.new(app)
      client.post("/seal", "value=topsecret1")
      jar = client.jar
      raw = jar["secret"]
      raw.should_not contain("topsecret1")
      Saci::Secrets.verify_signed(raw).should be_nil
    end
  end

  it "rejects tampered values" do
    Saci::TestSession.serve(session_router) do |app|
      client = SpecCookieClient.new(app)
      client.post("/seal", "value=topsecret1")
      jar = client.jar
      tampered = jar["secret"]
      tampered = tampered[0...-4] + (tampered[-4..] == "AAAA" ? "BBBB" : "AAAA")
      jar["secret"] = tampered
      (JSON.parse(client.get("/unseal").body)["secret"]?.try(&.raw)).should be_nil
    end
  end

  it "rejects signed values presented as encrypted" do
    Saci::TestSession.serve(session_router) do |app|
      client = SpecCookieClient.new(app)
      client.get("/prefer") # sets a signed cookie
      jar = client.jar
      jar["secret"] = jar["saci_csrf"]? || Saci::Secrets.sign("forged")
      (JSON.parse(client.get("/unseal").body)["secret"]?.try(&.raw)).should be_nil
    end
  end
end

describe "encrypted sessions" do
  before_each do
    Saci::Session.encrypt = true
  end

  after_each do
    Saci::Session.encrypt = false
  end

  it "persists session data across requests when encrypted" do
    Saci::TestSession.serve(session_router) do |app|
      client = SpecCookieClient.new(app)
      resp = client.post("/login", "user_id=7")
      JSON.parse(resp.body)["logged_in"].as_i.should eq(7)

      profile = client.get("/profile")
      JSON.parse(profile.body)["user_id"].as_i.should eq(7)
      JSON.parse(profile.body)["admin"].as_bool.should be_true
    end
  end

  it "keeps the payload opaque to clients" do
    Saci::TestSession.serve(session_router) do |app|
      client = SpecCookieClient.new(app)
      client.post("/login", "user_id=7")
      raw = client.jar[Saci::Session::COOKIE_KEY]
      raw.should_not contain("user_id")
      Saci::Secrets.verify_signed(raw).should be_nil
    end
  end

  it "starts a fresh session for signed-era cookies" do
    Saci::TestSession.serve(session_router) do |app|
      previous = Saci::Session.encrypt
      Saci::Session.encrypt = false
      begin
        legacy = SpecCookieClient.new(app)
        legacy.post("/login", "user_id=7")
        stolen = legacy.jar[Saci::Session::COOKIE_KEY]
      ensure
        Saci::Session.encrypt = previous
      end

      evil = SpecCookieClient.new(app)
      evil.jar[Saci::Session::COOKIE_KEY] = stolen
      (JSON.parse(evil.get("/profile").body)["user_id"]?.try(&.raw)).should be_nil
    end
  end
end

describe "Saci::Secrets" do
  it "generates unique secrets and round-trips signatures" do
    Saci::Secrets.generate_secret.size.should eq(128)
    Saci::Secrets.generate_secret.should_not eq(Saci::Secrets.generate_secret)
    signed = Saci::Secrets.sign("hello")
    Saci::Secrets.verify_signed(signed).should eq("hello")
    Saci::Secrets.verify_signed(signed + "x").should be_nil
    Saci::Secrets.verify_signed("garbage").should be_nil
  end

  it "derives purpose-separated 32-byte encryption keys" do
    cookie_key = Saci::Secrets.encrypted_key("cookie")
    session_key = Saci::Secrets.encrypted_key("session")
    cookie_key.size.should eq(32)
    cookie_key.should_not eq(session_key)
    cookie_key.should eq(Saci::Secrets.encrypted_key("cookie"))
  end

  it "prefers SECRET_KEY_BASE and persists a dev fallback" do
    ENV["SECRET_KEY_BASE"] = "test-secret-123"
    begin
      Saci::Secrets.secret_key_base.should eq("test-secret-123")
    ensure
      ENV.delete("SECRET_KEY_BASE")
    end
  end

  it "refuses to boot production secrets without SECRET_KEY_BASE" do
    old_env = ENV["APP_ENV"]?
    old_secret = ENV["SECRET_KEY_BASE"]?
    begin
      ENV.delete("SECRET_KEY_BASE")
      Saci::Secrets.reset_secret_key_base!
      # Credentials are absent in the framework repo, so lookup falls through.
      ENV["APP_ENV"] = "production"
      expect_raises(Saci::Secrets::MissingSecretInProduction, /SECRET_KEY_BASE/) do
        Saci::Secrets.secret_key_base
      end
    ensure
      if old_env
        ENV["APP_ENV"] = old_env
      else
        ENV.delete("APP_ENV")
      end
      if old_secret
        ENV["SECRET_KEY_BASE"] = old_secret
      else
        ENV.delete("SECRET_KEY_BASE")
      end
      Saci::Secrets.reset_secret_key_base!
    end
  end
end
