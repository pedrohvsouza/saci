module Saci
  # ActionMailer-style mailers (file/test/sendmail/SMTP delivery).
  #
  # ```
  # class UserMailer < Saci::Mailer::Base
  #   default_from "noreply@example.com"
  #
  #   def welcome(email : String) : Saci::Mailer::Mail
  #     mail(to: email, subject: "Welcome!") do |format|
  #       format.text { "Welcome, #{email}!" }
  #       format.html { "<h1>Welcome, #{email}!</h1>" }
  #     end
  #   end
  # end
  #
  # UserMailer.welcome("a@b.c").deliver_now
  # UserMailer.welcome("a@b.c").deliver_later # via Saci::Job
  # UserMailer.welcome("a@b.c").deliver_later(wait: 5.minutes)
  # ```
  #
  # Configure SMTP once at boot (`:smtp` adapter):
  #
  # ```
  # Saci::Mailer.delivery_adapter = :smtp
  # Saci::Mailer.smtp_settings = Saci::Mailer::SmtpSettings.new(
  #   host: "smtp.example.com", port: 587,
  #   username: "user", password: "secret", tls: :auto)
  # ```
  module Mailer
    @@delivery_adapter : Symbol = :file
    @@adapter_mutex = Mutex.new
    @@file_path : String = "tmp/mails"
    @@sendmail_path : String = "/usr/sbin/sendmail"
    @@smtp_settings = SmtpSettings.new
    @@deliveries = [] of Mail
    @@deliveries_mutex = Mutex.new

    def self.delivery_adapter : Symbol
      @@adapter_mutex.synchronize { @@delivery_adapter }
    end

    def self.delivery_adapter=(name : Symbol) : Nil
      unless [:test, :file, :sendmail, :smtp].includes?(name)
        raise ArgumentError.new("Unknown delivery adapter #{name.inspect} (expected :test, :file, :sendmail or :smtp)")
      end
      @@adapter_mutex.synchronize { @@delivery_adapter = name }
    end

    def self.file_path : String
      @@adapter_mutex.synchronize { @@file_path }
    end

    def self.file_path=(path : String) : Nil
      @@adapter_mutex.synchronize { @@file_path = path }
    end

    def self.sendmail_path : String
      @@adapter_mutex.synchronize { @@sendmail_path }
    end

    def self.sendmail_path=(path : String) : Nil
      @@adapter_mutex.synchronize { @@sendmail_path = path }
    end

    def self.smtp_settings : SmtpSettings
      @@adapter_mutex.synchronize { @@smtp_settings }
    end

    def self.smtp_settings=(settings : SmtpSettings) : Nil
      @@adapter_mutex.synchronize { @@smtp_settings = settings }
    end

    # Delivered mails while the `:test` adapter is active.
    def self.deliveries : Array(Mail)
      @@deliveries_mutex.synchronize { @@deliveries.dup }
    end

    def self.clear_deliveries! : Nil
      @@deliveries_mutex.synchronize { @@deliveries.clear }
    end

    def self.record_delivery(mail : Mail) : Nil
      @@deliveries_mutex.synchronize { @@deliveries << mail }
    end

    # A built email. Serializes to plain strings, so `deliver_later` works
    # through any job adapter (rendering happens now, delivery later).
    class Mail
      getter to : Array(String)
      getter from : String
      getter subject : String
      getter cc : Array(String)
      getter bcc : Array(String)
      getter body_text : String
      getter body_html : String?

      def initialize(@to : Array(String), @from : String, @subject : String, @body_text : String = "", @body_html : String? = nil, cc : Array(String) = [] of String, bcc : Array(String) = [] of String)
        @cc = cc
        @bcc = bcc
        raise ArgumentError.new("from address is required") if @from.strip.empty?
        raise ArgumentError.new("to address is required") if @to.empty?
      end

      def deliver_now : Nil
        case Mailer.delivery_adapter
        when :test
          Mailer.record_delivery(self)
        when :file
          dir = Mailer.file_path
          Dir.mkdir_p(dir)
          bytes = Bytes.new(8)
          Random::Secure.random_bytes(bytes)
          File.write(File.join(dir, "#{Time.utc.to_unix_ms}-#{bytes.hexstring}.eml"), to_mime)
        when :sendmail
          input = IO::Memory.new(to_mime)
          status = Process.run(Mailer.sendmail_path, args: ["-t", "-oi", "-f", from], input: input, output: Process::Redirect::Close, error: Process::Redirect::Close)
          raise "sendmail failed with status #{status.exit_code}" unless status.success?
        when :smtp
          SMTP.deliver(self)
        end
      end

      def deliver_later(wait : Time::Span? = nil) : Nil
        Mailer::DeliveryJob.set(wait: wait).perform_later(to_h)
      end

      def to_h : Hash(String, JSON::Any)
        {
          "to"        => JSON::Any.new(@to.map { |a| JSON::Any.new(a) }),
          "from"      => JSON::Any.new(@from),
          "subject"   => JSON::Any.new(@subject),
          "cc"        => JSON::Any.new(@cc.map { |a| JSON::Any.new(a) }),
          "bcc"       => JSON::Any.new(@bcc.map { |a| JSON::Any.new(a) }),
          "body_text" => JSON::Any.new(@body_text),
          "body_html" => JSON::Any.new(@body_html),
        }
      end

      def self.from_payload(payload : JSON::Any) : Mail
        str = ->(key : String) { payload[key]?.try(&.as_s?) || "" }
        list = ->(key : String) {
          case v = payload[key]?
          when Nil then [] of String
          else          v.as_a?.try(&.map(&.as_s)) || [v.to_s]
          end
        }
        new(
          list.call("to"), str.call("from"), str.call("subject"),
          str.call("body_text"), payload["body_html"]?.try(&.as_s?),
          cc: list.call("cc"), bcc: list.call("bcc")
        )
      end

      def to_mime : String
        boundary = "saci-#{Random::Secure.hex(16)}"
        String.build do |io|
          io << "From: " << from << "\r\n"
          io << "To: " << to.join(", ") << "\r\n"
          io << "Cc: " << cc.join(", ") << "\r\n" unless cc.empty?
          io << "Subject: " << subject << "\r\n"
          io << "Date: " << Time.utc.to_s("%a, %d %b %Y %H:%M:%S +0000") << "\r\n"
          io << "Message-ID: <" << Random::Secure.hex(16) << "@saci>\r\n"
          io << "MIME-Version: 1.0\r\n"
          if html = body_html
            io << "Content-Type: multipart/alternative; boundary=\"" << boundary << "\"\r\n\r\n"
            io << "--" << boundary << "\r\n"
            io << "Content-Type: text/plain; charset=UTF-8\r\n\r\n"
            io << body_text << "\r\n"
            io << "--" << boundary << "\r\n"
            io << "Content-Type: text/html; charset=UTF-8\r\n\r\n"
            io << html << "\r\n"
            io << "--" << boundary << "--\r\n"
          else
            io << "Content-Type: text/plain; charset=UTF-8\r\n\r\n"
            io << body_text << "\r\n"
          end
        end
      end
    end

    # Renders the mail later through the job system (payload is the fully
    # rendered email, so any adapter — present or future — can send it).
    class DeliveryJob < Job::Base
      queue_as :mailers

      def perform(payload : JSON::Any) : Nil
        Mail.from_payload(payload).deliver_now
      end
    end

    class FormatCollector
      @text : String = ""
      @html : String? = nil

      def text(& : -> String) : Nil
        @text = yield
      end

      def html(& : -> String) : Nil
        @html = yield
      end

      def text_body : String
        @text
      end

      def html_body : String?
        @html
      end
    end

    class Base
      macro default_from(address)
        def self.default_from_address : String
          {{address}}
        end
      end

      def self.default_from_address : String
        ""
      end

      def self.mail(to : String | Array(String), subject : String, from : String? = nil, cc : String | Array(String) | Nil = nil, bcc : String | Array(String) | Nil = nil, &block : FormatCollector -> Nil) : Mail
        formats = FormatCollector.new
        block.call(formats)
        build_mail(to, subject, from, cc, bcc, formats.text_body, formats.html_body)
      end

      def self.mail(to : String | Array(String), subject : String, from : String? = nil, cc : String | Array(String) | Nil = nil, bcc : String | Array(String) | Nil = nil) : Mail
        build_mail(to, subject, from, cc, bcc, "", nil)
      end

      private def self.build_mail(to, subject, from, cc, bcc, text, html) : Mail
        Mail.new(as_list(to), from || default_from_address, subject, text, html, cc: as_list(cc), bcc: as_list(bcc))
      end

      private def self.as_list(value : String | Array(String) | Nil) : Array(String)
        case value
        when Nil   then [] of String
        when Array then value
        else            [value]
        end
      end
    end
  end
end
