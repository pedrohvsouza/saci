require "spec"
require "file_utils"
require "../src/saci"
require "../src/saci/cable_testing"

CABLE_WAKE_DB_PATH = "/tmp/opencode/saci_cable_wake_test.db"

# A fresh SQLite file per run, so ids (and therefore `last_seen`) start at 0.
File.delete(CABLE_WAKE_DB_PATH) if File.exists?(CABLE_WAKE_DB_PATH)
CABLE_WAKE_DB = DB.open("sqlite3://#{CABLE_WAKE_DB_PATH}")

class CableWakeProbeChannel < Saci::Cable::Channel
  @@received = [] of String
  @@mutex = Mutex.new

  def self.received : Array(String)
    @@mutex.synchronize { @@received.dup }
  end

  def self.reset! : Nil
    @@mutex.synchronize { @@received.clear }
  end

  def subscribed
    stream_from "wake:probe"
  end

  def deliver(identifier : String, payload) : Nil
    @@mutex.synchronize { @@received << payload.to_json }
  end
end

def cable_wake_wait_until(desc : String, timeout : Time::Span = 3.seconds, &) : Nil
  deadline = Time.instant + timeout
  until yield
    raise "timed out waiting for #{desc}" if Time.instant > deadline
    sleep 5.milliseconds
  end
end

def cable_wake_subscriber(server : Saci::Cable::Server) : Saci::Cable::Connection
  connection = Saci::Cable::Connection.new(HTTP::WebSocket.new(IO::Memory.new), Saci::Params.new, server)
  server.register(connection)
  server.subscribe(CableWakeProbeChannel, connection,
    Saci::Cable.identifier_for("CableWakeProbeChannel"), {} of String => JSON::Any)
  connection
end

def cable_wake_free_port : Int32
  socket = UDPSocket.new
  socket.bind("0.0.0.0", 0)
  port = socket.local_address.as(Socket::IPAddress).port
  socket.close
  port
end

describe "Saci::Cable::LocalWake loopback transport" do
  it "derives a stable port from the wake key" do
    Saci::Cable::LocalWake.port_for("sqlite:saci_cable_messages").should eq(25244)
    Saci::Cable::LocalWake.port_for("wake:unit:a").should eq(26198)
    port = Saci::Cable::LocalWake.port_for("wake:unit:b")
    port.should be >= Saci::Cable::LocalWake::PORT_BASE
    port.should be < Saci::Cable::LocalWake::PORT_BASE + Saci::Cable::LocalWake::PORT_SPAN
    port.should_not eq(Saci::Cable::LocalWake.port_for("wake:unit:a"))
  end

  it "wakes every peer with the same key, ignores its own datagram and other keys" do
    a1_wakes = Atomic(Int32).new(0)
    a2_wakes = Atomic(Int32).new(0)
    b_wakes = Atomic(Int32).new(0)
    a1 = Saci::Cable::LocalWake.new("wake:unit:a", on_wake: -> { a1_wakes.add(1) })
    a2 = Saci::Cable::LocalWake.new("wake:unit:a", on_wake: -> { a2_wakes.add(1) })
    b = Saci::Cable::LocalWake.new("wake:unit:b", on_wake: -> { b_wakes.add(1) })
    begin
      a1.port.should eq(a2.port)
      a1.port.should_not eq(b.port)

      a1.signal
      cable_wake_wait_until("peer wake") { a2_wakes.get == 1 }
      sleep 100.milliseconds
      a2_wakes.get.should eq(1)
      # The sender already delivered locally: its own broadcast is ignored.
      a1_wakes.get.should eq(0)
      # A different wake key is a different port.
      b_wakes.get.should eq(0)

      # A non-wake datagram on the port is ignored, and the receiver stays up.
      intruder = UDPSocket.new
      intruder.broadcast = true
      intruder.send("not a wake", Socket::IPAddress.new(Saci::Cable::LocalWake::BROADCAST_ADDRESS, a2.port))
      sleep 100.milliseconds
      a2_wakes.get.should eq(1)
      a1.signal
      cable_wake_wait_until("wake after garbage") { a2_wakes.get == 2 }
    ensure
      a1.close
      a2.close
      b.close
    end
  end

  it "closes promptly and idempotently" do
    wake = Saci::Cable::LocalWake.new("wake:unit:close")
    wake.closed?.should be_false
    elapsed = Time.instant
    wake.close
    (Time.instant - elapsed).should be < 1.second
    wake.closed?.should be_true
    wake.close
    wake.signal # no-op after close
  end
end

describe "Saci::Cable::DbServer same-host wake channel" do
  it "delivers a peer's broadcast without waiting for the poll interval" do
    CableWakeProbeChannel.reset!
    publisher = Saci::Cable::DbServer.new(CABLE_WAKE_DB, adapter: :sqlite,
      poll_interval: 1.hour, cleanup_interval: 0, wake_key: "db-server:shared")
    subscriber = Saci::Cable::DbServer.new(CABLE_WAKE_DB, adapter: :sqlite,
      poll_interval: 1.hour, cleanup_interval: 0, wake_key: "db-server:shared")
    begin
      publisher.local_wake?.should be_true
      subscriber.local_wake?.should be_true
      publisher.wake_channel.not_nil!.port.should eq(subscriber.wake_channel.not_nil!.port)

      # Let the subscriber's boot poll finish: only then is a wake the only
      # way this broadcast can arrive within the hour-long interval.
      cable_wake_wait_until("subscriber's first poll") { subscriber.poll_count >= 1 }
      connection = cable_wake_subscriber(subscriber)

      publisher.broadcast("wake:probe", {n: 1})
      cable_wake_wait_until("wake delivery", 2.seconds) do
        CableWakeProbeChannel.received == [%({"n":1})]
      end
      connection.close
    ensure
      publisher.close
      subscriber.close
    end
  end

  it "delivers a burst exactly once per message through coalesced wakes" do
    CableWakeProbeChannel.reset!
    publisher = Saci::Cable::DbServer.new(CABLE_WAKE_DB, adapter: :sqlite,
      poll_interval: 1.hour, cleanup_interval: 0, wake_key: "db-server:burst")
    subscriber = Saci::Cable::DbServer.new(CABLE_WAKE_DB, adapter: :sqlite,
      poll_interval: 1.hour, cleanup_interval: 0, wake_key: "db-server:burst")
    begin
      cable_wake_wait_until("subscriber's first poll") { subscriber.poll_count >= 1 }
      connection = cable_wake_subscriber(subscriber)

      20.times { |i| publisher.broadcast("wake:probe", {n: i}) }
      cable_wake_wait_until("burst delivery", 3.seconds) do
        CableWakeProbeChannel.received.size == 20
      end
      # Wakes only trigger polls; the id cursor keeps delivery at-least-once
      # without duplicates.
      CableWakeProbeChannel.received.should eq((0...20).map { |i| %({"n":#{i}}) })
      connection.close
    ensure
      publisher.close
      subscriber.close
    end
  end

  it "falls back to polling when local_wake is disabled" do
    CableWakeProbeChannel.reset!
    publisher = Saci::Cable::DbServer.new(CABLE_WAKE_DB, adapter: :sqlite,
      poll_interval: 20.milliseconds, cleanup_interval: 0, local_wake: false,
      wake_key: "db-server:poll-only")
    subscriber = Saci::Cable::DbServer.new(CABLE_WAKE_DB, adapter: :sqlite,
      poll_interval: 20.milliseconds, cleanup_interval: 0, local_wake: false,
      wake_key: "db-server:poll-only")
    begin
      publisher.local_wake?.should be_false
      publisher.wake_channel.should be_nil
      subscriber.local_wake?.should be_false
      cable_wake_wait_until("subscriber's first poll") { subscriber.poll_count >= 1 }
      connection = cable_wake_subscriber(subscriber)

      publisher.broadcast("wake:probe", {fallback: true})
      cable_wake_wait_until("polling fallback", 2.seconds) do
        CableWakeProbeChannel.received == [%({"fallback":true})]
      end
      connection.close
    ensure
      publisher.close
      subscriber.close
    end
  end

  it "falls back to polling when the wake port cannot be bound" do
    errors = [] of Exception
    Saci::Cable.on_error { |ex| errors << ex }
    blocked_port = cable_wake_free_port
    blocker = UDPSocket.new
    blocker.bind("0.0.0.0", blocked_port)
    server = nil.as(Saci::Cable::DbServer?)
    begin
      server = Saci::Cable::DbServer.new(CABLE_WAKE_DB, adapter: :sqlite,
        poll_interval: 1.hour, cleanup_interval: 0, start_polling: false,
        wake_key: "db-server:blocked", wake_port: blocked_port)
      server.local_wake?.should be_false
      server.wake_channel.should be_nil
      errors.size.should eq(1)
      errors.first.should be_a(Socket::BindError)
    ensure
      server.try(&.close)
      blocker.close
      Saci::Cable.reset_error_handler!
    end
  end

  it "honours an explicit wake key and port" do
    port = cable_wake_free_port
    server = Saci::Cable::DbServer.new(CABLE_WAKE_DB, adapter: :sqlite,
      poll_interval: 1.hour, cleanup_interval: 0, start_polling: false,
      wake_key: "db-server:custom", wake_port: port)
    begin
      server.wake_key.should eq("db-server:custom")
      server.wake_channel.not_nil!.port.should eq(port)
    ensure
      server.close
    end
  end

  it "stops the wake receiver on close" do
    server = Saci::Cable::DbServer.new(CABLE_WAKE_DB, adapter: :sqlite,
      poll_interval: 1.hour, cleanup_interval: 0, wake_key: "db-server:close")
    channel = server.wake_channel.not_nil!
    begin
      channel.closed?.should be_false
    ensure
      server.close
    end
    channel.closed?.should be_true
    server.close # idempotent
  end
end

Spec.after_suite do
  CABLE_WAKE_DB.close
  File.delete(CABLE_WAKE_DB_PATH) if File.exists?(CABLE_WAKE_DB_PATH)
end
