require "spec"
require "http/client"
require "../src/saci"

class ExtrasSecurityController < Saci::Controller
  protect_from_forgery

  def token_info
    token = form_authenticity_token
    render json: {
      global:    token,
      masked:    Saci::CSRF.masked_token(token),
      per_form:  Saci::CSRF.per_form_token(token, "extras#create"),
      option:    form_authenticity_token(form_options: {"action" => "extras#create"}),
      option_nt: form_authenticity_token(form_options: {action: "extras#create"}),
      param:     request_forgery_protection_token,
      meta:      csp_meta_tag,
    }
  end

  def create
    render json: {ok: true}, status: :created
  end

  def repeat
    first = form_authenticity_token
    second = form_authenticity_token
    render json: {same: first == second, token: first}
  end

  def override_csp
    content_security_policy({
      "default-src" => "'self'",
      "script-src"  => "'self' 'nonce'",
    })
    render text: "csp"
  end

  def nonce
    render json: {
      nonce:  csp_nonce,
      meta:   csp_meta_tag,
      header: response.headers["Content-Security-Policy"]?,
    }
  end

  def permissions
    permissions_policy({"camera" => ["https://example.com"]})
    render text: "pp"
  end
end

class ExtrasStaticCspController < Saci::Controller
  csp "default-src 'none'"

  def static
    render text: "static"
  end
end

class ExtrasSessionController < Saci::Controller
  def login
    session[:user_id] = params["user_id"]? || "1"
    render json: {id: session.id, user_id: session.int(:user_id)}
  end

  def profile
    render json: {id: session.id, user_id: session.int(:user_id)}
  end

  def logout
    reset_session
    render json: {id: session.id}
  end

  def signed_write
    cookies.signed(purpose: "extras", serializer: :hybrid)[:tok] = "abc123"
    render text: "signed"
  end

  def signed_read_hybrid
    render json: {tok: cookies.signed(purpose: "extras", serializer: :hybrid)[:tok]}
  end

  def signed_read_json
    render json: {tok: cookies.signed(purpose: "extras", serializer: :json)[:tok]}
  end

  def encrypted_write
    cookies.encrypted(purpose: "extras", serializer: :json)[:secret] = "topsecret"
    render text: "encrypted"
  end

  def encrypted_read
    render json: {secret: cookies.encrypted(purpose: "extras", serializer: :json)[:secret]}
  end

  def permanent_write
    cookies.permanent[:ref] = "campaign"
    render text: "permanent"
  end
end

def extras_router : Saci::Router
  Saci::Router.new.draw do |r|
    r.get "/extras/token_info", ExtrasSecurityController, :token_info
    r.post "/extras/create", ExtrasSecurityController, :create
    r.get "/extras/repeat", ExtrasSecurityController, :repeat
    r.get "/extras/csp", ExtrasSecurityController, :override_csp
    r.get "/extras/nonce", ExtrasSecurityController, :nonce
    r.get "/extras/permissions", ExtrasSecurityController, :permissions
    r.get "/extras/static", ExtrasStaticCspController, :static
    r.post "/session/login", ExtrasSessionController, :login
    r.get "/session/profile", ExtrasSessionController, :profile
    r.post "/session/logout", ExtrasSessionController, :logout
    r.get "/cookies/signed", ExtrasSessionController, :signed_write
    r.get "/cookies/signed_hybrid", ExtrasSessionController, :signed_read_hybrid
    r.get "/cookies/signed_json", ExtrasSessionController, :signed_read_json
    r.get "/cookies/encrypted", ExtrasSessionController, :encrypted_write
    r.get "/cookies/unseal", ExtrasSessionController, :encrypted_read
    r.get "/cookies/permanent", ExtrasSessionController, :permanent_write
  end
end

class ExtrasCookieClient
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
    collect_cookies(resp)
    resp
  end

  private def collect_cookies(resp : HTTP::Client::Response) : Nil
    return unless resp.headers.has_key?("Set-Cookie")
    resp.headers.get("Set-Cookie").each do |line|
      pair = line.split(";").first
      key, _, value = pair.partition("=")
      if value.empty?
        @jar.delete(key)
      else
        @jar[key] = value
      end
    end
  end
end

def extras_set_cookie(resp : HTTP::Client::Response, name : String) : String?
  return nil unless resp.headers.has_key?("Set-Cookie")
  found = nil
  resp.headers.get("Set-Cookie").each do |line|
    pair = line.split(";").first
    key, _, value = pair.partition("=")
    found = value if key == name
  end
  found
end

describe "cookie serializers" do
  after_each do
    Saci::Cookies.reset!
  end

  it "defaults to JSON and round-trips through the signed jar" do
    Saci::Cookies.serializer.should eq(:json)
    Saci::TestSession.serve(extras_router) do |app|
      client = ExtrasCookieClient.new(app)
      client.get("/cookies/signed")
      JSON.parse(client.get("/cookies/signed_hybrid").body)["tok"].as_s.should eq("abc123")
    end
  end

  it "reads legacy raw values in :hybrid mode but not in :json mode" do
    Saci::TestSession.serve(extras_router) do |app|
      legacy = Saci::Cookies.sign_with_secret("legacy-value", Saci::Secrets.secret_key_base, "extras")
      headers = HTTP::Headers{"Cookie" => "tok=#{legacy}"}

      hybrid = JSON.parse(app.get("/cookies/signed_hybrid", headers).body)
      hybrid["tok"].as_s.should eq("legacy-value")

      strict = JSON.parse(app.get("/cookies/signed_json", headers).body)
      (strict["tok"]?.try(&.raw)).should be_nil
    end
  end

  it "rejects :marshal and unknown serializers" do
    expect_raises(ArgumentError, /not supported/) do
      Saci::Cookies.serializer = :marshal
    end
    expect_raises(ArgumentError, /Unknown cookie serializer/) do
      Saci::Cookies.normalize_serializer(:yaml)
    end
    Saci::Cookies.serializer_supported?(:json).should be_true
    Saci::Cookies.serializer_supported?(:marshal).should be_false
  end

  it "guards cookie value size with a clear error" do
    request = HTTP::Request.new("GET", "/")
    response = HTTP::Server::Response.new(IO::Memory.new)
    jar = Saci::CookieJar.new(request, response)
    expect_raises(Saci::CookieOverflow, /4096 bytes/) do
      jar.write(:big, "x" * 4097)
    end
  end
end

describe "cookie rotations" do
  after_each do
    Saci::Cookies.reset!
  end

  it "accepts signed cookies from an old secret and rewrites them with the current one" do
    old_secret = "old-secret-123"
    Saci::Cookies.rotations = [old_secret]
    Saci::TestSession.serve(extras_router) do |app|
      legacy = Saci::Cookies.sign_with_secret("rotated-value", old_secret, "extras")
      resp = app.get("/cookies/signed_hybrid", HTTP::Headers{"Cookie" => "tok=#{legacy}"})
      JSON.parse(resp.body)["tok"].as_s.should eq("rotated-value")

      rotated = extras_set_cookie(resp, "tok")
      rotated.should_not be_nil
      raw = rotated.not_nil!
      verified = Saci::Cookies.verify_signed(raw, "extras")
      verified.should_not be_nil
      Saci::Cookies.deserialize(verified.not_nil!, :hybrid).should eq("rotated-value")
      Saci::Cookies.verify_signed_with_secret(raw, old_secret, "extras").should be_nil
    end
  end

  it "accepts encrypted cookies from an old secret and rewrites them" do
    old_secret = "old-secret-456"
    Saci::Cookies.rotations = [old_secret]
    Saci::TestSession.serve(extras_router) do |app|
      legacy = Saci::Cookies.encrypt_with_secret("sealed-old".to_json, old_secret, "extras")
      resp = app.get("/cookies/unseal", HTTP::Headers{"Cookie" => "secret=#{legacy}"})
      JSON.parse(resp.body)["secret"].as_s.should eq("sealed-old")

      rotated = extras_set_cookie(resp, "secret")
      rotated.should_not be_nil
      plain = Saci::Cookies.decrypt(rotated.not_nil!, "extras")
      plain.should_not be_nil
      Saci::Cookies.deserialize(plain.not_nil!, :json).should eq("sealed-old")
    end
  end
end

describe "encrypted cookie decrypt cache" do
  it "serves repeat reads but never across a secret change or for tampered values" do
    previous = ENV["SECRET_KEY_BASE"]?
    begin
      ENV["SECRET_KEY_BASE"] = "decrypt-cache-secret-a"
      Saci::Secrets.reset_secret_key_base!
      sealed = Saci::Cookies.encrypt("payload-a", "cache")
      Saci::Cookies.decrypt(sealed, "cache").should eq("payload-a")
      Saci::Cookies.decrypt(sealed, "cache").should eq("payload-a")
      Saci::Cookies.decrypt(sealed, "other").should be_nil

      tampered = sealed[0...-2] + (sealed[-2] == 'A' ? "B" : "A") + sealed[-1]
      Saci::Cookies.decrypt(tampered, "cache").should be_nil

      ENV["SECRET_KEY_BASE"] = "decrypt-cache-secret-b"
      Saci::Secrets.reset_secret_key_base!
      Saci::Cookies.decrypt(sealed, "cache").should be_nil
    ensure
      previous ? (ENV["SECRET_KEY_BASE"] = previous) : ENV.delete("SECRET_KEY_BASE")
      Saci::Secrets.reset_secret_key_base!
    end
  end
end

describe "session stores" do
  after_each do
    Saci::Session.reset!
    Saci::Session.encrypt = false
    Saci::Cache.reset!
  end

  it "keeps the default cookie store signed and opaque" do
    Saci::TestSession.serve(extras_router) do |app|
      client = ExtrasCookieClient.new(app)
      client.post("/session/login", "user_id=7")
      raw = client.jar[Saci::Session::COOKIE_KEY]
      raw.should_not contain("user_id")
      JSON.parse(client.get("/session/profile").body)["user_id"].as_i.should eq(7)
    end
  end

  it "expires in-memory sessions after expire_after" do
    Saci::Session.store = Saci::SessionStore::MemoryStore.new(expire_after: 1.second)
    Saci::TestSession.serve(extras_router) do |app|
      client = ExtrasCookieClient.new(app)
      login = JSON.parse(client.post("/session/login", "user_id=9").body)
      login["user_id"].as_i.should eq(9)
      login["id"].as_s.should_not be_empty

      client.jar[Saci::Session::COOKIE_KEY].should_not contain("user_id")
      JSON.parse(client.get("/session/profile").body)["user_id"].as_i.should eq(9)

      sleep 1.1.seconds
      (JSON.parse(client.get("/session/profile").body)["user_id"]?.try(&.raw)).should be_nil
    end
  end

  it "expires cache-backed sessions after expire_after" do
    Saci::Session.store = Saci::SessionStore::CacheStore.new(expire_after: 1.second)
    Saci::TestSession.serve(extras_router) do |app|
      client = ExtrasCookieClient.new(app)
      client.post("/session/login", "user_id=11")
      JSON.parse(client.get("/session/profile").body)["user_id"].as_i.should eq(11)
      sleep 1.1.seconds
      (JSON.parse(client.get("/session/profile").body)["user_id"]?.try(&.raw)).should be_nil
    end
  end

  it "rotates the session id on reset_session (fixation defense)" do
    Saci::Session.store = Saci::SessionStore::MemoryStore.new(expire_after: 5.minutes)
    Saci::TestSession.serve(extras_router) do |app|
      client = ExtrasCookieClient.new(app)
      first = JSON.parse(client.post("/session/login", "user_id=5").body)["id"].as_s
      after_logout = JSON.parse(client.post("/session/logout").body)["id"].as_s
      first.should_not eq(after_logout)
      (JSON.parse(client.get("/session/profile").body)["user_id"]?.try(&.raw)).should be_nil
    end
  end

  it "stores sessions in a SQLite-backed saci_sessions table and GCs expired rows" do
    db_path = "/tmp/opencode/saci_sessions_spec.db"
    File.delete(db_path) if File.exists?(db_path)
    db = DB.open("sqlite3://#{db_path}")
    begin
      store = Saci::SessionStore::DatabaseStore.new(db, expire_after: 1.second)
      Saci::Session.store = store
      Saci::TestSession.serve(extras_router) do |app|
        client = ExtrasCookieClient.new(app)
        client.post("/session/login", "user_id=13")
        JSON.parse(client.get("/session/profile").body)["user_id"].as_i.should eq(13)
        db.scalar("SELECT COUNT(*) FROM saci_sessions").should eq(1_i64)

        sleep 1.1.seconds
        (JSON.parse(client.get("/session/profile").body)["user_id"]?.try(&.raw)).should be_nil
        store.gc.should eq(1)
        db.scalar("SELECT COUNT(*) FROM saci_sessions").should eq(0_i64)
      end
      store.clear
    ensure
      db.close
    end
  end

  it "reports backend gc counts and cookie attributes" do
    store = Saci::SessionStore::MemoryStore.new(expire_after: 30.seconds, secure: true, same_site: :strict, path: "/app", domain: "example.com")
    store.cookie_expires_at.should_not be_nil
    store.gc.should eq(0)
    store.commit("abc", {} of String => JSON::Any)
    store.gc.should eq(0)
    store.load(Saci::Secrets.sign("sid:missing")).should be_nil
  end

  it "honors the permanent cookie jar" do
    Saci::TestSession.serve(extras_router) do |app|
      resp = app.get("/cookies/permanent")
      cookie = extras_set_cookie(resp, "ref")
      cookie.should eq("campaign")
      line = resp.headers.get("Set-Cookie").find { |l| l.starts_with?("ref=") }
      line.not_nil!.should contain("expires=")
    end
  end
end

describe "masked and per-form CSRF tokens" do
  after_each do
    Saci::CSRF.reset!
  end

  it "masks and unmasks with a one-time pad" do
    token = Saci::CSRF.generate_token
    masked = Saci::CSRF.mask(token)
    masked.should_not eq(token)
    Saci::CSRF.unmask(masked).should eq(token)
    Saci::CSRF.unmask("not-base64!!").should be_nil
    Saci::CSRF.form_token(token).should_not eq(token)
    Saci::CSRF.form_token(token, "posts#create").should_not eq(Saci::CSRF.form_token(token))
  end

  it "accepts global, masked and per-form tokens over HTTP" do
    Saci::TestSession.serve(extras_router) do |app|
      info_resp = app.get("/extras/token_info")
      info_resp.headers.has_key?("Set-Cookie").should be_true
      info = JSON.parse(info_resp.body)
      info["param"].as_s.should eq("authenticity_token")
      cookie = info["global"].as_s

      headers = HTTP::Headers{
        "Cookie"       => "#{Saci::CSRF::COOKIE_NAME}=#{cookie}",
        "Content-Type" => "application/x-www-form-urlencoded",
      }
      app.post("/extras/create", headers, "authenticity_token=#{info["masked"].as_s}").status_code.should eq(201)
      app.post("/extras/create", headers, "authenticity_token=#{info["per_form"].as_s}").status_code.should eq(201)
      app.post("/extras/create", headers, "authenticity_token=#{info["option"].as_s}").status_code.should eq(201)
      app.post("/extras/create", headers, "authenticity_token=#{info["option_nt"].as_s}").status_code.should eq(201)
      app.post("/extras/create", headers, "authenticity_token=wrong").status_code.should eq(422)
    end
  end

  it "reuses one token per request across repeated calls" do
    Saci::TestSession.serve(extras_router) do |app|
      resp = app.get("/extras/repeat")
      body = JSON.parse(resp.body)
      body["same"].as_bool.should be_true
      resp.headers.get("Set-Cookie").size.should eq(1)
      cookie = resp.headers.get("Set-Cookie").first
      cookie.should contain(body["token"].as_s)
    end
  end

  it "binds per-form verification to the embedded action" do
    token = Saci::CSRF.generate_token
    per_form = Saci::CSRF.per_form_token(token, "posts#create")
    params = Saci::Params.new({"authenticity_token" => per_form})
    request = HTTP::Request.new("POST", "/posts", headers: HTTP::Headers{"Cookie" => "#{Saci::CSRF::COOKIE_NAME}=#{token}"})
    Saci::CSRF.verified?(request, params).should be_true
    Saci::CSRF.verified_for?(request, params, "posts#create").should be_true
    Saci::CSRF.verified_for?(request, params, "posts#destroy").should be_false

    global_masked = Saci::CSRF.masked_token(token)
    masked_params = Saci::Params.new({"authenticity_token" => global_masked})
    Saci::CSRF.verified_for?(request, masked_params, "posts#destroy").should be_true
  end
end

describe "CSP nonces" do
  after_each do
    Saci::SecureHeaders.reset!
  end

  it "interpolates a fresh per-request nonce into the policy" do
    Saci::SecureHeaders.configure do |h|
      h["Content-Security-Policy"] = "default-src 'self'; script-src 'self' 'nonce'"
    end
    Saci::TestSession.serve(extras_router) do |app|
      first = JSON.parse(app.get("/extras/nonce").body)
      second = JSON.parse(app.get("/extras/nonce").body)

      first["nonce"].as_s.should_not be_empty
      first["header"].as_s.should contain("'nonce-#{first["nonce"].as_s}'")
      first["meta"].as_s.should contain(%(content="#{first["nonce"].as_s}"))
      first["nonce"].as_s.should_not eq(second["nonce"].as_s)
    end
  end

  it "supports per-request directive overrides with the nonce" do
    Saci::TestSession.serve(extras_router) do |app|
      resp = app.get("/extras/csp")
      header = resp.headers["Content-Security-Policy"]
      header.should contain("default-src 'self'")
      header.should match(/script-src 'self' 'nonce-[A-Za-z0-9_-]+'/)
    end
  end

  it "preserves static csp policies without generating a nonce" do
    Saci::TestSession.serve(extras_router) do |app|
      resp = app.get("/extras/static")
      resp.headers["Content-Security-Policy"].should eq("default-src 'none'")
    end
  end
end

describe "Permissions-Policy" do
  after_each do
    Saci::SecureHeaders.reset!
  end

  it "serializes the DSL and applies the header" do
    Saci::SecureHeaders.permissions_policy(camera: [] of String, geolocation: ["self"], payment: ["*"])
    Saci::SecureHeaders.permissions_policy["camera"].should eq([] of String)
    Saci::TestSession.serve(extras_router) do |app|
      app.get("/extras/token_info").headers["Permissions-Policy"].should eq("camera=(), geolocation=(self), payment=(*)")
    end
  end

  it "merges per-response overrides feature by feature" do
    Saci::SecureHeaders.permissions_policy(camera: [] of String, geolocation: ["self"])
    Saci::TestSession.serve(extras_router) do |app|
      header = app.get("/extras/permissions").headers["Permissions-Policy"]
      header.should contain(%(camera=("https://example.com")))
      header.should contain("geolocation=(self)")
    end
  end

  it "emits no header when unconfigured" do
    Saci::TestSession.serve(extras_router) do |app|
      app.get("/extras/token_info").headers.has_key?("Permissions-Policy").should be_false
    end
  end
end

describe "extra default headers" do
  after_each do
    Saci::SecureHeaders.reset!
    Saci.force_ssl = false
  end

  it "applies download, cross-domain and cross-origin defaults" do
    Saci::TestSession.serve(extras_router) do |app|
      resp = app.get("/extras/token_info")
      resp.headers["X-Download-Options"].should eq("noopen")
      resp.headers["X-Permitted-Cross-Domain-Policies"].should eq("none")
      resp.headers["Cross-Origin-Opener-Policy"].should eq("same-origin")
      resp.headers["Cross-Origin-Resource-Policy"].should eq("same-site")
    end
  end

  it "only sends HSTS under force_ssl (or explicit opt-in)" do
    Saci::TestSession.serve(extras_router) do |app|
      app.get("/extras/token_info").headers.has_key?("Strict-Transport-Security").should be_false

      Saci.force_ssl = true
      app.get("/extras/token_info").headers["Strict-Transport-Security"].should eq("max-age=31536000; includeSubDomains")
    end

    Saci.force_ssl = false
    Saci::SecureHeaders.hsts = true
    Saci::SecureHeaders.hsts_max_age = 600
    Saci::TestSession.serve(extras_router) do |app|
      app.get("/extras/token_info").headers["Strict-Transport-Security"].should eq("max-age=600; includeSubDomains")
    end
  end

  it "lets default_headers be replaced wholesale" do
    Saci::SecureHeaders.default_headers = {"X-Custom" => "yes"}
    Saci::TestSession.serve(extras_router) do |app|
      resp = app.get("/extras/token_info")
      resp.headers["X-Custom"].should eq("yes")
      resp.headers.has_key?("X-Frame-Options").should be_false
    end
    Saci::SecureHeaders.reset!
    Saci::SecureHeaders.headers["X-Frame-Options"].should eq("SAMEORIGIN")
  end

  it "documents the regexp timeout setting as an unenforceable no-op" do
    Saci::SecureHeaders.regexp_timeout = 1.second
    Saci::SecureHeaders.regexp_timeout.should eq(1.second)
    Saci::SecureHeaders.regexp_timeout_enforced?.should be_false
  end

  it "exposes cookie settings through SecureHeaders" do
    Saci::SecureHeaders.cookies_same_site_protection = :strict
    Saci::Cookies.same_site_protection.should eq(:strict)
    Saci::SecureHeaders.cookies_rotations = ["old"]
    Saci::Cookies.rotations.should eq(["old"])
  ensure
    Saci::Cookies.reset!
  end
end
