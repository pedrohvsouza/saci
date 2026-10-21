require "spec"
require "file_utils"
require "http/server"
require "socket"
require "../src/saci"

# Exercise the helper module through a small includer instead of polluting
# every spec's top-level namespace (other test helpers may define similar
# method names).
class ExtrasMailerAssertions
  include Saci::Mailer::TestHelpers
end

EXTRAS_MAILER_ASSERTIONS = ExtrasMailerAssertions.new

# Shared event log for callback ordering (class vars are per-class in Crystal,
# so a global keeps parent/child callbacks in one observable list).
EXTRAS_CALLBACK_EVENTS = [] of String

def extras_reset_events! : Nil
  EXTRAS_CALLBACK_EVENTS.clear
end

class ExtrasAttachmentMailer < Saci::Mailer::Base
  default_from "noreply@example.com"

  def self.report(email : String) : Saci::Mailer::Mail
    attachments["report.pdf"] = {mime_type: "application/pdf", content: "PDFDATA"}
    attachments.inline["logo.png"] = {mime_type: "image/png", content: "PNGDATA"}
    mail(to: email, subject: "Report") do |format|
      format.text { "see attachment" }
      format.html { %(<img src="cid:logo.png">) }
    end
  end

  def self.text_only(email : String) : Saci::Mailer::Mail
    attachments["notes.txt"] = "plain notes"
    mail(to: email, subject: "Notes") do |format|
      format.text { "notes" }
    end
  end

  def self.dedupe(email : String) : Saci::Mailer::Mail
    attachments["same.txt"] = "one"
    attachments["same.txt"] = "two"
    mail(to: email, subject: "Dedupe") { |format| format.text { "x" } }
  end

  def self.from_path(email : String, path : String) : Saci::Mailer::Mail
    attachments["data.bin"] = {path: path}
    mail(to: email, subject: "Path") { |format| format.text { "x" } }
  end

  def self.unicode(email : String) : Saci::Mailer::Mail
    attachments["résumé.pdf"] = {mime_type: "application/pdf", content: "CV"}
    mail(to: email, subject: "CV") { |format| format.text { "x" } }
  end

  def self.hash_form(email : String) : Saci::Mailer::Mail
    attachments["a.txt"] = {"mime_type" => "text/plain", "content" => "hash body"}
    mail(to: email, subject: "Hash") { |format| format.text { "x" } }
  end
end

class ExtrasCallbackMailer < Saci::Mailer::Base
  default_from "noreply@example.com"

  before_action :parent_before
  before_action :only_welcome, only: :welcome
  before_action :except_welcome, except: :welcome
  after_action :parent_after
  around_action :parent_around
  rescue_from ArgumentError, with: :handle_argument_error

  def self.parent_before
    EXTRAS_CALLBACK_EVENTS << "parent_before"
    headers["X-Parent"] = "1"
  end

  def self.only_welcome
    EXTRAS_CALLBACK_EVENTS << "only_welcome"
  end

  def self.except_welcome
    EXTRAS_CALLBACK_EVENTS << "except_welcome"
  end

  def self.parent_after
    EXTRAS_CALLBACK_EVENTS << "parent_after"
  end

  def self.parent_around(&block : -> Saci::Mailer::Mail) : Saci::Mailer::Mail
    EXTRAS_CALLBACK_EVENTS << "parent_around_before"
    result = yield
    EXTRAS_CALLBACK_EVENTS << "parent_around_after"
    result
  end

  def self.handle_argument_error(error : ArgumentError) : Saci::Mailer::Mail
    EXTRAS_CALLBACK_EVENTS << "rescue"
    mail(to: "fallback@example.com", subject: "rescued #{error.message}") do |format|
      format.text { "fallback" }
    end
  end

  def self.welcome(email : String) : Saci::Mailer::Mail
    mail(to: email, subject: "Welcome") do |format|
      format.text { EXTRAS_CALLBACK_EVENTS << "action"; "hi" }
    end
  end

  def self.other(email : String) : Saci::Mailer::Mail
    mail(to: email, subject: "Other") do |format|
      format.text { EXTRAS_CALLBACK_EVENTS << "other_action"; "hi" }
    end
  end

  def self.boom(email : String) : Saci::Mailer::Mail
    mail(to: email, subject: "boom") do |format|
      format.text { raise ArgumentError.new("kaboom") }
    end
  end

  def self.hard_boom(email : String) : Saci::Mailer::Mail
    mail(to: email, subject: "hard") do |format|
      format.text { raise "unhandled" }
    end
  end
end

class ExtrasChildCallbackMailer < ExtrasCallbackMailer
  before_action :child_before, only: :welcome
  after_action :child_after

  def self.child_before
    EXTRAS_CALLBACK_EVENTS << "child_before"
  end

  def self.child_after
    EXTRAS_CALLBACK_EVENTS << "child_after"
  end

  def self.welcome(email : String) : Saci::Mailer::Mail
    mail(to: email, subject: "Child welcome") do |format|
      format.text { EXTRAS_CALLBACK_EVENTS << "child_action"; "hi" }
    end
  end

  def self.plain(email : String) : Saci::Mailer::Mail
    mail(to: email, subject: "Plain") do |format|
      format.text { EXTRAS_CALLBACK_EVENTS << "plain_action"; "hi" }
    end
  end
end

class ExtrasParamMailer < Saci::Mailer::Base
  default_from "noreply@example.com"

  def self.welcome : Saci::Mailer::Mail
    name = params.as_s?("name") || "friend"
    mail(to: params.as_s("email"), subject: "Hi #{name}") do |format|
      format.text { "hello #{name}" }
    end
  end

  def self.counted : Saci::Mailer::Mail
    mail(to: params.as_s("email"), subject: "Count #{params.as_i?("count") || 0}") do |format|
      format.text { "count" }
    end
  end
end

class ExtrasFileLayoutMailer < Saci::Mailer::Base
  default_from "noreply@example.com"
  layout "extras-file-layout"

  def self.note(email : String) : Saci::Mailer::Mail
    mail(to: email, subject: "Layered") do |format|
      format.text { "body" }
      format.html { "<p>body</p>" }
    end
  end
end

# Local HTTP sink used to verify provider payloads/headers without touching
# the network.
class ExtrasHttpSink
  getter method : String = ""
  getter path : String = ""
  getter headers = HTTP::Headers.new
  getter body : String = ""

  def initialize(@status_code : Int32 = 200)
    @server = HTTP::Server.new do |context|
      @method = context.request.method
      @path = context.request.path
      @headers = context.request.headers
      @body = context.request.body.try(&.gets_to_end) || ""
      context.response.status_code = @status_code
      context.response.content_type = "application/json"
      context.response.print(%({"ok":true}))
    end
  end

  def run(& : String ->) : Nil
    address = @server.bind_tcp("127.0.0.1", 0)
    spawn { @server.listen }
    begin
      yield "http://127.0.0.1:#{address.port}"
    ensure
      @server.close rescue nil
    end
  end
end

# Minimal SMTP sink that captures the DATA payload.
class ExtrasSmtpSink
  getter data : String = ""

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
  end

  def port : Int32
    @server.local_address.port
  end

  def run_once(& : ->) : Nil
    done = Channel(Nil).new
    spawn do
      begin
        client = @server.accept
        client << "220 extras-smtp\r\n"
        in_data = false
        buffer = IO::Memory.new
        while raw = client.gets(chomp: true)
          line = raw.ends_with?("\r") ? raw[0...-1] : raw
          if in_data
            if line == "."
              @data = buffer.to_s
              buffer.clear
              in_data = false
              client << "250 queued\r\n"
            else
              buffer << line << "\r\n"
            end
            next
          end
          upper = line.upcase
          case
          when upper.starts_with?("EHLO") || upper.starts_with?("HELO")
            client << "250-extras-smtp\r\n250 8BITMIME\r\n"
          when upper.starts_with?("MAIL FROM:") || upper.starts_with?("RCPT TO:")
            client << "250 ok\r\n"
          when upper == "DATA"
            client << "354 go\r\n"
            in_data = true
          when upper == "QUIT"
            client << "221 bye\r\n"
            break
          else
            client << "250 ok\r\n"
          end
        end
        client.close rescue nil
      ensure
        @server.close rescue nil
        done.send(nil)
      end
    end
    yield
    done.receive
  end
end

def extras_dkim_key : String
  io = IO::Memory.new
  status = Process.run("openssl", args: ["genrsa", "2048"], output: io, error: Process::Redirect::Close)
  raise "openssl genrsa failed" unless status.success?
  io.to_s
end

describe "mailer attachments (G77)" do
  before_each do
    Saci::Mailer.delivery_adapter = :test
    Saci::Mailer.clear_deliveries!
    Saci::Job.queue_adapter = :test
    Saci::Job.clear_enqueued!
  end

  after_each do
    Saci::Mailer.delivery_adapter = :file
    Saci::Job.queue_adapter = :async
    Saci::Mailer.max_attachment_size = 25 * 1024 * 1024
    Saci::Mailer.max_total_attachment_size = 50 * 1024 * 1024
  end

  it "builds a mixed multipart with alternative body and attachments" do
    mail = ExtrasAttachmentMailer.report("a@b.c")
    mail.attachments.size.should eq(2)
    mail.inline_attachments.size.should eq(1)
    mail.attachments["report.pdf"].mime_type.should eq("application/pdf")
    mail.attachment("report.pdf").not_nil!.mime_type.should eq("application/pdf")
    mail.attachment("logo.png").not_nil!.inline?.should be_true

    mime = mail.to_mime
    mime.should contain("Content-Type: multipart/mixed; boundary=\"saci-mixed-")
    mime.should contain("Content-Type: multipart/alternative; boundary=\"saci-alt-")
    mime.should contain("Content-Type: application/pdf; name=\"report.pdf\"")
    mime.should contain("Content-Disposition: attachment; filename=\"report.pdf\"")
    mime.should contain("Content-Disposition: inline; filename=\"logo.png\"")
    mime.should contain("Content-ID: <logo.png>")
    mime.should contain("Content-Transfer-Encoding: base64")
    mime.should contain("cid:logo.png")
    mime.should contain(Base64.strict_encode("PDFDATA"))
    mime.should contain(Base64.strict_encode("PNGDATA"))
  end

  it "keeps plain multipart structure for text-only mail with attachments" do
    mime = ExtrasAttachmentMailer.text_only("a@b.c").to_mime
    mime.should contain("Content-Type: multipart/mixed; boundary=\"saci-mixed-")
    mime.should contain("Content-Type: text/plain; charset=UTF-8")
    mime.should contain("Content-Disposition: attachment; filename=\"notes.txt\"")
    mime.should_not contain("multipart/alternative")
  end

  it "dedupes by filename, keeping the latest content" do
    mail = ExtrasAttachmentMailer.dedupe("a@b.c")
    mail.attachments.size.should eq(1)
    Base64.strict_encode(mail.attachments.first.content).should eq(Base64.strict_encode("two"))
  end

  it "reads attachment content from a path" do
    dir = "/tmp/opencode/saci-attach-#{Random.rand(1_000_000)}"
    Dir.mkdir_p(dir)
    path = File.join(dir, "blob.bin")
    File.write(path, Bytes[0_u8, 1_u8, 2_u8, 255_u8])
    begin
      mail = ExtrasAttachmentMailer.from_path("a@b.c", path)
      mail.attachments.first.content.should eq(Bytes[0_u8, 1_u8, 2_u8, 255_u8])
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "encodes non-ASCII filenames with RFC 2231" do
    mime = ExtrasAttachmentMailer.unicode("a@b.c").to_mime
    mime.should contain("filename*=UTF-8''r%C3%A9sum%C3%A9.pdf")
  end

  it "accepts hash-style options" do
    mail = ExtrasAttachmentMailer.hash_form("a@b.c")
    mail.attachments.first.mime_type.should eq("text/plain")
    mail.attachments.first.content.should eq("hash body".to_slice)
  end

  it "enforces per-attachment and total size limits" do
    Saci::Mailer.max_attachment_size = 3
    expect_raises(Saci::Mailer::AttachmentTooLarge) do
      ExtrasAttachmentMailer.text_only("a@b.c")
    end

    Saci::Mailer.max_attachment_size = 25 * 1024 * 1024
    Saci::Mailer.max_total_attachment_size = 4
    expect_raises(Saci::Mailer::AttachmentTooLarge) do
      Saci::Mailer::Mail.new(["a@b.c"], "f@x.io", "s", attachments: [
        Saci::Mailer::Attachment.new("a.txt", "abc"),
        Saci::Mailer::Attachment.new("b.txt", "def"),
      ])
    end
  end

  it "carries attachments through the test delivery adapter" do
    ExtrasAttachmentMailer.report("a@b.c").deliver_now
    Saci::Mailer.deliveries.size.should eq(1)
    Saci::Mailer.deliveries.first.attachments.size.should eq(2)
  end

  it "carries attachments through deliver_later" do
    ExtrasAttachmentMailer.report("a@b.c").deliver_later
    payload = JSON.parse(Saci::Job.enqueued_jobs.first[:payload])
    payload["attachments"]?.not_nil!.as_a.size.should eq(2)
    Saci::Job.with_adapter(:inline) do
      Saci::Mailer::DeliveryJob.perform_now(payload)
    end
    delivered = Saci::Mailer.deliveries.first
    delivered.attachments.size.should eq(2)
    delivered.attachment("report.pdf").not_nil!.content.should eq("PDFDATA".to_slice)
  end

  it "carries attachments through SMTP" do
    sink = ExtrasSmtpSink.new
    settings = Saci::Mailer::SmtpSettings.new(host: "127.0.0.1", port: sink.port, tls: :never)
    sink.run_once do
      Saci::Mailer::SMTP.deliver(ExtrasAttachmentMailer.report("a@b.c"), settings)
    end
    sink.data.should contain("Content-Disposition: attachment; filename=\"report.pdf\"")
    sink.data.should contain(Base64.strict_encode("PDFDATA"))
  end
end

describe "mailer callbacks (G81)" do
  before_each do
    extras_reset_events!
    Saci::Mailer.delivery_adapter = :test
    Saci::Mailer.clear_deliveries!
  end

  after_each do
    Saci::Mailer.delivery_adapter = :file
  end

  it "runs before/around/after callbacks in order with only/except filters" do
    mail = ExtrasCallbackMailer.welcome("a@b.c")
    mail.headers["X-Parent"]?.should eq("1")
    EXTRAS_CALLBACK_EVENTS.should eq([
      "parent_before", "only_welcome", "parent_around_before",
      "action", "parent_around_after", "parent_after",
    ])
  end

  it "applies except filters and skips only filters for other actions" do
    ExtrasCallbackMailer.other("a@b.c")
    EXTRAS_CALLBACK_EVENTS.should eq([
      "parent_before", "except_welcome", "parent_around_before",
      "other_action", "parent_around_after", "parent_after",
    ])
  end

  it "runs inherited callbacks parent-first" do
    ExtrasChildCallbackMailer.welcome("a@b.c")
    EXTRAS_CALLBACK_EVENTS.should eq([
      "parent_before", "only_welcome", "child_before", "parent_around_before",
      "child_action", "parent_around_after", "parent_after", "child_after",
    ])
  end

  it "rescues registered exceptions and returns the fallback mail" do
    mail = ExtrasCallbackMailer.boom("a@b.c")
    mail.subject.should eq("rescued kaboom")
    EXTRAS_CALLBACK_EVENTS.should contain("rescue")
  end

  it "re-raises unhandled exceptions" do
    expect_raises(Exception, /unhandled/) do
      ExtrasCallbackMailer.hard_boom("a@b.c")
    end
  end

  it "does not leak callback state between mails" do
    ExtrasCallbackMailer.welcome("a@b.c")
    Saci::Mailer::Context.current.should be_nil
  end
end

describe "parameterized mailers (G80)" do
  before_each do
    Saci::Job.queue_adapter = :test
    Saci::Job.clear_enqueued!
    Saci::Mailer.delivery_adapter = :test
    Saci::Mailer.clear_deliveries!
  end

  after_each do
    Saci::Job.queue_adapter = :async
    Saci::Mailer.delivery_adapter = :file
  end

  it "exposes params to the mail method" do
    mail = ExtrasParamMailer.with(email: "a@b.c", name: "Ada").welcome
    mail.to.should eq(["a@b.c"])
    mail.subject.should eq("Hi Ada")
    mail.mailer.should eq("ExtrasParamMailer")
    mail.action.should eq("welcome")
    mail.params["email"].as_s.should eq("a@b.c")
  end

  it "coerces scalar param types" do
    mail = ExtrasParamMailer.with(email: "a@b.c", name: "Grace").welcome
    mail.body_text.should contain("hello Grace")
    ExtrasParamMailer.with(email: "a@b.c", count: 3).counted.subject.should eq("Count 3")
  end

  it "clears params after the action" do
    ExtrasParamMailer.with(email: "a@b.c").welcome
    ExtrasParamMailer.params.empty?.should be_true
  end

  it "works with deliver_later" do
    ExtrasParamMailer.with(email: "a@b.c", name: "Ada").welcome.deliver_later
    entry = Saci::Job.enqueued_jobs.first
    payload = JSON.parse(entry[:payload])
    payload["_mailer"]?.try(&.as_s?).should eq("ExtrasParamMailer")
    payload["_action"]?.try(&.as_s?).should eq("welcome")
    payload["_params"]?.try(&.as_h?).not_nil!["name"].as_s.should eq("Ada")
  end

  it "rejects unknown actions" do
    expect_raises(ArgumentError, /Unknown parameterized mailer action/) do
      ExtrasParamMailer.with(email: "a@b.c").nope
    end
  end
end

describe "deliver_later wait/queue (G83)" do
  before_each do
    Saci::Job.queue_adapter = :test
    Saci::Job.clear_enqueued!
    Saci::Mailer.delivery_adapter = :test
    Saci::Mailer.clear_deliveries!
  end

  after_each do
    Saci::Job.queue_adapter = :async
    Saci::Mailer.delivery_adapter = :file
  end

  it "records wait, wait_until and queue metadata" do
    ExtrasAttachmentMailer.report("a@b.c").deliver_later(wait: 5.minutes, queue: "low")
    payload = JSON.parse(Saci::Job.enqueued_jobs.first[:payload])
    payload["_queue"]?.try(&.as_s?).should eq("low")
    payload["_mailer"]?.try(&.as_s?).should eq("ExtrasAttachmentMailer")
    payload["_action"]?.try(&.as_s?).should eq("report")
  end

  it "accepts wait_until without sleeping in inline mode" do
    mail = ExtrasAttachmentMailer.text_only("a@b.c")
    Saci::Job.with_adapter(:inline) do
      mail.deliver_later(wait_until: Time.utc + 1.second)
    end
    Saci::Mailer.deliveries.size.should eq(1)
  end

  it "keeps render-now semantics for later delivery" do
    ExtrasAttachmentMailer.report("a@b.c").deliver_later
    payload = JSON.parse(Saci::Job.enqueued_jobs.first[:payload])
    payload["body_text"]?.try(&.as_s?).should eq("see attachment")
    payload["attachments"]?.not_nil!.as_a.size.should eq(2)
  end
end

describe "mailer test helpers (G82)" do
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

  it "asserts delivered email counts" do
    EXTRAS_MAILER_ASSERTIONS.assert_emails(1) { ExtrasAttachmentMailer.text_only("a@b.c").deliver_now }
    EXTRAS_MAILER_ASSERTIONS.assert_no_emails { }
  end

  it "fails with a useful message when the count is wrong" do
    expect_raises(Saci::Mailer::TestHelpers::AssertionFailed, /Expected 2 email/) do
      EXTRAS_MAILER_ASSERTIONS.assert_emails(2) { ExtrasAttachmentMailer.text_only("a@b.c").deliver_now }
    end
  end

  it "asserts enqueued emails by mailer/action/params" do
    EXTRAS_MAILER_ASSERTIONS.assert_enqueued_email_with(ExtrasParamMailer, :welcome, params: {"email" => "a@b.c"}) do
      ExtrasParamMailer.with(email: "a@b.c", name: "Ada").welcome.deliver_later
    end
  end

  it "asserts enqueued email counts" do
    EXTRAS_MAILER_ASSERTIONS.assert_enqueued_emails(1) do
      ExtrasAttachmentMailer.text_only("a@b.c").deliver_later
    end
  end
end

describe "delivery providers (G78)" do
  before_each do
    Saci::Mailer.delivery_adapter = :test
  end

  after_each do
    Saci::Mailer.delivery_adapter = :file
  end

  it "sends a SendGrid payload with attachments" do
    sink = ExtrasHttpSink.new
    sink.run do |base|
      Saci::Mailer.sendgrid_settings = Saci::Mailer::SendgridSettings.new(api_key: "sg-key", endpoint: "#{base}/sendgrid")
      Saci::Mailer.delivery_adapter = :sendgrid
      ExtrasAttachmentMailer.report("a@b.c").deliver_now
    end
    sink.method.should eq("POST")
    sink.path.should eq("/sendgrid")
    sink.headers["Authorization"]?.should eq("Bearer sg-key")
    payload = JSON.parse(sink.body)
    payload["subject"].as_s.should eq("Report")
    payload["personalizations"].as_a.first["to"].as_a.first["email"].as_s.should eq("a@b.c")
    attachments = payload["attachments"].as_a
    attachments.size.should eq(2)
    attachments.first["content"].as_s.should eq(Base64.strict_encode("PDFDATA"))
    attachments[1]["disposition"].as_s.should eq("inline")
    attachments[1]["content_id"].as_s.should eq("logo.png")
  end

  it "sends a Mailgun multipart payload with attachments" do
    sink = ExtrasHttpSink.new
    sink.run do |base|
      Saci::Mailer.mailgun_settings = Saci::Mailer::MailgunSettings.new(api_key: "mg-key", domain: "example.com", api_base: base)
      Saci::Mailer.delivery_adapter = :mailgun
      ExtrasAttachmentMailer.report("a@b.c").deliver_now
    end
    sink.path.should eq("/v3/example.com/messages")
    sink.headers["Authorization"]?.not_nil!.should start_with("Basic ")
    sink.body.should contain("name=\"from\"")
    sink.body.should contain("noreply@example.com")
    sink.body.should contain("name=\"subject\"")
    sink.body.should contain("name=\"attachment\"; filename=\"report.pdf\"")
    sink.body.should contain("name=\"inline\"; filename=\"logo.png\"")
    sink.body.should contain("Content-ID: <logo.png>")
    sink.body.should contain("PDFDATA")
  end

  it "sends a Postmark payload with attachments" do
    sink = ExtrasHttpSink.new
    sink.run do |base|
      Saci::Mailer.postmark_settings = Saci::Mailer::PostmarkSettings.new(api_key: "pm-key", endpoint: "#{base}/postmark")
      Saci::Mailer.delivery_adapter = :postmark
      ExtrasAttachmentMailer.report("a@b.c").deliver_now
    end
    sink.headers["X-Postmark-Server-Token"]?.should eq("pm-key")
    payload = JSON.parse(sink.body)
    payload["Subject"].as_s.should eq("Report")
    payload["To"].as_s.should eq("a@b.c")
    payload["Attachments"].as_a.size.should eq(2)
    payload["Attachments"].as_a.first["Content"].as_s.should eq(Base64.strict_encode("PDFDATA"))
  end

  it "sends an unsigned SES payload by default in tests" do
    sink = ExtrasHttpSink.new
    sink.run do |base|
      Saci::Mailer.ses_settings = Saci::Mailer::SesSettings.new(region: "us-east-1", endpoint: "#{base}/ses", sign_requests: false)
      Saci::Mailer.delivery_adapter = :ses
      ExtrasAttachmentMailer.report("a@b.c").deliver_now
    end
    sink.path.should eq("/ses")
    sink.headers["Authorization"]?.should be_nil
    payload = JSON.parse(sink.body)
    payload["FromEmailAddress"].as_s.should eq("noreply@example.com")
    raw = String.new(Base64.decode(payload["Content"]["Raw"]["Data"].as_s))
    raw.should contain("Content-Disposition: attachment; filename=\"report.pdf\"")
  end

  it "signs SES requests with SigV4 when credentials are present" do
    sink = ExtrasHttpSink.new
    sink.run do |base|
      Saci::Mailer.ses_settings = Saci::Mailer::SesSettings.new(
        access_key_id: "AKIAEXAMPLE", secret_access_key: "secret",
        region: "us-east-1", endpoint: "#{base}/ses")
      Saci::Mailer.delivery_adapter = :ses
      ExtrasAttachmentMailer.text_only("a@b.c").deliver_now
    end
    authorization = sink.headers["Authorization"]?.not_nil!
    authorization.should start_with("AWS4-HMAC-SHA256 Credential=AKIAEXAMPLE/")
    authorization.should contain("SignedHeaders=content-type;host;x-amz-date")
    authorization.should contain("Signature=")
    sink.headers["X-Amz-Date"]?.should_not be_nil
  end

  it "raises DeliveryError with status and body on provider errors" do
    sink = ExtrasHttpSink.new(status_code: 500)
    expect_raises(Saci::Mailer::DeliveryError, /HTTP 500/) do
      sink.run do |base|
        Saci::Mailer.postmark_settings = Saci::Mailer::PostmarkSettings.new(api_key: "pm-key", endpoint: "#{base}/postmark")
        Saci::Mailer.delivery_adapter = :postmark
        ExtrasAttachmentMailer.text_only("a@b.c").deliver_now
      end
    end
  end

  it "reports missing credentials clearly" do
    settings = Saci::Mailer::SendgridSettings.new(api_key: "")
    expect_raises(Saci::Mailer::DeliveryError, /SENDGRID_API_KEY/) do
      settings.resolved_api_key
    end
  end
end

describe "DKIM signing (G79)" do
  it "adds a verifiable DKIM-Signature header" do
    key = extras_dkim_key
    dir = "/tmp/opencode/saci-dkim-#{Random.rand(1_000_000)}"
    Dir.mkdir_p(dir)
    begin
      priv_path = File.join(dir, "priv.pem")
      pub_path = File.join(dir, "pub.pem")
      File.write(priv_path, key)
      status = Process.run("openssl", args: ["rsa", "-in", priv_path, "-pubout", "-out", pub_path],
        output: Process::Redirect::Close, error: Process::Redirect::Close)
      status.success?.should be_true

      Saci::Mailer.dkim_settings = Saci::Mailer::DkimSettings.new("example.com", "sel", key)
      mime = ExtrasAttachmentMailer.text_only("a@b.c").to_mime
      lines = mime.split("\r\n")
      dkim_line = lines.find { |line| line.starts_with?("DKIM-Signature:") }.not_nil!
      dkim_line.should contain("v=1; a=rsa-sha256; c=relaxed/relaxed; d=example.com; s=sel;")
      dkim_line.should contain("h=from:to:subject:date:message-id:mime-version:content-type")
      dkim_line.should contain("bh=")

      value = dkim_line.sub("DKIM-Signature: ", "")
      signature_b64 = value[/b=([A-Za-z0-9+\/=]*)$/, 1]
      unsigned_value = value.sub(/b=[A-Za-z0-9+\/=]*$/, "b=")

      separator = mime.index("\r\n\r\n").not_nil!
      header_block = mime[0...separator]
      body = mime[(separator + 4)..]
      raw_headers = header_block.split("\r\n").reject { |line| line.starts_with?("DKIM-Signature:") }
      header_map = {} of String => String
      raw_headers.each do |line|
        colon = line.index(':')
        next unless colon
        header_map[line[0...colon].downcase] = line
      end

      signing_input = String.build do |io|
        %w(from to subject date message-id mime-version content-type).each do |name|
          io << Saci::Mailer::Dkim.canonical_header(header_map[name]) << "\r\n"
        end
        io << Saci::Mailer::Dkim.canonical_header("DKIM-Signature: #{unsigned_value}") << "\r\n"
      end

      input_path = File.join(dir, "signing-input.bin")
      sig_path = File.join(dir, "signature.bin")
      File.write(input_path, signing_input)
      File.write(sig_path, Base64.decode(signature_b64))
      verify = Process.run("openssl", args: ["dgst", "-sha256", "-verify", pub_path, "-signature", sig_path, input_path],
        output: Process::Redirect::Close, error: Process::Redirect::Close)
      verify.success?.should be_true
    ensure
      Saci::Mailer.dkim_settings = nil
      FileUtils.rm_rf(dir)
    end
  end

  it "leaves mails unsigned without settings" do
    Saci::Mailer.dkim_settings.should be_nil
    ExtrasAttachmentMailer.text_only("a@b.c").to_mime.should_not contain("DKIM-Signature")
  end
end

describe "mailer view helpers (G204)" do
  before_each do
    Saci::Mailer.default_host = nil
    Saci::Mailer.default_protocol = "https"
  end

  after_each do
    Saci::Mailer.default_host = nil
    Saci::Mailer.default_protocol = "https"
  end

  it "builds mailto links with escaped text and query options" do
    html = Saci::Mailer.mail_to("a@b.c", "Alice & Bob", subject: "Hi there")
    html.should contain(%(href="mailto:a@b.c?subject=Hi+there"))
    html.should contain("Alice &amp; Bob")
  end

  it "is available to mailer classes" do
    ExtrasAttachmentMailer.mail_to("a@b.c").should contain("mailto:a@b.c")
  end

  it "builds absolute mailer URLs from configured options" do
    Saci::Mailer.default_host = "example.com"
    Saci::Mailer.mailer_url("/users/1").should eq("https://example.com/users/1")
    Saci::Mailer.mailer_url("users/1", protocol: "http", host: "other.test").should eq("http://other.test/users/1")
    Saci::Mailer.default_host = nil
    expect_raises(ArgumentError, /requires a host/) { Saci::Mailer.mailer_url("/x") }
  end
end

describe "file-based mailer layouts (G222)" do
  it "wraps parts with registered layout files" do
    dir = "/tmp/opencode/saci-layout-#{Random.rand(1_000_000)}"
    Dir.mkdir_p(dir)
    text_path = File.join(dir, "extras-file-layout.text")
    html_path = File.join(dir, "extras-file-layout.html")
    File.write(text_path, "== File ==\n<%= content %>")
    File.write(html_path, %(<div class="file"><%= content %></div>))
    begin
      Saci::Mailer.register_layout_files("extras-file-layout", dir)
      mail = ExtrasFileLayoutMailer.note("a@b.c")
      mail.body_text.should eq("== File ==\nbody")
      mail.body_html.should eq(%(<div class="file"><p>body</p></div>))
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
