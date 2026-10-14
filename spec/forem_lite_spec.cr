require "spec"
require "file_utils"
require "../examples/forem_lite_domain"

# Forem Lite validation suite: one app exercising every Saci subsystem —
# router, controllers/filters, ORM, views, caching, CSRF/sessions, throttle,
# storage, jobs, mailers, cable, I18n, logging, credentials, env, multidb.
LITE_SPEC_DB           = "/tmp/opencode/forem_lite_spec.db"
LITE_SPEC_ANALYTICS_DB = "/tmp/opencode/forem_lite_spec_analytics.db"
LITE_SPEC_STORAGE      = "/tmp/opencode/forem_lite_spec_storage"

# Cookie-jar HTTP driver (Crystal's client keeps no cookies itself).
class LiteClient
  getter cookies : Hash(String, String)

  def initialize(@app : Saci::TestSession)
    @cookies = {} of String => String
  end

  def get(path : String, extra : HTTP::Headers? = nil) : HTTP::Client::Response
    track(@app.get(path, with_cookies(extra)))
  end

  def post(path : String, body : String, content_type : String = "application/json") : HTTP::Client::Response
    ensure_csrf!
    headers = HTTP::Headers{"Content-Type" => content_type, "X-CSRF-Token" => @cookies["saci_csrf"]}
    track(@app.post(path, with_cookies(headers), body))
  end

  def put(path : String, body : String, content_type : String = "application/json") : HTTP::Client::Response
    ensure_csrf!
    headers = HTTP::Headers{"Content-Type" => content_type, "X-CSRF-Token" => @cookies["saci_csrf"]}
    track(@app.put(path, with_cookies(headers), body))
  end

  # Rails-style `_method` tunneling (what `link_to(..., method: :delete)` emits).
  def post_override(path : String, method : String) : HTTP::Client::Response
    ensure_csrf!
    headers = HTTP::Headers{
      "Content-Type" => "application/x-www-form-urlencoded",
      "X-CSRF-Token" => @cookies["saci_csrf"],
    }
    track(@app.post(path, with_cookies(headers), "_method=#{method}"))
  end

  def delete(path : String) : HTTP::Client::Response
    ensure_csrf!
    headers = HTTP::Headers{"X-CSRF-Token" => @cookies["saci_csrf"]}
    track(@app.delete(path, with_cookies(headers)))
  end

  private def ensure_csrf! : Nil
    get("/lite_health") unless @cookies.has_key?("saci_csrf")
  end

  private def with_cookies(extra : HTTP::Headers?) : HTTP::Headers
    headers = extra ? extra.dup : HTTP::Headers.new
    unless @cookies.empty?
      headers["Cookie"] = @cookies.map { |k, v| "#{k}=#{v}" }.join("; ")
    end
    headers
  end

  private def track(resp : HTTP::Client::Response) : HTTP::Client::Response
    if resp.headers.has_key?("Set-Cookie")
      resp.headers.get("Set-Cookie").each do |line|
        pair = line.split(";").first
        key, _, value = pair.partition("=")
        if value.empty? || line.downcase.includes?("expires=thu, 01 jan 1970")
          @cookies.delete(key)
        else
          @cookies[key] = value
        end
      end
    end
    resp
  end
end

def lite_seed! : NamedTuple(alice: LiteUser, bob: LiteUser, article: LiteArticle)
  alice = LiteUser.create!(username: "alice", email: "alice@example.com",
    password: "secret123", password_confirmation: "secret123")
  bob = LiteUser.create!(username: "bob", email: "bob@example.com",
    password: "secret123", password_confirmation: "secret123")
  article = LiteArticle.create!(title: "Hello from Forem Lite",
    body: "First post body.", user_id: alice.id)
  {alice: alice, bob: bob, article: article}
end

def lite_login!(client : LiteClient, username : String = "alice") : HTTP::Client::Response
  resp = client.post("/lite_login", {username: username, password: "secret123"}.to_json)
  resp.status_code.should eq(200)
  resp
end

describe "forem-lite validation app" do
  before_all do
    ENV["SECRET_KEY_BASE"] = "forem-lite-spec-secret"
    [LITE_SPEC_DB, LITE_SPEC_ANALYTICS_DB].each do |path|
      File.delete(path) if File.exists?(path)
    end
    FileUtils.rm_rf(LITE_SPEC_STORAGE)
    Dir.mkdir_p(LITE_SPEC_STORAGE)
    ForemLite.setup(LITE_SPEC_DB, LITE_SPEC_ANALYTICS_DB, LITE_SPEC_STORAGE)
    Saci::Mailer.delivery_adapter = :test
    Saci::Job.queue_adapter = :test
  end

  after_all do
    Saci::Mailer.delivery_adapter = :file
    Saci::Job.queue_adapter = :async
    Saci::Record.bcrypt_min_cost = false
    Saci.filter_parameters = ["password", "password_confirmation", "token", "secret"]
    Saci::Throttle.reset!
    Saci::Record.database("primary").close
    Saci::Record.database("analytics").close
    ENV.delete("SECRET_KEY_BASE")
  end

  before_each do
    forem_lite_clean!
    Saci::Mailer.clear_deliveries!
    Saci::Job.clear_enqueued!
    Saci::Throttle.clear_counts!
    lite_seed!
  end

  it "registers routes, websocket endpoints and file routes" do
    router = forem_lite_router
    table = router.routes_table.join("\n")
    table.should contain("GET    /lite_articles")
    table.should contain("POST   /lite_login")
    table.should contain("GET    /lite_files/*key")
    router.ws_routes_table.join("\n").should contain("/lite_cable")
  end

  it "signs users up, logs them in (session) and welcomes them by mail" do
    Saci::Job.with_adapter(:inline) do
      Saci::TestSession.serve(forem_lite_router) do |app|
        client = LiteClient.new(app)
        resp = client.post("/lite_users",
          {username: "carol", email: "carol@example.com", password: "secret123"}.to_json)
        resp.status_code.should eq(201)
        body = JSON.parse(resp.body)
        body["username"].as_s.should eq("carol")
        # Session persisted: the profile round-trips behind the cookie.
        me = client.get("/lite_users/#{body["id"].as_i}")
        me.status_code.should eq(200)
        JSON.parse(me.body)["username"].as_s.should eq("carol")
        # Welcome mail rendered now, delivered through the job system.
        Saci::Mailer.deliveries.map(&.subject).should contain("Welcome to Forem Lite, carol!")
      end
    end
  end

  it "rejects duplicate emails and short data with 422" do
    Saci::TestSession.serve(forem_lite_router) do |app|
      client = LiteClient.new(app)
      dup = client.post("/lite_users",
        {username: "alice2", email: "alice@example.com", password: "secret123"}.to_json)
      dup.status_code.should eq(422)
      JSON.parse(dup.body)["errors"].as_a.map(&.as_s).join.should contain("already been taken")

      lite_login!(client)
      short = client.post("/lite_articles", {title: "hey", body: "too short"}.to_json)
      short.status_code.should eq(422)
      JSON.parse(short.body)["errors"].as_a.map(&.as_s).join.should contain("too short")
    end
  end

  it "logs in and out, rejecting bad passwords with 401" do
    Saci::TestSession.serve(forem_lite_router) do |app|
      client = LiteClient.new(app)
      lite_login!(client)
      # Logged in: creating articles works.
      created = client.post("/lite_articles", {title: "A valid title", body: "body"}.to_json)
      created.status_code.should eq(201)

      bad = client.post("/lite_login", {username: "alice", password: "wrong"}.to_json)
      bad.status_code.should eq(401)

      client.delete("/lite_login").status_code.should eq(200)
      again = client.post("/lite_articles", {title: "A valid title", body: "body"}.to_json)
      again.status_code.should eq(401)
    end
  end

  it "rejects forged state-changing requests with 422 (CSRF)" do
    Saci::TestSession.serve(forem_lite_router) do |app|
      resp = app.post("/lite_articles", HTTP::Headers{"Content-Type" => "application/json"},
        {title: "x", body: "y"}.to_json)
      resp.status_code.should eq(422)
    end
  end

  it "applies secure headers and escapes user input (XSS)" do
    LiteArticle.create!(title: "<script>alert(1)</script> hey", body: "xss", user_id: LiteUser.first.not_nil!.id)
    Saci::TestSession.serve(forem_lite_router) do |app|
      resp = app.get("/")
      resp.headers["X-Frame-Options"].should eq("SAMEORIGIN")
      resp.headers["X-Content-Type-Options"].should eq("nosniff")
      resp.body.should contain("&lt;script&gt;")
      resp.body.should_not contain("<script>")
    end
  end

  it "serves the HTML feed with layout, counts and guidelines partial" do
    Saci::TestSession.serve(forem_lite_router) do |app|
      resp = app.get("/")
      resp.status_code.should eq(200)
      resp.headers["Content-Type"].should contain("text/html")
      resp.body.should contain("<html>")
      resp.body.should contain("Hello from Forem Lite")
      resp.body.should contain("1 article")
      resp.body.should contain("Be kind")
    end
  end

  it "runs article CRUD with ownership checks" do
    Saci::TestSession.serve(forem_lite_router) do |app|
      alice_client = LiteClient.new(app)
      lite_login!(alice_client)
      created = alice_client.post("/lite_articles",
        {title: "CRUD works here", body: "body text"}.to_json)
      created.status_code.should eq(201)
      id = JSON.parse(created.body)["id"].as_i

      show = alice_client.get("/lite_articles/#{id}")
      show.status_code.should eq(200)
      show.body.should contain("CRUD works here")
      show.body.should contain("Comments (0)")
      show.body.should contain("Be kind")
      show.body.should contain(%(name="_method" value="DELETE"))

      updated = alice_client.put("/lite_articles/#{id}", {title: "CRUD works edited"}.to_json)
      updated.status_code.should eq(200)
      JSON.parse(updated.body)["title"].as_s.should eq("CRUD works edited")

      bob_client = LiteClient.new(app)
      lite_login!(bob_client, "bob")
      forbidden = bob_client.put("/lite_articles/#{id}", {title: "hijack"}.to_json)
      forbidden.status_code.should eq(403)

      alice_client.delete("/lite_articles/#{id}").status_code.should eq(204)
      alice_client.get("/lite_articles/#{id}").status_code.should eq(404)
      alice_client.get("/lite_articles/999999").status_code.should eq(404)
    end
  end

  it "supports _method tunneling for link_to delete forms" do
    Saci::TestSession.serve(forem_lite_router) do |app|
      client = LiteClient.new(app)
      lite_login!(client)
      created = client.post("/lite_articles", {title: "tunnel me away", body: "body"}.to_json)
      id = JSON.parse(created.body)["id"].as_i
      resp = client.post_override("/lite_articles/#{id}", "DELETE")
      resp.status_code.should eq(204)
      client.get("/lite_articles/#{id}").status_code.should eq(404)
    end
  end

  it "requires login (401) and reports missing params (400)" do
    Saci::TestSession.serve(forem_lite_router) do |app|
      anon = LiteClient.new(app)
      anon.post("/lite_articles", {title: "A valid title", body: "b"}.to_json).status_code.should eq(401)

      client = LiteClient.new(app)
      lite_login!(client, "bob")
      article = LiteArticle.first.not_nil!
      missing = client.post("/lite_articles/#{article.id}/comments", %({})).status_code
      missing.should eq(400)
      no_user = client.post("/lite_login", %({})).status_code
      no_user.should eq(400)
    end
  end

  it "caches article pages with etags (304 on revalidate)" do
    Saci::TestSession.serve(forem_lite_router) do |app|
      article = LiteArticle.first.not_nil!
      first = app.get("/lite_articles/#{article.id}")
      first.status_code.should eq(200)
      etag = first.headers["ETag"]?
      etag.should_not be_nil
      second = app.get("/lite_articles/#{article.id}", HTTP::Headers{"If-None-Match" => etag.not_nil!})
      second.status_code.should eq(304)
    end
  end

  it "streams new comments over websockets and persists them" do
    Saci::TestSession.serve(forem_lite_router) do |app|
      article = LiteArticle.first.not_nil!
      ws = Saci::Cable::TestClient.new(app.host, app.port, "/lite_cable")
      begin
        ws.subscribe("LiteCommentsChannel", {"article_id" => article.id.to_s})
        client = LiteClient.new(app)
        lite_login!(client, "bob")
        resp = client.post("/lite_articles/#{article.id}/comments", {body: "hello cable"}.to_json)
        resp.status_code.should eq(201)
        msg = ws.next_message
        msg["message"]["body"].as_s.should eq("hello cable")
      ensure
        ws.close
      end
      article.comments.count.should eq(1)
    end
  end

  it "recalculates article scores via background jobs" do
    Saci::Job.with_adapter(:inline) do
      Saci::TestSession.serve(forem_lite_router) do |app|
        article = LiteArticle.first.not_nil!
        client = LiteClient.new(app)
        lite_login!(client, "bob")
        client.post("/lite_articles/#{article.id}/comments", {body: "nice post"}.to_json).status_code.should eq(201)
        client.post("/lite_articles/#{article.id}/reactions", {category: "like"}.to_json).status_code.should eq(201)
        # 1 reaction * 5 + 1 comment * 3
        article.reload.score.should eq(8)
      end
    end
  end

  it "uploads cover images and serves them through signed urls" do
    Saci::TestSession.serve(forem_lite_router) do |app|
      client = LiteClient.new(app)
      lite_login!(client)
      resp = client.post("/lite_uploads",
        {data: "hello-bytes", filename: "note.txt", content_type: "text/plain"}.to_json)
      resp.status_code.should eq(201)
      payload = JSON.parse(resp.body)
      key = payload["key"].as_s
      url = payload["url"].as_s
      Saci::Storage.exists?(key).should be_true

      got = client.get(url)
      got.status_code.should eq(200)
      got.body.should eq("hello-bytes")

      client.get(url + "x").status_code.should eq(404)
      Saci::Storage.exists?("../evil").should be_false
    end
  end

  it "throttles login attempts with 429 + Retry-After" do
    ForemLite.configure_throttle!(limit: 3)
    begin
      Saci::TestSession.serve(forem_lite_router) do |app|
        client = LiteClient.new(app)
        3.times do
          client.post("/lite_login", {username: "nobody", password: "nope"}.to_json).status_code.should eq(401)
        end
        limited = client.post("/lite_login", {username: "nobody", password: "nope"}.to_json)
        limited.status_code.should eq(429)
        limited.headers["Retry-After"]?.should_not be_nil
      end
    ensure
      ForemLite.configure_throttle!
    end
  end

  it "localizes greetings and feed (params + Accept-Language)" do
    Saci::TestSession.serve(forem_lite_router) do |app|
      en = app.get("/lite_health")
      JSON.parse(en.body)["greeting"].as_s.should eq("Welcome, dev!")

      es = app.get("/lite_health?locale=es&name=Ada")
      es.status_code.should eq(200)
      JSON.parse(es.body)["greeting"].as_s.should eq("¡Bienvenido, Ada!")

      feed = app.get("/?locale=es")
      feed.body.should contain("Últimas publicaciones")

      header_es = app.get("/lite_health", HTTP::Headers{"Accept-Language" => "es"})
      JSON.parse(header_es.body)["greeting"].as_s.should eq("¡Bienvenido, dev!")
    end
  end

  it "tracks page views in the analytics database (multidb isolation)" do
    Saci::TestSession.serve(forem_lite_router) do |app|
      article = LiteArticle.first.not_nil!
      app.get("/lite_articles/#{article.id}?ip=10.0.0.7")
      LitePageView.count.should eq(1)
      view = LitePageView.first.not_nil!
      view.article_id.should eq(article.id)
      view.ip.should eq("10.0.0.7")
      # The primary database never sees the analytics table.
      Saci::Record.database("primary").scalar(
        "SELECT COUNT(*) FROM sqlite_master WHERE name = 'lite_page_views'").should eq(0)
    end
  end

  it "maps associations across users, articles and comments" do
    alice = LiteUser.find_by(username: "alice").not_nil!
    article = LiteArticle.first.not_nil!
    article.user.not_nil!.username.should eq("alice")
    alice.articles.count.should eq(1)
    LiteComment.create!(article_id: article.id, user_id: alice.id, body: "nice")
    article.comments.count.should eq(1)
    article.comments.first.not_nil!.body.should eq("nice")
  end

  it "rolls back multi-record transactions" do
    alice = LiteUser.first.not_nil!
    Saci::Record.transaction do |_conn|
      LiteArticle.create!(title: "doomed tx article", body: "will roll back", user_id: alice.id)
      raise DB::Rollback.new
    end
    LiteArticle.where(title: "doomed tx article").exists?.should be_false
    LiteArticle.count.should eq(1)
  end

  it "tags requests and filters secrets from logs" do
    Saci.filter_params({"username" => "alice", "password" => "hunter2"}).should eq(
      {"username" => "alice", "password" => "[FILTERED]"})
    Saci.tagged("validation") do
      Saci.current_tags.should eq(["validation"])
    end
    Saci::TestSession.serve(forem_lite_router) do |app|
      app.get("/lite_health").headers["X-Request-Id"]?.should_not be_nil
    end
  end

  it "encrypts secrets and round-trips credentials" do
    key = Bytes.new(32)
    Random::Secure.random_bytes(key)
    envelope = Saci::MessageEncryptor.encrypt_and_sign(key, "sekret".to_slice)
    String.new(Saci::MessageEncryptor.decrypt_and_verify(key, envelope)).should eq("sekret")
    parts = envelope.split("--")
    tampered = parts.dup
    tail = tampered[1]
    tampered[1] = tail[0...-2] + (tail[-2..] == "AA" ? "BB" : "AA")
    expect_raises(Exception) { Saci::MessageEncryptor.decrypt_and_verify(key, tampered.join("--")) }

    dir = "/tmp/opencode/forem_lite_creds"
    Dir.mkdir_p(dir)
    key_path = File.join(dir, "master.key")
    file_path = File.join(dir, "credentials.yml.enc")
    File.write(key_path, Saci::Credentials.generate_key + "\n")
    old_key_path = Saci::Credentials.key_path
    Saci::Credentials.key_path = key_path
    begin
      Saci::Credentials.write({"mailer_api_key" => YAML::Any.new("sekret-123")}, file_path)
      Saci::Credentials.dig("mailer_api_key", file_path).should eq("sekret-123")
      Saci::Credentials.dig("missing", file_path).should be_nil
    ensure
      Saci::Credentials.key_path = old_key_path
    end
  end

  it "reads environments" do
    old = ENV["APP_ENV"]?
    begin
      ENV.delete("APP_ENV")
      Saci.env.should eq("development")
      Saci.development?.should be_true
      ENV["APP_ENV"] = "production"
      Saci.env.should eq("production")
      Saci.production?.should be_true
      Saci.test?.should be_false
    ensure
      if v = old
        ENV["APP_ENV"] = v
      else
        ENV.delete("APP_ENV")
      end
    end
  end
end
