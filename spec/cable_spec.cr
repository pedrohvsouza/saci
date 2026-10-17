require "spec"
require "../src/saci"

class CableEchoChannel < Saci::Cable::Channel
  def subscribed
    stream_from "echo:#{params["room"]?.try(&.as_s?) || "lobby"}"
  end

  def receive(data)
    transmit({echo: data["text"]? || data})
  end
end

class CableRejectChannel < Saci::Cable::Channel
  def subscribed
    reject unless params["token"]?.try(&.as_s?) == "secret"
    stream_from "open"
  end
end

class CableCounterChannel < Saci::Cable::Channel
  def subscribed
    stream_from "counter"
  end

  def receive(data)
    n = data["n"]?.try(&.as_i?) || 0
    Saci::Cable.broadcast("counter", {n: n + 1})
  end
end

def cable_router : Saci::Router
  Saci::Router.new.draw do |r|
    r.cable "/cable", CableEchoChannel, CableRejectChannel, CableCounterChannel
    r.websocket("/live") { |ws, _ctx, _params| ws.send("hi") }
  end
end

describe Saci::Cable do
  it "welcomes connections and confirms subscriptions" do
    Saci::TestSession.serve(cable_router) do |app|
      client = Saci::Cable::TestClient.new(app.host, app.port)
      ident = client.subscribe("CableEchoChannel", {"room" => "1"})
      ident.should contain("CableEchoChannel")
      client.close
    end
  end

  it "echoes messages back to the sender" do
    Saci::TestSession.serve(cable_router) do |app|
      client = Saci::Cable::TestClient.new(app.host, app.port)
      ident = client.subscribe("CableEchoChannel", {"room" => "1"})
      client.send_message(ident, {text: "hi"})
      msg = client.next_message
      msg["identifier"]?.try(&.as_s?).should eq(ident)
      msg["message"].as_h["echo"].as_s.should eq("hi")
      client.close
    end
  end

  it "broadcasts to every subscriber of a stream" do
    Saci::TestSession.serve(cable_router) do |app|
      a = Saci::Cable::TestClient.new(app.host, app.port)
      b = Saci::Cable::TestClient.new(app.host, app.port)
      a_ident = a.subscribe("CableCounterChannel")
      b_ident = b.subscribe("CableCounterChannel")
      a.send_message(a_ident, {n: 41})
      first = a.next_message
      first["identifier"]?.try(&.as_s?).should eq(a_ident)
      first["message"].as_h["n"].as_i.should eq(42)
      other = b.next_message
      other["identifier"]?.try(&.as_s?).should eq(b_ident)
      other["message"].as_h["n"].as_i.should eq(42)
      a.close
      b.close
    end
  end

  it "isolates streams from each other" do
    Saci::TestSession.serve(cable_router) do |app|
      a = Saci::Cable::TestClient.new(app.host, app.port)
      b = Saci::Cable::TestClient.new(app.host, app.port)
      a.subscribe("CableEchoChannel", {"room" => "1"})
      b.subscribe("CableEchoChannel", {"room" => "2"})
      Saci::Cable.broadcast("echo:1", {ping: true})
      msg = a.next_message
      msg["message"].as_h["ping"].as_bool.should be_true
      expect_raises(Exception, /imed out/) do
        b.next_message(0.5.seconds)
      end
      a.close
      b.close
    end
  end

  it "rejects subscriptions without credentials" do
    Saci::TestSession.serve(cable_router) do |app|
      client = Saci::Cable::TestClient.new(app.host, app.port)
      expect_raises(Exception, /ejected/) do
        client.subscribe("CableRejectChannel")
      end
      ident = client.subscribe("CableRejectChannel", {"token" => "secret"})
      ident.should contain("CableRejectChannel")
      client.close
    end
  end

  it "rejects unknown channels" do
    Saci::TestSession.serve(cable_router) do |app|
      client = Saci::Cable::TestClient.new(app.host, app.port)
      expect_raises(Exception, /ejected/) do
        client.subscribe("NopeChannel")
      end
      client.close
    end
  end

  it "stops delivery after unsubscribe" do
    Saci::TestSession.serve(cable_router) do |app|
      client = Saci::Cable::TestClient.new(app.host, app.port)
      ident = client.subscribe("CableEchoChannel", {"room" => "9"})
      client.unsubscribe(ident)
      sleep 0.3.seconds
      Saci::Cable.broadcast("echo:9", {ping: true})
      expect_raises(Exception, /imed out/) do
        client.next_message(0.5.seconds)
      end
      client.close
    end
  end

  it "serves raw websocket routes" do
    Saci::TestSession.serve(cable_router) do |app|
      ws = HTTP::WebSocket.new(app.host, "/live", app.port)
      box = ::Channel(String).new
      ws.on_message { |msg| box.send(msg) }
      spawn { ws.run }
      select
      when msg = box.receive
        msg.should eq("hi")
      when timeout(5.seconds)
        raise "timed out waiting for /live greeting"
      end
      ws.close
    end
  end

  it "matches websocket routes with path params" do
    router = Saci::Router.new.draw do |r|
      r.websocket("/rooms/:id") { |ws, _ctx, _params| ws.send("ok") }
    end
    handler, path_params = router.find_ws("/rooms/7").not_nil!
    path_params["id"].should eq("7")
    handler.should be_a(Proc(HTTP::WebSocket, HTTP::Server::Context, Saci::Params, Nil))
  end
end

# ---------------------------------------------------------------------------
# Redis adapter (Saci::Cable::RedisServer).
#
# Dependency choice (documented): NO shard dependency. The Redis hop is a
# vendored pure-socket RESP2 client (`Saci::Cable::RedisWire`, plain
# `TCPSocket`, no OpenSSL linkage), so default SQLite builds link exactly
# as before and `crystal spec` needs no running server. Live-server specs
# below are gated on `REDIS_URL` (`pending!` without it — never failing);
# the fake-Redis specs prove the wire protocol in every run.
# ---------------------------------------------------------------------------

# Minimal in-spec Redis stand-in: speaks just enough RESP2 (PING /
# AUTH / SELECT / SUBSCRIBE / PUBLISH) to prove the client wire protocol
# and multi-instance fan-out without a real server.
class FakeCableRedis
  getter port : Int32

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.local_address.as(Socket::IPAddress).port
    @subs = Hash(String, Array(TCPSocket)).new { |h, k| h[k] = [] of TCPSocket }
    @mutex = Mutex.new
    @io_mutex = Mutex.new
    @closed = false
    spawn { accept_loop }
  end

  def url : String
    "redis://127.0.0.1:#{@port}"
  end

  def subscriber_count(channel : String) : Int32
    @mutex.synchronize { @subs[channel].size }
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
    my_channels = [] of String
    loop do
      args = read_args(sock)
      break if args.nil? || args.empty?
      case args[0].upcase
      when "PING"
        emit(sock, "+PONG\r\n")
      when "AUTH", "SELECT"
        emit(sock, "+OK\r\n")
      when "SUBSCRIBE"
        ch = args[1]
        @mutex.synchronize { @subs[ch] << sock }
        my_channels << ch
        emit(sock, "*3\r\n$9\r\nsubscribe\r\n$#{ch.bytesize}\r\n#{ch}\r\n:1\r\n")
      when "PUBLISH"
        ch, payload = args[1], args[2]
        targets = @mutex.synchronize { @subs[ch].dup }
        targets.each do |s|
          emit(s, "*3\r\n$7\r\nmessage\r\n$#{ch.bytesize}\r\n#{ch}\r\n$#{payload.bytesize}\r\n#{payload}\r\n")
        end
        emit(sock, ":#{targets.size}\r\n")
      else
        emit(sock, "-ERR unknown command\r\n")
      end
    end
  rescue
  ensure
    if channels = my_channels
      @mutex.synchronize { channels.each { |ch| @subs[ch].delete(sock) } }
    end
    begin
      sock.close
    rescue
    end
  end
end

# Channel whose receive path broadcasts through its OWN server (not the

# Channel whose receive path broadcasts through its OWN server (not the
# global default), so two apps on two RedisServer instances fan out.
class CableRedisFanoutChannel < Saci::Cable::Channel
  def subscribed
    stream_from "redis-fanout"
  end

  def receive(data)
    n = data["n"]?.try(&.as_i?) || 0
    connection.server.broadcast("redis-fanout", {n: n + 1})
  end
end

def cable_wait_until(desc : String, timeout : Time::Span = 10.seconds, &) : Nil
  deadline = Time.monotonic + timeout
  until yield
    raise "timed out waiting for #{desc}" if Time.monotonic > deadline
    sleep 50.milliseconds
  end
end

describe "Saci::Cable Redis wire protocol" do
  it "encodes commands in RESP2 framing" do
    Saci::Cable::RedisWire.encode(["PING"]).should eq("*1\r\n$4\r\nPING\r\n")
    Saci::Cable::RedisWire.encode(["PUBLISH", "ch", "hi"]).should eq(
      "*3\r\n$7\r\nPUBLISH\r\n$2\r\nch\r\n$2\r\nhi\r\n")
    Saci::Cable::RedisWire.encode(["EVAL", "return 1", "0"]).should eq(
      "*3\r\n$4\r\nEVAL\r\n$8\r\nreturn 1\r\n$1\r\n0\r\n")
  end

  it "parses every reply type" do
    Saci::Cable::RedisWire.read_reply(IO::Memory.new("+OK\r\n")).should eq("OK")
    Saci::Cable::RedisWire.read_reply(IO::Memory.new(":42\r\n")).should eq(42_i64)
    Saci::Cable::RedisWire.read_reply(IO::Memory.new("$5\r\nhello\r\n")).should eq("hello")
    Saci::Cable::RedisWire.read_reply(IO::Memory.new("$-1\r\n")).should be_nil
    Saci::Cable::RedisWire.read_reply(IO::Memory.new("*-1\r\n")).should be_nil
    arr = Saci::Cable::RedisWire.read_reply(IO::Memory.new("*3\r\n$7\r\nmessage\r\n$2\r\nch\r\n$2\r\nhi\r\n"))
    arr.should eq(["message", "ch", "hi"])
    expect_raises(Saci::Cable::RedisDown, /ERR/) do
      Saci::Cable::RedisWire.read_reply(IO::Memory.new("-ERR boom\r\n"))
    end
    expect_raises(Saci::Cable::RedisDown) do
      Saci::Cable::RedisWire.read_reply(IO::Memory.new(""))
    end
  end

  it "parses redis URLs" do
    info = Saci::Cable::RedisWire.parse_url("redis://127.0.0.1:63979")
    info.host.should eq("127.0.0.1")
    info.port.should eq(63979)
    info.password.should be_nil
    info.db.should be_nil
    info = Saci::Cable::RedisWire.parse_url("redis://:secret@redis.internal:6380/2")
    info.host.should eq("redis.internal")
    info.port.should eq(6380)
    info.password.should eq("secret")
    info.db.should eq(2)
    info = Saci::Cable::RedisWire.parse_url("redis://localhost")
    info.port.should eq(6379)
    expect_raises(Saci::Cable::RedisDown, /scheme/) do
      Saci::Cable::RedisWire.parse_url("http://localhost:6379")
    end
  end
end

describe "Saci::Cable::RedisServer" do
  it "fans out broadcasts across two server instances (fake redis wire)" do
    fake = FakeCableRedis.new
    begin
      srv_a = Saci::Cable::RedisServer.new(fake.url, "saci:spec-fanout")
      srv_b = Saci::Cable::RedisServer.new(fake.url, "saci:spec-fanout")
      begin
        cable_wait_until("both servers subscribed") { fake.subscriber_count("saci:spec-fanout") == 2 }
        router_a = Saci::Router.new.draw { |r| r.cable "/cable", CableRedisFanoutChannel, server: srv_a }
        router_b = Saci::Router.new.draw { |r| r.cable "/cable", CableRedisFanoutChannel, server: srv_b }
        Saci::TestSession.serve(router_a) do |app_a|
          Saci::TestSession.serve(router_b) do |app_b|
            a = Saci::Cable::TestClient.new(app_a.host, app_a.port)
            b = Saci::Cable::TestClient.new(app_b.host, app_b.port)
            begin
              a_ident = a.subscribe("CableRedisFanoutChannel")
              b_ident = b.subscribe("CableRedisFanoutChannel")
              a.send_message(a_ident, {n: 41})
              # Sender's own server delivers locally...
              got_a = a.next_message
              got_a["identifier"]?.try(&.as_s?).should eq(a_ident)
              got_a["message"].as_h["n"].as_i.should eq(42)
              # ...and the peer server delivers via the Redis hop.
              got_b = b.next_message
              got_b["identifier"]?.try(&.as_s?).should eq(b_ident)
              got_b["message"].as_h["n"].as_i.should eq(42)
            ensure
              a.close
              b.close
            end
          end
        end
      ensure
        srv_a.close
        srv_b.close
      end
    ensure
      fake.close
    end
  end

  it "resubscribes with backoff after the connection drops (fake redis wire)" do
    fake = FakeCableRedis.new
    begin
      srv_a = Saci::Cable::RedisServer.new(fake.url, "saci:spec-resub")
      srv_b = Saci::Cable::RedisServer.new(fake.url, "saci:spec-resub")
      begin
        cable_wait_until("both servers subscribed") { fake.subscriber_count("saci:spec-resub") == 2 }
        srv_b.disconnect!
        cable_wait_until("resubscribed after drop") do
          srv_b.subscribed? && fake.subscriber_count("saci:spec-resub") == 2
        end
        # Fan-out still works after the resubscribe.
        router_a = Saci::Router.new.draw { |r| r.cable "/cable", CableRedisFanoutChannel, server: srv_a }
        router_b = Saci::Router.new.draw { |r| r.cable "/cable", CableRedisFanoutChannel, server: srv_b }
        Saci::TestSession.serve(router_a) do |app_a|
          Saci::TestSession.serve(router_b) do |app_b|
            a = Saci::Cable::TestClient.new(app_a.host, app_a.port)
            b = Saci::Cable::TestClient.new(app_b.host, app_b.port)
            begin
              a_ident = a.subscribe("CableRedisFanoutChannel")
              b_ident = b.subscribe("CableRedisFanoutChannel")
              a.send_message(a_ident, {n: 7})
              a.next_message["message"].as_h["n"].as_i.should eq(8)
              b.next_message["message"].as_h["n"].as_i.should eq(8)
            ensure
              a.close
              b.close
            end
          end
        end
      ensure
        srv_a.close
        srv_b.close
      end
    ensure
      fake.close
    end
  end

  it "delivers locally and never raises when redis is down (fail-open: log + drop)" do
    srv = Saci::Cable::RedisServer.new("redis://127.0.0.1:63981", "saci:spec-down")
    begin
      router = Saci::Router.new.draw { |r| r.cable "/cable", CableEchoChannel, server: srv }
      Saci::TestSession.serve(router) do |app|
        client = Saci::Cable::TestClient.new(app.host, app.port)
        begin
          ident = client.subscribe("CableEchoChannel", {"room" => "x"})
          client.send_message(ident, {text: "hi"})
          client.next_message["message"].as_h["echo"].as_s.should eq("hi")
          # Broadcast path: local delivery happens despite dead redis,
          # remote hop is dropped with a warning — no raise.
          srv.broadcast("echo:x", {ping: true})
          client.next_message["message"].as_h["ping"].as_bool.should be_true
        ensure
          client.close
        end
      end
    ensure
      srv.close
    end
  end
end

describe "Saci::Cable::RedisServer (live)" do
  it "fans out broadcasts across two server instances on real redis" do
    pending!("set REDIS_URL to run live redis specs (e.g. REDIS_URL=redis://127.0.0.1:63979)") if ENV["REDIS_URL"]?.nil?
    url = ENV["REDIS_URL"].not_nil!
    channel = "saci:live-cable-#{Time.utc.to_unix_ms}"
    srv_a = Saci::Cable::RedisServer.new(url, channel)
    srv_b = Saci::Cable::RedisServer.new(url, channel)
    begin
      cable_wait_until("both servers subscribed") { srv_a.subscribed? && srv_b.subscribed? }
      router_a = Saci::Router.new.draw { |r| r.cable "/cable", CableRedisFanoutChannel, server: srv_a }
      router_b = Saci::Router.new.draw { |r| r.cable "/cable", CableRedisFanoutChannel, server: srv_b }
      Saci::TestSession.serve(router_a) do |app_a|
        Saci::TestSession.serve(router_b) do |app_b|
          a = Saci::Cable::TestClient.new(app_a.host, app_a.port)
          b = Saci::Cable::TestClient.new(app_b.host, app_b.port)
          begin
            a_ident = a.subscribe("CableRedisFanoutChannel")
            b_ident = b.subscribe("CableRedisFanoutChannel")
            a.send_message(a_ident, {n: 41})
            a.next_message["message"].as_h["n"].as_i.should eq(42)
            b.next_message["message"].as_h["n"].as_i.should eq(42)
          ensure
            a.close
            b.close
          end
        end
      end
    ensure
      srv_a.close
      srv_b.close
    end
  end

  it "resubscribes after the connection drops on real redis" do
    pending!("set REDIS_URL to run live redis specs (e.g. REDIS_URL=redis://127.0.0.1:63979)") if ENV["REDIS_URL"]?.nil?
    url = ENV["REDIS_URL"].not_nil!
    channel = "saci:live-resub-#{Time.utc.to_unix_ms}"
    srv_a = Saci::Cable::RedisServer.new(url, channel)
    srv_b = Saci::Cable::RedisServer.new(url, channel)
    begin
      cable_wait_until("both servers subscribed") { srv_a.subscribed? && srv_b.subscribed? }
      srv_b.disconnect!
      cable_wait_until("resubscribed after drop") { srv_b.subscribed? }
      sleep 0.5.seconds # let the server-side SUBSCRIBE register before publishing
      router_a = Saci::Router.new.draw { |r| r.cable "/cable", CableRedisFanoutChannel, server: srv_a }
      router_b = Saci::Router.new.draw { |r| r.cable "/cable", CableRedisFanoutChannel, server: srv_b }
      Saci::TestSession.serve(router_a) do |app_a|
        Saci::TestSession.serve(router_b) do |app_b|
          a = Saci::Cable::TestClient.new(app_a.host, app_a.port)
          b = Saci::Cable::TestClient.new(app_b.host, app_b.port)
          begin
            a_ident = a.subscribe("CableRedisFanoutChannel")
            b_ident = b.subscribe("CableRedisFanoutChannel")
            a.send_message(a_ident, {n: 7})
            a.next_message["message"].as_h["n"].as_i.should eq(8)
            b.next_message["message"].as_h["n"].as_i.should eq(8)
          ensure
            a.close
            b.close
          end
        end
      end
    ensure
      srv_a.close
      srv_b.close
    end
  end
end
