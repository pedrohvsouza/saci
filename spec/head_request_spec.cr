require "spec"
require "socket"
require "../src/saci"

class HeadSpecController < Saci::Controller
  def show
    expires_in 5.minutes, public: true
    render text: "hello from get"
  end

  def page
    render html: "<p>#{"x" * 4000}</p>"
  end

  def create
    render text: "created", status: 201
  end
end

private def head_router : Saci::Router
  Saci::Router.new.draw do |r|
    r.get "/hello", HeadSpecController, :show
    r.get "/page", HeadSpecController, :page
    r.post "/only-post", HeadSpecController, :create
  end
end

# Sends raw requests on one keep-alive connection and returns everything
# the server wrote back (so a stray HEAD body would show up).
private def raw_exchange(port : Int32, requests : String) : String
  socket = TCPSocket.new("127.0.0.1", port)
  socket.read_timeout = 2.seconds
  socket << requests
  socket.flush
  socket.gets_to_end
ensure
  socket.try(&.close)
end

describe "HEAD requests" do
  it "use the GET route and send its headers without a body" do
    Saci::TestSession.serve(head_router) do |app|
      get = app.get("/hello")
      head = app.head("/hello")
      head.status_code.should eq(200)
      head.body.should eq("")
      head.headers["Content-Length"].should eq(get.body.bytesize.to_s)
      head.headers["Cache-Control"].should eq(get.headers["Cache-Control"])
      head.headers["Content-Type"].should eq(get.headers["Content-Type"])
    end
  end

  it "never write the body on the wire, so keep-alive stays in sync" do
    Saci::TestSession.serve(head_router) do |app|
      wire = raw_exchange(app.port,
        "HEAD /hello HTTP/1.1\r\nHost: localhost\r\n\r\n" \
        "GET /hello HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
      wire.scan("HTTP/1.1 200 OK").size.should eq(2)
      wire.scan("hello from get").size.should eq(1)
      wire.should end_with("hello from get")
    end
  end

  it "report the compressed length when the GET would be gzipped" do
    Saci::TestSession.serve(head_router) do |app|
      gzip = HTTP::Headers{"Accept-Encoding" => "gzip"}
      get = app.get("/page", gzip)
      head = app.head("/page", gzip)
      head.status_code.should eq(200)
      head.headers["Content-Encoding"]?.should eq(get.headers["Content-Encoding"]?)
      if length = get.headers["Content-Length"]?
        head.headers["Content-Length"].should eq(length)
      end
    end
  end

  it "stay 404 for unknown paths and routes without GET" do
    Saci::TestSession.serve(head_router) do |app|
      app.head("/nope").status_code.should eq(404)
      app.head("/only-post").status_code.should eq(404)
    end
  end

  it "resolve to the GET route in the router" do
    router = head_router
    found = router.find("HEAD", "/hello").not_nil!
    found[0].http_method.should eq("GET")
    router.find("HEAD", "/only-post").should be_nil
  end
end
