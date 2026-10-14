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
