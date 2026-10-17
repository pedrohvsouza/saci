require "spec"
require "../src/saci"

class ThrottleDemoController < Saci::Controller
  def index
    render text: "ok"
  end
end

def throttle_router : Saci::Router
  Saci::Router.new.draw do |r|
    r.get "/limited", ThrottleDemoController, :index
    r.get "/open", ThrottleDemoController, :index
  end
end

describe Saci::Throttle do
  before_each do
    Saci::Throttle.reset!
    Saci::Throttle.throttle("demo/ip", limit: 2, period: 60.seconds) do |ctx|
      ctx.request.path == "/limited" ? Saci::Throttle.client_ip(ctx) : nil
    end
  end

  after_each do
    Saci::Throttle.reset!
  end

  it "allows under the limit and throttles above it" do
    Saci::TestSession.serve(throttle_router) do |app|
      app.get("/limited").status_code.should eq(200)
      app.get("/limited").status_code.should eq(200)
      third = app.get("/limited")
      third.status_code.should eq(429)
      third.headers["Retry-After"]?.should_not be_nil
      JSON.parse(third.body)["error"].as_s.should contain("Too many")
    end
  end

  it "skips routes the discriminator ignores" do
    Saci::TestSession.serve(throttle_router) do |app|
      4.times { app.get("/open").status_code.should eq(200) }
    end
  end

  it "honors safelists" do
    Saci::Throttle.safelist { |ctx| Saci::Throttle.client_ip(ctx) == "127.0.0.1" }
    Saci::TestSession.serve(throttle_router) do |app|
      4.times { app.get("/limited").status_code.should eq(200) }
    end
  end

  it "blocks blocklisted requests with 403" do
    Saci::Throttle.blocklist { |ctx| (ctx.request.path || "") == "/limited" }
    Saci::TestSession.serve(throttle_router) do |app|
      app.get("/limited").status_code.should eq(403)
      app.get("/open").status_code.should eq(200)
    end
  end

  it "resets windows after the period" do
    Saci::Throttle.reset!
    Saci::Throttle.throttle("fast/ip", limit: 1, period: 1.second) do |ctx|
      ctx.request.path == "/limited" ? "k" : nil
    end
    Saci::TestSession.serve(throttle_router) do |app|
      app.get("/limited").status_code.should eq(200)
      app.get("/limited").status_code.should eq(429)
      sleep 1.1.seconds
      app.get("/limited").status_code.should eq(200)
    end
  end

  it "multi enforces the tightest window" do
    Saci::Throttle.reset!
    Saci::Throttle.multi("stacked", windows: [
      {limit: 5, period: 60.seconds},
      {limit: 2, period: 60.seconds},
    ]) do |ctx|
      ctx.request.path == "/limited" ? Saci::Throttle.client_ip(ctx) : nil
    end
    Saci::TestSession.serve(throttle_router) do |app|
      app.get("/limited").status_code.should eq(200)
      app.get("/limited").status_code.should eq(200)
      third = app.get("/limited")
      third.status_code.should eq(429)
      third.headers["Retry-After"]?.should_not be_nil
    end
  end

  it "multi isolates each window (1s vs 1m)" do
    Saci::Throttle.reset!
    Saci::Throttle.multi("mixed", windows: [
      {limit: 1, period: 1.second},
      {limit: 10, period: 60.seconds},
    ]) do |ctx|
      ctx.request.path == "/limited" ? "k" : nil
    end
    Saci::TestSession.serve(throttle_router) do |app|
      app.get("/limited").status_code.should eq(200)
      app.get("/limited").status_code.should eq(429)
      sleep 1.1.seconds
      app.get("/limited").status_code.should eq(200)
    end
  end

  it "throttle_login only counts POST /login*" do
    Saci::Throttle.reset!
    Saci::Throttle.throttle_login(limit: 1, period: 60.seconds)
    Saci::TestSession.serve(throttle_router) do |app|
      # non-login paths are ignored by the discriminator
      2.times { app.get("/limited").status_code.should eq(200) }
      2.times { app.get("/open").status_code.should eq(200) }
    end

    Saci::Throttle.reset!
    Saci::Throttle.throttle_login(limit: 1, period: 60.seconds)
    router = Saci::Router.new.draw do |r|
      r.post "/login", ThrottleDemoController, :index
      r.get "/open", ThrottleDemoController, :index
    end
    Saci::TestSession.serve(router) do |app|
      app.post("/login", HTTP::Headers.new, "").status_code.should eq(200)
      over = app.post("/login", HTTP::Headers.new, "")
      over.status_code.should eq(429)
      over.headers["Retry-After"]?.should_not be_nil
      # GETs still pass under a login-only throttle
      app.get("/open").status_code.should eq(200)
    end
  end
end

# ---------------------------------------------------------------------------
# Redis store (Saci::Throttle::RedisStore).
#
# Same dependency story as Cable (see cable_spec.cr): no shard dep, the
# vendored pure-socket `Saci::Cable::RedisWire` client is reused, default
# builds link unchanged. `Throttle.store` defaults to the in-process
# `MemoryStore`; swap in `RedisStore` to share fixed windows across
# processes. Live specs gate on `REDIS_URL`; degradation is fail-open
# (allow + STDERR warning), spec-pinned below.
# ---------------------------------------------------------------------------

# Minimal in-spec Redis stand-in for the throttle path: PING / AUTH /
# SELECT plus the atomic INCR+EXPIRE Lua step (EVAL) and DEL for resets.
class FakeThrottleRedis
  getter port : Int32

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.local_address.as(Socket::IPAddress).port
    @data = {} of String => Int64
    @mutex = Mutex.new
    @io_mutex = Mutex.new
    @closed = false
    spawn { accept_loop }
  end

  def url : String
    "redis://127.0.0.1:#{@port}"
  end

  def close : Nil
    @closed = true
    begin
      @server.close
    rescue
    end
  end

  private def accept_loop : Nil
    loop do
      begin
        sock = @server.accept?
      rescue
        break
      end
      break if sock.nil? || @closed
      spawn { handle(sock) }
    end
  end

  private def read_args(sock : TCPSocket) : Array(String)?
    line = sock.gets
    return nil if line.nil?
    line = line.chomp
    return nil unless line.starts_with?("*")
    n = line[1..].to_i? || return nil
    args = [] of String
    n.times do
      hdr = sock.gets.try(&.chomp) || return nil
      return nil unless hdr.starts_with?("$")
      len = hdr[1..].to_i? || return nil
      buf = Bytes.new(len + 2)
      begin
        sock.read_fully(buf)
      rescue
        return nil
      end
      args << String.new(buf[0, len])
    end
    args
  rescue
    nil
  end

  private def emit(sock : TCPSocket, frame : String) : Nil
    @io_mutex.synchronize { sock.write(frame.to_slice) }
  rescue
  end

  private def handle(sock : TCPSocket) : Nil
    loop do
      args = read_args(sock)
      break if args.nil? || args.empty?
      case args[0].upcase
      when "PING"
        emit(sock, "+PONG\r\n")
      when "AUTH", "SELECT"
        emit(sock, "+OK\r\n")
      when "EVAL"
        # ["EVAL", script, "1", key, ttl] — atomic INCR (+EXPIRE on first
        # hit, matching the Lua script's contract; the fake ignores TTL —
        # each spec uses fresh buckets).
        key = args[3]
        count = @mutex.synchronize do
          next_count = (@data[key]? || 0_i64) + 1
          @data[key] = next_count
          next_count
        end
        emit(sock, ":#{count}\r\n")
      when "DEL"
        n = @mutex.synchronize do
          removed = 0
          args[1..].each { |k| removed += 1 if @data.delete(k) }
          removed
        end
        emit(sock, ":#{n}\r\n")
      else
        emit(sock, "-ERR unknown command\r\n")
      end
    end
  rescue
  ensure
    begin
      sock.close
    rescue
    end
  end
end

describe "Saci::Throttle::RedisStore" do
  it "shares fixed windows across two store instances (fake redis)" do
    fake = FakeThrottleRedis.new
    begin
      a = Saci::Throttle::RedisStore.new(fake.url, prefix: "saci:spec-a:")
      b = Saci::Throttle::RedisStore.new(fake.url, prefix: "saci:spec-a:")
      begin
        a.increment("r:k:1", 1_i64, 60_i64, 60).should eq(1)
        # Second checker on the same Redis sees the first checker's count.
        b.increment("r:k:1", 1_i64, 60_i64, 60).should eq(2)
        a.increment("r:k:1", 1_i64, 60_i64, 60).should eq(3)
        # Independent buckets stay independent.
        b.increment("r:other:1", 1_i64, 60_i64, 60).should eq(1)
      ensure
        a.clear
        b.clear
      end
    ensure
      fake.close
    end
  end

  it "enforces limits over HTTP with 429 + Retry-After on the redis store" do
    fake = FakeThrottleRedis.new
    begin
      Saci::Throttle.reset!
      Saci::Throttle.store = Saci::Throttle::RedisStore.new(fake.url, prefix: "saci:spec-http:")
      Saci::Throttle.throttle("demo/ip", limit: 2, period: 60.seconds) do |ctx|
        ctx.request.path == "/limited" ? Saci::Throttle.client_ip(ctx) : nil
      end
      begin
        Saci::TestSession.serve(throttle_router) do |app|
          app.get("/limited").status_code.should eq(200)
          app.get("/limited").status_code.should eq(200)
          third = app.get("/limited")
          third.status_code.should eq(429)
          third.headers["Retry-After"]?.should_not be_nil
          JSON.parse(third.body)["error"].as_s.should contain("Too many")
        end
      ensure
        Saci::Throttle.reset!
        Saci::Throttle.store = Saci::Throttle::MemoryStore.new
      end
    ensure
      fake.close
    end
  end

  it "keeps safelist/blocklist behavior on the redis store" do
    fake = FakeThrottleRedis.new
    begin
      Saci::Throttle.reset!
      Saci::Throttle.store = Saci::Throttle::RedisStore.new(fake.url, prefix: "saci:spec-lists:")
      Saci::Throttle.throttle("demo/ip", limit: 1, period: 60.seconds) do |ctx|
        ctx.request.path == "/limited" ? Saci::Throttle.client_ip(ctx) : nil
      end
      Saci::Throttle.safelist { |ctx| Saci::Throttle.client_ip(ctx) == "127.0.0.1" }
      begin
        Saci::TestSession.serve(throttle_router) do |app|
          3.times { app.get("/limited").status_code.should eq(200) }
        end
      ensure
        Saci::Throttle.reset!
        Saci::Throttle.store = Saci::Throttle::MemoryStore.new
      end
      Saci::Throttle.reset!
      Saci::Throttle.store = Saci::Throttle::RedisStore.new(fake.url, prefix: "saci:spec-lists:")
      Saci::Throttle.throttle("demo/ip", limit: 1, period: 60.seconds) do |ctx|
        ctx.request.path == "/limited" ? Saci::Throttle.client_ip(ctx) : nil
      end
      Saci::Throttle.blocklist { |ctx| (ctx.request.path || "") == "/limited" }
      begin
        Saci::TestSession.serve(throttle_router) do |app|
          app.get("/limited").status_code.should eq(403)
          app.get("/open").status_code.should eq(200)
        end
      ensure
        Saci::Throttle.reset!
        Saci::Throttle.store = Saci::Throttle::MemoryStore.new
      end
    ensure
      fake.close
    end
  end

  it "fails open (allows requests) when redis is down" do
    Saci::Throttle.reset!
    Saci::Throttle.store = Saci::Throttle::RedisStore.new("redis://127.0.0.1:63981")
    Saci::Throttle.throttle("demo/ip", limit: 1, period: 60.seconds) do |ctx|
      ctx.request.path == "/limited" ? Saci::Throttle.client_ip(ctx) : nil
    end
    begin
      Saci::TestSession.serve(throttle_router) do |app|
        3.times { app.get("/limited").status_code.should eq(200) }
      end
    ensure
      Saci::Throttle.reset!
      Saci::Throttle.store = Saci::Throttle::MemoryStore.new
    end
  end

  it "raises Throttle::RedisDown on direct increment when redis is down" do
    store = Saci::Throttle::RedisStore.new("redis://127.0.0.1:63981")
    expect_raises(Saci::Throttle::RedisDown) do
      store.increment("b", 1_i64, 60_i64, 60)
    end
  end
end

describe "Saci::Throttle::RedisStore (live)" do
  it "enforces a joint limit across two checkers on real redis" do
    pending!("set REDIS_URL to run live redis specs (e.g. REDIS_URL=redis://127.0.0.1:63979)") if ENV["REDIS_URL"]?.nil?
    url = ENV["REDIS_URL"].not_nil!
    prefix = "saci:live-thr-#{Time.utc.to_unix_ms}:"
    a = Saci::Throttle::RedisStore.new(url, prefix: prefix)
    b = Saci::Throttle::RedisStore.new(url, prefix: prefix)
    begin
      bucket = "joint:k:#{Time.utc.to_unix // 60}"
      a.increment(bucket, 1_i64, 60_i64, 60).should eq(1)
      b.increment(bucket, 1_i64, 60_i64, 60).should eq(2)
      a.increment(bucket, 1_i64, 60_i64, 60).should eq(3)
    ensure
      a.clear
      b.clear
    end
  end

  it "limits over HTTP on real redis with 429 + Retry-After" do
    pending!("set REDIS_URL to run live redis specs (e.g. REDIS_URL=redis://127.0.0.1:63979)") if ENV["REDIS_URL"]?.nil?
    url = ENV["REDIS_URL"].not_nil!
    Saci::Throttle.reset!
    Saci::Throttle.store = Saci::Throttle::RedisStore.new(url, prefix: "saci:live-http-#{Time.utc.to_unix_ms}:")
    Saci::Throttle.throttle("demo/ip", limit: 2, period: 60.seconds) do |ctx|
      ctx.request.path == "/limited" ? Saci::Throttle.client_ip(ctx) : nil
    end
    begin
      Saci::TestSession.serve(throttle_router) do |app|
        app.get("/limited").status_code.should eq(200)
        app.get("/limited").status_code.should eq(200)
        third = app.get("/limited")
        third.status_code.should eq(429)
        third.headers["Retry-After"]?.should_not be_nil
      end
    ensure
      Saci::Throttle.reset!
      Saci::Throttle.store = Saci::Throttle::MemoryStore.new
    end
  end
end
