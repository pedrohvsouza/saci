require "spec"
require "file_utils"
require "../src/saci"
require "../src/saci/cable_testing"

# ---------------------------------------------------------------------------
# Cable extras: record-derived streams (G94), periodically timers (G95),
# remote disconnect (G96), test helpers (G97), identifiers (G203), DB
# adapter (G93/G164), PostgreSQL entry point (G282) and the concurrency
# model (G281). No live Redis/PostgreSQL needed: the DB adapter runs on
# SQLite and the Postgres LISTEN/NOTIFY stub is asserted via its raise path.
# ---------------------------------------------------------------------------

CABLE_EXTRAS_DB_PATH = "/tmp/opencode/saci_cable_extras_test.db"

# Models used by G94: one with default `saci:Model:id` naming, one declaring
# a Rails-like `broadcasts_for :articles` prefix.
class CableExtrasPost < Saci::Record::Base
  column id : Int64, primary: true
  column title : String
end

class CableExtrasArticle < Saci::Record::Base
  column id : Int64, primary: true
  column title : String
  broadcasts_for :articles
end

class CableExtrasBare < Saci::Record::Base
  column id : Int64, primary: true
  broadcasts_for
end

# Non-ORM record-like object (generic fallback path).
struct CableFakeRecord
  getter id : Int64

  def initialize(@id : Int64)
  end
end

class CableStreamsChannel < Saci::Cable::Channel
  def subscribed
    stream_for CableExtrasPost.new(id: 7_i64, title: "streamed")
  end
end

class CablePrefixedStreamChannel < Saci::Cable::Channel
  def subscribed
    stream_for CableExtrasPost.new(id: 8_i64, title: "prefixed"), "rooms"
  end
end

class CableTimerChannel < Saci::Cable::Channel
  @@ticks = Atomic(Int32).new(0)
  @@errors = Atomic(Int32).new(0)

  periodically(20.milliseconds) { CableTimerChannel.tick }
  periodically(20.milliseconds) { CableTimerChannel.fail_tick }

  def self.tick : Nil
    @@ticks.add(1)
  end

  def self.fail_tick : Nil
    @@errors.add(1)
    raise "timer boom"
  end

  def self.ticks : Int32
    @@ticks.get
  end

  def self.errors : Int32
    @@errors.get
  end

  def self.reset! : Nil
    @@ticks.set(0)
    @@errors.set(0)
  end

  def subscribed
    stream_from "timer:test"
  end
end

class CableIdentifiedChannel < Saci::Cable::Channel
  identified_by :current_user, CableExtrasPost

  def subscribed
    user = current_user
    stream_from user ? "identified:#{user["id"]}" : "identified:none"
  end
end

class CableRawIdentifiedChannel < Saci::Cable::Channel
  identified_by :current_user

  def subscribed
    stream_from "raw-identified:#{current_user}"
  end
end

class CableHelpersEchoChannel < Saci::Cable::Channel
  def subscribed
    stream_from "helpers:echo"
  end

  def receive(data)
    connection.server.broadcast("helpers:echo", {got: data["text"]?})
  end
end

class CableDbProbeChannel < Saci::Cable::Channel
  @@received = [] of String
  @@mutex = Mutex.new

  def self.received : Array(String)
    @@mutex.synchronize { @@received.dup }
  end

  def self.reset! : Nil
    @@mutex.synchronize { @@received.clear }
  end

  def subscribed
    stream_from "db:probe"
  end

  def deliver(identifier : String, payload) : Nil
    @@mutex.synchronize { @@received << payload.to_json }
  end
end

# Instance-level harness for the included test-helper module.
class CableExtrasHelperHarness
  include Saci::Cable::TestHelpers
end

def cable_extras_wait_until(desc : String, timeout : Time::Span = 5.seconds, &) : Nil
  deadline = Time.instant + timeout
  until yield
    raise "timed out waiting for #{desc}" if Time.instant > deadline
    sleep 10.milliseconds
  end
end

def cable_extras_fake_connection(server : Saci::Cable::Server,
                                 params : Hash(String, String) = {} of String => String)
  io = IO::Memory.new
  socket = HTTP::WebSocket.new(io)
  connection = Saci::Cable::Connection.new(socket, Saci::Params.new(params), server)
  server.register(connection)
  {connection, io}
end

def cable_extras_subscribe(server : Saci::Cable::Server, channel_class : Saci::Cable::Channel.class,
                           connection : Saci::Cable::Connection, name : String = "spec")
  identifier = Saci::Cable.identifier_for(name)
  server.subscribe(channel_class, connection, identifier, {} of String => JSON::Any)
end

describe "Saci::Cable record-derived streams (G94)" do
  it "derives default and custom-prefix stream names" do
    post = CableExtrasPost.new(id: 5_i64, title: "hello")
    article = CableExtrasArticle.new(id: 2_i64, title: "news")

    Saci::Cable.broadcasting_for(post).should eq("saci:CableExtrasPost:5")
    Saci::Cable.broadcasting_for(article).should eq("articles:2")
    Saci::Cable.broadcasting_for(post, prefix: "rooms").should eq("rooms:5")
    Saci::Cable.broadcasting_for("raw:1").should eq("raw:1")
    Saci::Cable.broadcasting_for("raw:1", prefix: "rooms").should eq("rooms:raw:1")
    Saci::Cable.broadcasting_for(CableExtrasPost.new).should eq("saci:CableExtrasPost:new")
    Saci::Cable.broadcasting_for(CableExtrasBare.new(id: 1_i64)).should eq("cable_extras_bares:1")
    Saci::Cable.broadcasting_for(CableFakeRecord.new(3_i64)).should eq("saci:CableFakeRecord:3")
    Saci::Cable.broadcasting_for(CableFakeRecord.new(3_i64), prefix: "fake").should eq("fake:3")
    post.broadcasting_stream.should eq("saci:CableExtrasPost:5")
    CableExtrasArticle.new(id: 9_i64).broadcasting_stream.should eq("articles:9")
  end

  it "supports collections with sorted, joined names" do
    post = CableExtrasPost.new(id: 5_i64)
    article = CableExtrasArticle.new(id: 2_i64)
    Saci::Cable.broadcasting_for([post, article]).should eq("articles:2:saci:CableExtrasPost:5")
    Saci::Cable.broadcasting_for([post, article], prefix: "x").should eq("x:2:x:5")
    Saci::Cable.broadcasting_for([post] of CableExtrasPost).should eq("saci:CableExtrasPost:5")
  end

  it "exposes class-level broadcasts_for and broadcast_to on channels" do
    post = CableExtrasPost.new(id: 5_i64)
    Saci::Cable::Channel.broadcasts_for(post).should eq("saci:CableExtrasPost:5")
    Saci::Cable::Channel.broadcasting_for(post).should eq("saci:CableExtrasPost:5")

    server = Saci::Cable::TestServer.new
    Saci::Cable::Channel.broadcast_to(post, {ping: true}, server: server)
    server.broadcasts("saci:CableExtrasPost:5").size.should eq(1)
    server.broadcasts("saci:CableExtrasPost:5").first["ping"].as_bool.should be_true
  end

  it "subscribes channels to record streams via stream_for" do
    server = Saci::Cable::Server.new
    connection, _io = cable_extras_fake_connection(server)
    channel = cable_extras_subscribe(server, CableStreamsChannel, connection, "CableStreamsChannel")
    channel.should_not be_nil
    server.has_stream?("saci:CableExtrasPost:7").should be_true
    CableExtrasHelperHarness.new.assert_has_stream_for(CableExtrasPost.new(id: 7_i64), nil, server)

    server.unsubscribe(connection, channel.not_nil!.identifier)
    server.has_stream?("saci:CableExtrasPost:7").should be_false
    connection.close
  end

  it "supports custom prefixes through stream_for" do
    server = Saci::Cable::Server.new
    connection, _io = cable_extras_fake_connection(server)
    channel = cable_extras_subscribe(server, CablePrefixedStreamChannel, connection, "CablePrefixedStreamChannel")
    server.has_stream?("rooms:8").should be_true
    server.unsubscribe(connection, channel.not_nil!.identifier)
    connection.close
  end
end

describe "Saci::Cable periodically timers (G95)" do
  it "runs every declared timer and cancels them on unsubscribe" do
    CableTimerChannel.reset!
    handled = Atomic(Int32).new(0)
    Saci::Cable.on_error do |ex|
      handled.add(1) if ex.message == "timer boom"
    end

    server = Saci::Cable::Server.new
    connection, _io = cable_extras_fake_connection(server)
    channel = cable_extras_subscribe(server, CableTimerChannel, connection, "CableTimerChannel").not_nil!.as(CableTimerChannel)

    cable_extras_wait_until("timers to fire") { CableTimerChannel.ticks >= 2 }
    CableTimerChannel.errors.should be >= 1
    handled.get.should be >= 1
    channel.periodic_timers.size.should eq(2)

    server.unsubscribe(connection, channel.identifier)
    channel.periodic_timers.should be_empty
    stopped = CableTimerChannel.ticks
    sleep 80.milliseconds
    CableTimerChannel.ticks.should eq(stopped)
    connection.close
  ensure
    Saci::Cable.reset_error_handler!
  end

  it "cancels timers when the connection closes" do
    CableTimerChannel.reset!
    Saci::Cable.on_error { |_ex| }
    server = Saci::Cable::Server.new
    connection, _io = cable_extras_fake_connection(server)
    channel = cable_extras_subscribe(server, CableTimerChannel, connection, "CableTimerChannel").not_nil!.as(CableTimerChannel)
    cable_extras_wait_until("timer to fire") { CableTimerChannel.ticks >= 1 }

    server.unsubscribe_connection(connection)
    channel.periodic_timers.should be_empty
    connection.close
  ensure
    Saci::Cable.reset_error_handler!
  end
end

describe "Saci::Cable identifiers and remote disconnect (G96/G203)" do
  it "exposes typed identifiers to channels" do
    server = Saci::Cable::Server.new
    connection, _io = cable_extras_fake_connection(server)
    user = CableExtrasPost.new(id: 42_i64, title: "alice")
    connection.set_identifier("current_user", user)

    channel = cable_extras_subscribe(server, CableIdentifiedChannel, connection, "CableIdentifiedChannel").not_nil!.as(CableIdentifiedChannel)
    channel.current_user.should eq(user)
    server.has_stream?("identified:42").should be_true
    connection.close
  end

  it "supports untyped identifiers (wire values/strings)" do
    server = Saci::Cable::Server.new
    connection, _io = cable_extras_fake_connection(server)
    connection.set_identifier("current_user", "alice")
    channel = cable_extras_subscribe(server, CableRawIdentifiedChannel, connection, "CableRawIdentifiedChannel")
    channel.should_not be_nil
    server.has_stream?("raw-identified:alice").should be_true
    connection.close
  end

  it "resolves the identify hook and rejects unauthorized connections" do
    server = Saci::Cable::Server.new
    connection, _io = cable_extras_fake_connection(server, {"token" => "good"})
    user = CableExtrasPost.new(id: 1_i64, title: "hook")
    Saci::Cable.identify do |conn|
      conn.reject_unauthorized_connection if conn.params["token"]? != "good"
      conn.current_user = user
    end

    Saci::Cable.run_identify(connection).should be_true
    connection.current_user.should eq(user)

    rejected, _io2 = cable_extras_fake_connection(server, {"token" => "bad"})
    Saci::Cable.run_identify(rejected).should be_false
    rejected.rejected?.should be_true
    rejected.closed?.should be_true
    connection.close
  ensure
    Saci::Cable.reset_identify_hook!
  end

  it "filters and disconnects remote connections" do
    server = Saci::Cable::Server.new
    alice, _io_a = cable_extras_fake_connection(server)
    bob, _io_b = cable_extras_fake_connection(server)
    alice_user = CableExtrasPost.new(id: 1_i64)
    bob_user = CableExtrasPost.new(id: 2_i64)
    alice.set_identifier("current_user", alice_user)
    bob.set_identifier("current_user", bob_user)

    server.remote_connections.where(current_user: alice_user).to_a.size.should eq(1)
    server.remote_connections.where({"current_user" => alice_user}).to_a.size.should eq(1)
    server.remote_connections.where({:current_user => alice_user}).to_a.size.should eq(1)
    server.remote_connections.where(current_user: 2_i64).to_a.size.should eq(1)
    server.remote_connections.where(identifier: alice.identifier).to_a.size.should eq(1)

    server.remote_connections.where(current_user: alice_user).disconnect.should eq(1)
    alice.closed?.should be_true
    bob.closed?.should be_false
    server.open_connections_count.should eq(1)

    server.disconnect_all.should eq(1)
    server.open_connections_count.should eq(0)
    bob.closed?.should be_true
  end

  it "supports Channel#disconnect and reject_unauthorized_connection" do
    server = Saci::Cable::Server.new
    connection, _io = cable_extras_fake_connection(server)
    channel = cable_extras_subscribe(server, CableTimerChannel, connection, "CableTimerChannel").not_nil!
    channel.disconnect
    connection.closed?.should be_true
    server.open_connections_count.should eq(0)

    other, _io2 = cable_extras_fake_connection(server)
    expect_raises(Saci::Cable::RejectedError) do
      other.reject_unauthorized_connection
    end
    other.rejected?.should be_true
    other.closed?.should be_true
  end
end

describe "Saci::Cable test helpers (G97)" do
  it "captures broadcasts in the test adapter" do
    server = Saci::Cable::TestServer.new
    server.broadcast("room:1", {n: 1})
    server.broadcast("room:1", {n: 2})
    server.broadcast("room:2", {n: 3})
    server.broadcasts("room:1").size.should eq(2)
    server.broadcast_count("room:2").should eq(1)
    server.broadcasts.first["n"].as_i.should eq(1)
    server.clear_broadcasts
    server.broadcasts("room:1").should be_empty
    Saci::Cable::TestAdapter.new.should be_a(Saci::Cable::TestServer)
  end

  it "provides TestSession assertions end to end" do
    server = Saci::Cable::TestServer.new
    router = Saci::Router.new.draw { |r| r.cable "/cable", CableHelpersEchoChannel, server: server }

    Saci::TestSession.serve(router) do |app|
      client = app.cable_client
      begin
        app.assert_no_broadcasts("helpers:echo", server)
        identifier = client.subscribe("CableHelpersEchoChannel")
        app.assert_has_stream("helpers:echo", server)
        app.assert_has_stream_for("helpers:echo", nil, server)
        app.open_connections(server).size.should be >= 1

        client.send_message(identifier, {text: "hi"})
        cable_extras_wait_until("helper broadcast") { app.broadcasts("helpers:echo", server).size == 1 }
        app.assert_broadcasts("helpers:echo", 1, server)
        app.broadcasts("helpers:echo", server).first["got"].as_s.should eq("hi")

        app.assert_reject_connection { app.cable_client.subscribe("NopeChannel") }
      ensure
        client.close
      end
    end
  end

  it "asserts rejected fake connections" do
    server = Saci::Cable::Server.new
    connection, _io = cable_extras_fake_connection(server)
    connection.reject_unauthorized_connection rescue nil
    CableExtrasHelperHarness.new.assert_reject_connection(connection)

    open_server = Saci::Cable::Server.new
    open, _io2 = cable_extras_fake_connection(open_server)
    expect_raises(Exception, /rejected/) do
      CableExtrasHelperHarness.new.assert_reject_connection(open)
    end
    open.close
  end
end

def cable_extras_db : DB::Database
  Saci::Record.database("primary").as(DB::Database)
end

describe "Saci::Cable DB adapter (G93/G164) and PostgreSQL entry (G282)" do
  before_all do
    File.delete(CABLE_EXTRAS_DB_PATH) if File.exists?(CABLE_EXTRAS_DB_PATH)
    Saci::Record.connection = DB.open("sqlite3://#{CABLE_EXTRAS_DB_PATH}")
  end

  after_all do
    cable_extras_db.close
    File.delete(CABLE_EXTRAS_DB_PATH) if File.exists?(CABLE_EXTRAS_DB_PATH)
  end

  it "generates portable schema/placeholder SQL" do
    adapter = Saci::Cable::DbAdapter.new(cable_extras_db, :sqlite)
    adapter.create_table_sql.should contain("INTEGER PRIMARY KEY AUTOINCREMENT")
    adapter.create_table_sql.should contain("saci_cable_messages")
    adapter.adapt("SELECT ? WHERE id > ?").should eq("SELECT ? WHERE id > ?")

    pg = Saci::Cable::DbAdapter.new(cable_extras_db, :postgres)
    pg.create_table_sql.should contain("BIGSERIAL PRIMARY KEY")
    pg.adapt("SELECT ? WHERE id > ?").should eq("SELECT $1 WHERE id > $2")
    pg.insert_sql.should contain("VALUES (?, ?, ?)")

    mysql = Saci::Cable::DbAdapter.new(cable_extras_db, :mysql)
    mysql.create_table_sql.should contain("AUTO_INCREMENT")
    mysql.quote("x").should eq("`x`")
  end

  it "fans out between two SQLite-backed servers via polling" do
    CableDbProbeChannel.reset!
    server_a = Saci::Cable::DbServer.new(cable_extras_db, poll_interval: 1.hour, cleanup_interval: 0, start_polling: false)
    server_b = Saci::Cable::DbServer.new(cable_extras_db, poll_interval: 1.hour, cleanup_interval: 0, start_polling: false)
    begin
      connection_a, _io_a = cable_extras_fake_connection(server_a)
      connection_b, _io_b = cable_extras_fake_connection(server_b)
      channel_a = cable_extras_subscribe(server_a, CableDbProbeChannel, connection_a, "CableDbProbeChannel")
      channel_b = cable_extras_subscribe(server_b, CableDbProbeChannel, connection_b, "CableDbProbeChannel")
      channel_a.should_not be_nil
      channel_b.should_not be_nil

      server_a.broadcast("db:probe", {n: 1})
      # The publisher delivers locally without waiting for a poll...
      CableDbProbeChannel.received.should eq([%({"n":1})])
      # ...and the peer picks the row up on its next poll.
      server_b.poll.should eq(1)
      CableDbProbeChannel.received.size.should eq(2)
      CableDbProbeChannel.received.last.should eq(%({"n":1}))

      # A server never re-delivers its own rows.
      server_a.poll.should eq(0)
      server_b.poll.should eq(0)
      CableDbProbeChannel.received.size.should eq(2)

      connection_a.close
      connection_b.close
    ensure
      server_a.close
      server_b.close
    end
  end

  it "fans out automatically through the background poller" do
    CableDbProbeChannel.reset!
    server_a = Saci::Cable::DbServer.new(cable_extras_db, poll_interval: 25.milliseconds, cleanup_interval: 0)
    server_b = Saci::Cable::DbServer.new(cable_extras_db, poll_interval: 25.milliseconds, cleanup_interval: 0)
    begin
      connection_a, _io_a = cable_extras_fake_connection(server_a)
      connection_b, _io_b = cable_extras_fake_connection(server_b)
      cable_extras_subscribe(server_a, CableDbProbeChannel, connection_a, "CableDbProbeChannel")
      cable_extras_subscribe(server_b, CableDbProbeChannel, connection_b, "CableDbProbeChannel")

      server_a.broadcast("db:probe", {auto: true})
      cable_extras_wait_until("peer poller to deliver") { CableDbProbeChannel.received.size >= 2 }
      CableDbProbeChannel.received.count { |raw| raw.includes?("auto") }.should eq(2)

      connection_a.close
      connection_b.close
    ensure
      server_a.close
      server_b.close
    end
  end

  it "delivers bare payloads written by external tools" do
    CableDbProbeChannel.reset!
    server = Saci::Cable::DbServer.new(cable_extras_db, adapter: :sqlite, start_polling: false, cleanup_interval: 0)
    begin
      connection, _io = cable_extras_fake_connection(server)
      cable_extras_subscribe(server, CableDbProbeChannel, connection, "CableDbProbeChannel")
      server.adapter.insert("db:probe", %({"external":true}), Time.utc)
      server.poll.should eq(1)
      CableDbProbeChannel.received.should eq([%({"external":true})])
      connection.close
    ensure
      server.close
    end
  end

  it "cleans up rows older than the retention window" do
    adapter = Saci::Cable::DbAdapter.new(cable_extras_db, :sqlite, "saci_cable_cleanup_test")
    adapter.ensure_schema!
    adapter.insert("old", %({"sender":"x","message":1}), Time.utc - 2.days)
    adapter.insert("new", %({"sender":"x","message":2}), Time.utc)
    adapter.cleanup_before((Time.utc - 1.day).to_unix_ms).should eq(1)
    adapter.max_id.should be >= 1_i64
  end

  it "raises a clear error when LISTEN/NOTIFY is requested" do
    Saci::Cable::PostgresServer.listen_notify_supported?.should be_false
    expect_raises(NotImplementedError, /LISTEN\/NOTIFY/) do
      Saci::Cable::PostgresServer.new(cable_extras_db, listen_notify: true)
    end
  end
end

describe "Saci::Cable concurrency model (G281)" do
  it "bounds connections and buffers outbound frames" do
    server = Saci::Cable::Server.new(max_connections: 1)
    first, io = cable_extras_fake_connection(server)
    first.message_buffer_size.should eq(Saci::Cable::Connection::DEFAULT_MESSAGE_BUFFER_SIZE)

    second_io = IO::Memory.new
    second = Saci::Cable::Connection.new(HTTP::WebSocket.new(second_io), Saci::Params.new, server, message_buffer_size: 1)
    server.register(second).should be_false
    server.open_connections_count.should eq(1)

    first.send_json({hello: "world"})
    first.flush
    io.to_s.should contain("hello")
    first.overflowed?.should be_false

    first.close
    second.close
    server.unregister(second)
  end
end
