require "spec"
require "file_utils"
require "../src/saci"

class ViewHelperAuthor < Saci::Record::Base
  table "view_helper_authors"

  column id : Int64, primary: true
  column name : String
  column bio : String
  column published_at : Time
  column editor_id : Int64
end

# A record whose `new_record?` is false, so `dom_id` exercises the
# persisted branch without touching a database.
class ViewHelperSavedAuthor < Saci::Record::Base
  table "view_helper_authors"

  column id : Int64, primary: true
  column name : String

  def new_record? : Bool
    false
  end
end

class ViewHelperDemoController < Saci::Controller
  def tags
    record = ViewHelperAuthor.new(name: "Ada")
    render html: tag("div", {class: "card"}, "<b>Hi</b>") +
                 content_tag("p", "Text", class: "lead") +
                 button_tag("Go", type: "button", class: "btn") +
                 button_to("Delete", "/things/1", method: :delete, class: "danger") +
                 div_for(record) { "<span>inside</span>" }
  end

  def slots
    render_template("spec_helpers/slots", layout: "spec_helpers")
  end

  def block_slots
    @slot_label = "x<y"
    render_template("spec_helpers/block_slots", layout: "spec_helpers")
  end

  def block_form
    @form_id = 7
    render_template("spec_helpers/block_form", layout: false)
  end

  def slot_values
    content_for(:side, "A")
    content_for(:side) { "<b>B</b>" }
    render html: content_for(:side) + "|" + content_for?(:side).to_s + "|" +
                 content_for?(:missing).to_s + "|" + yield_content(:side) + "|" +
                 capture { "cap" } + "|" + safe_join(["a<b", nil, "c"], " | ")
  end

  def forms
    authors = [
      ViewHelperAuthor.new(id: 1_i64, name: "Ada"),
      ViewHelperAuthor.new(id: 2_i64, name: "Bob & Co"),
    ]
    author = ViewHelperAuthor.new(
      id: 3_i64, name: "Draft <x>", bio: "body", editor_id: 2_i64,
      published_at: Time.utc(2026, 5, 1, 12, 30)
    )
    render html: form_with("/authors", model: author, scope: "author") { |f|
      f.fields_for("profile") { |p| p.text_field("bio") } +
        f.collection_select("editor_id", authors, "id", "name", "2") +
        f.number_field("age") + f.email_field("email") + f.url_field("website") +
        f.telephone_field("phone") + f.color_field("color") + f.range_field("rating") +
        f.search_field("q") + f.datetime_local_field("published_at") +
        f.time_field("published_at") + f.month_field("published_at") +
        f.week_field("published_at") + f.radio_button("kind", "draft", true) +
        f.rich_text_area("bio") + f.date_select("published_at") +
        f.grouped_collection_select("grouped", [{"Group A", [{"One", "1"}, {"Two", "2"}]}], "items", "label", "value", "text", "2") +
        f.submit("Save")
    }
  end

  def form_tags
    search = form_tag("/search", method: :get, class: "search") {
      text_field_tag("q", "a\"b", placeholder: "Search") +
        select_tag("kind", options_for_select([{"A", "a"}, {"B", "b"}], "b"), multiple: true) +
        check_box_tag("ok", "1", true) + radio_button_tag("pick", "x", true) +
        hidden_field_tag("page", "2") + submit_tag("Go", class: "btn") +
        label_tag("q", "Search") + text_area_tag("body", "<b>") +
        file_field_tag("avatar", accept: "image/*")
    }
    deletion = form_tag("/things/1", method: :delete) { button_tag("Delete") }
    patch = form_with("/things/1", method: :patch) { |f| f.text_field("title") }
    render html: search + deletion + patch
  end

  def assets
    render html: image_tag("images/logo.png", alt: "A \"B", size: "10x20", data: {controller: "pic"}) +
                 stylesheet_link_tag("app.css", media: "screen") +
                 javascript_include_tag("app.js", defer: true, async: true) +
                 favicon_link_tag("favicon.png") +
                 audio_tag("sound.mp3", autoplay: true) +
                 video_tag("movie.mp4", poster: "poster.jpg", size: "320x240") +
                 auto_discovery_link_tag(:atom, "/feed.atom", title: "Feed & Co")
  end

  def meta
    render html: csrf_meta_tags + csp_meta_tag(nonce: "n<1>")
  end

  def urls
    render html: link_to_if(true, "Home", "/", class: "nav") +
                 link_to_unless(true, "No", "/x") +
                 mail_to("a@b.com", "Mail", subject: "Hi there") +
                 phone_to("+1 (555) 0100", "Call") +
                 sms_to("+15550100", "Text", body: "Yo & hi")
  end

  def cache_demo
    Saci::Cache.reset! if params["reset"]? == "1"
    render html: cache_if(true, "spec-cache-if") { "IF" } +
                 cache_unless(false, "spec-cache-unless") { "UNLESS" } +
                 cache?("spec-cache-if").to_s
  end
end

def view_helper_router : Saci::Router
  Saci::Router.new.draw do |r|
    r.get "/tags", ViewHelperDemoController, :tags
    r.get "/slots", ViewHelperDemoController, :slots
    r.get "/block-slots", ViewHelperDemoController, :block_slots
    r.get "/block-form", ViewHelperDemoController, :block_form
    r.get "/slot-values", ViewHelperDemoController, :slot_values
    r.get "/forms", ViewHelperDemoController, :forms
    r.get "/form-tags", ViewHelperDemoController, :form_tags
    r.get "/assets", ViewHelperDemoController, :assets
    r.get "/meta", ViewHelperDemoController, :meta
    r.get "/urls", ViewHelperDemoController, :urls
    r.get "/cache", ViewHelperDemoController, :cache_demo
  end
end

describe "asset pipeline" do
  assets_root = ""
  manifest = {} of String => String

  before_each do
    assets_root = File.join("/tmp/opencode", "saci_assets_#{Process.pid}_#{Time.utc.to_unix_ns}")
    source = File.join(assets_root, "src_assets")
    output = File.join(assets_root, "public", "assets")
    Dir.mkdir_p(File.join(source, "images"))
    File.write(File.join(source, "app.css"), "body { color: red; }")
    File.write(File.join(source, "app.js"), "console.log('hi')")
    File.write(File.join(source, "images", "logo.png"), "PNG")
    File.write(File.join(source, "movie.mp4"), "MP4")
    File.write(File.join(source, "sound.mp3"), "MP3")
    File.write(File.join(source, "poster.jpg"), "JPG")
    File.write(File.join(source, "favicon.png"), "ICO")
    manifest = Saci::Assets.build_manifest(source, output)
    Saci::Assets.configure(root: assets_root)
  end

  after_each do
    Saci::Assets.configure(root: Dir.current)
    FileUtils.rm_rf(assets_root)
  end

  it "builds a fingerprinted manifest and copies assets" do
    manifest.has_key?("app.css").should be_true
    manifest.has_key?("images/logo.png").should be_true
    manifest["app.css"].should match(/\Aapp-[0-9a-f]{64}\.css\z/)
    manifest["images/logo.png"].should match(/\Aimages\/logo-[0-9a-f]{64}\.png\z/)
    File.exists?(File.join(assets_root, "public", "assets", manifest["app.css"])).should be_true
    File.exists?(File.join(assets_root, "public", "assets", ".manifest.json")).should be_true
    Saci::Assets.manifest_path.should eq(File.join(assets_root, "public", "assets", ".manifest.json"))
    Saci::Assets.manifest["app.css"].should eq(manifest["app.css"])
    Saci::Assets.exists?("app.css").should be_true
    Saci::Assets.exists?("nope.css").should be_false
  end

  it "resolves paths/urls and falls back to the logical path" do
    Saci::Assets.asset_path("app.css").should eq("/assets/#{manifest["app.css"]}")
    Saci::Assets.asset_path("nope.css").should eq("/assets/nope.css")
    Saci::Assets.asset_path("https://cdn.example.com/x.css").should eq("https://cdn.example.com/x.css")
    Saci::Assets.asset_path("//cdn.example.com/x.css").should eq("//cdn.example.com/x.css")
    Saci::Assets.asset_path("app.css", digest: false).should eq("/assets/app.css")
    Saci::Assets.asset_url("app.css", host: "cdn.example.com").should eq("http://cdn.example.com/assets/#{manifest["app.css"]}")
    Saci::Assets.asset_url("app.css", host: "cdn.example.com", protocol: "https", port: 8443).should eq("https://cdn.example.com:8443/assets/#{manifest["app.css"]}")
  end

  it "renders asset tags with escaping and options" do
    out = Saci::Views.stylesheet_link_tag("app.css", media: "screen")
    out.should contain(%(rel="stylesheet"))
    out.should contain(%(href="/assets/#{manifest["app.css"]}"))
    out.should contain(%(media="screen"))

    js = Saci::Views.javascript_include_tag("app.js", defer: true, async: true, type: "module")
    js.should contain(%(src="/assets/#{manifest["app.js"]}"))
    js.should contain(" defer")
    js.should contain(" async")
    js.should contain(%(type="module"))
    js.should contain("></script>")

    img = Saci::Views.image_tag("images/logo.png", alt: "A \"B", size: "10x20", data: {controller: "pic"})
    img.should contain(%(src="/assets/#{manifest["images/logo.png"]}"))
    img.should contain(%(alt="A &quot;B"))
    img.should contain(%(width="10"))
    img.should contain(%(height="20"))
    img.should contain(%(data-controller="pic"))

    fav = Saci::Views.favicon_link_tag("favicon.png")
    fav.should contain(%(rel="icon"))
    fav.should contain(%(href="/assets/#{manifest["favicon.png"]}"))
    fav.should contain(%(type="image/png"))

    audio = Saci::Views.audio_tag("sound.mp3", autoplay: true)
    audio.should contain(%(<audio controls autoplay src="/assets/#{manifest["sound.mp3"]}"></audio>))

    video = Saci::Views.video_tag("movie.mp4", poster: "poster.jpg", size: "320x240")
    video.should contain(%(poster="/assets/#{manifest["poster.jpg"]}"))
    video.should contain(%(width="320"))
    video.should contain(%(src="/assets/#{manifest["movie.mp4"]}"))

    feed = Saci::Views.auto_discovery_link_tag(:atom, "/feed.atom", title: "Feed & Co")
    feed.should contain(%(rel="alternate"))
    feed.should contain(%(type="application/atom+xml"))
    feed.should contain(%(title="Feed &amp; Co"))
    Saci::Views.auto_discovery_link_tag.should contain(%(href="/feed.rss"))

    multi = Saci::Views.audio_tag("sound.mp3", "sound.ogg")
    multi.should contain(%(<source src="/assets/sound.ogg" type="audio/ogg">))
    video_multi = Saci::Views.video_tag("movie.mp4", "movie.webm")
    video_multi.should contain(%(<source src="/assets/movie.webm" type="video/webm">))
  end

  it "renders asset tags through a controller and falls back for missing files" do
    Saci::TestSession.serve(view_helper_router) do |app|
      resp = app.get("/assets")
      resp.status_code.should eq(200)
      resp.body.should contain(%(href="/assets/#{manifest["app.css"]}"))
      resp.body.should contain(%(src="/assets/#{manifest["app.js"]}"))
      resp.body.should contain(%(title="Feed &amp; Co"))
    end
    Saci::Assets.configure(root: assets_root, manifest_path: "/tmp/opencode/no-such-manifest.json")
    Saci::Views.image_tag("missing.png", alt: "M").should contain(%(src="/assets/missing.png"))
  end
end

describe "tag builders" do
  it "builds tags, escapes attribute values and content, and supports booleans" do
    Saci::Views.tag("br").should eq("<br>")
    Saci::Views.tag("input", {type: "text", name: "q", disabled: true, hidden: false, value: "a\"b"})
      .should eq(%(<input type="text" name="q" disabled value="a&quot;b">))
    Saci::Views.tag("div", {class: "card", data: {controller: "x", id: 3}}, "<b>Hi</b>")
      .should eq(%(<div class="card" data-controller="x" data-id="3">&lt;b&gt;Hi&lt;/b&gt;</div>))
    Saci::Views.tag("div", class: "card") { "<b>raw</b>" }
      .should eq(%(<div class="card"><b>raw</b></div>))
  end

  it "builds content_tag/button_tag/div_for" do
    Saci::Views.content_tag("p", "Hi & bye", class: "lead")
      .should eq(%(<p class="lead">Hi &amp; bye</p>))
    Saci::Views.content_tag("div", class: "wrap") { "<em>raw</em>" }
      .should eq(%(<div class="wrap"><em>raw</em></div>))
    Saci::Views.button_tag("Go").should eq(%(<button type="submit">Go</button>))
    Saci::Views.button_tag("Go", type: "button", class: "btn")
      .should eq(%(<button type="button" class="btn">Go</button>))

    saved = ViewHelperSavedAuthor.new(id: 7_i64, name: "Ada")
    Saci::Views.div_for(saved) { "<span>x</span>" }
      .should eq(%(<div id="view_helper_saved_author_7" class="view_helper_saved_author"><span>x</span></div>))
  end

  it "renders button_to with method override and CSRF through a controller" do
    Saci::TestSession.serve(view_helper_router) do |app|
      body = app.get("/tags").body
      body.should contain(%(<div class="card">&lt;b&gt;Hi&lt;/b&gt;</div>))
      body.should contain(%(<p class="lead">Text</p>))
      body.should contain(%(<button type="button" class="btn">Go</button>))
      body.should contain(%(<form action="/things/1" method="post">))
      body.should contain(%(name="_method" value="DELETE"))
      body.should contain(%(name="authenticity_token"))
      body.should contain(%(<button type="submit" class="danger">Delete</button></form>))
      body.should contain(%(<div id="new_view_helper_author" class="view_helper_author"><span>inside</span></div>))
    end
  end
end

describe "content_for and capture" do
  it "stores named slots and renders them in layouts" do
    Saci::TestSession.serve(view_helper_router) do |app|
      body = app.get("/slots").body
      body.should contain(%(<head><meta name="slot" content="yes"></head>))
      body.should contain(%(<p><meta name="slot" content="yes"></p>))
      body.should contain("slot? true")
    end
  end

  it "captures ECR do...end blocks instead of writing them in place" do
    Saci::TestSession.serve(view_helper_router) do |app|
      body = app.get("/block-slots").body
      head = body[body.index!("<head>")...body.index!("</head>")]
      head.should contain(%(<style>.orb { color: red; }</style>))
      head.should contain(%(<meta name="second" content="x&lt;y">))
      main = body[body.index!("<main>")...body.index!("</main>")]
      main.should_not contain("<style>")
      main.scan(%(<div class="card">)).size.should eq(2)
      body.scan("<style>").size.should eq(1)
    end
  end

  it "writes form_with ECR blocks into the page in place" do
    Saci::TestSession.serve(view_helper_router) do |app|
      body = app.get("/block-form").body
      body.scan("<form").size.should eq(2)
      patch = body[body.index!(%(<form action="/sessions/7"))...body.index!("</form>")]
      patch.should contain(%(name="_method" value="PATCH"))
      patch.should contain(%(name="email"))
      patch.should contain("Sign in")
      body.index!("before").should be < body.index!(%(action="/sessions/7"))
      body.index!(%(action="/sessions/7")).should be < body.index!(%(action="/search"))
      body.index!(%(action="/search")).should be < body.index!("after")
      body.should contain(%(name="q"))
    end
  end

  it "supports value/block forms, capture, safe_join and escape_once" do
    Saci::TestSession.serve(view_helper_router) do |app|
      body = app.get("/slot-values").body
      body.should eq("A<b>B</b>|true|false|A<b>B</b>|cap|a&lt;b |  | c")
    end
    Saci::Views.escape_once("a & b &amp; <c>").should eq("a &amp; b &amp; &lt;c&gt;")
  end
end

describe "form helpers" do
  it "builds nested model forms, selects and HTML5 inputs" do
    Saci::TestSession.serve(view_helper_router) do |app|
      body = app.get("/forms").body
      body.should contain(%(name="author[profile][bio]"))
      body.should contain(%(id="author_profile_bio"))
      body.should contain(%(name="author[editor_id]"))
      body.should contain(%(<option value="2" selected>Bob &amp; Co</option>))
      body.should contain(%(type="number" name="author[age]"))
      body.should contain(%(type="email" name="author[email]"))
      body.should contain(%(type="url" name="author[website]"))
      body.should contain(%(type="tel" name="author[phone]"))
      body.should contain(%(type="color" name="author[color]"))
      body.should contain(%(type="range" name="author[rating]"))
      body.should contain(%(type="search" name="author[q]"))
      body.should contain(%(type="datetime-local" name="author[published_at]"))
      body.should contain(%(value="2026-05-01T12:30"))
      body.should contain(%(type="time" name="author[published_at]"))
      body.should contain(%(value="12:30"))
      body.should contain(%(type="month" name="author[published_at]"))
      body.should contain(%(value="2026-05"))
      body.should contain(%(type="week" name="author[published_at]"))
      body.should contain(%(value="2026-W18"))
      body.should contain(%(type="radio" name="author[kind]"))
      body.should contain(%(id="author_kind_draft"))
      body.should contain(" checked")
      body.should contain(%(<textarea name="author[bio]" id="author_bio" rows="8" data-rich-text="true">body</textarea>))
      body.should contain(%(name="author[published_at][year]"))
      body.should contain(%(name="author[published_at][month]"))
      body.should contain(%(name="author[published_at][day]"))
      body.should contain(%(<input type="submit" value="Save">))
      body.should contain(%(<optgroup label="Group A">))
      body.should contain(%(<option value="2" selected>Two</option>))
    end
  end

  it "builds form_tag and non-model tag helpers" do
    Saci::TestSession.serve(view_helper_router) do |app|
      body = app.get("/form-tags").body
      body.should contain(%(<form class="search" action="/search" method="get">))
      body.should contain(%(name="q" id="q"))
      body.should contain(%(value="a&quot;b"))
      body.should contain(%(placeholder="Search"))
      body.should contain(%(name="kind" id="kind"))
      body.should contain(%(multiple))
      body.should contain(%(<option value="b" selected>B</option>))
      body.should contain(%(type="checkbox" name="ok" id="ok" value="1" checked))
      body.should contain(%(type="radio" name="pick" id="pick_x" value="x" checked))
      body.should contain(%(type="hidden" name="page" id="page" value="2"))
      body.should contain(%(type="submit" value="Go"))
      body.should contain(%(class="btn"))
      body.should contain(%(<label for="q">Search</label>))
      body.should contain(%(<textarea name="body" id="body">&lt;b&gt;</textarea>))
      body.should contain(%(type="file" name="avatar" id="avatar"))
      body.should contain(%(accept="image/*"))
      body.should contain(%(action="/things/1" method="post"))
      body.should contain(%(name="_method" value="DELETE"))
      body.should contain(%(name="authenticity_token"))
      body.should contain(%(name="_method" value="PATCH"))
    end
  end

  it "renders option helpers" do
    Saci::Views.options_for_select(["a", "b"], "b")
      .should eq(%(<option value="a">a</option><option value="b" selected>b</option>))
    Saci::Views.options_for_select([{"One", "1"}, {"Two", "2"}], "2")
      .should eq(%(<option value="1">One</option><option value="2" selected>Two</option>))
    Saci::Views.options_from_collection_for_select(
      [ViewHelperAuthor.new(id: 1_i64, name: "Ada"), ViewHelperAuthor.new(id: 2_i64, name: "Bob")],
      "id", "name", "2"
    ).should contain(%(<option value="2" selected>Bob</option>))
    grouped = Saci::Views.grouped_options_for_select(
      [{"Group A", [{"One", "1"}, {"Two", "2"}]}], "items", "label", "value", "text", "1"
    )
    grouped.should contain(%(<optgroup label="Group A">))
    grouped.should contain(%(<option value="1" selected>One</option>))
    Saci::Views.options_for_select([1, 2], 2).should contain(%(<option value="2" selected>2</option>))
  end
end

describe "number and date/time helpers" do
  it "formats numbers and human sizes" do
    Saci::Views.number_with_delimiter(1_234_567).should eq("1,234,567")
    Saci::Views.number_with_delimiter(1234.5).should eq("1,234.5")
    Saci::Views.number_with_precision(1234.5678, precision: 2).should eq("1,234.57")
    Saci::Views.number_with_precision(1.0, precision: 3).should eq("1.000")
    Saci::Views.number_with_precision(1.0, precision: 3, strip_insignificant_zeros: true).should eq("1")
    Saci::Views.number_to_currency(1234.5).should eq("$1,234.50")
    Saci::Views.number_to_currency(-1234.5).should eq("-$1,234.50")
    Saci::Views.number_to_currency(12, unit: "€", precision: 0).should eq("€12")
    Saci::Views.number_with_precision(1234.5678, precision: 3, significant: true).should eq("1,230")
    Saci::Views.number_to_percentage(12.345, precision: 1).should eq("12.3%")
    Saci::Views.number_to_human(1234).should eq("1.23 Thousand")
    Saci::Views.number_to_human(2_000_000).should eq("2 Million")
    Saci::Views.number_to_human_size(1536).should eq("1.5 KB")
    Saci::Views.number_to_human_size(1024).should eq("1 KB")
    Saci::Views.number_to_human_size(1).should eq("1 Byte")
  end

  it "formats distances, time tags and localizes" do
    now = Time.utc(2026, 5, 1, 12, 0, 0)
    Saci::Views.time_ago_in_words(Time.utc - 2.days).should eq("2 days")
    Saci::Views.distance_of_time_in_words(now, now + 90.minutes).should eq("about 2 hours")
    Saci::Views.distance_of_time_in_words(now, now + 30.seconds, include_seconds: true).should eq("half a minute")
    tag = Saci::Views.time_tag(now, "May")
    tag.should contain(%(<time datetime="2026-05-01T12:00:00Z">May</time>))
    Saci::Views.l(now, "short").should eq("01 May 12:00")
    Saci::Views.l(now, :short).should eq("01 May 12:00")
    date = Saci::Views.date_select("event[starts_at]", now)
    date.should contain(%(name="event[starts_at][year]"))
    date.should contain(%(name="event[starts_at][day]"))
    date.should contain(%(selected>2026</option>))
    dt = Saci::Views.datetime_select("event[starts_at]", now)
    dt.should contain(%(name="event[starts_at][hour]"))
    dt.should contain(%(name="event[starts_at][minute]"))
  end
end

describe "text and sanitize helpers" do
  it "formats text" do
    Saci::Views.simple_format("Hello\n\nWorld <b>")
      .should eq("<p>Hello</p>\n<p>World &lt;b&gt;</p>")
    Saci::Views.truncate("Hello world", length: 8).should eq("Hello...")
    Saci::Views.truncate_words("one two three", words: 2).should eq("one two...")
    Saci::Views.excerpt("Hello world", "world", radius: 3).should eq("...lo world")
    Saci::Views.pluralize(1, "post").should eq("1 post")
    Saci::Views.pluralize(2, "post").should eq("2 posts")
    Saci::Views.pluralize(1, "person", "people").should eq("1 person")
    Saci::Views.pluralize(2, "person", "people").should eq("2 people")
    Saci::Views.strip_tags("<p>Hi <b>there</b></p>").should eq("Hi there")
    Saci::Views.strip_links(%(<a href="/x">Hi</a> there)).should eq("Hi there")
    Saci::Views.highlight("Hello <world>", "world").should eq("Hello &lt;<mark>world</mark>&gt;")
    Saci::Views.word_wrap("one two three", line_width: 7).should eq("one two\nthree")
  end

  it "sanitizes with a safe allowlist and escapes JavaScript/JSON" do
    out = Saci::Views.sanitize(%(<script>alert(1)</script><b>ok</b><a href="javascript:alert(1)">x</a>))
    out.should_not contain("<script")
    out.should_not contain("javascript:")
    out.should contain("alert(1)")
    out.should contain("<b>ok</b>")
    out.should contain("<a>x</a>")
    Saci::Views.sanitize(%(<b onclick="x">ok</b>)).should eq("<b>ok</b>")
    Saci::Views.sanitize(%(<div class="x"><b>ok</b></div>)).should eq(%(<div class="x"><b>ok</b></div>))
    Saci::Views.escape_javascript("a\n\"b\"</script>").should eq(%(a\\n\\"b\\"<\\/script>))
    Saci::Views.javascript_tag("alert('x')", type: "text/javascript")
      .should eq(%(<script type="text/javascript">alert('x')</script>))
    Saci::Views.json_escape("<b>&").should eq("\\u003cb\\u003e\\u0026")
  end
end

describe "URL and DOM helpers" do
  it "builds conditional links, mail/phone/sms links and blocks" do
    Saci::Views.link_to_if(true, "Home", "/", class: "nav")
      .should eq(%(<a class="nav" href="/">Home</a>))
    Saci::Views.link_to_if(false, "Home <b>", "/").should eq("Home &lt;b&gt;")
    Saci::Views.link_to_if(true, "/x") { "<b>X</b>" }.should eq(%(<a href="/x"><b>X</b></a>))
    Saci::Views.link_to_unless(true, "No", "/x").should eq("No")
    Saci::Views.link_to_unless(false, "/x") { "<b>Y</b>" }.should eq(%(<a href="/x"><b>Y</b></a>))
    Saci::Views.mail_to("a@b.com", "Mail", subject: "Hi there")
      .should contain(%(href="mailto:a@b.com?subject=Hi%20there"))
    Saci::Views.phone_to("+1 (555) 0100", "Call")
      .should eq(%(<a href="tel:+15550100">Call</a>))
    Saci::Views.sms_to("+1 555 0100", "Text", body: "Yo & hi")
      .should contain(%(href="sms:+15550100?body=Yo%20%26%20hi"))
    Saci::Views.mail_to("a@b.com") { "Mail" }.should eq(%(<a href="mailto:a@b.com">Mail</a>))
    Saci::Views.phone_to("+15550100") { "Call" }.should eq(%(<a href="tel:+15550100">Call</a>))
    Saci::Views.sms_to("+15550100", body: "Hi") { "Text" }
      .should eq(%(<a href="sms:+15550100?body=Hi">Text</a>))
  end

  it "derives dom ids and classes with prefixes" do
    saved = ViewHelperSavedAuthor.new(id: 7_i64, name: "Ada")
    Saci::Views.dom_id(saved).should eq("view_helper_saved_author_7")
    Saci::Views.dom_id(saved, "edit").should eq("edit_view_helper_saved_author_7")
    Saci::Views.dom_class(saved).should eq("view_helper_saved_author")
    Saci::Views.dom_class(saved, "edit").should eq("edit_view_helper_saved_author")
    Saci::Views.dom_id(ViewHelperAuthor.new).should eq("new_view_helper_author")
  end

  it "renders URL helpers through a controller" do
    Saci::TestSession.serve(view_helper_router) do |app|
      body = app.get("/urls").body
      body.should contain(%(<a class="nav" href="/">Home</a>))
      body.should contain("No")
      body.should contain(%(href="mailto:a@b.com?subject=Hi%20there"))
      body.should contain(%(href="tel:+15550100"))
      body.should contain(%(href="sms:+15550100?body=Yo%20%26%20hi"))
    end
  end
end

describe "cache and meta helpers" do
  it "caches conditionally and reports cache presence" do
    Saci::Cache.reset!
    calls = 0
    Saci::Views.cache_if(true, "spec-if") { calls += 1; "one" }.should eq("one")
    Saci::Views.cache_if(true, "spec-if") { calls += 1; "two" }.should eq("one")
    calls.should eq(1)
    Saci::Views.cache_unless(false, "spec-unless") { "u" }.should eq("u")
    Saci::Views.cache?("spec-if").should be_true
    Saci::Views.cache?("missing").should be_false
    Saci::Cache.reset!
  end

  it "renders cache helpers and meta tags through a controller" do
    Saci::TestSession.serve(view_helper_router) do |app|
      first = app.get("/cache?reset=1").body
      first.should eq("IFUNLESStrue")
      second = app.get("/cache").body
      second.should eq("IFUNLESStrue")

      meta = app.get("/meta").body
      meta.should contain(%(<meta name="csrf-param" content="authenticity_token">))
      meta.should contain(%(<meta name="csrf-token" content="))
      meta.should contain(%(<meta name="csp-nonce" content="n&lt;1&gt;">))
    end
    Saci::Cache.reset!
  end

  it "extracts a nonce from a configured CSP policy" do
    Saci::Views.csp_meta_tag(policy: "default-src 'self'; script-src 'nonce-abc123'")
      .should eq(%(<meta name="csp-nonce" content="abc123">))
    Saci::Views.csp_meta_tag(policy: "default-src 'self'").should eq("")
  end
end
