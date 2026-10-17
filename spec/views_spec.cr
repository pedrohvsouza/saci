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

# -- framework web upgrades (partials, model forms, pagination, markdown, rss)

class SpecFormStory < Saci::Record::Base
  table "spec_form_stories"

  column id : Int64, primary: true
  column title : String
  column draft : Bool, default: false
  column published_on : Time
end

class SpecPartsController < Saci::Controller
  def greet
    render html: render_partial("spec_parts/greet", name: params["name"]? || "stranger")
  end

  def list
    render html: render_partial("spec_parts/comment", collection: ["one", "two"])
  end

  def aliased
    render html: render_partial("spec_parts/greet", collection: ["Ada"], as: "name")
  end

  def nested
    render html: render_partial("spec_parts/outer", value: "Ada")
  end

  def nested_collection
    render html: render_partial("spec_parts/comment_box", collection: ["one", "two"])
  end

  def model_form
    story = SpecFormStory.new(title: params["title"]? || "Draft <b>", draft: true, published_on: Time.utc(2026, 5, 1))
    story.errors.add(:title, "can't be blank") if params["err"]? == "1"
    render html: form_with("/stories", model: story, scope: "story", multipart: true) { |f|
      f.error_messages + f.text_field("title") + f.check_box("draft") +
        f.select("kind", ["tech", "news"]) + f.date_field("published_on") +
        f.file_field("avatar") + f.submit
    }
  end

  def md
    render html: markdown(params["body"]? || "")
  end

  def pages
    render html: page_numbers(params.int("page", 1) || 1, 5, "/stories")
  end

  def feed
    items = [Saci::Views::RSSItem.new("T<C", "http://x/1", "D & more", Time.utc(2026, 1, 2, 3, 4, 5))]
    render xml: rss_feed(title: "Feed & Co", link: "http://x/", description: "d", items: items)
  end
end

def spec_parts_router : Saci::Router
  Saci::Router.new.draw do |r|
    r.get "/greet", SpecPartsController, :greet
    r.get "/list", SpecPartsController, :list
    r.get "/aliased", SpecPartsController, :aliased
    r.get "/nested", SpecPartsController, :nested
    r.get "/nested-collection", SpecPartsController, :nested_collection
    r.get "/model-form", SpecPartsController, :model_form
    r.get "/md", SpecPartsController, :md
    r.get "/pages", SpecPartsController, :pages
    r.get "/feed", SpecPartsController, :feed
  end
end

describe "partials with locals and collections" do
  it "renders partials with locals" do
    Saci::TestSession.serve(spec_parts_router) do |app|
      resp = app.get("/greet?name=Ada<b>")
      resp.status_code.should eq(200)
      resp.body.should contain("<span>Hello, Ada&lt;b&gt;!</span>")
    end
  end

  it "renders partials over a collection" do
    Saci::TestSession.serve(spec_parts_router) do |app|
      resp = app.get("/list")
      resp.body.should contain(%(<div class="comment">one</div>))
      resp.body.should contain(%(<div class="comment">two</div>))
    end
  end

  it "overrides the collection variable with as:" do
    Saci::TestSession.serve(spec_parts_router) do |app|
      resp = app.get("/aliased")
      resp.body.should contain("<span>Hello, Ada!</span>")
    end
  end

  it "renders a partial that renders another partial without clobbering the outer buffer" do
    Saci::TestSession.serve(spec_parts_router) do |app|
      resp = app.get("/nested")
      resp.body.should contain(%(<div class="outer"><span>IN Ada</span>TAIL</div>))
    end
  end

  it "renders a collection whose partial renders another partial" do
    Saci::TestSession.serve(spec_parts_router) do |app|
      resp = app.get("/nested-collection")
      resp.body.should contain(%(<div class="comment-box"><div class="comment">one</div>\nBOX-END</div>))
      resp.body.should contain(%(<div class="comment-box"><div class="comment">two</div>\nBOX-END</div>))
    end
  end
end

describe "model form builder" do
  it "binds values, scopes names and escapes" do
    Saci::TestSession.serve(spec_parts_router) do |app|
      resp = app.get("/model-form")
      resp.body.should contain(%(enctype="multipart/form-data"))
      resp.body.should contain(%(name="story[title]"))
      resp.body.should contain(%(value="Draft &lt;b&gt;"))
      resp.body.should contain(%(type="hidden" name="story[draft]" value="0"))
      resp.body.should contain(%(type="checkbox" name="story[draft]"))
      resp.body.should contain("checked")
      resp.body.should contain(%(<option value="tech">tech</option>))
      resp.body.should contain(%(type="date" name="story[published_on]"))
      resp.body.should contain(%(value="2026-05-01"))
      resp.body.should contain(%(type="file" name="story[avatar]"))
      resp.body.should_not contain("field-with-errors")
    end
  end

  it "renders model errors and flags fields" do
    Saci::TestSession.serve(spec_parts_router) do |app|
      resp = app.get("/model-form?err=1")
      resp.body.should contain(%(<div class="errors"><ul>))
      resp.body.should contain("Title can&#39;t be blank")
      resp.body.should contain("field-with-errors")
    end
  end
end

describe "Saci::Views.markdown" do
  it "renders paragraphs, headings, bold, italic, code and links" do
    Saci::Views.markdown("Hello **world**").should contain("<p>Hello <strong>world</strong></p>")
    Saci::Views.markdown("# Title\n\npara one\n\npara two").should contain("<h1>Title</h1>")
    Saci::Views.markdown("# Title\n\npara one\n\npara two").should contain("<p>para one</p>")
    Saci::Views.markdown("a *b* c").should contain("<em>b</em>")
    Saci::Views.markdown("use `code` here").should contain("<code>code</code>")
    Saci::Views.markdown("[Saci](https://example.com)").should contain(%(<a href="https://example.com">Saci</a>))
  end

  it "renders fenced code blocks without formatting their contents" do
    out = Saci::Views.markdown("before\n\n```cr\nputs **x**\n```\nafter")
    out.should contain("<pre><code>puts **x**</code></pre>")
    out.should_not contain("<strong>x</strong>")
  end

  it "is XSS-safe (pinned)" do
    out = Saci::Views.markdown("<script>alert(1)</script>")
    out.should_not contain("<script>")
    out.should contain("&lt;script&gt;")
    Saci::Views.markdown("[x](javascript:alert(1))").should_not contain("javascript:")
    Saci::Views.markdown("[x](javascript:alert(1))").should contain("x")
  end

  it "renders through controllers" do
    Saci::TestSession.serve(spec_parts_router) do |app|
      resp = app.get("/md?body=" + URI.encode_path("**hi** <b>"))
      resp.body.should contain("<strong>hi</strong>")
      resp.body.should_not contain("<b>")
    end
  end
end

describe "Saci::Views.page_numbers" do
  it "is empty for a single page" do
    Saci::Views.page_numbers(1, 1, "/stories").should eq("")
  end

  it "links pages with a current marker and prev/next" do
    out = Saci::Views.page_numbers(2, 5, "/stories")
    out.should contain(%(<nav class="pagination">))
    out.should contain(%(href="/stories"))
    out.should contain(%(href="/stories/page/3"))
    out.should contain(%(<span class="current">2</span>))
    out.should contain(%(rel="prev"))
    out.should contain(%(rel="next"))
  end

  it "supports :page placeholders" do
    out = Saci::Views.page_numbers(3, 3, "/active/page/:page")
    out.should contain(%(href="/active/page/1"))
    out.should contain(%(<span class="current">3</span>))
  end

  it "renders through controllers" do
    Saci::TestSession.serve(spec_parts_router) do |app|
      resp = app.get("/pages?page=2")
      resp.body.should contain(%(<span class="current">2</span>))
    end
  end
end

describe "Saci::Views.rss_feed" do
  it "builds escaped RSS with pub dates" do
    feed = Saci::Views.rss_feed(
      title: "Feed & Co", link: "http://x/", description: "d",
      items: [Saci::Views::RSSItem.new("T<C", "http://x/1", "D", Time.utc(2026, 1, 2, 3, 4, 5))]
    )
    feed.should contain(%(<?xml version="1.0" encoding="UTF-8"?>))
    feed.should contain("<title>Feed &amp; Co</title>")
    feed.should contain("T&lt;C")
    feed.should contain("Fri, 02 Jan 2026 03:04:05 GMT")
  end

  it "renders through controllers as XML" do
    Saci::TestSession.serve(spec_parts_router) do |app|
      resp = app.get("/feed")
      resp.headers["Content-Type"].should contain("application/xml")
      resp.body.should contain("<title>Feed &amp; Co</title>")
    end
  end
end
