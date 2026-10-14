require "spec"
require "socket"
require "../src/saci"

# Scripted in-process SMTP sink: serves one scripted conversation on a fiber
# while the block delivers, then joins. Captures AUTH/MAIL/RCPT/DATA.
# Plaintext only (`tls: :never`) — the STARTTLS upgrade path is verified
# live against Ethereal instead (no test certs here).
class FakeSmtp
  getter data : String = ""
  getter mail_from : String = ""
  getter rcpt_to : Array(String) = [] of String
  getter authed_user : String = ""
  getter commands : Array(String) = [] of String

  def initialize(@extensions : Array(String) = ["STARTTLS", "AUTH LOGIN"], @rcpt_code : Int32 = 250)
    @server = TCPServer.new("127.0.0.1", 0)
  end

  def port : Int32
    @server.local_address.port
  end

  def run_once(& : ->) : Nil
    done = ::Channel(Nil).new
    spawn do
      begin
        serve(@server.accept)
      ensure
        @server.close rescue nil
        done.send(nil)
      end
    end
    yield
    done.receive
  end

  private def serve(client : TCPSocket) : Nil
    send_line(client, "220 fake-smtp ESMTP ready")
    in_data = false
    buf = IO::Memory.new
    loop do
      raw = client.gets(chomp: true) || break
      line = raw.ends_with?("\r") ? raw[0...-1] : raw
      if in_data
        if line == "."
          @data = buf.to_s
          buf.clear
          in_data = false
          send_line(client, "250 queued")
        else
          buf << line << "\r\n"
        end
        next
      end
      @commands << line.split(" ", 2)[0].upcase
      upper = line.upcase
      if upper.starts_with?("EHLO") || upper.starts_with?("HELO")
        client << "250-fake-smtp greets you\r\n"
        @extensions.each_with_index do |ext, i|
          client << "250#{i == @extensions.size - 1 ? " " : "-"}#{ext}\r\n"
        end
      elsif upper == "AUTH LOGIN"
        send_line(client, "334 VXNlcm5hbWU6")
        user_line = (client.gets(chomp: true) || "").strip
        begin
          @authed_user = String.new(Base64.decode(user_line))
        rescue
          @authed_user = ""
        end
        send_line(client, "334 UGFzc3dvcmQ6")
        client.gets
        send_line(client, "235 authenticated")
      elsif upper.starts_with?("MAIL FROM:")
        @mail_from = line[10..].strip
        send_line(client, "250 ok")
      elsif upper.starts_with?("RCPT TO:")
        @rcpt_to << line[8..].strip
        send_line(client, "#{@rcpt_code} #{@rcpt_code == 250 ? "ok" : "mailbox unavailable"}")
      elsif upper == "DATA"
        send_line(client, "354 end with a dot")
        in_data = true
      elsif upper == "QUIT"
        send_line(client, "221 bye")
        break
      elsif upper == "RSET"
        send_line(client, "250 ok")
      else
        # Includes STARTTLS (unimplemented on purpose: the client must
        # never silently fall back to plaintext AUTH).
        send_line(client, "502 unimplemented")
      end
    end
  ensure
    client.close rescue nil
  end

  private def send_line(client : TCPSocket, text : String) : Nil
    client << text << "\r\n"
  end
end

def smtp_mail : Saci::Mailer::Mail
  Saci::Mailer::Mail.new(["to@example.com"], "from@example.com", "Hi!", "hello")
end

describe Saci::Mailer::SMTP do
  it "delivers through EHLO/AUTH/MAIL/RCPT/DATA/QUIT" do
    server = FakeSmtp.new
    settings = Saci::Mailer::SmtpSettings.new(
      host: "127.0.0.1", port: server.port,
      username: "user", password: "secret", tls: :never)
    server.run_once do
      Saci::Mailer::SMTP.deliver(smtp_mail, settings)
    end
    server.mail_from.should eq("<from@example.com>")
    server.rcpt_to.should eq(["<to@example.com>"])
    server.authed_user.should eq("user")
    server.data.should contain("Subject: Hi!")
    server.data.should contain("hello")
    server.commands.should contain("EHLO")
    server.commands.should contain("DATA")
    server.commands.should contain("QUIT")
  end

  it "dot-stuffs body lines starting with a dot" do
    server = FakeSmtp.new
    settings = Saci::Mailer::SmtpSettings.new(
      host: "127.0.0.1", port: server.port, tls: :never)
    mail = Saci::Mailer::Mail.new(["t@e.c"], "f@e.c", "dots", ".hidden\nnormal")
    server.run_once do
      Saci::Mailer::SMTP.deliver(mail, settings)
    end
    server.data.should contain("\r\n..hidden\r\n")
  end

  it "raises SmtpError on recipient rejection" do
    server = FakeSmtp.new(rcpt_code: 550)
    settings = Saci::Mailer::SmtpSettings.new(
      host: "127.0.0.1", port: server.port, tls: :never)
    expect_raises(Saci::Mailer::SmtpError, /550/) do
      server.run_once do
        Saci::Mailer::SMTP.deliver(smtp_mail, settings)
      end
    end
  end

  it "never falls back to plaintext AUTH" do
    server = FakeSmtp.new
    settings = Saci::Mailer::SmtpSettings.new(
      host: "127.0.0.1", port: server.port,
      username: "user", password: "secret", tls: :auto)
    # STARTTLS advertised but unimplementable here → 502 → SmtpError,
    # and no credentials cross the wire.
    expect_raises(Saci::Mailer::SmtpError, /502/) do
      server.run_once do
        Saci::Mailer::SMTP.deliver(smtp_mail, settings)
      end
    end
    server.authed_user.should eq("")
  end

  it "rejects bad settings early" do
    expect_raises(ArgumentError, /tls/) do
      Saci::Mailer::SmtpSettings.new(tls: :sometimes)
    end
    expect_raises(ArgumentError, /Unknown delivery adapter/) do
      Saci::Mailer.delivery_adapter = :pigeon
    end
  end
end
