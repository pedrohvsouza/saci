require "spec"
require "../src/saci"

class ViewsDemoController < Saci::Controller
  def show
    @title = params["name"]? || "stranger"
    render_template(:show)
  end

  def plain
    render_template("demo/plain", layout: false)
  end

  def form_demo
    render html: form_with("/submit") { |f| f.text_field("name", params["name"]?) + f.submit("Go") }
  end

  def link_demo
    render html: link_to("Home", "/") + link_to("Delete", "/things/1", method: :delete)
  end

  def cached
    @stamp = Time.utc.to_unix_ms.to_s
    return unless stale?(etag: "v1")
    render text: "fresh-#{@stamp}"
  end
end

def views_router : Saci::Router
  Saci::Router.new.draw do |r|
    r.get "/show", ViewsDemoController, :show
    r.get "/plain", ViewsDemoController, :plain
    r.get "/form", ViewsDemoController, :form_demo
    r.get "/links", ViewsDemoController, :link_demo
    r.get "/cached", ViewsDemoController, :cached
  end
end

describe "views" do
  it "renders templates with layouts, ivars, helpers and partials" do
    Saci::TestSession.serve(views_router) do |app|
      resp = app.get("/show?name=<b>Ada")
      resp.status_code.should eq(200)
      resp.headers["Content-Type"].should contain("text/html")
      resp.body.should contain("<html>")
      resp.body.should contain("<h1>&lt;b&gt;Ada</h1>")
      resp.body.should contain("<span>badge</span>")
      resp.body.should_not contain("<b>Ada")
    end
  end

  it "renders explicit paths without a layout" do
    Saci::TestSession.serve(views_router) do |app|
      resp = app.get("/plain")
      resp.body.should contain("<p>plain</p>")
      resp.body.should_not contain("<html>")
    end
  end

  it "builds escaped forms with method override and CSRF tokens" do
    Saci::TestSession.serve(views_router) do |app|
      resp = app.get("/form?name=a\"b")
      resp.body.should contain(%(<form action="/submit" method="post">))
      resp.body.should contain(%(name="authenticity_token"))
      resp.body.should contain(%(value="a&quot;b"))
      resp.body.should contain(%(<input type="submit" value="Go">))
    end
  end

  it "builds links and standalone delete forms" do
    Saci::TestSession.serve(views_router) do |app|
      resp = app.get("/links")
      resp.body.should contain(%(<a href="/">Home</a>))
      resp.body.should contain(%(name="_method" value="DELETE"))
      resp.body.should contain(%(name="authenticity_token"))
    end
  end

  it "returns fresh bodies then 304s on etag match" do
    Saci::TestSession.serve(views_router) do |app|
      first = app.get("/cached")
      first.status_code.should eq(200)
      etag = first.headers["ETag"]?
      etag.should_not be_nil
      second = app.get("/cached", HTTP::Headers{"If-None-Match" => etag.not_nil!})
      second.status_code.should eq(304)
    end
  end
end
