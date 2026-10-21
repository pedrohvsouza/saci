require "spec"
require "file"
require "file_utils"
require "base64"
require "../src/saci"
require "../src/saci/mailbox"

include Saci::Mailbox::TestHelpers

# ---------------------------------------------------------------------------
# Spec mailboxes (compile-time registered for symbol/string resolution)
# ---------------------------------------------------------------------------

class MailboxSpecBackupMailbox < Saci::Mailbox::Base
  @@subjects = [] of String

  def self.subjects
    @@subjects
  end

  def self.clear!
    @@subjects.clear
  end

  def process : Nil
    @@subjects << mail.subject
  end
end

class MailboxSpecSupportMailbox < Saci::Mailbox::Base
  @@subjects = [] of String

  def self.subjects
    @@subjects
  end

  def self.clear!
    @@subjects.clear
  end

  def process : Nil
    @@subjects << mail.subject
  end
end

class MailboxSpecSpamMailbox < Saci::Mailbox::Base
  @@subjects = [] of String

  def self.subjects
    @@subjects
  end

  def self.clear!
    @@subjects.clear
  end

  def process : Nil
    @@subjects << mail.subject
  end
end

class MailboxSpecBossMailbox < Saci::Mailbox::Base
  @@subjects = [] of String

  def self.subjects
    @@subjects
  end

  def self.clear!
    @@subjects.clear
  end

  def process : Nil
    @@subjects << mail.subject
  end
end

class MailboxSpecUrgentMailbox < Saci::Mailbox::Base
  @@subjects = [] of String

  def self.subjects
    @@subjects
  end

  def self.clear!
    @@subjects.clear
  end

  def process : Nil
    @@subjects << mail.subject
  end
end

class MailboxSpecFilesMailbox < Saci::Mailbox::Base
  @@attachments = [] of Tuple(String?, String)

  def self.attachments
    @@attachments
  end

  def self.clear!
    @@attachments.clear
  end

  def process : Nil
    mail.attachments.each { |attachment| @@attachments << {attachment.filename, attachment.content_type} }
  end
end

class MailboxSpecCallbackMailbox < Saci::Mailbox::Base
  @@events = [] of String

  def self.events
    @@events
  end

  def self.clear!
    @@events.clear
  end

  before_processing :before_hook
  after_processing :after_hook
  around_processing do |proceed|
    @@events << "around-before"
    proceed.call
    @@events << "around-after"
  end

  def process : Nil
    @@events << "process"
  end

  private def before_hook
    @@events << "before"
  end

  private def after_hook
    @@events << "after"
  end
end

class MailboxSpecNamedAroundMailbox < Saci::Mailbox::Base
  @@events = [] of String

  def self.events
    @@events
  end

  def self.clear!
    @@events.clear
  end

  around_processing :wrap

  def process : Nil
    @@events << "process"
  end

  private def wrap(&block : -> Nil)
    @@events << "wrap-before"
    block.call
    @@events << "wrap-after"
  end
end

class MailboxSpecRescueMailbox < Saci::Mailbox::Base
  @@handled = [] of String

  def self.handled
    @@handled
  end

  def self.clear!
    @@handled.clear
  end

  rescue_from ArgumentError do |error|
    @@handled << (error.message || "")
  end

  def process : Nil
    raise ArgumentError.new("bad payload")
  end
end

class MailboxSpecFailureMailbox < Saci::Mailbox::Base
  def process : Nil
    raise RuntimeError.new("exploded")
  end
end

class MailboxSpecBounceMailbox < Saci::Mailbox::Base
  def process : Nil
    bounce_with("Re: #{mail.subject}", "Rejected")
  end
end

class MailboxSpecRelayMailbox < Saci::Mailbox::Base
  def process : Nil
    relay_to("archive@example.com")
  end
end

class MailboxSpecInferenceMailbox < Saci::Mailbox::Base
  @@subjects = [] of String

  def self.subjects
    @@subjects
  end

  def self.clear!
    @@subjects.clear
  end

  def process : Nil
    @@subjects << mail.subject
  end
end

# ---------------------------------------------------------------------------
# Raw emails
# ---------------------------------------------------------------------------

SIMPLE_EMAIL = <<-EMAIL
From: "Jane Doe" <jane@example.com>
To: Support <support@example.com>, ops@example.com
Cc: =?UTF-8?Q?Jos=C3=A9?= <jose@example.com>
Subject: =?UTF-8?B?UsOpcG9uc2U=?= =?UTF-8?Q?_needed?=
Date: Wed, 21 Oct 2015 07:28:00 +0200
Message-ID: <simple-1@example.com>
In-Reply-To: <parent-1@example.com>
References: <parent-1@example.com> <older-1@example.com>
MIME-Version: 1.0
Content-Type: text/plain; charset=UTF-8
Content-Transfer-Encoding: quoted-printable

Hello=2C world=21
This is a soft=
 break.
EMAIL

MULTIPART_EMAIL = <<-EMAIL
From: alerts@example.com
To: files@example.com
Subject: Report attached
Date: 21 Oct 2015 09:00:00 +0000
Message-ID: <multi-1@example.com>
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="outer"

preamble text
--outer
Content-Type: multipart/alternative; boundary="alt"

--alt
Content-Type: text/plain; charset=ISO-8859-1
Content-Transfer-Encoding: quoted-printable

Caf=E9 report
--alt
Content-Type: text/html; charset=UTF-8
Content-Transfer-Encoding: base64

PGgxPkNhZsOpPC9oMT4=
--alt--
--outer
Content-Type: application/pdf; name="report.pdf"
Content-Disposition: attachment; filename*=UTF-8''caf%C3%A9.pdf
Content-Transfer-Encoding: base64

JVBERi0xLjQK
--outer
Content-Type: image/png; name="logo.png"
Content-Disposition: inline; filename="logo.png"
Content-ID: <logo@example.com>
Content-Transfer-Encoding: base64

aGVsbG8=
--outer--
EMAIL

# ---------------------------------------------------------------------------
# Suite
# ---------------------------------------------------------------------------

MAILBOX_DB_PATH = "/tmp/opencode/saci_mailbox_spec.db"

describe Saci::Mailbox do
  before_all do
    File.delete(MAILBOX_DB_PATH) if File.exists?(MAILBOX_DB_PATH)
    Saci::Record.connection = DB.open("sqlite3://#{MAILBOX_DB_PATH}")
    Saci::Mailbox.ensure_schema!
    Saci.log_requests = false
  end

  after_all do
    Saci.log_requests = true
    Saci::Record.connection.as(DB::Database).close
  end

  before_each do
    Saci::Record.clean_database!
    Saci::Mailbox.reset!
    Saci::Mailer.delivery_adapter = :test
    Saci::Mailer.clear_deliveries!
    MailboxSpecBackupMailbox.clear!
    MailboxSpecSupportMailbox.clear!
    MailboxSpecSpamMailbox.clear!
    MailboxSpecBossMailbox.clear!
    MailboxSpecUrgentMailbox.clear!
    MailboxSpecFilesMailbox.clear!
    MailboxSpecCallbackMailbox.clear!
    MailboxSpecNamedAroundMailbox.clear!
    MailboxSpecRescueMailbox.clear!
    MailboxSpecInferenceMailbox.clear!
  end

  after_each do
    Saci::Mailer.delivery_adapter = :test
  end

  # -------------------------------------------------------------------------
  describe "Message (MIME parsing)" do
    it "parses headers, addresses, dates and threading headers" do
      mail = Saci::Mailbox::Message.parse(SIMPLE_EMAIL)
      mail.from.should eq("jane@example.com")
      mail.from_name.should eq("Jane Doe")
      mail.to.should eq(["support@example.com", "ops@example.com"])
      mail.cc.should eq(["jose@example.com"])
      mail.subject.should eq("Réponse needed")
      mail.date.not_nil!.year.should eq(2015)
      mail.message_id.should eq("simple-1@example.com")
      mail.in_reply_to.should eq("parent-1@example.com")
      mail.references.should eq(["parent-1@example.com", "older-1@example.com"])
      mail.header("subject").should eq("Réponse needed")
      mail.content_type.should eq("text/plain")
    end

    it "decodes quoted-printable bodies including soft line breaks" do
      mail = Saci::Mailbox::Message.parse(SIMPLE_EMAIL)
      mail.text_body.should eq("Hello, world!\nThis is a soft break.")
    end

    it "parses nested multipart with text, html and attachments" do
      mail = Saci::Mailbox::Message.parse(MULTIPART_EMAIL)
      mail.text_body.should eq("Café report")
      mail.html_body.should eq("<h1>Café</h1>")
      mail.has_attachments?.should be_true

      pdf = mail.attachments.find { |attachment| attachment.filename == "café.pdf" }
      pdf.should_not be_nil
      pdf = pdf.not_nil!
      pdf.content_type.should eq("application/pdf")
      pdf.body.should eq("%PDF-1.4\n")
      pdf.size.should eq(9)
      pdf.inline.should be_false

      logo = mail.attachments.find { |attachment| attachment.filename == "logo.png" }
      logo.should_not be_nil
      logo = logo.not_nil!
      logo.inline.should be_true
      logo.content_id.should eq("logo@example.com")
      logo.body.should eq("hello")
    end

    it "exposes a JSON metadata round-trip" do
      mail = Saci::Mailbox::Message.parse(MULTIPART_EMAIL)
      metadata = Saci::Mailbox::Message.from_metadata(mail.to_h.to_json)
      metadata.subject.should eq("Report attached")
      metadata.to.should eq(["files@example.com"])
      metadata.text_body.should eq("Café report")
      metadata.html_body.should eq("<h1>Café</h1>")
      metadata.attachments.map(&.filename).should eq(["café.pdf", "logo.png"])
      metadata.attachments.first.content_type.should eq("application/pdf")
    end

    it "parses message/rfc822 attachments and base64 bodies" do
      raw = <<-EMAIL
From: fwd@example.com
To: inbox@example.com
Subject: Fwd
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="b"

--b
Content-Type: text/plain

See attached.
--b
Content-Type: message/rfc822

From: inner@example.com
To: inbox@example.com
Subject: Inner

Inner body
--b--
EMAIL
      mail = Saci::Mailbox::Message.parse(raw)
      mail.text_body.should eq("See attached.")
      mail.attachments.size.should eq(1)
      mail.attachments.first.filename.should eq("message.eml")
      mail.attachments.first.content_type.should eq("message/rfc822")
      mail.attachments.first.body.should contain("Inner body")
    end

    it "rejects empty input" do
      expect_raises(Saci::Mailbox::ParseError) { Saci::Mailbox::Message.parse("   ") }
    end
  end

  # -------------------------------------------------------------------------
  describe "Router" do
    it "matches the first route in registration order" do
      router = Saci::Mailbox::Router.new.draw do |r|
        r.route MailboxSpecBackupMailbox, all: true
        r.route MailboxSpecSupportMailbox, to: "support@example.com"
      end
      inbound = Saci::Mailbox::InboundEmail.build(SIMPLE_EMAIL)
      router.mailbox_for(inbound).should be_a(MailboxSpecBackupMailbox)
      router.mailbox_class_for(inbound).should eq(MailboxSpecBackupMailbox)
    end

    it "routes by to:, from: and subject: conditions" do
      inbound = Saci::Mailbox::InboundEmail.build(SIMPLE_EMAIL)

      to_router = Saci::Mailbox::Router.new.draw { |r| r.route MailboxSpecSupportMailbox, to: "support@example.com" }
      to_router.mailbox_for(inbound).should be_a(MailboxSpecSupportMailbox)

      from_router = Saci::Mailbox::Router.new.draw { |r| r.route MailboxSpecBossMailbox, from: /jane@/ }
      from_router.mailbox_for(inbound).should be_a(MailboxSpecBossMailbox)

      subject_router = Saci::Mailbox::Router.new.draw { |r| r.route MailboxSpecUrgentMailbox, subject: /réponse/i }
      subject_router.mailbox_for(inbound).should be_a(MailboxSpecUrgentMailbox)
    end

    it "requires every condition to match (AND)" do
      router = Saci::Mailbox::Router.new.draw do |r|
        r.route MailboxSpecSupportMailbox, to: "support@example.com", from: "nobody@example.com"
      end
      inbound = Saci::Mailbox::InboundEmail.build(SIMPLE_EMAIL)
      expect_raises(Saci::Mailbox::NoRouteError) { router.mailbox_for(inbound) }
    end

    it "supports Proc matchers" do
      router = Saci::Mailbox::Router.new.draw do |r|
        r.route ->(inbound : Saci::Mailbox::InboundEmail) {
          inbound.mail.attachments.any?
        }, mailbox: MailboxSpecFilesMailbox
      end
      router.mailbox_for(Saci::Mailbox::InboundEmail.build(MULTIPART_EMAIL)).should be_a(MailboxSpecFilesMailbox)
      expect_raises(Saci::Mailbox::NoRouteError) do
        router.mailbox_for(Saci::Mailbox::InboundEmail.build(SIMPLE_EMAIL))
      end
    end

    it "combines a class, conditions and a block matcher" do
      router = Saci::Mailbox::Router.new.draw do |r|
        r.route MailboxSpecFilesMailbox, to: "files@example.com" do |inbound|
          inbound.mail.text_body.includes?("Café")
        end
      end
      router.mailbox_for(Saci::Mailbox::InboundEmail.build(MULTIPART_EMAIL)).should be_a(MailboxSpecFilesMailbox)
    end

    it "resolves symbols and strings through the mailbox registry" do
      router = Saci::Mailbox::Router.new.draw do |r|
        r.route all: :mailbox_spec_backup
        r.route to: "support@example.com", mailbox: "mailbox_spec_support"
      end
      inbound = Saci::Mailbox::InboundEmail.build(SIMPLE_EMAIL)
      router.mailbox_for(inbound).should be_a(MailboxSpecBackupMailbox)
      Saci::Mailbox.resolve_mailbox(:mailbox_spec_support).should eq(MailboxSpecSupportMailbox)
      Saci::Mailbox.resolve_mailbox("MailboxSpecSupportMailbox").should eq(MailboxSpecSupportMailbox)
      expect_raises(Saci::Mailbox::UnknownMailboxError) { Saci::Mailbox.resolve_mailbox(:nope) }
    end

    it "infers the mailbox from a to: address local part" do
      router = Saci::Mailbox::Router.new.draw do |r|
        r.route to: "mailbox_spec_inference@example.com"
      end
      raw = "From: jane@example.com\nTo: mailbox_spec_inference@example.com\nSubject: Infer\nMessage-ID: <infer-1@example.com>\n\nBody"
      inbound = Saci::Mailbox::InboundEmail.build(raw)
      router.mailbox_class_for(inbound).should eq(MailboxSpecInferenceMailbox)
      expect_raises(Saci::Mailbox::ConfigurationError) do
        Saci::Mailbox::Router.new.route(to: "nobody@example.com")
      end
    end

    it "raises a descriptive error when nothing matches" do
      router = Saci::Mailbox::Router.new.draw do |r|
        r.route MailboxSpecSupportMailbox, to: "other@example.com"
      end
      inbound = Saci::Mailbox::InboundEmail.build(SIMPLE_EMAIL)
      error = expect_raises(Saci::Mailbox::NoRouteError) { router.mailbox_for(inbound) }
      message = error.message || ""
      message.should contain("No mailbox matched")
      message.should contain("simple-1@example.com")
      message.should contain("support@example.com")
      message.should contain("route")
    end
  end

  # -------------------------------------------------------------------------
  describe "processing" do
    it "routes, processes and persists an inbound email" do
      Saci::Mailbox.router = Saci::Mailbox::Router.new.draw do |r|
        r.route MailboxSpecSupportMailbox, to: "support@example.com"
      end
      inbound = Saci::Mailbox::InboundEmail.receive(SIMPLE_EMAIL)
      inbound.pending?.should be_true

      Saci::Mailbox.process!(inbound)
      inbound.processed?.should be_true
      inbound.reload.processed?.should be_true
      MailboxSpecSupportMailbox.subjects.should eq(["Réponse needed"])
      inbound.mail_message.subject.should eq("Réponse needed")
    end

    it "is idempotent for processed mail" do
      Saci::Mailbox.router = Saci::Mailbox::Router.new.draw { |r| r.route MailboxSpecSupportMailbox, all: true }
      inbound = Saci::Mailbox::InboundEmail.receive(SIMPLE_EMAIL)
      Saci::Mailbox.process!(inbound)
      Saci::Mailbox.process!(inbound)
      MailboxSpecSupportMailbox.subjects.size.should eq(1)
    end

    it "runs before/around/after callbacks in order" do
      Saci::Mailbox.router = Saci::Mailbox::Router.new.draw { |r| r.route MailboxSpecCallbackMailbox, all: true }
      inbound = Saci::Mailbox::InboundEmail.build(SIMPLE_EMAIL)
      MailboxSpecCallbackMailbox.new(inbound).perform_processing
      MailboxSpecCallbackMailbox.events.should eq(["before", "around-before", "process", "around-after", "after"])
    end

    it "supports named around_processing methods" do
      Saci::Mailbox.router = Saci::Mailbox::Router.new.draw { |r| r.route MailboxSpecNamedAroundMailbox, all: true }
      inbound = Saci::Mailbox::InboundEmail.build(SIMPLE_EMAIL)
      MailboxSpecNamedAroundMailbox.new(inbound).perform_processing
      MailboxSpecNamedAroundMailbox.events.should eq(["wrap-before", "process", "wrap-after"])
    end

    it "rescues declared exceptions with rescue_from" do
      Saci::Mailbox.router = Saci::Mailbox::Router.new.draw { |r| r.route MailboxSpecRescueMailbox, all: true }
      inbound = Saci::Mailbox::InboundEmail.build(SIMPLE_EMAIL)
      MailboxSpecRescueMailbox.new(inbound).perform_processing
      MailboxSpecRescueMailbox.handled.should eq(["bad payload"])
      inbound.processed?.should be_true
    end

    it "marks unhandled failures and re-raises" do
      Saci::Mailbox.router = Saci::Mailbox::Router.new.draw { |r| r.route MailboxSpecFailureMailbox, all: true }
      inbound = Saci::Mailbox::InboundEmail.receive(SIMPLE_EMAIL)
      expect_raises(RuntimeError, "exploded") { Saci::Mailbox.process!(inbound) }
      inbound.reload.failed?.should be_true
      inbound.last_error.should eq("exploded")
    end

    it "bounces and delivers the bounce mail" do
      Saci::Mailbox.bounce_from = "mailbox@example.com"
      Saci::Mailbox.router = Saci::Mailbox::Router.new.draw { |r| r.route MailboxSpecBounceMailbox, all: true }
      inbound = Saci::Mailbox::InboundEmail.receive(SIMPLE_EMAIL)
      Saci::Mailbox.process!(inbound)
      inbound.reload.bounced?.should be_true
      Saci::Mailer.deliveries.size.should eq(1)
      bounce = Saci::Mailer.deliveries.first
      bounce.to.should eq(["jane@example.com"])
      bounce.subject.should eq("Re: Réponse needed")
      bounce.body_text.should eq("Rejected")
    end

    it "relays mail through the configured mailer" do
      Saci::Mailbox.router = Saci::Mailbox::Router.new.draw { |r| r.route MailboxSpecRelayMailbox, all: true }
      inbound = Saci::Mailbox::InboundEmail.receive(SIMPLE_EMAIL)
      Saci::Mailbox.process!(inbound)
      Saci::Mailer.deliveries.size.should eq(1)
      forwarded = Saci::Mailer.deliveries.first
      forwarded.to.should eq(["archive@example.com"])
      forwarded.from.should eq("jane@example.com")
      forwarded.subject.should eq("Fwd: Réponse needed")
      forwarded.headers["X-Saci-Forwarded-Message-Id"].should eq("simple-1@example.com")
    end

    it "incinerates the raw source after processing when configured" do
      Saci::Mailbox.incinerate_after_processing = true
      Saci::Mailbox.router = Saci::Mailbox::Router.new.draw { |r| r.route MailboxSpecSupportMailbox, all: true }
      inbound = Saci::Mailbox::InboundEmail.receive(SIMPLE_EMAIL)
      Saci::Mailbox.process!(inbound)
      inbound.reload.incinerated?.should be_true
      inbound.raw_email.should be_nil
      inbound.processed?.should be_true
      # Metadata survives incineration.
      inbound.mail_message.subject.should eq("Réponse needed")
      inbound.mail_message.attachments.should be_empty
    end

    it "supports manual incineration and incineration through jobs" do
      inbound = Saci::Mailbox::InboundEmail.receive(SIMPLE_EMAIL)
      inbound.incinerate
      inbound.reload.incinerated?.should be_true

      second = Saci::Mailbox::InboundEmail.receive(MULTIPART_EMAIL)
      Saci::Job.with_adapter(:inline) { second.incinerate_later }
      second.reload.incinerated?.should be_true
      second.forget
      second.incinerated?.should be_true
    end

    it "exposes attachments to mailbox code" do
      Saci::Mailbox.router = Saci::Mailbox::Router.new.draw { |r| r.route MailboxSpecFilesMailbox, all: true }
      inbound = Saci::Mailbox::InboundEmail.receive(MULTIPART_EMAIL)
      Saci::Mailbox.process!(inbound)
      MailboxSpecFilesMailbox.attachments.should eq([
        {"café.pdf", "application/pdf"},
        {"logo.png", "image/png"},
      ])
    end
  end

  # -------------------------------------------------------------------------
  describe "InboundEmail persistence" do
    it "creates the schema idempotently" do
      Saci::Mailbox::InboundEmail.table_exists?.should be_true
      Saci::Mailbox.ensure_schema!
      Saci::Record::Migrator.applied_names(Saci::Record.connection).should contain("Saci::Mailbox::CreateInboundEmails")
    end

    it "persists raw source and JSON metadata" do
      inbound = Saci::Mailbox::InboundEmail.receive(SIMPLE_EMAIL)
      inbound.persisted?.should be_true
      inbound.message_id.should eq("simple-1@example.com")
      inbound.status.should eq("pending")
      inbound.created_at.should_not be_nil
      inbound.mail_json.not_nil!["subject"].as_s.should eq("Réponse needed")
      inbound.raw_email.should eq(SIMPLE_EMAIL)
    end

    it "deduplicates by Message-ID" do
      first = Saci::Mailbox::InboundEmail.receive(SIMPLE_EMAIL)
      second = Saci::Mailbox::InboundEmail.receive(SIMPLE_EMAIL)
      second.id.should eq(first.id)
      Saci::Mailbox::InboundEmail.count.should eq(1)
    end

    it "builds unsaved inbound emails without touching the database" do
      inbound = Saci::Mailbox::InboundEmail.build(SIMPLE_EMAIL)
      inbound.new_record?.should be_true
      inbound.message_id.should eq("simple-1@example.com")
      inbound.mail_message.from.should eq("jane@example.com")
    end

    it "tracks processed and bounced states" do
      inbound = Saci::Mailbox::InboundEmail.build(SIMPLE_EMAIL)
      inbound.mark_processing!
      inbound.processing?.should be_true
      inbound.mark_processed!
      inbound.processed?.should be_true
      inbound.bounced?.should be_false
      inbound.mark_bounced!
      inbound.bounced?.should be_true
    end
  end

  # -------------------------------------------------------------------------
  describe "ingress" do
    it "mounts the default Rails-style ingress path" do
      router = Saci::Router.new
      Saci::Mailbox.mount(router).should be(router)
      router.routes_table.any? { |line| line.includes?("/rails/action_mailbox/:provider/inbound_emails") }.should be_true
      Saci::Mailbox::Ingress.ingress_path?("/rails/action_mailbox/postmark/inbound_emails").should be_true
      Saci::Mailbox::Ingress.ingress_path?("/rails/action_mailbox/postmark/other").should be_false
    end

    it "mounts a custom path" do
      router = Saci::Router.new
      Saci::Mailbox.mount(router, path: "/inbound/email")
      router.routes_table.any? { |line| line.includes?("/inbound/email") }.should be_true
    end

    it "accepts raw MIME with bearer auth and returns 204" do
      Saci::Mailbox.router = Saci::Mailbox::Router.new.draw { |r| r.route MailboxSpecSupportMailbox, all: true }
      Saci::Mailbox.ingress_password = "s3cret"
      router = Saci::Router.new
      Saci::Mailbox.mount(router)

      Saci::TestSession.serve(router) do |app|
        headers = HTTP::Headers{"Content-Type" => "message/rfc822", "Authorization" => "Bearer s3cret"}
        response = app.post("/rails/action_mailbox/postmark/inbound_emails", headers, SIMPLE_EMAIL)
        response.status_code.should eq(204)
        response.body.should eq("")
      end

      Saci::Mailbox::InboundEmail.count.should eq(1)
      Saci::Mailbox::InboundEmail.first.not_nil!.processed?.should be_true
      MailboxSpecSupportMailbox.subjects.should eq(["Réponse needed"])
    end

    it "accepts Basic auth and token headers" do
      Saci::Mailbox.router = Saci::Mailbox::Router.new.draw { |r| r.route MailboxSpecSupportMailbox, all: true }
      Saci::Mailbox.ingress_password = "s3cret"
      router = Saci::Router.new
      Saci::Mailbox.mount(router)

      Saci::TestSession.serve(router) do |app|
        basic = HTTP::Headers{
          "Content-Type"  => "message/rfc822",
          "Authorization" => "Basic #{Base64.strict_encode("actionmailbox:s3cret")}",
        }
        app.post("/rails/action_mailbox/mailgun/inbound_emails", basic, SIMPLE_EMAIL).status_code.should eq(204)

        token = HTTP::Headers{
          "Content-Type"         => "message/rfc822",
          "X-Saci-Mailbox-Token" => "s3cret",
        }
        app.post("/rails/action_mailbox/sendgrid/inbound_emails", token, SIMPLE_EMAIL).status_code.should eq(204)
      end
    end

    it "rejects bad credentials with 401" do
      Saci::Mailbox.router = Saci::Mailbox::Router.new.draw { |r| r.route MailboxSpecSupportMailbox, all: true }
      Saci::Mailbox.ingress_password = "s3cret"
      router = Saci::Router.new
      Saci::Mailbox.mount(router)

      Saci::TestSession.serve(router) do |app|
        headers = HTTP::Headers{"Content-Type" => "message/rfc822", "Authorization" => "Bearer nope"}
        response = app.post("/rails/action_mailbox/postmark/inbound_emails", headers, SIMPLE_EMAIL)
        response.status_code.should eq(401)
        response.body.should contain("Unauthorized")
      end
      Saci::Mailbox::InboundEmail.count.should eq(0)
    end

    it "is open when no password is configured" do
      Saci::Mailbox.router = Saci::Mailbox::Router.new.draw { |r| r.route MailboxSpecSupportMailbox, all: true }
      router = Saci::Router.new
      Saci::Mailbox.mount(router)

      Saci::TestSession.serve(router) do |app|
        headers = HTTP::Headers{"Content-Type" => "message/rfc822"}
        app.post("/rails/action_mailbox/postmark/inbound_emails", headers, SIMPLE_EMAIL).status_code.should eq(204)
      end
    end

    it "rejects oversized sources with 422" do
      Saci::Mailbox.router = Saci::Mailbox::Router.new.draw { |r| r.route MailboxSpecSupportMailbox, all: true }
      Saci::Mailbox.max_ingress_size = 20
      router = Saci::Router.new
      Saci::Mailbox.mount(router)

      Saci::TestSession.serve(router) do |app|
        headers = HTTP::Headers{"Content-Type" => "message/rfc822"}
        response = app.post("/rails/action_mailbox/postmark/inbound_emails", headers, SIMPLE_EMAIL)
        response.status_code.should eq(422)
        response.body.should contain("exceeds")
      end
      Saci::Mailbox::InboundEmail.count.should eq(0)
    end

    it "rejects missing or blank sources with 422" do
      Saci::Mailbox.router = Saci::Mailbox::Router.new.draw { |r| r.route MailboxSpecSupportMailbox, all: true }
      router = Saci::Router.new
      Saci::Mailbox.mount(router)

      Saci::TestSession.serve(router) do |app|
        headers = HTTP::Headers{"Content-Type" => "message/rfc822"}
        app.post("/rails/action_mailbox/postmark/inbound_emails", headers, "   ").status_code.should eq(422)
      end
      Saci::Mailbox::InboundEmail.count.should eq(0)
    end

    it "accepts provider JSON payloads" do
      Saci::Mailbox.router = Saci::Mailbox::Router.new.draw { |r| r.route MailboxSpecSupportMailbox, all: true }
      router = Saci::Router.new
      Saci::Mailbox.mount(router)

      body = %({"email": #{SIMPLE_EMAIL.to_json}})
      Saci::TestSession.serve(router) do |app|
        headers = HTTP::Headers{"Content-Type" => "application/json"}
        response = app.post("/rails/action_mailbox/postmark/inbound_emails", headers, body)
        response.status_code.should eq(204)
      end
      Saci::Mailbox::InboundEmail.first.not_nil!.processed?.should be_true
    end

    it "accepts provider form payloads" do
      Saci::Mailbox.router = Saci::Mailbox::Router.new.draw { |r| r.route MailboxSpecSupportMailbox, all: true }
      router = Saci::Router.new
      Saci::Mailbox.mount(router)

      body = URI::Params.encode({"body-mime" => SIMPLE_EMAIL})
      Saci::TestSession.serve(router) do |app|
        headers = HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"}
        response = app.post("/rails/action_mailbox/mailgun/inbound_emails", headers, body)
        response.status_code.should eq(204)
      end
      Saci::Mailbox::InboundEmail.first.not_nil!.processed?.should be_true
    end

    it "returns 422 when no route matches" do
      Saci::Mailbox.router = Saci::Mailbox::Router.new
      router = Saci::Router.new
      Saci::Mailbox.mount(router)

      Saci::TestSession.serve(router) do |app|
        headers = HTTP::Headers{"Content-Type" => "message/rfc822"}
        response = app.post("/rails/action_mailbox/postmark/inbound_emails", headers, SIMPLE_EMAIL)
        response.status_code.should eq(422)
        response.body.should contain("No mailbox matched")
      end
    end
  end

  # -------------------------------------------------------------------------
  describe "test helpers" do
    it "creates inbound emails from mail fields" do
      inbound = create_inbound_email_from_mail(
        from: "jane@example.com",
        to: "support@example.com",
        subject: "Help",
        body: "Please help")
      inbound.persisted?.should be_true
      inbound.mail_message.subject.should eq("Help")
      inbound.mail_message.to.should eq(["support@example.com"])
      assert_emails_received(1)
    end

    it "creates inbound emails from a Saci::Mailer::Mail" do
      mail = Saci::Mailer::Mail.new(["support@example.com"], "jane@example.com", "From mailer", "Body")
      inbound = create_inbound_email_from_mail(mail)
      inbound.mail_message.subject.should eq("From mailer")
      assert_emails_received
    end

    it "creates inbound emails from a fixture" do
      inbound = create_inbound_email_from_fixture("support_request")
      inbound.message_id.should eq("fixture-support-1@example.com")
      inbound.mail_message.subject.should eq("Help needed")
      inbound.mail_message.text_body.should eq("Hi support,\nMy account is locked and I can't sign in.\nThanks!\n")
    end

    it "creates inbound emails from a source string" do
      inbound = create_inbound_email_from_source(SIMPLE_EMAIL)
      inbound.message_id.should eq("simple-1@example.com")
      assert_emails_received(1)
    end

    it "processes through perform_processing" do
      Saci::Mailbox.router = Saci::Mailbox::Router.new.draw { |r| r.route MailboxSpecSupportMailbox, all: true }
      inbound = create_inbound_email_from_source(SIMPLE_EMAIL)
      perform_processing(inbound).processed?.should be_true
      MailboxSpecSupportMailbox.subjects.should eq(["Réponse needed"])
    end

    it "asserts on received email counts" do
      assert_no_emails
      create_inbound_email_from_source(SIMPLE_EMAIL)
      assert_emails_received(1)
      expect_raises(Saci::Mailbox::AssertionFailed) { assert_emails_received(2) }
      clear_inbound_emails!
      assert_no_emails
    end
  end
end
