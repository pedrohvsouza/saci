require "spec"
require "../src/saci"

describe "logging" do
  it "filters sensitive parameters" do
    Saci.filter_params({"user" => "ada", "password" => "x", "user_token" => "y"}).should eq(
      {"user" => "ada", "password" => "[FILTERED]", "user_token" => "[FILTERED]"}
    )
  end

  it "filters via Params#filtered" do
    Saci::Params.new({"a" => "1", "password" => "x"}).filtered.should eq(
      {"a" => "1", "password" => "[FILTERED]"}
    )
  end

  it "builds request log lines" do
    line = Saci.request_log_line("GET", "/posts", 200, 3.24, {"a" => "1"}, "abc123")
    line.should contain("Completed 200")
    line.should contain("3.2ms")
    line.should contain("GET /posts")
    line.should contain(%({"a" => "1"}))
    line.should contain("[abc123]")
  end

  it "supports nested tagged contexts" do
    Saci.current_tags.should be_empty
    Saci.tagged("a", "b") do
      Saci.current_tags.should eq(["a", "b"])
      Saci.tagged("c") do
        Saci.current_tags.should eq(["a", "b", "c"])
      end
      Saci.current_tags.should eq(["a", "b"])
    end
    Saci.current_tags.should be_empty
  end

  it "keeps tags isolated across fibers" do
    done = Channel(String).new(2)
    spawn do
      Saci.tagged("one") do
        sleep 0.05.seconds
        done.send(Saci.current_tags.join(","))
      end
    end
    spawn do
      Saci.tagged("two") do
        sleep 0.05.seconds
        done.send(Saci.current_tags.join(","))
      end
    end
    [done.receive, done.receive].sort.should eq(["one", "two"])
  end

  it "emits request ids and completed lines" do
    Saci.log_requests.should be_true
    router = Saci::Router.new.draw do |r|
      r.get("/ping") { |ctx, _params| ctx.response.print("pong") }
    end
    Saci::TestSession.serve(router) do |app|
      resp = app.get("/ping?password=secret")
      resp.status_code.should eq(200)
      resp.headers["X-Request-Id"]?.should_not be_nil
    end
  end
end
