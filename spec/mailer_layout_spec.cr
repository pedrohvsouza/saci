require "spec"
require "../src/saci"

class LayoutDemoMailer < Saci::Mailer::Base
  default_from "noreply@example.com"
  default_reply_to "replies@example.com"
  layout "demo-layout"

  def self.note(email : String) : Saci::Mailer::Mail
    mail(to: email, subject: "Note", headers: {"Message-Id" => "<note-1@example.com>", "In-Reply-To" => "<parent@example.com>"}) do |format|
      format.text { "hello" }
      format.html { "<p>hello</p>" }
    end
  end

  def self.plain_note(email : String, reply_to : String? = nil) : Saci::Mailer::Mail
    mail(to: email, subject: "Plain", reply_to: reply_to) do |format|
      format.text { "hi" }
    end
  end
end

class LayoutBareMailer < Saci::Mailer::Base
  default_from "noreply@example.com"

  def self.ping(email : String) : Saci::Mailer::Mail
    mail(to: email, subject: "Ping") do |format|
      format.text { "pong" }
    end
  end
end

class LayoutMissingMailer < Saci::Mailer::Base
  default_from "noreply@example.com"
  layout "never-registered"

  def self.ping(email : String) : Saci::Mailer::Mail
    mail(to: email, subject: "Ping") do |format|
      format.text { "pong" }
    end
  end
end

describe "Mailer layouts, reply_to and headers" do
  before_all do
    Saci::Mailer.register_layout("demo-layout",
      text: "== MyApp ==\n<%= content %>\n-- footer",
      html: %(<div class="mail"><%= content %></div>))
  end

  before_each do
    Saci::Mailer.delivery_adapter = :test
    Saci::Mailer.clear_deliveries!
    Saci::Job.queue_adapter = :test
    Saci::Job.clear_enqueued!
  end

  after_each do
    Saci::Mailer.delivery_adapter = :file
    Saci::Job.queue_adapter = :async
  end

  it "wraps text and html parts with the layout" do
    mail = LayoutDemoMailer.note("a@b.c")
    mail.body_text.should eq("== MyApp ==\nhello\n-- footer")
    mail.body_html.should eq(%(<div class="mail"><p>hello</p></div>))
  end

  it "leaves mails unwrapped without a layout or with an unknown one" do
    LayoutBareMailer.ping("a@b.c").body_text.should eq("pong")
    LayoutMissingMailer.ping("a@b.c").body_text.should eq("pong")
  end

  it "applies default reply_to with per-mail override" do
    LayoutDemoMailer.note("a@b.c").reply_to.should eq("replies@example.com")
    LayoutDemoMailer.plain_note("a@b.c").reply_to.should eq("replies@example.com")
    LayoutDemoMailer.plain_note("a@b.c", reply_to: "direct@example.com").reply_to.should eq("direct@example.com")
    LayoutBareMailer.ping("a@b.c").reply_to.should be_nil
    LayoutDemoMailer.note("a@b.c").to_mime.should contain("Reply-To: replies@example.com")
  end

  it "passes threading headers through to MIME" do
    mime = LayoutDemoMailer.note("a@b.c").to_mime
    mime.should contain("In-Reply-To: <parent@example.com>")
  end

  it "lets a custom Message-Id replace the generated one" do
    mime = LayoutDemoMailer.note("a@b.c").to_mime
    mime.scan(/Message-ID:/).size.should eq(1)
    mime.should contain("Message-ID: <note-1@example.com>")
  end

  it "round-trips reply_to and headers through the delivery job" do
    LayoutDemoMailer.note("a@b.c").deliver_later
    payload = JSON.parse(Saci::Job.enqueued_jobs.first[:payload])
    Saci::Job.with_adapter(:inline) do
      Saci::Mailer::DeliveryJob.perform_now(payload)
    end
    delivered = Saci::Mailer.deliveries.first
    delivered.reply_to.should eq("replies@example.com")
    delivered.headers["In-Reply-To"].should eq("<parent@example.com>")
    delivered.body_text.should contain("== MyApp ==")
  end
end
