require "spec"
require "file"
require "../src/saci"

class CreateRichTextPosts < Saci::Record::Migration
  def change
    create_table :rich_text_posts do |t|
      t.string :title, null: false
      t.text :body
      t.timestamps
    end
  end
end

class RichTextPost < Saci::Record::Base
  table "rich_text_posts"

  column id : Int64, primary: true
  column title : String
  column body : String
  timestamps

  has_rich_text :body
end

RICH_TEXT_DB_PATH = "/tmp/opencode/saci_rich_text_test.db"

describe "Saci::RichText.sanitize" do
  it "keeps the allowlisted tags and drops their attributes" do
    out = Saci::RichText.sanitize(%(<p class="x">Hi <strong>there</strong> <em>you</em></p>))
    out.should eq(%(<p>Hi <strong>there</strong> <em>you</em></p>))
    Saci::RichText.sanitize("<ul><li>one</li><li>two</li></ul>").should eq("<ul><li>one</li><li>two</li></ul>")
    Saci::RichText.sanitize("<ol><li>x</li></ol>").should eq("<ol><li>x</li></ol>")
    Saci::RichText.sanitize("<blockquote><p>q</p></blockquote>").should eq("<blockquote><p>q</p></blockquote>")
    Saci::RichText.sanitize("<h1>T</h1><h2>S</h2><h3>s</h3>").should eq("<h1>T</h1><h2>S</h2><h3>s</h3>")
    Saci::RichText.sanitize("<pre><code>puts 1</code></pre>").should eq("<pre><code>puts 1</code></pre>")
    Saci::RichText.sanitize("a<br>b").should eq("a<br>b")
    Saci::RichText.sanitize("a<br/>b").should eq("a<br>b")
    Saci::RichText.sanitize(%(<a href="https://example.com">x</a>)).should eq(%(<a href="https://example.com">x</a>))
    Saci::RichText.sanitize(%(<a href="http://example.com">x</a>)).should eq(%(<a href="http://example.com">x</a>))
    Saci::RichText.sanitize(%(<a href="mailto:a@b.c">x</a>)).should eq(%(<a href="mailto:a@b.c">x</a>))
    Saci::RichText.sanitize(%(<a href="/posts/1">x</a>)).should eq(%(<a href="/posts/1">x</a>))
    Saci::RichText.sanitize(%(<a href="#top">x</a>)).should eq(%(<a href="#top">x</a>))
  end

  it "pins the XSS battery" do
    Saci::RichText.sanitize(%(<script>alert(1)</script>)).should_not contain("<script>")
    Saci::RichText.sanitize(%(<ScRiPt>alert(1)</ScRiPt>)).should_not contain("ScRiPt>")
    Saci::RichText.sanitize(%(<p onclick="evil()">x</p>)).should eq("<p>x</p>")
    Saci::RichText.sanitize(%(<p onmouseover="evil()">x</p>)).should eq("<p>x</p>")
    Saci::RichText.sanitize(%(<a href="javascript:alert(1)">x</a>)).should eq("<a>x</a>")
    Saci::RichText.sanitize(%(<a href="JaVaScRiPt:alert(1)">x</a>)).should eq("<a>x</a>")
    Saci::RichText.sanitize(%(<a href="  javascript:alert(1)">x</a>)).should eq("<a>x</a>")
    Saci::RichText.sanitize("<a href=\"java\tscript:alert(1)\">x</a>").should eq("<a>x</a>")
    Saci::RichText.sanitize(%(<a href="javascript&#58;alert(1)">x</a>)).should eq("<a>x</a>")
    Saci::RichText.sanitize(%(<a href="&#106;avascript:alert(1)">x</a>)).should eq("<a>x</a>")
    Saci::RichText.sanitize(%(<a href="data:text/html,<script>alert(1)</script>">x</a>)).should eq("<a>x</a>")
    Saci::RichText.sanitize(%(<a href="vbscript:msgbox(1)">x</a>)).should eq("<a>x</a>")
    Saci::RichText.sanitize(%(<a href="https://x" onclick="evil()">x</a>)).should eq(%(<a href="https://x">x</a>))
    Saci::RichText.sanitize(%(<style>body{display:none}</style>)).should_not contain("<style>")
    Saci::RichText.sanitize(%(<p style="color:red">x</p>)).should eq("<p>x</p>")
    Saci::RichText.sanitize(%(<iframe src="https://evil"></iframe>)).should_not contain("<iframe")
    Saci::RichText.sanitize(%(<img src="x" onerror="evil()">)).should_not contain("<img")
    Saci::RichText.sanitize(%(<svg onload="evil()">)).should_not contain("<svg")
    Saci::RichText.sanitize(%(<<script>script>alert(1)</script>)).should_not contain("<script>")
    Saci::RichText.sanitize(%(<div>hi</div>)).should_not contain("<div>")
    Saci::RichText.sanitize(%(<h4>hi</h4>)).should_not contain("<h4>")
    Saci::RichText.sanitize(%(<!-- comment --><p>x</p>)).should eq("<p>x</p>")
    Saci::RichText.sanitize(%(<a href="page.html">x</a>)).should eq("<a>x</a>")
    # Escaped payloads stay inert text, never executable markup.
    out = Saci::RichText.sanitize(%(<script>alert("xss")</script>))
    out.should contain("&lt;script&gt;")
    out.should contain("alert")
  end

  it "escapes bare angle brackets and renders nil as empty" do
    Saci::RichText.sanitize("2 < 3 and 4 > 1").should contain("&lt;")
    Saci::RichText.sanitize(nil).should eq("")
    Saci::RichText.sanitize("").should eq("")
  end
end

describe "Saci::RichText::Content" do
  it "exposes sanitized HTML, plain text, excerpts and blank?" do
    doc = Saci::RichText::Content.new(%(<p>Hello <strong>world</strong></p>))
    doc.to_s.should eq(%(<p>Hello <strong>world</strong></p>))
    doc.to_plain_text.should eq("Hello world")
    doc.blank?.should be_false
    doc.present?.should be_true
    Saci::RichText::Content.new(nil).blank?.should be_true
    Saci::RichText::Content.new("").blank?.should be_true
    Saci::RichText::Content.new("   ").blank?.should be_true
    Saci::RichText::Content.new("<br>").blank?.should be_true
    Saci::RichText::Content.new("<!-- only a comment -->").blank?.should be_true
    Saci::RichText::Content.new("<p>  </p>").blank?.should be_true
  end

  it "decodes entities and truncates excerpts" do
    doc = Saci::RichText::Content.new("<p>fish &amp; chips &lt;3</p>")
    doc.to_plain_text.should eq("fish & chips <3")
    long = Saci::RichText::Content.new("<p>#{("ab " * 100).strip}</p>")
    long.excerpt(20).size.should be <= 21 + 5
    long.excerpt(20).should end_with("…")
    long.to_plain_text(10).should end_with("…")
    Saci::RichText::Content.new("<p>short</p>").excerpt(200).should eq("short")
  end
end

describe "Saci::Views.rich_text" do
  it "sanitizes strings and passes Content through" do
    Saci::Views.rich_text(%(<p>hi <script>evil()</script></p>)).should_not contain("<script>")
    Saci::Views.rich_text(Saci::RichText::Content.new("<p>hi</p>")).should eq("<p>hi</p>")
    Saci::Views.rich_text(nil).should eq("")
  end
end

describe "FormBuilder#rich_text_area" do
  it "emits a data-hooked textarea with escaped raw content" do
    builder = Saci::FormBuilder.new("/posts")
    out = builder.rich_text_area("body", %(<p>hi</p><script>evil()</script>))
    out.should contain("<textarea")
    out.should contain(%(data-rich-text="true"))
    out.should contain("&lt;script&gt;")
    out.should_not contain("<script>")
  end

  it "binds model values with scoped names" do
    post = RichTextPost.new(title: "t", body: "<p>bound</p>")
    builder = Saci::FormBuilder.new("/posts", "post", nil, post, "post")
    out = builder.rich_text_area("body")
    out.should contain(%(name="post[body]"))
    out.should contain(%(id="post_body"))
    out.should contain("&lt;p&gt;bound&lt;/p&gt;")
  end
end

describe "has_rich_text round-trip" do
  before_all do
    File.delete(RICH_TEXT_DB_PATH) if File.exists?(RICH_TEXT_DB_PATH)
    Saci::Record::Base.connection = DB.open("sqlite3://#{RICH_TEXT_DB_PATH}")
    Saci::Record::Migrator.migrate(
      Saci::Record::Base.connection.as(DB::Database),
      [CreateRichTextPosts] of Saci::Record::Migration.class
    )
  end

  after_all do
    Saci::Record::Base.connection.as(DB::Database).close
  end

  before_each do
    Saci::Record.clean_database!
  end

  it "persists raw HTML on an existing text column and sanitizes on read" do
    payload = %(<p>Hello <strong>Ada</strong></p><script>alert(1)</script><a href="javascript:alert(1)">x</a>)
    post = RichTextPost.create!(title: "Hi", body: payload)
    found = RichTextPost.find(post.id.not_nil!)
    found.body.should eq(payload)
    rich = found.body_rich_text
    rich.to_s.should contain("<p>Hello <strong>Ada</strong></p>")
    rich.to_s.should_not contain("<script>")
    rich.to_s.should contain("<a>x</a>")
    rich.to_plain_text.should contain("Hello Ada")
    rich.blank?.should be_false
    Saci::Views.rich_text(found.body).should eq(rich.to_s)
  end

  it "writes through the rich-text setter and reports blank drafts" do
    post = RichTextPost.create!(title: "Draft")
    post.body_rich_text.blank?.should be_true
    post.body_rich_text = "<h1>Title</h1><p>Body text here</p>"
    post.save!
    RichTextPost.find(post.id.not_nil!).body_rich_text.to_plain_text.should eq("Title Body text here")
  end
end
