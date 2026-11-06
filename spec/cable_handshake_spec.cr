require "spec"
require "../src/saci"
require "../src/saci/cable_testing"

# The websocket upgrade request is exposed on the connection so the
# identify hook can authenticate with cookies/session and check Origin.
class CableHandshakeWhoChannel < Saci::Cable::Channel
  def subscribed
    stream_from "handshake:who"
  end

  def receive(data)
    transmit({user: connection.current_user.to_s, origin: connection.headers.try(&.["Origin"]?)})
  end
end

describe "Saci::Cable handshake access" do
  it "exposes request, headers, cookies and session to the identify hook" do
    router = Saci::Router.new.draw { |r| r.cable "/cable", CableHandshakeWhoChannel }
    seen = [] of String
    Saci::Cable.on_error { |ex| seen << "error: #{ex.class}: #{ex.message}" }
    Saci::Cable.identify do |conn|
      seen << "request" if conn.request
      seen << "context" if conn.context
      if conn.headers.try(&.["Origin"]?) == "http://evil.test"
        conn.reject_unauthorized_connection
      end
      who = conn.cookies.try(&.["who"])
      conn.reject_unauthorized_connection if who.nil?
      seen << "session" if conn.session
      conn.current_user = who
    end

    Saci::TestSession.serve(router) do |app|
      headers = HTTP::Headers{"Cookie" => "who=ada", "Origin" => "http://good.test"}
      client = app.cable_client(headers: headers)
      begin
        identifier = begin
          client.subscribe("CableHandshakeWhoChannel")
        rescue ex
          raise "#{ex.message} (hook saw: #{seen})"
        end
        seen.should eq(["request", "context", "session"])
        client.send_message(identifier, {ping: 1})
        reply = client.next_message
        until reply["message"]?
          reply = client.next_message
        end
        reply["message"]["user"].as_s.should eq("ada")
        reply["message"]["origin"].as_s.should eq("http://good.test")
      ensure
        client.close
      end

      # Connection-level rejection closes the socket before `welcome`.
      expect_raises(Exception) do
        app.cable_client(headers: HTTP::Headers{"Origin" => "http://good.test"}).subscribe("CableHandshakeWhoChannel", timeout: 300.milliseconds)
      end
      expect_raises(Exception) do
        app.cable_client(headers: HTTP::Headers{"Cookie" => "who=eve", "Origin" => "http://evil.test"}).subscribe("CableHandshakeWhoChannel", timeout: 300.milliseconds)
      end
    end
  ensure
    Saci::Cable.reset_identify_hook!
    Saci::Cable.reset_error_handler!
  end

  it "leaves request/cookies nil for connections built without a context" do
    server = Saci::Cable::Server.new
    connection = Saci::Cable::Connection.new(HTTP::WebSocket.new(IO::Memory.new), Saci::Params.new, server)
    connection.request.should be_nil
    connection.headers.should be_nil
    connection.cookies.should be_nil
    connection.session.should be_nil
  end
end
