require "spec"
require "file_utils"
require "../src/saci"

class MailersUserMailer < Saci::Mailer::Base
  default_from "noreply@example.com"

  def self.welcome(email : String) : Saci::Mailer::Mail
    mail(to: email, subject: "Welcome!") do |format|
      format.text { "Welcome, #{email}!" }
      format.html { "<h1>Welcome, #{email}!</h1>" }
    end
  end

  def self.ping(email : String) : Saci::Mailer::Mail
    mail(to: [email, "cc@example.com"], subject: "Ping", cc: "boss@example.com")
  end
end

describe Saci::Mailer do
  before_each do
    Saci::Mailer.delivery_adapter = :test
    Saci::Mailer.clear_deliveries!
  end

  after_each do
    Saci::Mailer.delivery_adapter = :file
  end

  it "builds multipart mails with defaults" do
    mail = MailersUserMailer.welcome("a@b.c")
    mail.to.should eq(["a@b.c"])
    mail.from.should eq("noreply@example.com")
    mail.subject.should eq("Welcome!")
    mail.body_text.should contain("Welcome, a@b.c!")
    mail.body_html.not_nil!.should contain("<h1>")
    mime = mail.to_mime
    mime.should contain("Content-Type: multipart/alternative")
    mime.should contain("Message-ID:")
  end

  it "supports array recipients and text-only mails" do
    mail = MailersUserMailer.ping("a@b.c")
    mail.to.should eq(["a@b.c", "cc@example.com"])
    mail.cc.should eq(["boss@example.com"])
    mail.body_html.should be_nil
    mail.to_mime.should contain("Content-Type: text/plain")
  end

  it "requires from and to addresses" do
    expect_raises(ArgumentError) do
      Saci::Mailer::Mail.new([] of String, "f@x.io", "s")
    end
  end

  it "delivers to the test mailbox" do
    MailersUserMailer.welcome("a@b.c").deliver_now
    Saci::Mailer.deliveries.size.should eq(1)
    Saci::Mailer.deliveries.first.subject.should eq("Welcome!")
  end

  it "deliver_later enqueues a delivery job" do
    Saci::Job.queue_adapter = :test
    Saci::Job.clear_enqueued!
    begin
      MailersUserMailer.welcome("a@b.c").deliver_later
      jobs = Saci::Job.enqueued_jobs
      jobs.size.should eq(1)
      jobs.first[:job].should contain("DeliveryJob")
    ensure
      Saci::Job.queue_adapter = :async
    end
  end

  it "executes delivery jobs end to end" do
    Saci::Job.with_adapter(:inline) do
      MailersUserMailer.welcome("a@b.c").deliver_later
    end
    Saci::Mailer.deliveries.size.should eq(1)
  end

  it "writes .eml files with the file adapter" do
    dir = "/tmp/opencode/saci-mails-#{Random.rand(1_000_000)}"
    begin
      Saci::Mailer.file_path = dir
      Saci::Mailer.delivery_adapter = :file
      MailersUserMailer.ping("a@b.c").deliver_now
      files = Dir.glob("#{dir}/*.eml")
      files.size.should eq(1)
      File.read(files.first).should contain("To: a@b.c, cc@example.com")
    ensure
      Saci::Mailer.file_path = "tmp/mails"
      FileUtils.rm_rf(dir)
    end
  end

  it "rejects unknown adapters" do
    expect_raises(ArgumentError) { Saci::Mailer.delivery_adapter = :pigeon }
  end

  it "accepts the smtp adapter with settings" do
    Saci::Mailer.delivery_adapter = :smtp
    begin
      Saci::Mailer.delivery_adapter.should eq(:smtp)
      Saci::Mailer.smtp_settings = Saci::Mailer::SmtpSettings.new(host: "smtp.example.com", port: 587)
      Saci::Mailer.smtp_settings.host.should eq("smtp.example.com")
      Saci::Mailer.smtp_settings.port.should eq(587)
    ensure
      Saci::Mailer.delivery_adapter = :test
    end
  end
end
