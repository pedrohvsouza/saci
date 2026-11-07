require "spec"
require "../src/saci"

# Encode-once broadcast fan-out: a broadcast is serialised once per process
# and each subscription's frame is spliced from that shared String. These
# specs pin the wire format (byte-identical to the previous per-subscriber
# `{"identifier" => ..., "message" => ...}.to_json`), the single encode,
# identifier escaping and compatibility with `Channel#deliver` overrides.

# Connection that records outbound frames instead of writing them, so the
# exact bytes a client would receive can be compared. `send_json` delegates
# to `send_raw`, so confirmations are recorded too (filtered by `#messages`).
class CableFanoutRecordingConnection < Saci::Cable::Connection
  @recorded = [] of String
  @recorded_mutex = Mutex.new

  def send_raw(text : String) : Nil
    @recorded_mutex.synchronize { @recorded << text }
  end

  # Broadcast/transmit frames only (drops `{"type":...}` control frames).
  def messages : Array(String)
    @recorded_mutex.synchronize { @recorded.reject(&.starts_with?(%({"type":))) }
  end
end

class CableFanoutChannel < Saci::Cable::Channel
  def subscribed
    stream_from "fanout:room"
  end
end

# Overrides `deliver`: must keep receiving the payload object.
class CableFanoutOverrideChannel < Saci::Cable::Channel
  @@received = [] of String
  @@mutex = Mutex.new

  def self.received : Array(String)
    @@mutex.synchronize { @@received.dup }
  end

  def self.reset! : Nil
    @@mutex.synchronize { @@received.clear }
  end

  def subscribed
    stream_from "fanout:room"
  end

  def deliver(identifier : String, payload) : Nil
    @@mutex.synchronize { @@received << "#{payload.class.name}:#{payload.to_json}" }
  end
end

# Inherits the override without redefining it.
class CableFanoutOverrideChild < CableFanoutOverrideChannel
end

# Payload whose serialisation is counted (`to_json`, `to_json(io)` and
# nested builder writes all funnel into `to_json(JSON::Builder)`).
class CableFanoutCountingPayload
  @@encodes = Atomic(Int32).new(0)

  def self.encodes : Int32
    @@encodes.get
  end

  def self.reset! : Nil
    @@encodes.set(0)
  end

  def to_json(json : JSON::Builder) : Nil
    @@encodes.add(1)
    json.object do
      json.field "text", "hello"
      json.field "n", 1
    end
  end
end

def cable_fanout_connection(server : Saci::Cable::Server) : CableFanoutRecordingConnection
  connection = CableFanoutRecordingConnection.new(HTTP::WebSocket.new(IO::Memory.new), Saci::Params.new, server)
  server.register(connection)
  connection
end

def cable_fanout_subscribe(server : Saci::Cable::Server, connection : Saci::Cable::Connection,
                           identifier : String,
                           channel_class : Saci::Cable::Channel.class = CableFanoutChannel) : Saci::Cable::Channel
  channel = server.subscribe(channel_class, connection, identifier, {} of String => JSON::Any)
  channel.should_not be_nil
  channel.not_nil!
end

# The frame format produced before the encode-once change.
def cable_fanout_legacy_frame(identifier : String, payload) : String
  {"identifier" => identifier, "message" => payload}.to_json
end

describe "Saci::Cable encode-once fan-out" do
  it "sends every subscriber a frame byte-identical to the previous format" do
    server = Saci::Cable::Server.new
    idents = [
      Saci::Cable.identifier_for("CableFanoutChannel", {"room" => "1"}),
      Saci::Cable.identifier_for("CableFanoutChannel", {"room" => "1"}),
      Saci::Cable.identifier_for("CableFanoutChannel", {"room" => "1", "extra" => "x"}),
    ]
    connections = idents.map do |ident|
      connection = cable_fanout_connection(server)
      cable_fanout_subscribe(server, connection, ident)
      connection
    end
    server.stream_subscriber_count("fanout:room").should eq(3)

    payload = {"text" => %(hi "there" \\ é \u0001), "n" => 42, "f" => 1.5, "nested" => {"ok" => true}}
    server.broadcast("fanout:room", payload)

    connections.each_with_index do |connection, i|
      connection.messages.should eq([cable_fanout_legacy_frame(idents[i], payload)])
    end
    # Same identifier + same broadcast: subscribers share identical bytes.
    connections[0].messages.should eq(connections[1].messages)

    # NamedTuple payloads and nil keep the old encoding too.
    server.broadcast("fanout:room", {kind: "tuple", list: [1, 2, 3]})
    server.deliver_local("fanout:room", nil)
    connections.each_with_index do |connection, i|
      connection.messages[1].should eq(cable_fanout_legacy_frame(idents[i], {kind: "tuple", list: [1, 2, 3]}))
      connection.messages[2].should eq(cable_fanout_legacy_frame(idents[i], nil))
    end
  end

  it "encodes the payload once per broadcast regardless of subscriber count" do
    server = Saci::Cable::Server.new
    ident = Saci::Cable.identifier_for("CableFanoutChannel")
    connections = Array.new(5) do
      connection = cable_fanout_connection(server)
      cable_fanout_subscribe(server, connection, ident)
      connection
    end

    CableFanoutCountingPayload.reset!
    server.broadcast("fanout:room", CableFanoutCountingPayload.new)
    CableFanoutCountingPayload.encodes.should eq(1)

    CableFanoutCountingPayload.reset!
    server.deliver_local("fanout:room", CableFanoutCountingPayload.new)
    CableFanoutCountingPayload.encodes.should eq(1)

    expected = cable_fanout_legacy_frame(ident, JSON.parse(%({"text":"hello","n":1})))
    connections.each { |connection| connection.messages.should eq([expected, expected]) }
  end

  it "still encodes once when the test server records broadcasts" do
    server = Saci::Cable::TestServer.new
    ident = Saci::Cable.identifier_for("CableFanoutChannel")
    3.times { cable_fanout_subscribe(server, cable_fanout_connection(server), ident) }

    CableFanoutCountingPayload.reset!
    server.broadcast("fanout:room", CableFanoutCountingPayload.new)
    CableFanoutCountingPayload.encodes.should eq(1)
    server.broadcasts("fanout:room").map(&.to_json).should eq([%({"text":"hello","n":1})])
  end

  it "escapes identifiers containing quotes and backslashes as JSON strings" do
    server = Saci::Cable::Server.new
    idents = [
      Saci::Cable.identifier_for("CableFanoutChannel", {"room" => %(a"b\\c)}),
      %(raw "quoted" \\ back\\slash\n\ttab),
    ]
    connections = idents.map do |ident|
      connection = cable_fanout_connection(server)
      cable_fanout_subscribe(server, connection, ident)
      connection
    end

    server.broadcast("fanout:room", {"text" => "x"})
    connections.each_with_index do |connection, i|
      frame = connection.messages.first
      frame.should eq(cable_fanout_legacy_frame(idents[i], {"text" => "x"}))
      parsed = JSON.parse(frame)
      parsed["identifier"].as_s.should eq(idents[i])
      parsed["message"]["text"].as_s.should eq("x")
    end

    Saci::Cable.broadcast_frame(%(a"b\\c), %({"k":1})).should eq(%({"identifier":"a\\"b\\\\c","message":{"k":1}}))
  end

  it "keeps transmit byte-compatible" do
    server = Saci::Cable::Server.new
    ident = %({"channel":"CableFanoutChannel","q":"\\"x\\""})
    connection = cable_fanout_connection(server)
    channel = cable_fanout_subscribe(server, connection, ident)
    channel.transmit({"hello" => "world"})
    connection.messages.should eq([cable_fanout_legacy_frame(ident, {"hello" => "world"})])
  end

  it "routes broadcasts through Channel#deliver for subclasses that override it" do
    Saci::Cable::Channel.new(cable_fanout_connection(Saci::Cable::Server.new), "x", {} of String => JSON::Any)
      .deliver_overridden?.should be_false

    CableFanoutOverrideChannel.reset!
    CableFanoutOverrideChild.reset!
    server = Saci::Cable::Server.new
    plain_conn = cable_fanout_connection(server)
    plain = cable_fanout_subscribe(server, plain_conn, Saci::Cable.identifier_for("CableFanoutChannel"))
    override = cable_fanout_subscribe(server, cable_fanout_connection(server),
      Saci::Cable.identifier_for("CableFanoutOverrideChannel"), CableFanoutOverrideChannel)
    child = cable_fanout_subscribe(server, cable_fanout_connection(server),
      Saci::Cable.identifier_for("CableFanoutOverrideChild"), CableFanoutOverrideChild)

    plain.deliver_overridden?.should be_false
    override.deliver_overridden?.should be_true
    child.deliver_overridden?.should be_true

    CableFanoutCountingPayload.reset!
    server.broadcast("fanout:room", CableFanoutCountingPayload.new)
    # Overrides receive the original object (not a pre-encoded String).
    # Crystal class vars are per class, so the child keeps its own list.
    CableFanoutOverrideChannel.received.should eq([%(CableFanoutCountingPayload:{"text":"hello","n":1})])
    CableFanoutOverrideChild.received.should eq([%(CableFanoutCountingPayload:{"text":"hello","n":1})])
    plain_conn.messages.size.should eq(1)
    # 1 shared encode + one `payload.to_json` per override (their own code).
    CableFanoutCountingPayload.encodes.should eq(3)
  end

  it "drops subscribers for unencodable payloads without raising (as before)" do
    server = Saci::Cable::Server.new
    connection = cable_fanout_connection(server)
    cable_fanout_subscribe(server, connection, Saci::Cable.identifier_for("CableFanoutChannel"))
    server.stream_subscriber_count("fanout:room").should eq(1)

    server.broadcast("fanout:room", {"bad" => Float64::NAN})
    server.stream_subscriber_count("fanout:room").should eq(0)
    connection.messages.should be_empty
  end

  it "delivers pre-encoded messages and parses them only for deliver overrides" do
    CableFanoutOverrideChannel.reset!
    CableFanoutOverrideChild.reset!
    server = Saci::Cable::Server.new
    ident = Saci::Cable.identifier_for("CableFanoutChannel")
    connection = cable_fanout_connection(server)
    cable_fanout_subscribe(server, connection, ident)
    cable_fanout_subscribe(server, cable_fanout_connection(server),
      Saci::Cable.identifier_for("CableFanoutOverrideChannel"), CableFanoutOverrideChannel)

    message_json = %({"text":"remote","n":2})
    server.deliver_local_encoded("fanout:room", message_json)
    connection.messages.should eq([cable_fanout_legacy_frame(ident, JSON.parse(message_json))])
    CableFanoutOverrideChannel.received.should eq([%(JSON::Any:#{message_json})])
  end
end
