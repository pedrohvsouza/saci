require "spec"
require "file_utils"
require "../src/saci"

class PreviewSpecMailer < Saci::Mailer::Base
  default_from "noreply@example.com"

  def self.welcome(email : String) : Saci::Mailer::Mail
    mail(to: email, subject: "Welcome!") do |format|
      format.text { "Hi #{email}" }
      format.html { "<h1>Hi #{email}</h1>" }
    end
  end
end

def preview_spec_router : Saci::Router
  Saci::Router.new.draw do |r|
    r.get "/saci/mailers", Saci::Mailer::PreviewController, :index
    r.get "/saci/mailers/:name", Saci::Mailer::PreviewController, :show
  end
end

describe Saci::Mailer::Preview do
  before_each do
    Saci::Mailer::Preview.reset!
    Saci::Mailer::Preview.enabled = true
  end

  after_each do
    Saci::Mailer::Preview.reset!
  end

  it "lists registered previews" do
    Saci::Mailer::Preview.register("welcome") { PreviewSpecMailer.welcome("demo@example.com") }
    Saci::Mailer::Preview.names.should eq(["welcome"])
    Saci::TestSession.serve(preview_spec_router) do |app|
      resp = app.get("/saci/mailers")
      resp.status_code.should eq(200)
      resp.body.should contain("welcome")
      resp.body.should contain("/saci/mailers/welcome")
    end
  end

  it "shows a preview with headers and both parts" do
    Saci::Mailer::Preview.register("welcome") { PreviewSpecMailer.welcome("demo@example.com") }
    Saci::TestSession.serve(preview_spec_router) do |app|
      resp = app.get("/saci/mailers/welcome")
      resp.status_code.should eq(200)
      resp.headers["Content-Type"].should contain("text/html")
      resp.body.should contain("demo@example.com")
      resp.body.should contain("Welcome!")
      resp.body.should contain("Hi demo@example.com")
      resp.body.should contain("<h1>Hi demo@example.com</h1>")
    end
  end

  it "404s unknown previews" do
    Saci::TestSession.serve(preview_spec_router) do |app|
      app.get("/saci/mailers/nope").status_code.should eq(404)
    end
  end

  it "404s the list and previews when disabled" do
    Saci::Mailer::Preview.register("welcome") { PreviewSpecMailer.welcome("demo@example.com") }
    Saci::Mailer::Preview.enabled = false
    Saci::TestSession.serve(preview_spec_router) do |app|
      app.get("/saci/mailers").status_code.should eq(404)
      app.get("/saci/mailers/welcome").status_code.should eq(404)
    end
  end

  it "is disabled by default in production" do
    old = ENV["APP_ENV"]?
    begin
      ENV["APP_ENV"] = "production"
      Saci::Mailer::Preview.reset!
      Saci::Mailer::Preview.enabled.should be_false
    ensure
      if old.nil?
        ENV.delete("APP_ENV")
      else
        ENV["APP_ENV"] = old
      end
      Saci::Mailer::Preview.reset!
    end
  end
end

describe "mailer subject encoding" do
  it "keeps in-memory subjects readable and round-trips encoded-words" do
    subject = "Héllo wörld 🎉"
    mail = Saci::Mailer::Mail.new(["a@b.c"], "f@x.io", subject)
    mail.subject.should eq(subject)
    mail.decoded_subject.should eq(subject)
    encoded = mail.encoded_subject
    encoded.should contain("=?UTF-8?B?")
    Saci::Mailer.decode_subject(encoded).should eq(subject)
    mail.to_mime.should contain("=?UTF-8?B?")
  end

  it "leaves ASCII subjects unfolded when short, readable in memory" do
    mail = Saci::Mailer::Mail.new(["a@b.c"], "f@x.io", "Welcome!")
    mail.encoded_subject.should eq("Welcome!")
    mail.to_mime.should contain("Subject: Welcome!\r\n")
  end

  it "folds long ASCII subjects at 75 chars and decodes back" do
    subject = (["word"] * 40).join(" ")
    subject.size.should be > 75
    mail = Saci::Mailer::Mail.new(["a@b.c"], "f@x.io", subject)
    lines = mail.to_mime.split("\r\n")
    idx = lines.index { |l| l.starts_with?("Subject:") }.not_nil!
    header_lines = [lines[idx]]
    j = idx + 1
    while j < lines.size && (lines[j].starts_with?(" ") || lines[j].starts_with?("\t"))
      header_lines << lines[j]
      j += 1
    end
    (header_lines.size > 1).should be_true
    header_lines.each { |l| (l.size <= 75).should be_true }
    Saci::Mailer.decode_subject(header_lines.join("\r\n").sub(/^Subject: /, "")).should eq(subject)
  end

  it "round-trips a 200-char UTF-8 subject with emoji within 75-char lines" do
    subject = (["héllo 🎉"] * 34).join(" ")
    (subject.size >= 200).should be_true
    encoded = Saci::Mailer.encode_subject(subject)
    Saci::Mailer.decode_subject(encoded).should eq(subject)
    first, *rest = encoded.split("\r\n")
    (("Subject: ".size + first.size) <= 75).should be_true
    rest.each { |l| (l.size <= 75).should be_true }
  end

  it "writes RFC 2047 subjects to .eml files via the file adapter" do
    dir = "/tmp/opencode/saci-mails-preview-#{Random.rand(1_000_000)}"
    old_adapter = Saci::Mailer.delivery_adapter
    old_path = Saci::Mailer.file_path
    begin
      Saci::Mailer.file_path = dir
      Saci::Mailer.delivery_adapter = :file
      Saci::Mailer::Mail.new(["a@b.c"], "f@x.io", "Grüße 🎉").deliver_now
      files = Dir.glob("#{dir}/*.eml")
      files.size.should eq(1)
      File.read(files.first).should contain("=?UTF-8?B?")
    ensure
      Saci::Mailer.delivery_adapter = old_adapter
      Saci::Mailer.file_path = old_path
      FileUtils.rm_rf(dir)
    end
  end
end
