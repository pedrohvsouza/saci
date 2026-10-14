require "socket"
require "openssl"
require "base64"

module Saci
  module Mailer
    # Delivery failure with the server's reply attached.
    class SmtpError < Exception
      getter code : Int32

      def initialize(@code : Int32, message : String)
        super("SMTP #{@code}: #{message}")
      end
    end

    # Connection settings for the `:smtp` adapter. Configure once at boot:
    #
    # ```
    # Saci::Mailer.smtp_settings = Saci::Mailer::SmtpSettings.new(
    #   host: "smtp.ethereal.email", port: 587,
    #   username: "user", password: "secret", tls: :auto)
    # ```
    struct SmtpSettings
      property host : String = "localhost"
      property port : Int32 = 25
      property username : String? = nil
      property password : String? = nil
      property helo_domain : String = "localhost"
      # :auto — STARTTLS when advertised (required before AUTH unless :never);
      # :always — refuse to continue without STARTTLS; :never — plaintext only.
      property tls : Symbol = :auto

      def initialize(@host = "localhost", @port = 25, @username = nil,
                     @password = nil, @helo_domain = "localhost", @tls = :auto)
        unless [:auto, :always, :never].includes?(@tls)
          raise ArgumentError.new("tls must be :auto, :always or :never")
        end
      end
    end

    # Minimal SMTP conversation (EHLO → STARTTLS → AUTH LOGIN → MAIL →
    # RCPT* → DATA → QUIT) over stdlib sockets. No dependencies.
    class SMTP
      def self.deliver(mail : Mail, settings : SmtpSettings = Mailer.smtp_settings) : Nil
        new(settings).deliver(mail)
      end

      def initialize(@settings : SmtpSettings)
      end

      def deliver(mail : Mail) : Nil
        socket = TCPSocket.new(@settings.host, @settings.port, nil, 10.seconds)
        socket.read_timeout = 30.seconds
        io : IO = socket
        begin
          expect(io, 220)
          extensions = ehlo(io)
          if @settings.tls != :never && extensions.includes?("starttls")
            command(io, "STARTTLS", 220)
            context = OpenSSL::SSL::Context::Client.new
            tls = OpenSSL::SSL::Socket::Client.new(socket, context, true, @settings.host)
            io = tls
            extensions = ehlo(io)
          elsif @settings.tls == :always
            raise SmtpError.new(0, "server does not advertise STARTTLS (tls=:always)")
          end
          encrypted = io.is_a?(OpenSSL::SSL::Socket)
          if username = @settings.username
            unless encrypted || @settings.tls == :never
              raise SmtpError.new(0, "refusing plaintext AUTH (use tls=:auto/:always or tls=:never explicitly)")
            end
            raise SmtpError.new(0, "server does not advertise AUTH LOGIN") unless extensions.includes?("auth login")
            auth_login(io, username, @settings.password || "")
          end
          command(io, "MAIL FROM:<#{mail.from}>", 250)
          recipients = mail.to + mail.cc + mail.bcc
          raise SmtpError.new(0, "no recipients") if recipients.empty?
          recipients.each do |addr|
            code, _ = command(io, "RCPT TO:<#{addr}>", 250, 251)
          end
          command(io, "DATA", 354)
          send_data(io, mail.to_mime)
          command(io, ".", 250)
          begin
            command(io, "QUIT", 221)
          rescue SmtpError
            # QUIT failure after acceptance must not fail the delivery.
          end
        ensure
          io.close rescue nil
        end
      end

      private def ehlo(io : IO) : Set(String)
        _, lines = command(io, "EHLO #{@settings.helo_domain}", 250)
        extensions = Set(String).new
        lines.each do |line|
          parts = line.split
          extensions << parts[0].downcase if parts.size > 0
          if parts.size > 1 && parts[0].downcase == "auth"
            parts[1..].each { |mech| extensions << "auth #{mech.downcase}" }
          end
        end
        extensions
      end

      private def auth_login(io : IO, username : String, password : String) : Nil
        _, _ = command(io, "AUTH LOGIN", 334)
        _, _ = command(io, Base64.strict_encode(username), 334)
        command(io, Base64.strict_encode(password), 235)
      end

      private def send_data(io : IO, mime : String) : Nil
        mime.each_line do |line|
          content = line.ends_with?("\r\n") ? line : "#{line.chomp}\r\n"
          content = ".#{content}" if content.starts_with?(".")
          io << content
        end
        io.flush
      end

      # Sends a command, returns {code, reply lines}. Raises SmtpError
      # unless the reply code is expected.
      private def command(io : IO, text : String, *expected : Int32) : Tuple(Int32, Array(String))
        STDERR.puts "C: #{text}" if ENV["SMTP_DEBUG"]?
        io << text << "\r\n"
        io.flush
        code, lines = read_response(io)
        STDERR.puts "S: #{code} #{lines.first?}" if ENV["SMTP_DEBUG"]?
        unless expected.includes?(code)
          raise SmtpError.new(code, lines.join(" "))
        end
        {code, lines}
      end

      private def expect(io : IO, *expected : Int32) : Tuple(Int32, Array(String))
        code, lines = read_response(io)
        unless expected.includes?(code)
          raise SmtpError.new(code, lines.join(" "))
        end
        {code, lines}
      end

      # Reads a (possibly multiline) reply: lines of `250-...` continue,
      # `250 ...` ends.
      private def read_response(io : IO) : Tuple(Int32, Array(String))
        lines = [] of String
        code = 0
        loop do
          raw = io.gets(chomp: true) || raise SmtpError.new(0, "connection closed by server")
          line = raw.ends_with?("\r") ? raw[0...-1] : raw
          raise SmtpError.new(0, "malformed reply: #{line.inspect}") if line.size < 4
          code = line[0, 3].to_i? || raise SmtpError.new(0, "malformed reply: #{line.inspect}")
          lines << (line.size > 4 ? line[4..] : "")
          break if line[3]? == ' '
        end
        {code, lines}
      end
    end
  end
end
