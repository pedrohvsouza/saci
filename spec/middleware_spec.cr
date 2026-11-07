require "spec"
require "http/client"
require "compress/gzip"
require "../src/saci"

# -- shared test fixtures ----------------------------------------------------

class MiddlewareDemoController < Saci::Controller
  def index
    render json: {ok: true}
  end

  def big
    render text: "compress me " * 200
  end

  def explode
    raise "middleware boom"
  end
end

class MiddlewareEchoController < Saci::Controller
  def remote
    address = context.remote_address
    if ip = address.as?(Socket::IPAddress)
      render json: {remote: ip.address}
    else
      render json: {remote: address.try(&.to_s)}
    end
  end
end

# Records the order middleware ran in through a response header.
class MiddlewareRecorder
  include HTTP::Handler

  def initialize(@label : String)
  end

  def call(context : HTTP::Server::Context) : Nil
    existing = context.response.headers["X-Chain"]?
    context.response.headers["X-Chain"] = existing ? "#{existing},#{@label}" : @label
    call_next(context)
  end
end

# Class-based middleware with a named-argument constructor, exercised through
# `stack.use MiddlewareTag, tag: "x"`.
class MiddlewareTag
  include HTTP::Handler

  def initialize(@tag : String)
  end

  def call(context : HTTP::Server::Context) : Nil
    context.response.headers["X-Tag"] = @tag
    call_next(context)
  end
end

# Class-based middleware with an options-hash constructor.
class MiddlewareHashOptions
  include HTTP::Handler

  @tag : String

  def initialize(options : Hash(Symbol, String))
    @tag = options[:tag]
  end

  def call(context : HTTP::Server::Context) : Nil
    context.response.headers["X-Hash"] = @tag
    call_next(context)
  end
end

class MiddlewareTerminal
  include HTTP::Handler

  def call(context : HTTP::Server::Context) : Nil
    context.response.print("terminal")
  end
end

def middleware_router : Saci::Router
  Saci::Router.new.draw do |r|
    r.get "/demo", MiddlewareDemoController, :index
    r.post "/demo", MiddlewareDemoController, :index
    r.get "/big", MiddlewareDemoController, :big
    r.get "/boom", MiddlewareDemoController, :explode
    r.get "/remote", MiddlewareEchoController, :remote
    r.get("/ip") do |ctx, _params|
      address = ctx.remote_address
      if ip = address.as?(Socket::IPAddress)
        ctx.response.print(ip.address)
      else
        ctx.response.print(address.try(&.to_s) || "")
      end
    end
  end
end

def chain_classes(handler : HTTP::Handler) : Array(String)
  classes = [] of String
  current : HTTP::Handler? = handler
  while current
    classes << current.class.name
    following = current.next
    current = following.is_a?(HTTP::Handler) ? following : nil
  end
  classes
end

def middleware_cors_config : Saci::Configuration
  config = Saci::Configuration.new
  config.cors do |cors|
    cors.allowed_origins = ["https://app.example.com", "https://*.example.org"]
    cors.allowed_methods = ["GET", "POST", "PATCH"]
    cors.allowed_headers = ["Content-Type", "Authorization"]
    cors.exposed_headers = ["X-Request-Id"]
    cors.credentials = true
    cors.max_age = 600
  end
  config
end

def middleware_static_config(root : String) : Saci::Configuration
  config = Saci::Configuration.new
  config.public_file_server.enabled = true
  config.public_file_server.root = root
  config.public_file_server.cache_control = "public, max-age=60"
  config
end

def middleware_compression_config : Saci::Configuration
  config = Saci::Configuration.new
  config.compression.enabled = true
  config.compression.min_size = 32
  config
end

def with_env(name : String, value : String?, &)
  previous = ENV[name]?
  if value
    ENV[name] = value
  else
    ENV.delete(name)
  end
  begin
    yield
  ensure
    if previous
      ENV[name] = previous
    else
      ENV.delete(name)
    end
  end
end

def with_force_ssl(value : Bool, &)
  previous = Saci.force_ssl
  Saci.force_ssl = value
  begin
    yield
  ensure
    Saci.force_ssl = previous
  end
end

# -- middleware stack --------------------------------------------------------

describe Saci::Middleware::Stack do
  it "appends instances and class+options middleware" do
    stack = Saci::Middleware::Stack.new
    stack.use(MiddlewareRecorder.new("one"))
    stack.use(MiddlewareTag, tag: "two")
    stack.use(MiddlewareHashOptions, {:tag => "three"})
    stack.size.should eq(3)
    stack.entries[1].should be_a(MiddlewareTag)
    stack.entries[2].should be_a(MiddlewareHashOptions)
  end

  it "inserts before/after, swaps and deletes by class" do
    first = MiddlewareRecorder.new("first")
    second = MiddlewareRecorder.new("second")
    stack = Saci::Middleware::Stack.new([first.as(HTTP::Handler), second.as(HTTP::Handler)])

    inserted = MiddlewareRecorder.new("inserted")
    stack.insert_before(MiddlewareRecorder, inserted)
    stack.entries.first.should be(inserted)

    tail = MiddlewareRecorder.new("tail")
    stack.insert_after(MiddlewareRecorder, tail)
    stack.entries.index { |entry| entry.same?(tail) }.not_nil!.should eq(1)

    replacement = MiddlewareTag.new("swapped")
    stack.swap(MiddlewareRecorder, replacement)
    stack.entries[0].should be(replacement)

    deleted = stack.delete(MiddlewareTag)
    deleted.should_not be_nil
    stack.delete(MiddlewareTag).should be_nil
  end

  it "raises when the target is absent" do
    stack = Saci::Middleware::Stack.new
    expect_raises(ArgumentError) { stack.insert_before(MiddlewareTag, MiddlewareRecorder.new("x")) }
  end

  it "builds a linked chain ending in the terminal" do
    stack = Saci::Middleware::Stack.new
    stack.use(MiddlewareRecorder.new("a"))
    stack.use(MiddlewareTag, tag: "b")
    built = stack.build(MiddlewareTerminal.new)
    chain_classes(built).should eq([
      "MiddlewareRecorder", "MiddlewareTag", "MiddlewareTerminal",
    ])
  end

  it "skips disabled built-ins without removing them from the stack" do
    config = Saci::Configuration.new
    config.hosts = [] of String
    stack = config.middleware
    stack.build(MiddlewareTerminal.new, skip_disabled: true)
    # HostAuthorization stays a valid insertion target even while disabled.
    stack.insert_before(Saci::Middleware::HostAuthorization, MiddlewareRecorder.new("host-check"))
    stack.entries.any? { |entry| entry.is_a?(Saci::Middleware::HostAuthorization) }.should be_true
  end
end

describe "Saci::Application middleware integration" do
  it "keeps the websocket handler first and the router handler last" do
    handlers = Saci::Application.handlers(middleware_router)
    handlers.first.should be_a(HTTP::WebSocketHandler)
    handlers.last.should be_a(Saci::Handler)
  end

  it "runs custom middleware in registration order before the router" do
    config = Saci::Configuration.new
    config.middleware.use(MiddlewareRecorder.new("one"))
    config.middleware.use(MiddlewareRecorder.new("two"))
    config.middleware.use(MiddlewareTag, tag: "three")

    Saci::TestSession.serve(middleware_router, config: config) do |app|
      response = app.get("/demo")
      response.status_code.should eq(200)
      response.headers["X-Chain"].should eq("one,two")
      response.headers["X-Tag"].should eq("three")
    end
  end

  it "supports insert_before/swap against the built-in stack" do
    config = Saci::Configuration.new
    config.middleware.insert_before(Saci::Middleware::HealthCheck, MiddlewareRecorder.new("before-health"))
    config.middleware.swap(Saci::Middleware::Compression, MiddlewareTag.new("replaced-compression"))

    Saci::TestSession.serve(middleware_router, config: config) do |app|
      response = app.get("/demo")
      response.status_code.should eq(200)
      response.headers["X-Chain"].should eq("before-health")
      response.headers["X-Tag"].should eq("replaced-compression")
    end
  end

  it "back-compat: Application.handlers(router) still builds a working server" do
    handlers = Saci::Application.handlers(middleware_router)
    server = HTTP::Server.new(handlers)
    port = server.bind_tcp("127.0.0.1", 0).port
    spawn { server.listen }
    sleep 0.05.seconds
    begin
      response = HTTP::Client.get("http://127.0.0.1:#{port}/demo")
      response.status_code.should eq(200)
    ensure
      server.close
    end
  end
end

# -- CORS --------------------------------------------------------------------

describe Saci::Middleware::CORS do
  it "answers allowed preflights with 204 and the negotiated headers" do
    Saci::TestSession.serve(middleware_router, config: middleware_cors_config) do |app|
      headers = HTTP::Headers{
        "Origin"                        => "https://app.example.com",
        "Access-Control-Request-Method" => "PATCH",
        "Access-Control-Request-Headers" => "Content-Type, Authorization",
      }
      response = app.options("/demo", headers)
      response.status_code.should eq(204)
      response.headers["Access-Control-Allow-Origin"].should eq("https://app.example.com")
      response.headers["Access-Control-Allow-Methods"].should contain("PATCH")
      response.headers["Access-Control-Allow-Headers"].should eq("Content-Type, Authorization")
      response.headers["Access-Control-Allow-Credentials"].should eq("true")
      response.headers["Access-Control-Max-Age"].should eq("600")
      response.headers["Vary"].should contain("Origin")
    end
  end

  it "adds CORS headers to actual requests and exposes configured headers" do
    Saci::TestSession.serve(middleware_router, config: middleware_cors_config) do |app|
      response = app.get("/demo", HTTP::Headers{"Origin" => "https://app.example.com"})
      response.status_code.should eq(200)
      response.headers["Access-Control-Allow-Origin"].should eq("https://app.example.com")
      response.headers["Access-Control-Expose-Headers"].should eq("X-Request-Id")
      response.headers["Vary"].should contain("Origin")
    end
  end

  it "matches wildcard subdomains" do
    Saci::TestSession.serve(middleware_router, config: middleware_cors_config) do |app|
      allowed = app.get("/demo", HTTP::Headers{"Origin" => "https://api.example.org"})
      allowed.headers["Access-Control-Allow-Origin"].should eq("https://api.example.org")

      apex = app.get("/demo", HTTP::Headers{"Origin" => "https://example.org"})
      apex.headers["Access-Control-Allow-Origin"]?.should be_nil
    end
  end

  it "rejects disallowed preflights and leaves disallowed actual requests alone" do
    Saci::TestSession.serve(middleware_router, config: middleware_cors_config) do |app|
      preflight = app.options("/demo", HTTP::Headers{
        "Origin"                        => "https://evil.example",
        "Access-Control-Request-Method" => "GET",
      })
      preflight.status_code.should eq(403)
      preflight.headers["Access-Control-Allow-Origin"]?.should be_nil

      actual = app.get("/demo", HTTP::Headers{"Origin" => "https://evil.example"})
      actual.status_code.should eq(200)
      actual.headers["Access-Control-Allow-Origin"]?.should be_nil
    end
  end

  it "echoes the origin instead of * when credentials are enabled for a * allowlist" do
    config = Saci::Configuration.new
    config.cors do |cors|
      cors.allowed_origins = ["*"]
      cors.credentials = true
    end

    Saci::TestSession.serve(middleware_router, config: config) do |app|
      response = app.get("/demo", HTTP::Headers{"Origin" => "https://anything.example"})
      response.headers["Access-Control-Allow-Origin"].should eq("https://anything.example")
    end
  end
end

# -- host authorization ------------------------------------------------------

describe Saci::Middleware::HostAuthorization do
  it "allows listed hosts and rejects others with 403" do
    config = Saci::Configuration.new
    config.hosts = ["example.com"]

    Saci::TestSession.serve(middleware_router, config: config) do |app|
      allowed = app.get("/demo", HTTP::Headers{"Host" => "example.com"})
      allowed.status_code.should eq(200)

      blocked = app.get("/demo", HTTP::Headers{"Host" => "evil.example"})
      blocked.status_code.should eq(403)
      blocked.body.should contain("Blocked host")
    end
  end

  it "handles ports, wildcards, localhost and IPv6 entries" do
    middleware = Saci::Middleware::HostAuthorization.new(["example.com:3000", "*.example.org", "localhost"])
    middleware.allowed?("example.com:3000").should be_true
    middleware.allowed?("example.com:4000").should be_false
    middleware.allowed?("api.example.org").should be_true
    middleware.allowed?("example.org").should be_false
    middleware.allowed?("localhost:9999").should be_true
    middleware.allowed?("127.0.0.1").should be_true
    middleware.allowed?("::1").should be_true

    ipv6 = Saci::Middleware::HostAuthorization.new(["[::1]:8080"])
    ipv6.allowed?("[::1]:8080").should be_true
    ipv6.allowed?("[::1]:9090").should be_false
  end

  it "can be disabled while hosts are configured" do
    config = Saci::Configuration.new
    config.hosts = ["example.com"]
    config.host_authorization = false

    Saci::TestSession.serve(middleware_router, config: config) do |app|
      app.get("/demo", HTTP::Headers{"Host" => "evil.example"}).status_code.should eq(200)
    end
  end
end

# -- remote ip ---------------------------------------------------------------

describe Saci::Middleware::RemoteIp do
  it "resolves the client from X-Forwarded-For behind a trusted proxy" do
    config = Saci::Configuration.new
    config.trusted_proxies = ["127.0.0.0/8"]

    Saci::TestSession.serve(middleware_router, config: config) do |app|
      response = app.get("/ip", HTTP::Headers{"X-Forwarded-For" => "203.0.113.5, 127.0.0.1"})
      response.body.should eq("203.0.113.5")
    end
  end

  it "ignores X-Forwarded-For when the peer is not trusted" do
    config = Saci::Configuration.new
    config.trusted_proxies = ["10.0.0.0/8"]

    Saci::TestSession.serve(middleware_router, config: config) do |app|
      response = app.get("/ip", HTTP::Headers{"X-Forwarded-For" => "203.0.113.5"})
      response.body.should eq("127.0.0.1")
    end
  end

  it "ignores a malformed forwarded chain rather than guessing" do
    config = Saci::Configuration.new
    config.trusted_proxies = ["127.0.0.1"]

    Saci::TestSession.serve(middleware_router, config: config) do |app|
      response = app.get("/ip", HTTP::Headers{"X-Forwarded-For" => "not-an-ip, 127.0.0.1"})
      response.body.should eq("127.0.0.1")
    end
  end

  it "parses CIDR and exact trusted-proxy entries" do
    Saci::Middleware::Net.trusted_proxy?("10.1.2.3", ["10.0.0.0/8"]).should be_true
    Saci::Middleware::Net.trusted_proxy?("11.1.2.3", ["10.0.0.0/8"]).should be_false
    Saci::Middleware::Net.trusted_proxy?("::1", ["::1/128"]).should be_true
    Saci::Middleware::Net.trusted_proxy?("2001:db8::1", ["2001:db8::/32"]).should be_true
    Saci::Middleware::Net.trusted_proxy?("2001:db9::1", ["2001:db8::/32"]).should be_false
  end
end

# -- static files ------------------------------------------------------------

describe Saci::Middleware::Static do
  static_dir = File.join(Dir.tempdir, "saci-static-spec-#{Random::Secure.hex(4)}")
  Dir.mkdir_p(File.join(static_dir, "nested"))
  File.write(File.join(static_dir, "app.css"), "body { color: red; }")
  File.write(File.join(static_dir, "index.html"), "<h1>index</h1>")
  File.write(File.join(static_dir, "nested", "inner.txt"), "inner")
  File.write(File.join(static_dir, ".env"), "SECRET=1")

  it "serves files with validators and cache headers" do
    Saci::TestSession.serve(middleware_router, config: middleware_static_config(static_dir)) do |app|
      response = app.get("/app.css")
      response.status_code.should eq(200)
      response.body.should eq("body { color: red; }")
      response.headers["Content-Type"].should contain("text/css")
      response.headers["Cache-Control"].should eq("public, max-age=60")
      response.headers["ETag"].should_not be_nil
      response.headers["Last-Modified"].should_not be_nil
    end
  end

  it "re-reads the root's entries on every request when entry_cache_ttl is zero" do
    root = File.join(Dir.tempdir, "saci-static-ttl-#{Random::Secure.hex(4)}")
    Dir.mkdir_p(root)
    File.write(File.join(root, "a.txt"), "a")
    fresh = Saci::Middleware::Static.new(root)
    fresh.settings.entry_cache_ttl = Time::Span.zero
    fresh.enabled?.should be_true # populates the entry set without b.txt
    File.write(File.join(root, "b.txt"), "b")
    io = IO::Memory.new
    response = HTTP::Server::Response.new(io)
    fresh.call(HTTP::Server::Context.new(HTTP::Request.new("GET", "/b.txt"), response))
    response.close
    io.to_s.should contain("200 OK")
  ensure
    FileUtils.rm_rf(root.not_nil!) if root
  end

  it "answers If-None-Match and If-Modified-Since with 304" do
    Saci::TestSession.serve(middleware_router, config: middleware_static_config(static_dir)) do |app|
      first = app.get("/app.css")
      etag = first.headers["ETag"]

      cached = app.get("/app.css", HTTP::Headers{"If-None-Match" => etag})
      cached.status_code.should eq(304)
      cached.body.should be_empty

      modified = app.get("/app.css", HTTP::Headers{"If-Modified-Since" => HTTP.format_time(Time.utc + 1.hour)})
      modified.status_code.should eq(304)
    end
  end

  it "supports HEAD requests" do
    Saci::TestSession.serve(middleware_router, config: middleware_static_config(static_dir)) do |app|
      response = app.head("/app.css")
      response.status_code.should eq(200)
      response.body.should be_empty
      response.headers["Content-Length"].should eq(File.size(File.join(static_dir, "app.css")).to_s)
    end
  end

  it "serves directory index files but not dotfiles" do
    Saci::TestSession.serve(middleware_router, config: middleware_static_config(static_dir)) do |app|
      root = app.get("/")
      root.status_code.should eq(200)
      root.body.should contain("index")

      dotfile = app.get("/.env")
      dotfile.status_code.should eq(404)

      nested = app.get("/nested/inner.txt")
      nested.status_code.should eq(200)
      nested.body.should eq("inner")
    end
  end

  it "rejects traversal attempts including encoded dots" do
    Saci::TestSession.serve(middleware_router, config: middleware_static_config(static_dir)) do |app|
      app.get("/%2e%2e/app.css").status_code.should eq(404)
      app.get("/nested/%2e%2e/%2e%2e/app.css").status_code.should eq(404)
      app.get("/%252e%252e/app.css").status_code.should eq(404)
    end
  end

  it "falls through to the router for missing files" do
    Saci::TestSession.serve(middleware_router, config: middleware_static_config(static_dir)) do |app|
      response = app.get("/missing.css")
      response.status_code.should eq(404)
      response.headers["Content-Type"].should contain("application/json")
    end
  end
end

# -- compression -------------------------------------------------------------

describe Saci::Middleware::Compression do
  it "gzips large compressible responses with the right headers" do
    Saci::TestSession.serve(middleware_router, config: middleware_compression_config) do |app|
      response = app.get("/big", HTTP::Headers{"Accept-Encoding" => "gzip"})
      response.status_code.should eq(200)
      response.headers["Content-Encoding"].should eq("gzip")
      response.headers["Vary"].should contain("Accept-Encoding")

      decompressed = Compress::Gzip::Reader.open(IO::Memory.new(response.body.to_slice)) do |gzip|
        gzip.gets_to_end
      end
      decompressed.should eq("compress me " * 200)
    end
  end

  it "does not compress small responses or clients without gzip support" do
    Saci::TestSession.serve(middleware_router, config: middleware_compression_config) do |app|
      no_gzip = app.get("/big", HTTP::Headers{"Accept-Encoding" => "identity"})
      no_gzip.headers["Content-Encoding"]?.should be_nil
      no_gzip.body.should eq("compress me " * 200)

      small = app.get("/demo", HTTP::Headers{"Accept-Encoding" => "gzip"})
      small.headers["Content-Encoding"]?.should be_nil
    end
  end

  it "honors q=0 and never double-compresses" do
    Saci::TestSession.serve(middleware_router, config: middleware_compression_config) do |app|
      rejected = app.get("/big", HTTP::Headers{"Accept-Encoding" => "gzip;q=0"})
      rejected.headers["Content-Encoding"]?.should be_nil
    end
  end
end

# -- health endpoint ---------------------------------------------------------

describe Saci::Middleware::HealthCheck do
  it "serves /up by default without an app route" do
    Saci::TestSession.serve(middleware_router, config: Saci::Configuration.new) do |app|
      response = app.get("/up")
      response.status_code.should eq(200)
      response.body.should eq("OK")
      response.headers["Content-Type"].should contain("text/plain")

      head = app.head("/up")
      head.status_code.should eq(200)
      head.body.should be_empty
    end
  end

  it "honors a custom path and can be disabled" do
    config = Saci::Configuration.new
    config.healthcheck_path = "/healthz"
    Saci::TestSession.serve(middleware_router, config: config) do |app|
      app.get("/up").status_code.should eq(404)
      app.get("/healthz").status_code.should eq(200)
    end

    disabled = Saci::Configuration.new
    disabled.healthcheck_path = nil
    Saci::TestSession.serve(middleware_router, config: disabled) do |app|
      app.get("/up").status_code.should eq(404)
    end
  end
end

# -- request body limit ------------------------------------------------------

describe Saci::Middleware::RequestBodyLimit do
  it "rejects oversized bodies with 413 and passes small ones through" do
    config = Saci::Configuration.new
    config.max_request_body = 100

    Saci::TestSession.serve(middleware_router, config: config) do |app|
      small = app.post("/demo", HTTP::Headers{"Content-Type" => "application/json"}, %({"x":"1"}))
      small.status_code.should eq(200)

      oversized = app.post("/demo", HTTP::Headers{"Content-Type" => "application/json"}, "x" * 200)
      oversized.status_code.should eq(413)
      oversized.body.should contain("Request Entity Too Large")
    end
  end

  it "leaves requests unlimited when max_request_body is nil" do
    Saci::TestSession.serve(middleware_router, config: Saci::Configuration.new) do |app|
      app.post("/demo", HTTP::Headers{"Content-Type" => "application/json"}, "x" * 5000).status_code.should eq(200)
    end
  end
end

# -- initializers lifecycle --------------------------------------------------

describe Saci::Initializers do
  it "runs before_configuration, to_prepare and after_initialize once" do
    Saci::Initializers.reset!
    order = [] of String
    Saci::Initializers.before_configuration { order << "before" }
    Saci::Initializers.to_prepare { order << "prepare" }
    Saci::Initializers.after_initialize { order << "after" }

    application = Saci::Application.new(middleware_router, Saci::Configuration.new)
    application.boot
    order.should eq(["before", "prepare", "after"])

    application.boot
    order.should eq(["before", "prepare", "after"])
  end

  it "re-runs to_prepare on reload and is idempotent" do
    Saci::Initializers.reset!
    counter = 0
    Saci::Initializers.to_prepare { counter += 1 }

    Saci::Initializers.run!
    counter.should eq(1)
    Saci::Initializers.run_to_prepare!
    counter.should eq(2)
    Saci::Initializers.run_to_prepare!
    counter.should eq(3)
  ensure
    Saci::Initializers.reset!
  end

  it "boots through TestSession" do
    Saci::Initializers.reset!
    booted = false
    Saci::Initializers.after_initialize { booted = true }

    Saci::TestSession.serve(middleware_router, config: Saci::Configuration.new) do |app|
      app.get("/demo").status_code.should eq(200)
    end
    booted.should be_true
  ensure
    Saci::Initializers.reset!
  end
end

# -- configuration object ----------------------------------------------------

describe Saci::Configuration do
  it "has safe defaults" do
    config = Saci::Configuration.new
    config.hosts.should be_empty
    config.trusted_proxies.should be_empty
    config.assume_ssl.should be_false
    config.healthcheck_path.should eq("/up")
    config.max_request_body.should be_nil
    config.cors.enabled?.should be_false
    config.compression.enabled.should be_false
    config.public_file_server.root.should eq("public")
    config.default_error_pages.should be_true
    config.exceptions_app.should be_nil
    config.middleware.entries.any? { |entry| entry.is_a?(Saci::Middleware::CORS) }.should be_true
  end

  it "delegates the historical module-level setters" do
    previous = Saci.force_ssl
    begin
      Saci.force_ssl = true
      Saci.config.force_ssl.should be_true
      Saci.config.force_ssl = false
      Saci.force_ssl.should be_false
      Saci.config.log_level.should eq(Saci.log_level)
    ensure
      Saci.force_ssl = previous
    end
  end

  it "supports block configuration helpers" do
    config = Saci::Configuration.new
    config.cors { |cors| cors.allowed_origins = ["https://one.example"] }
    config.public_file_server { |server| server.root = "public" }
    config.compression { |compression| compression.enabled = true }
    config.ssl { |ssl| ssl.hsts_max_age = 60 }

    config.cors.allowed_origins.should eq(["https://one.example"])
    config.compression.enabled.should be_true
    config.ssl_options.hsts_max_age.should eq(60)
  end

  it "Saci.configure yields the global config" do
    previous_hosts = Saci.config.hosts
    begin
      Saci.configure { |config| config.hosts = ["configured.example"] }
      Saci.config.hosts.should eq(["configured.example"])
      Saci.hosts.should eq(["configured.example"])
      Saci.middleware.should be(Saci.config.middleware)
    ensure
      Saci.config.hosts = previous_hosts
    end
  end
end

# -- exceptions app + error reporting ---------------------------------------

describe "exceptions app and error reporting" do
  it "applies a custom exceptions_app to error responses" do
    config = Saci::Configuration.new
    config.exceptions_app = Saci::Exceptions::App.new do |context, status, exception|
      detail = exception.try(&.message) || "none"
      Saci::Middleware.respond_text(context.response, status, "custom error #{status} #{detail}")
    end

    Saci::TestSession.serve(middleware_router, config: config) do |app|
      missing = app.get("/missing")
      missing.status_code.should eq(404)
      missing.body.should eq("custom error 404 none")

      boom = app.get("/boom")
      boom.status_code.should eq(500)
      boom.body.should eq("custom error 500 middleware boom")
    end
  end

  it "renders the built-in production pages in production" do
    with_env("APP_ENV", "production") do
      Saci::TestSession.serve(middleware_router, config: Saci::Configuration.new) do |app|
        html = app.get("/missing", HTTP::Headers{"Accept" => "text/html"})
        html.status_code.should eq(404)
        html.headers["Content-Type"].should contain("text/html")
        html.body.should contain("404 Not Found")

        text = app.get("/missing", HTTP::Headers{"Accept" => "application/json"})
        text.status_code.should eq(404)
        text.body.should eq("404 Not Found\n")
      end
    end
  end

  it "keeps the router's dev error handling when no exceptions app is set" do
    with_env("APP_ENV", "development") do
      Saci::TestSession.serve(middleware_router, config: Saci::Configuration.new) do |app|
        missing = app.get("/missing")
        missing.status_code.should eq(404)
        missing.headers["Content-Type"].should contain("application/json")
      end
    end
  end

  it "calls Saci.report_error for unhandled server errors" do
    seen = [] of String
    previous = Saci.error_reporter
    Saci.error_reporter = ->(exception : Exception) { seen << exception.message.to_s }
    begin
      Saci::TestSession.serve(middleware_router, config: Saci::Configuration.new) do |app|
        app.get("/boom").status_code.should eq(500)
      end
      seen.should eq(["middleware boom"])
    ensure
      Saci.error_reporter = previous
    end
  end
end

# -- SSL / assume_ssl --------------------------------------------------------

describe Saci::Middleware::SSL do
  it "adds HSTS on secure responses when force_ssl is on" do
    with_force_ssl(true) do
      config = Saci::Configuration.new
      Saci::TestSession.serve(middleware_router, config: config) do |app|
        response = app.get("/demo", HTTP::Headers{
          "Host"              => "example.com",
          "X-Forwarded-Proto" => "https",
        })
        response.status_code.should eq(200)
        response.headers["Strict-Transport-Security"].should contain("max-age=31536000")

        redirect = app.get("/demo", HTTP::Headers{"Host" => "example.com"})
        redirect.status_code.should eq(301)
      end
    end
  end

  it "assume_ssl treats plain requests as secure without redirecting" do
    with_force_ssl(false) do
      config = Saci::Configuration.new
      config.assume_ssl = true
      Saci::TestSession.serve(middleware_router, config: config) do |app|
        response = app.get("/demo", HTTP::Headers{"Host" => "example.com"})
        response.status_code.should eq(200)
        response.headers["Strict-Transport-Security"].should_not be_nil
      end
    end
  end
end
