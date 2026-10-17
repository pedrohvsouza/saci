require "spec"
require "../src/saci"

describe Saci::Cache do
  before_each do
    Saci::Cache.reset!
  end

  after_each do
    Saci::Cache.reset!
  end

  it "reads/writes/deletes String entries (module fast-path)" do
    Saci::Cache.read("missing").should be_nil
    Saci::Cache.exist?("k").should be_false
    Saci::Cache.delete("k").should be_false
    Saci::Cache.write("k", "v").should be_true
    Saci::Cache.read("k").should eq("v")
    Saci::Cache.exist?("k").should be_true
    Saci::Cache.delete("k").should be_true
    Saci::Cache.read("k").should be_nil
    Saci::Cache.exist?("k").should be_false
  end

  it "expires entries (purge on read)" do
    Saci::Cache.write("t", "v", expires_in: 100.milliseconds)
    Saci::Cache.read("t").should eq("v")
    sleep 150.milliseconds
    Saci::Cache.read("t").should be_nil
    Saci::Cache.exist?("t").should be_false
    Saci::Cache.delete("t").should be_false
  end

  it "keeps entries without expiry" do
    Saci::Cache.write("forever", "v")
    Saci::Cache.read("forever").should eq("v")
    Saci::Cache.exist?("forever").should be_true
  end

  it "memoizes through fetch (block runs once on miss)" do
    calls = 0
    Saci::Cache.fetch("f") { calls += 1; "computed" }.should eq("computed")
    Saci::Cache.fetch("f") { calls += 1; "computed" }.should eq("computed")
    calls.should eq(1)
  end

  it "recomputes fetch after expiry" do
    calls = 0
    Saci::Cache.fetch("e", expires_in: 100.milliseconds) { calls += 1; "v#{calls}" }.should eq("v1")
    sleep 150.milliseconds
    Saci::Cache.fetch("e", expires_in: 100.milliseconds) { calls += 1; "v#{calls}" }.should eq("v2")
    calls.should eq(2)
  end

  it "round-trips typed values (Int64, Float64, Bool, Time, Nil)" do
    Saci::Cache.write("i", 42_i64)
    Saci::Cache.write("i32", 7)
    Saci::Cache.write("f", 0.1_f64 + 0.2_f64)
    Saci::Cache.write("bt", true)
    Saci::Cache.write("bf", false)
    now = Time.utc
    Saci::Cache.write("t", now)
    Saci::Cache.write("n", nil)
    Saci::Cache.read_value("i").should eq(42_i64)
    Saci::Cache.read_value("i32").should eq(7_i64)
    Saci::Cache.read_value("f").should eq(0.1_f64 + 0.2_f64)
    Saci::Cache.read_value("bt").should eq(true)
    Saci::Cache.read_value("bf").should eq(false)
    Saci::Cache.read_value("t").as(Time).to_unix_ns.should eq(now.to_unix_ns)
    Saci::Cache.read_value("n").should be_nil
    # A stored Nil is still a present entry...
    Saci::Cache.exist?("n").should be_true
    # ...and fetch treats it as a hit (block never runs).
    calls = 0
    Saci::Cache.fetch_value("n") { calls += 1; "x" }.should be_nil
    calls.should eq(0)
  end

  it "keeps tag-like and unicode Strings intact" do
    Saci::Cache.write("evil", "S:1")
    Saci::Cache.read("evil").should eq("S:1")
    Saci::Cache.write("uni", "héllo:wörld:B:1:N:🎉")
    Saci::Cache.read("uni").should eq("héllo:wörld:B:1:N:🎉")
    Saci::Cache.read_value("evil").should eq("S:1")
  end

  it "returns nil from String read for non-String entries" do
    Saci::Cache.write("i", 1_i64)
    Saci::Cache.read("i").should be_nil
    Saci::Cache.read_value("i").should eq(1_i64)
  end

  it "increments counters" do
    Saci::Cache.increment("c").should eq(1_i64)
    Saci::Cache.increment("c").should eq(2_i64)
    Saci::Cache.increment("c", by: 8).should eq(10_i64)
    Saci::Cache.read_value("c").should eq(10_i64)
  end

  it "increments String counters while preserving their shape" do
    Saci::Cache.write("s", "5")
    Saci::Cache.increment("s", by: 2).should eq(7_i64)
    Saci::Cache.read("s").should eq("7")
  end

  it "rejects incrementing non-numeric values" do
    Saci::Cache.write("nope", "abc")
    expect_raises(ArgumentError, /non-numeric/) { Saci::Cache.increment("nope") }
    Saci::Cache.write("f", 1.5_f64)
    expect_raises(ArgumentError, /non-numeric/) { Saci::Cache.increment("f") }
  end

  it "resets expired counters on increment" do
    Saci::Cache.write("e", 100_i64, expires_in: 100.milliseconds)
    sleep 150.milliseconds
    Saci::Cache.increment("e", by: 3).should eq(3_i64)
  end

  it "isolates keys by namespace" do
    Saci::Cache.namespace = "a"
    Saci::Cache.write("k", "va")
    Saci::Cache.namespace = "b"
    Saci::Cache.read("k").should be_nil
    Saci::Cache.write("k", "vb")
    Saci::Cache.read("k").should eq("vb")
    Saci::Cache.namespace = "a"
    Saci::Cache.read("k").should eq("va")
    Saci::Cache.namespace = ""
  end

  it "clears everything" do
    Saci::Cache.write("a", "1")
    Saci::Cache.write("b", "2")
    Saci::Cache.clear
    Saci::Cache.read("a").should be_nil
    Saci::Cache.read("b").should be_nil
  end

  it "delegates store= (swappable backend)" do
    mem = Saci::Cache::MemoryStore.new
    mem.write("direct", "yes")
    Saci::Cache.store = mem
    Saci::Cache.read("direct").should eq("yes")
    Saci::Cache.store.should be(mem)
  end

  it "caps MemoryStore with LRU eviction" do
    store = Saci::Cache::MemoryStore.new(2)
    store.write("a", "1")
    store.write("b", "2")
    store.read("a").should eq("1") # refreshes a; b is now least-recent
    store.write("c", "3")
    store.read("b").should be_nil
    store.read("a").should eq("1")
    store.read("c").should eq("3")
  end

  it "serves stale + refreshes in background with race_condition_ttl" do
    store = Saci::Cache::MemoryStore.new
    store.write("k", "stale", expires_in: 100.milliseconds)
    sleep 150.milliseconds
    calls = 0
    result = store.fetch("k", expires_in: 5.seconds, race_condition_ttl: 5.seconds) do
      calls += 1
      sleep 200.milliseconds
      "fresh"
    end
    result.should eq("stale") # served immediately, refresh happens behind
    sleep 500.milliseconds
    calls.should eq(1)
    store.read("k").should eq("fresh")
  end

  it "recomputes synchronously past the race_condition_ttl grace window" do
    store = Saci::Cache::MemoryStore.new
    store.write("k", "stale", expires_in: 100.milliseconds)
    sleep 150.milliseconds
    calls = 0
    result = store.fetch("k", expires_in: 5.seconds, race_condition_ttl: 10.milliseconds) do
      calls += 1
      "fresh"
    end
    result.should eq("fresh")
    calls.should eq(1)
  end
end

# ---------------------------------------------------------------------------
# Redis store (Saci::Cache::RedisStore).
#
# Same dependency story as Cable/Throttle: no shard dep, the vendored
# pure-socket `Saci::Cable::RedisWire` client is reused, default builds
# link unchanged. Live specs gate on `REDIS_URL` (`pending!` without it —
# never failing); the fake-Redis specs prove the wire protocol + encoding
# in every run.
# ---------------------------------------------------------------------------

# Minimal in-spec Redis stand-in for the cache path: PING / AUTH / SELECT
# plus GET / SET (with EX) / DEL / EXISTS, with server-side expiry.
class FakeCacheRedis
  getter port : Int32

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.local_address.as(Socket::IPAddress).port
    @data = {} of String => Tuple(String, Time?)
    @mutex = Mutex.new
    @io_mutex = Mutex.new
    @closed = false
    spawn { accept_loop }
  end

  def url : String
    "redis://127.0.0.1:#{@port}"
  end

  def inject(key : String, raw : String) : Nil
    @mutex.synchronize { @data[key] = {raw, nil} }
  end

  def has?(key : String) : Bool
    @mutex.synchronize { @data.has_key?(key) }
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

  private def bulk(str : String) : String
    "$#{str.bytesize}\r\n#{str}\r\n"
  end

  private def live_locked(key : String) : String?
    entry = @data[key]?
    return nil if entry.nil?
    raw, exp = entry
    if exp && Time.utc >= exp
      @data.delete(key)
      return nil
    end
    raw
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
      when "GET"
        raw = @mutex.synchronize { live_locked(args[1]) }
        emit(sock, raw.nil? ? "$-1\r\n" : bulk(raw))
      when "SET"
        exp = nil
        if args.size == 5 && args[3].upcase == "EX"
          exp = Time.utc + (args[4].to_i? || 0).seconds
        end
        @mutex.synchronize { @data[args[1]] = {args[2], exp} }
        emit(sock, "+OK\r\n")
      when "DEL"
        n = @mutex.synchronize do
          removed = 0_i64
          args[1..].each do |k|
            if @data.has_key?(k)
              @data.delete(k)
              removed += 1
            end
          end
          removed
        end
        emit(sock, ":#{n}\r\n")
      when "EXISTS"
        hit = @mutex.synchronize { !live_locked(args[1]).nil? }
        emit(sock, hit ? ":1\r\n" : ":0\r\n")
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

describe "Saci::Cache::RedisStore" do
  it "round-trips Strings and typed values (fake redis)" do
    fake = FakeCacheRedis.new
    begin
      store = Saci::Cache::RedisStore.new(fake.url)
      begin
        store.write("s", "hello").should be_true
        store.read("s").should eq("hello")
        store.write("evil", "S:1")
        store.read("evil").should eq("S:1")
        store.write("i", 42_i64)
        store.write("f", 0.1_f64 + 0.2_f64)
        store.write("bt", true)
        store.write("bf", false)
        now = Time.utc
        store.write("t", now)
        store.write("n", nil)
        store.read_value("i").should eq(42_i64)
        store.read_value("f").should eq(0.1_f64 + 0.2_f64)
        store.read_value("bt").should eq(true)
        store.read_value("bf").should eq(false)
        store.read_value("t").as(Time).to_unix_ns.should eq(now.to_unix_ns)
        store.read_value("n").should be_nil
        store.exist?("n").should be_true
        store.read("missing").should be_nil
        store.exist?("missing").should be_false
      ensure
        store.clear
      end
    ensure
      fake.close
    end
  end

  it "reads untagged foreign keys as Strings (fake redis)" do
    fake = FakeCacheRedis.new
    begin
      store = Saci::Cache::RedisStore.new(fake.url)
      begin
        fake.inject("saci:cache:foreign", "plain")
        store.read("foreign").should eq("plain")
        store.read_value("foreign").should eq("plain")
      ensure
        store.clear
      end
    ensure
      fake.close
    end
  end

  it "expires entries server-side (fake redis)" do
    fake = FakeCacheRedis.new
    begin
      store = Saci::Cache::RedisStore.new(fake.url)
      begin
        store.write("t", "v", expires_in: 1.second)
        store.read("t").should eq("v")
        sleep 1.2.seconds
        store.read("t").should be_nil
        store.exist?("t").should be_false
      ensure
        store.clear
      end
    ensure
      fake.close
    end
  end

  it "deletes and checks existence (fake redis)" do
    fake = FakeCacheRedis.new
    begin
      store = Saci::Cache::RedisStore.new(fake.url)
      begin
        store.write("k", "v")
        store.exist?("k").should be_true
        store.delete("k").should be_true
        store.delete("k").should be_false
        store.exist?("k").should be_false
      ensure
        store.clear
      end
    ensure
      fake.close
    end
  end

  it "increments counters, shared across instances (fake redis)" do
    fake = FakeCacheRedis.new
    begin
      prefix = "saci:spec-cache-inc:"
      a = Saci::Cache::RedisStore.new(fake.url, prefix: prefix)
      b = Saci::Cache::RedisStore.new(fake.url, prefix: prefix)
      begin
        a.increment("c").should eq(1_i64)
        b.increment("c").should eq(2_i64)
        a.increment("c", by: 8).should eq(10_i64)
        b.read_value("c").should eq(10_i64)
        a.write("s", "5")
        b.increment("s").should eq(6_i64)
        a.read("s").should eq("6")
      ensure
        a.clear
        b.clear
      end
    ensure
      fake.close
    end
  end

  it "isolates namespaces and prefixes (fake redis)" do
    fake = FakeCacheRedis.new
    begin
      a = Saci::Cache::RedisStore.new(fake.url, prefix: "saci:spec-ns-a:")
      b = Saci::Cache::RedisStore.new(fake.url, prefix: "saci:spec-ns-b:")
      begin
        a.namespace = "one"
        a.write("k", "va")
        a.namespace = "two"
        a.read("k").should be_nil
        b.read("k").should be_nil
        a.namespace = "one"
        a.read("k").should eq("va")
      ensure
        a.clear
        b.clear
      end
    ensure
      fake.close
    end
  end

  it "clear deletes only keys written through that instance (fake redis)" do
    fake = FakeCacheRedis.new
    begin
      store = Saci::Cache::RedisStore.new(fake.url)
      begin
        store.write("mine", "v")
        fake.inject("saci:cache:foreign", "untouched")
        store.clear
        store.read("mine").should be_nil
        fake.has?("saci:cache:foreign").should be_true
      ensure
        store.clear
      end
    ensure
      fake.close
    end
  end

  it "memoizes through fetch (fake redis)" do
    fake = FakeCacheRedis.new
    begin
      store = Saci::Cache::RedisStore.new(fake.url)
      begin
        calls = 0
        store.fetch("f") { calls += 1; "computed" }.should eq("computed")
        store.fetch("f") { calls += 1; "computed" }.should eq("computed")
        calls.should eq(1)
      ensure
        store.clear
      end
    ensure
      fake.close
    end
  end

  it "works behind the module store= swap (fake redis)" do
    fake = FakeCacheRedis.new
    begin
      Saci::Cache.reset!
      Saci::Cache.store = Saci::Cache::RedisStore.new(fake.url, prefix: "saci:spec-mod:")
      begin
        Saci::Cache.write("k", "v").should be_true
        Saci::Cache.read("k").should eq("v")
        Saci::Cache.fetch("f") { "c" }.should eq("c")
        Saci::Cache.increment("n").should eq(1_i64)
        Saci::Cache.exist?("k").should be_true
      ensure
        Saci::Cache.reset!
      end
    ensure
      fake.close
    end
  end

  it "raises Cache::RedisDown when redis is down" do
    store = Saci::Cache::RedisStore.new("redis://127.0.0.1:63981")
    expect_raises(Saci::Cache::RedisDown) { store.read("k") }
    expect_raises(Saci::Cache::RedisDown) { store.write("k", "v") }
    expect_raises(Saci::Cache::RedisDown) { store.increment("k") }
    expect_raises(Saci::Cache::RedisDown) { store.exist?("k") }
    expect_raises(Saci::Cache::RedisDown) { store.delete("k") }
    expect_raises(Saci::Cache::RedisDown) { store.fetch("k") { "v" } }
  end

  it "raises Cache::RedisDown for bad URL schemes" do
    expect_raises(Saci::Cache::RedisDown, /scheme/) do
      Saci::Cache::RedisStore.new("http://localhost:6379")
    end
  end
end

describe "Saci::Cache::RedisStore (live)" do
  it "round-trips every value type on real redis" do
    pending!("set REDIS_URL to run live redis specs (e.g. REDIS_URL=redis://127.0.0.1:63979)") if ENV["REDIS_URL"]?.nil?
    url = ENV["REDIS_URL"].not_nil!
    store = Saci::Cache::RedisStore.new(url, prefix: "saci:live-cache-#{Time.utc.to_unix_ms}:")
    begin
      store.write("s", "hello")
      store.read("s").should eq("hello")
      store.write("i", 42_i64)
      store.write("f", 0.1_f64 + 0.2_f64)
      store.write("bt", true)
      now = Time.utc
      store.write("t", now)
      store.write("n", nil)
      store.read_value("i").should eq(42_i64)
      store.read_value("f").should eq(0.1_f64 + 0.2_f64)
      store.read_value("bt").should eq(true)
      store.read_value("t").as(Time).to_unix_ns.should eq(now.to_unix_ns)
      store.exist?("n").should be_true
      store.delete("s").should be_true
      store.read("s").should be_nil
    ensure
      store.clear
    end
  end

  it "shares increments and honors TTLs on real redis" do
    pending!("set REDIS_URL to run live redis specs (e.g. REDIS_URL=redis://127.0.0.1:63979)") if ENV["REDIS_URL"]?.nil?
    url = ENV["REDIS_URL"].not_nil!
    prefix = "saci:live-cache2-#{Time.utc.to_unix_ms}:"
    a = Saci::Cache::RedisStore.new(url, prefix: prefix)
    b = Saci::Cache::RedisStore.new(url, prefix: prefix)
    begin
      a.increment("c").should eq(1_i64)
      b.increment("c").should eq(2_i64)
      a.write("t", "v", expires_in: 1.second)
      a.read("t").should eq("v")
      sleep 1.2.seconds
      b.read("t").should be_nil
      a.fetch("f") { "computed" }.should eq("computed")
      b.read("f").should eq("computed")
    ensure
      a.clear
      b.clear
    end
  end
end
