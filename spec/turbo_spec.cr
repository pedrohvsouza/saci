require "spec"
require "../src/saci"

describe "Saci::Turbo.turbo_frame_tag" do
  it "wraps block HTML in a turbo-frame element" do
    Saci::Turbo.turbo_frame_tag("profile") { "<p>hi</p>" }.should eq(
      %(<turbo-frame id="profile"><p>hi</p></turbo-frame>)
    )
  end

  it "emits escaped src and loading attributes when given" do
    Saci::Turbo.turbo_frame_tag("feed", src: "/feed?page=2", loading: "lazy") { "" }.should eq(
      %(<turbo-frame id="feed" src="/feed?page=2" loading="lazy"></turbo-frame>)
    )
  end

  it "escapes the id but leaves block HTML raw (pinned)" do
    out = Saci::Turbo.turbo_frame_tag(%(a"b")) { "<p>x</p>" }
    out.should contain(%(id="a&quot;b&quot;"))
    out.should contain("<p>x</p>")
  end
end

describe "Saci::Turbo stream builders" do
  it "builds append" do
    Saci::Turbo.append("msgs", "<p>hi</p>").should eq(
      %(<turbo-stream action="append" target="msgs"><template><p>hi</p></template></turbo-stream>)
    )
  end

  it "builds prepend" do
    Saci::Turbo.prepend("msgs", "<p>top</p>").should eq(
      %(<turbo-stream action="prepend" target="msgs"><template><p>top</p></template></turbo-stream>)
    )
  end

  it "builds replace" do
    Saci::Turbo.replace("msg_1", "<p>new</p>").should eq(
      %(<turbo-stream action="replace" target="msg_1"><template><p>new</p></template></turbo-stream>)
    )
  end

  it "builds update" do
    Saci::Turbo.update("msg_1", "<p>new</p>").should eq(
      %(<turbo-stream action="update" target="msg_1"><template><p>new</p></template></turbo-stream>)
    )
  end

  it "builds remove with no template element (Rails parity, pinned)" do
    Saci::Turbo.remove("msg_1").should eq(
      %(<turbo-stream action="remove" target="msg_1"></turbo-stream>)
    )
  end

  it "builds before and after" do
    Saci::Turbo.before("msg_1", "<hr>").should eq(
      %(<turbo-stream action="before" target="msg_1"><template><hr></template></turbo-stream>)
    )
    Saci::Turbo.after("msg_1", "<hr>").should eq(
      %(<turbo-stream action="after" target="msg_1"><template><hr></template></turbo-stream>)
    )
  end

  it "keeps template HTML raw and escapes the target (pinned)" do
    out = Saci::Turbo.append(%(a"b), "<p>&lt;escaped by caller&gt;</p>")
    out.should contain(%(target="a&quot;b"))
    out.should contain("<template><p>&lt;escaped by caller&gt;</p></template>")
  end

  it "emits targets= for CSS-selector broadcasts" do
    Saci::Turbo.append("ignored", "<p>x</p>", targets: ".msg").should eq(
      %(<turbo-stream action="append" targets=".msg"><template><p>x</p></template></turbo-stream>)
    )
    Saci::Turbo.remove("ignored", targets: ".old").should eq(
      %(<turbo-stream action="remove" targets=".old"></turbo-stream>)
    )
  end
end

class TurboDemoController < Saci::Controller
  def create
    render turbo_stream: Saci::Turbo.append("msgs", "<p>#{h(params["text"]? || "hi")}</p>")
  end

  def bulk
    render turbo_stream: [Saci::Turbo.append("a", "<p>1</p>"), Saci::Turbo.remove("b")]
  end

  def via_helper
    render_turbo_stream Saci::Turbo.prepend("msgs", "<p>top</p>"), status: :ok
  end

  def frame
    render html: turbo_frame_tag("profile") { "<p>#{h(params["name"]? || "?")}</p>" }
  end
end

def turbo_router : Saci::Router
  Saci::Router.new.draw do |r|
    r.get "/create", TurboDemoController, :create
    r.get "/bulk", TurboDemoController, :bulk
    r.get "/via-helper", TurboDemoController, :via_helper
    r.get "/frame", TurboDemoController, :frame
  end
end

describe "turbo_stream rendering" do
  it "renders a single stream with the turbo-stream content type" do
    Saci::TestSession.serve(turbo_router) do |app|
      resp = app.get("/create?text=<b>Ada")
      resp.status_code.should eq(200)
      resp.headers["Content-Type"].should contain("text/vnd.turbo-stream.html")
      resp.body.should eq(
        %(<turbo-stream action="append" target="msgs"><template><p>&lt;b&gt;Ada</p></template></turbo-stream>)
      )
    end
  end

  it "joins arrays of streams into one body" do
    Saci::TestSession.serve(turbo_router) do |app|
      resp = app.get("/bulk")
      resp.headers["Content-Type"].should contain("text/vnd.turbo-stream.html")
      resp.body.should eq(
        %(<turbo-stream action="append" target="a"><template><p>1</p></template></turbo-stream>) +
        %(<turbo-stream action="remove" target="b"></turbo-stream>)
      )
    end
  end

  it "renders through render_turbo_stream with status support" do
    Saci::TestSession.serve(turbo_router) do |app|
      resp = app.get("/via-helper")
      resp.status_code.should eq(200)
      resp.headers["Content-Type"].should contain("text/vnd.turbo-stream.html")
      resp.body.should contain(%(action="prepend"))
    end
  end

  it "exposes turbo_frame_tag in controller context" do
    Saci::TestSession.serve(turbo_router) do |app|
      resp = app.get("/frame?name=<b>Ada")
      resp.body.should eq(%(<turbo-frame id="profile"><p>&lt;b&gt;Ada</p></turbo-frame>))
    end
  end
end

class RecordingCableServer < Saci::Cable::Server
  getter calls : Array(Tuple(String, String))

  def initialize
    super
    @calls = [] of Tuple(String, String)
  end

  def broadcast(stream : String, payload) : Nil
    @calls << {stream, payload.to_s}
  end
end

describe "Saci::Turbo cable broadcasts" do
  it "broadcasts every action as a turbo-stream payload on the given stream" do
    server = RecordingCableServer.new
    Saci::Turbo.broadcast_append("room:1", "msgs", "<p>1</p>", server)
    Saci::Turbo.broadcast_prepend("room:1", "msgs", "<p>0</p>", server)
    Saci::Turbo.broadcast_replace("room:1", "m1", "<p>n</p>", server)
    Saci::Turbo.broadcast_update("room:1", "m1", "<p>u</p>", server)
    Saci::Turbo.broadcast_remove("room:1", "m1", server)
    Saci::Turbo.broadcast_before("room:1", "m1", "<hr>", server)
    Saci::Turbo.broadcast_after("room:1", "m1", "<hr>", server)
    server.calls.map(&.[1]).should eq([
      Saci::Turbo.append("msgs", "<p>1</p>"),
      Saci::Turbo.prepend("msgs", "<p>0</p>"),
      Saci::Turbo.replace("m1", "<p>n</p>"),
      Saci::Turbo.update("m1", "<p>u</p>"),
      Saci::Turbo.remove("m1"),
      Saci::Turbo.before("m1", "<hr>"),
      Saci::Turbo.after("m1", "<hr>"),
    ])
    server.calls.each { |stream, _| stream.should eq("room:1") }
  end

  it "broadcasts through the default Cable.server" do
    recording = RecordingCableServer.new
    previous = Saci::Cable.server
    Saci::Cable.server = recording
    begin
      Saci::Turbo.broadcast_append("room:9", "msgs", "<p>hi</p>")
    ensure
      Saci::Cable.server = previous
    end
    recording.calls.should eq([{"room:9", Saci::Turbo.append("msgs", "<p>hi</p>")}])
  end
end
