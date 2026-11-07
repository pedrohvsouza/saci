require "spec"
require "http/client"
require "../src/saci"

class HttpServerBigController < Saci::Controller
  def show
    render plain: "x" * 300_000
  end

  def echo
    render plain: (params["data"]? || "").size.to_s
  end
end

describe Saci::HTTPServer do
  it "defaults to small, GC-friendly per-socket and websocket buffers" do
    config = Saci::Configuration.new
    config.socket_buffer_size.should eq(4000)
    config.websocket_buffer_size.should eq(2000)
  end

  it "applies the websocket buffer size and still assembles larger messages" do
    received = Channel(String).new(1)
    router = Saci::Router.new.draw do |r|
      r.websocket("/echo") { |socket, _ctx, _params| socket.on_message { |m| received.send(m) } }
    end
    Saci::TestSession.serve(router) do |app|
      HTTP::WebSocket.read_buffer_size.should eq(Saci.config.websocket_buffer_size)
      ws = HTTP::WebSocket.new(app.host, "/echo", app.port)
      spawn { ws.run }
      big = "z" * 50_000
      ws.send(big)
      select
      when m = received.receive
        m.should eq(big)
      when timeout(5.seconds)
        fail "no message"
      end
      ws.close
    end
  end

  it "streams bodies larger than the socket buffer both ways" do
    router = Saci::Router.new.draw do |r|
      r.get "/big", HttpServerBigController, :show
      r.post "/echo", HttpServerBigController, :echo
    end
    Saci::TestSession.serve(router) do |app|
      client = HTTP::Client.new(app.host, app.port)
      begin
        client.get("/big").body.size.should eq(300_000)
        client.post("/echo", form: {"data" => "y" * 200_000}).body.should eq("200000")
        # Keep-alive: the same socket keeps working after big transfers.
        client.get("/big").body.size.should eq(300_000)
      ensure
        client.close
      end
    end
  end

  it "keeps the stdlib buffer when configured with nil" do
    server = Saci::HTTPServer.new(->(ctx : HTTP::Server::Context) { ctx.response.print("ok") }, nil)
    server.socket_buffer_size.should be_nil
  end
end
