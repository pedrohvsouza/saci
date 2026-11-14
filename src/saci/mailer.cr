require "base64"
require "digest/sha256"
require "json"
require "openssl"
require "uri"

require "./mailer/attachments"
require "./mailer/context"
require "./mailer/callbacks"
require "./mailer/parameterized"
require "./mailer/dkim"
require "./mailer/providers"
require "./mailer/view_helpers"

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
  # UserMailer.welcome("a@b.c").deliver_later(wait_until: at, queue: "mailers")
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
  #
  # HTTP providers use `delivery_method =` (or the older
  # `delivery_adapter =`) plus env credentials:
  #
  # ```
  # Saci::Mailer.delivery_method = :sendgrid # SENDGRID_API_KEY
  # Saci::Mailer.delivery_method = :mailgun  # MAILGUN_API_KEY + MAILGUN_DOMAIN
  # Saci::Mailer.delivery_method = :postmark # POSTMARK_API_KEY
  # Saci::Mailer.delivery_method = :ses      # AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY
  # ```
  #
  # Attachments can be added before calling `mail`:
  #
  # ```
  # attachments["report.pdf"] = {mime_type: "application/pdf", path: path}
  # attachments.inline["logo.png"] = {mime_type: "image/png", content: png}
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
      unless [:test, :file, :sendmail, :smtp, :sendgrid, :mailgun, :postmark, :ses].includes?(name)
        raise ArgumentError.new("Unknown delivery adapter #{name.inspect} (expected :test, :file, :sendmail, :smtp, :sendgrid, :mailgun, :postmark or :ses)")
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

    # Named mailer layouts (`layout "mailer"` in a mailer class wraps the
    # text/html parts with the registered templates' `<%= content %>`).
    #
    # ```
    # Saci::Mailer.register_layout("mailer",
    #   text: "== MyApp ==\n<%= content %>",
    #   html: "<div class=\"mail\"><%= content %></div>")
    # ```
    alias LayoutEntry = NamedTuple(text: String?, html: String?)

    @@layouts = {} of String => LayoutEntry
    @@layouts_mutex = Mutex.new

    def self.register_layout(name : String, text : String? = nil, html : String? = nil) : Nil
      @@layouts_mutex.synchronize { @@layouts[name] = {text: text, html: html} }
    end

    def self.find_layout(name : String) : LayoutEntry?
      @@layouts_mutex.synchronize { @@layouts[name]? }
    end

    def self.clear_layouts! : Nil
      @@layouts_mutex.synchronize { @@layouts.clear }
    end

    # File-based layout registration for apps that keep mailer layouts on
    # disk. Files are read once (at registration); pass a placeholder
    # `<%= content %>` to position the body (otherwise the body is appended).
    #
    # ```
    # Saci::Mailer.register_layout_file("mailer",
    #   text_path: "app/views/layouts/mailer.text",
    #   html_path: "app/views/layouts/mailer.html")
    # ```
    def self.register_layout_file(name : String, *, text_path : String? = nil, html_path : String? = nil) : Nil
      text = text_path ? File.read(text_path) : nil
      html = html_path ? File.read(html_path) : nil
      register_layout(name, text: text, html: html)
    end

    # Loads `<directory>/<name>.text` and `<directory>/<name>.html` if they
    # exist. Used by `layout_file` in mailer classes.
    def self.register_layout_files(name : String, directory : String) : Nil
      text_path = File.join(directory, "#{name}.text")
      html_path = File.join(directory, "#{name}.html")
      register_layout_file(
        name,
        text_path: File.exists?(text_path) ? text_path : nil,
        html_path: File.exists?(html_path) ? html_path : nil
      )
    end

    # RFC 2047 encoded-word subject handling. In-memory `Mail#subject`
    # stays readable Unicode; the wire form (`to_mime`, hence the
    # `:file`/`:sendmail`/`:smtp` adapters) uses `encode_subject`:
    # pure-ASCII subjects are folded at 75 chars, anything else becomes
    # `=?UTF-8?B?...?=` words folded at 75 chars. `decode_subject`
    # reverses the encoding (B and Q words).
    def self.encode_subject(subject : String) : String
      clean = subject.gsub(/\r\n|\r|\n/, " ")
      return fold_ascii_subject(clean) if clean.each_char.all?(&.ascii?)
      words = [] of String
      current = IO::Memory.new
      current_bytes = 0
      clean.each_char do |ch|
        size = ch.bytesize
        if current_bytes + size > 30 && current_bytes > 0
          words << "=?UTF-8?B?#{Base64.strict_encode(current.to_s)}?="
          current = IO::Memory.new
          current_bytes = 0
        end
        current << ch
        current_bytes += size
      end
      words << "=?UTF-8?B?#{Base64.strict_encode(current.to_s)}?=" unless current.empty?
      words.join("\r\n ")
    end

    # Decodes RFC 2047 encoded-words; anything unrecognized passes
    # through untouched (never raises).
    def self.decode_subject(value : String) : String
      unfolded = value.gsub(/\?=\r\n[ \t]+=\?/, "?==?")
      unfolded = unfolded.gsub(/\r\n[ \t]+/, " ")
      String.build do |io|
        i = 0
        size = unfolded.size
        while i < size
          start = unfolded.index("=?", i)
          if start.nil?
            io << unfolded[i..-1]
            break
          end
          io << unfolded[i...start] if start > i
          finish = unfolded.index("?=", start + 2)
          if finish.nil?
            io << unfolded[start..-1]
            break
          end
          io << decode_subject_word(unfolded[start..(finish + 1)])
          i = finish + 2
        end
      end
    end

    private def self.decode_subject_word(word : String) : String
      parts = word[2...-2].split("?")
      return word unless parts.size == 3
      case parts[1].upcase
      when "B"
        String.new(Base64.decode(parts[2]))
      when "Q"
        decode_subject_q(parts[2])
      else
        word
      end
    rescue
      word
    end

    private def self.decode_subject_q(payload : String) : String
      io = IO::Memory.new
      bytes = payload.to_slice
      i = 0
      while i < bytes.size
        b = bytes[i]
        if b == '_'.ord
          io.write_byte(' '.ord.to_u8)
          i += 1
        elsif b == '='.ord && i + 2 < bytes.size
          io.write_byte(String.new(bytes[i + 1, 2]).to_u8(16))
          i += 3
        else
          io.write_byte(b)
          i += 1
        end
      end
      String.new(io.to_slice)
    end

    # Folds a pure-ASCII header value so every emitted line (including
    # the `Subject: ` prefix on the first) stays within 75 chars.
    private def self.fold_ascii_subject(clean : String) : String
      return clean if "Subject: ".size + clean.size <= 75
      lines = [] of String
      current = IO::Memory.new
      budget = 75 - "Subject: ".size
      clean.split(" ", remove_empty: true).each do |word|
        pieces = [] of String
        rest = word
        while rest.size > 74
          pieces << rest[0, 74]
          rest = rest[74..-1]
        end
        pieces << rest
        pieces.each do |piece|
          if current.empty?
            current << piece
          elsif current.to_s.size + 1 + piece.size <= budget
            current << " " << piece
          else
            lines << current.to_s
            current = IO::Memory.new
            current << piece
            budget = 74
          end
        end
      end
      lines << current.to_s unless current.empty?
      lines = [""] if lines.empty?
      lines.join("\r\n ")
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
      getter reply_to : String?
      getter headers : Hash(String, String)
      getter attachments : Attachments
      getter mailer : String?
      getter action : String?
      getter params : Hash(String, JSON::Any)

      def initialize(@to : Array(String), @from : String, @subject : String, @body_text : String = "", @body_html : String? = nil, cc : Array(String) = [] of String, bcc : Array(String) = [] of String, reply_to : String? = nil, headers : Hash(String, String) = {} of String => String, attachments : Array(Attachment) = [] of Attachment, @mailer : String? = nil, @action : String? = nil, params : Hash(String, JSON::Any) = {} of String => JSON::Any)
        @cc = cc
        @bcc = bcc
        @reply_to = reply_to
        @headers = headers.dup
        @attachments = Attachments.new(attachments.dup)
        @params = params.dup
        raise ArgumentError.new("from address is required") if @from.strip.empty?
        raise ArgumentError.new("to address is required") if @to.empty?
        Mailer.validate_attachments!(@attachments.to_a)
      end

      def inline_attachments : Array(Attachment)
        @attachments.select(&.inline?)
      end

      def attachment(name : String) : Attachment?
        @attachments[name]?
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
        when :sendgrid
          SendgridDelivery.new(Mailer.sendgrid_settings).deliver(self)
        when :mailgun
          MailgunDelivery.new(Mailer.mailgun_settings).deliver(self)
        when :postmark
          PostmarkDelivery.new(Mailer.postmark_settings).deliver(self)
        when :ses
          SesDelivery.new(Mailer.ses_settings).deliver(self)
        end
      end

      # Render now, deliver later. `wait:`/`wait_until:` are forwarded to
      # `Job.set`; `queue:` is persisted in the payload and used directly by
      # the durable (`:db` and `:redis`) adapters.
      def deliver_later(wait : Time::Span? = nil, wait_until : Time? = nil, queue : String? = nil) : Nil
        delay = wait
        if target = wait_until
          remaining = target - Time.utc
          delay = remaining > Time::Span.zero ? remaining : Time::Span.zero
        end
        payload = to_h
        payload["_queue"] = JSON::Any.new(queue) if queue
        if queue && Job.queue_adapter == :db
          run_at = Time.utc + (delay || Time::Span.zero)
          Job::Db.enqueue("Saci::Mailer::DeliveryJob", queue, payload.to_json, run_at)
        elsif queue && Job.queue_adapter == :redis
          run_at = Time.utc + (delay || Time::Span.zero)
          Job::Redis.enqueue("Saci::Mailer::DeliveryJob", queue, payload.to_json, run_at)
        else
          DeliveryJob.set(wait: delay).perform_later(payload)
        end
      end

      # Wire-ready (RFC 2047, folded at 75 chars) Subject header value.
      def encoded_subject : String
        Mailer.encode_subject(@subject)
      end

      # Decodes RFC 2047 encoded-words in `#subject` (round-trips
      # `#encoded_subject`; equals `#subject` for readable in-memory mail).
      def decoded_subject : String
        Mailer.decode_subject(@subject)
      end

      def to_h : Hash(String, JSON::Any)
        hdrs = {} of String => JSON::Any
        @headers.each { |k, v| hdrs[k] = JSON::Any.new(v) }
        params_json = {} of String => JSON::Any
        @params.each { |k, v| params_json[k] = v }
        attachment_json = @attachments.map { |attachment| JSON::Any.new(attachment.to_h) }
        {
          "to"          => JSON::Any.new(@to.map { |a| JSON::Any.new(a) }),
          "from"        => JSON::Any.new(@from),
          "subject"     => JSON::Any.new(@subject),
          "cc"          => JSON::Any.new(@cc.map { |a| JSON::Any.new(a) }),
          "bcc"         => JSON::Any.new(@bcc.map { |a| JSON::Any.new(a) }),
          "body_text"   => JSON::Any.new(@body_text),
          "body_html"   => JSON::Any.new(@body_html),
          "reply_to"    => JSON::Any.new(@reply_to),
          "headers"     => JSON::Any.new(hdrs),
          "attachments" => JSON::Any.new(attachment_json),
          "_mailer"     => JSON::Any.new(@mailer),
          "_action"     => JSON::Any.new(@action),
          "_params"     => JSON::Any.new(params_json),
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
        hdrs = {} of String => String
        if h = payload["headers"]?
          h.as_h?.try(&.each { |k, v| hdrs[k] = v.as_s? || v.to_s })
        end
        attachments = [] of Attachment
        if list_json = payload["attachments"]?
          list_json.as_a?.try(&.each { |value| attachments << Attachment.from_json_any(value) })
        end
        params = {} of String => JSON::Any
        if p = payload["_params"]?
          p.as_h?.try(&.each { |k, v| params[k] = v })
        end
        mailer = payload["_mailer"]?.try(&.as_s?)
        action = payload["_action"]?.try(&.as_s?)
        new(
          list.call("to"), str.call("from"), str.call("subject"),
          str.call("body_text"), payload["body_html"]?.try(&.as_s?),
          cc: list.call("cc"), bcc: list.call("bcc"),
          reply_to: payload["reply_to"]?.try(&.as_s?),
          headers: hdrs, attachments: attachments,
          mailer: mailer, action: action, params: params
        )
      end

      # Strips CR/LF so custom headers can never inject extra MIME lines.
      private def sanitize_header(value : String) : String
        value.gsub(/\r\n|\r|\n/, " ")
      end

      def to_mime : String
        mime = build_mime
        if settings = Mailer.dkim_settings
          Dkim.sign(mime, settings)
        else
          mime
        end
      end

      private def build_mime : String
        String.build do |io|
          io << "From: " << sanitize_header(from) << "\r\n"
          io << "To: " << sanitize_header(to.join(", ")) << "\r\n"
          io << "Cc: " << sanitize_header(cc.join(", ")) << "\r\n" unless cc.empty?
          if rt = reply_to
            io << "Reply-To: " << sanitize_header(rt) << "\r\n"
          end
          io << "Subject: " << Mailer.encode_subject(subject) << "\r\n"
          io << "Date: " << Time.utc.to_s("%a, %d %b %Y %H:%M:%S +0000") << "\r\n"
          msg_id_key = @headers.keys.find { |k| k.downcase == "message-id" }
          if msg_id_key
            io << "Message-ID: " << sanitize_header(@headers[msg_id_key]) << "\r\n"
          else
            io << "Message-ID: <" << Random::Secure.hex(16) << "@saci>\r\n"
          end
          @headers.each do |k, v|
            next if k.downcase == "message-id"
            io << sanitize_header(k) << ": " << sanitize_header(v) << "\r\n"
          end
          io << "MIME-Version: 1.0\r\n"

          if @attachments.empty?
            if html = body_html
              boundary = "saci-#{Random::Secure.hex(16)}"
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
          else
            boundary = "saci-mixed-#{Random::Secure.hex(16)}"
            io << "Content-Type: multipart/mixed; boundary=\"" << boundary << "\"\r\n\r\n"
            write_body_part(io, boundary)
            @attachments.each { |attachment| write_mime_attachment(io, boundary, attachment) }
            io << "--" << boundary << "--\r\n"
          end
        end
      end

      private def write_body_part(io : IO, boundary : String) : Nil
        if html = body_html
          alt = "saci-alt-#{Random::Secure.hex(16)}"
          io << "--" << boundary << "\r\n"
          io << "Content-Type: multipart/alternative; boundary=\"" << alt << "\"\r\n\r\n"
          io << "--" << alt << "\r\n"
          io << "Content-Type: text/plain; charset=UTF-8\r\n\r\n"
          io << body_text << "\r\n"
          io << "--" << alt << "\r\n"
          io << "Content-Type: text/html; charset=UTF-8\r\n\r\n"
          io << html << "\r\n"
          io << "--" << alt << "--\r\n"
        else
          io << "--" << boundary << "\r\n"
          io << "Content-Type: text/plain; charset=UTF-8\r\n\r\n"
          io << body_text << "\r\n"
        end
      end

      private def write_mime_attachment(io : IO, boundary : String, attachment : Attachment) : Nil
        io << "--" << boundary << "\r\n"
        io << "Content-Type: " << attachment.content_type << "\r\n"
        io << "Content-Transfer-Encoding: base64\r\n"
        io << "Content-Disposition: " << attachment.content_disposition << "\r\n"
        if cid = attachment.content_id
          io << "Content-ID: <" << sanitize_header(cid) << ">\r\n"
        end
        io << "\r\n"
        io << attachment.encoded_content
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
      extend Saci::Mailer::ViewHelpers

      # Draft accessors used from callbacks and mail actions. They are
      # fiber-local, so concurrent deliveries never share headers/attachments.
      def self.params : Saci::Mailer::Params
        Saci::Mailer::Context.current.try(&.params) || Saci::Mailer::Params.empty
      end

      def self.attachments : Saci::Mailer::Attachments
        Saci::Mailer::Context.stage.attachments
      end

      def self.headers : Hash(String, String)
        Saci::Mailer::Context.stage.headers
      end

      def self.action_name : String?
        Saci::Mailer::Context.current.try(&.action)
      end

      def self.current_mail : Saci::Mailer::Mail?
        Saci::Mailer::Context.current.try(&.mail)
      end

      macro default_from(address)
        def self.default_from_address : String
          {{address}}
        end
      end

      def self.default_from_address : String
        ""
      end

      macro default_reply_to(address)
        def self.default_reply_to_address : String?
          {{address}}
        end
      end

      def self.default_reply_to_address : String?
        nil
      end

      # Wraps the text/html parts with the named layout (registered via
      # `Saci::Mailer.register_layout`). Each kind uses its own template;
      # missing kinds pass through unwrapped, as do unknown layout names.
      macro layout(name)
        def self.mailer_layout_name : String?
          {{name}}
        end
      end

      # File-based layout: loads `<directory>/<name>.text` and
      # `<directory>/<name>.html` (either may be missing).
      macro layout_file(name, directory = "app/views/layouts/mailer")
        {% layout_name = name.is_a?(StringLiteral) ? name.string : name.id.stringify %}
        {% layout_dir = directory.is_a?(StringLiteral) ? directory.string : directory.id.stringify %}
        def self.mailer_layout_name : String?
          Saci::Mailer.register_layout_files({{layout_name}}, {{layout_dir}})
          {{layout_name}}
        end
      end

      def self.mailer_layout_name : String?
        nil
      end

      def self.mail(to : String | Array(String), subject : String, from : String? = nil, cc : String | Array(String) | Nil = nil, bcc : String | Array(String) | Nil = nil, reply_to : String? = nil, headers : Hash(String, String)? = nil, attachments : Array(Mailer::Attachment)? = nil, &block : FormatCollector -> Nil) : Mail
        __saci_run_mail do
          formats = FormatCollector.new
          block.call(formats)
          build_mail(to, subject, from, cc, bcc, formats.text_body, formats.html_body, reply_to, headers, attachments)
        end
      end

      def self.mail(to : String | Array(String), subject : String, from : String? = nil, cc : String | Array(String) | Nil = nil, bcc : String | Array(String) | Nil = nil, reply_to : String? = nil, headers : Hash(String, String)? = nil, attachments : Array(Mailer::Attachment)? = nil) : Mail
        __saci_run_mail do
          build_mail(to, subject, from, cc, bcc, "", nil, reply_to, headers, attachments)
        end
      end

      # Convenience for code that used a separate deliver hand-off.
      def self.deliver(mail : Mail) : Nil
        mail.deliver_now
      end

      # Creates/adopts a fiber-local context, runs before/around/after
      # callbacks, and tears down a context that this mail build owns.
      private def self.__saci_run_mail(&build : -> Mail) : Mail
        ctx = Saci::Mailer::Context.current
        created = false
        unless ctx
          ctx = Saci::Mailer::Context.new(action: __saci_infer_action, mailer: self.name)
          Saci::Mailer::Context.push(ctx)
          created = true
        else
          ctx.action ||= __saci_infer_action
          ctx.mailer ||= self.name
        end
        begin
          __saci_run_callbacks(ctx) { build.call }
        ensure
          Saci::Mailer::Context.pop(ctx) if created || ctx.staged?
        end
      end

      # Class-method mailers do not have an instance to carry the action name,
      # so infer it from the immediate non-internal caller. Parameterized
      # proxies set `ctx.action` explicitly and win.
      private def self.__saci_infer_action : String?
        internal = ["mail", "build_mail", "__saci_run_mail", "__saci_run_callbacks",
                    "__saci_infer_action", "run_callbacks", "with_params", "call", "yield"]
        caller.each do |frame|
          if match = frame.match(/ in '([^']+)'/)
            name = match[1].split(':', 2)[0]
            next if internal.includes?(name)
            return name
          end
        end
        nil
      end

      private def self.build_mail(to, subject, from, cc, bcc, text, html, reply_to, headers, extra_attachments) : Mail
        wrapped_text, wrapped_html = apply_mailer_layout(mailer_layout_name, text, html)
        ctx = Saci::Mailer::Context.current
        merged_headers = {} of String => String
        ctx.try(&.headers.each { |k, v| merged_headers[k] = v })
        headers.try(&.each { |k, v| merged_headers[k] = v })
        all_attachments = ctx.try(&.attachments.to_a) || [] of Attachment
        if extra = extra_attachments
          combined = Attachments.new(all_attachments)
          extra.each { |attachment| combined.add(attachment) }
          all_attachments = combined.to_a
        end
        Mail.new(as_list(to), from || default_from_address, subject, wrapped_text, wrapped_html,
          cc: as_list(cc), bcc: as_list(bcc),
          reply_to: reply_to || default_reply_to_address,
          headers: merged_headers,
          attachments: all_attachments,
          mailer: self.name,
          action: ctx.try(&.action),
          params: ctx.try(&.params.to_h) || {} of String => JSON::Any)
      end

      private def self.apply_mailer_layout(name : String?, text : String, html : String?) : Tuple(String, String?)
        return {text, html} if name.nil?
        entry = Mailer.find_layout(name)
        return {text, html} if entry.nil?
        wrapped_html = html.nil? ? nil : wrap_layout_part(entry[:html], html)
        {wrap_layout_part(entry[:text], text), wrapped_html}
      end

      private def self.wrap_layout_part(template : String?, body : String) : String
        return body if template.nil?
        if template.includes?("<%= content %>")
          template.gsub("<%= content %>", body)
        else
          template + body
        end
      end

      private def self.as_list(value : String | Array(String) | Nil) : Array(String)
        case value
        when Nil   then [] of String
        when Array then value
        else            [value]
        end
      end
    end

    # Dev-only mailer previews (Rails-style, without the Rails path).
    #
    # ```
    # Saci::Mailer::Preview.register("welcome") { UserMailer.welcome("demo@example.com") }
    #
    # router = Saci::Router.new.draw do |r|
    #   r.get "/saci/mailers", Saci::Mailer::PreviewController, :index
    #   r.get "/saci/mailers/:name", Saci::Mailer::PreviewController, :show
    # end
    # ```
    #
    # Deliberately mounted at `/saci/mailers` rather than
    # `/rails/mailers*` to avoid confusion with Rails. Enabled by
    # default outside production (`Preview.enabled = Saci.env !=
    # "production"`); both actions 404 when disabled. No auth is
    # built-in — put the routes behind an admin gate if you enable
    # them outside development.
    module Preview
      @@mutex = Mutex.new
      @@entries = {} of String => Proc(Mail)
      @@enabled_override : Bool? = nil

      # Live env-derived default (`Saci.env != "production"`) unless
      # overridden; assign explicitly to force on/off.
      def self.enabled : Bool
        @@mutex.synchronize do
          override = @@enabled_override
          override.nil? ? Saci.env != "production" : override
        end
      end

      def self.enabled=(value : Bool) : Nil
        @@mutex.synchronize { @@enabled_override = value }
      end

      def self.register(name : String, &block : -> Mail) : Nil
        @@mutex.synchronize { @@entries[name] = block }
      end

      def self.names : Array(String)
        @@mutex.synchronize { @@entries.keys.sort }
      end

      def self.find(name : String) : Mail?
        proc = @@mutex.synchronize { @@entries[name]? }
        proc.try(&.call)
      end

      def self.clear! : Nil
        @@mutex.synchronize { @@entries.clear }
      end

      # Spec isolation: clears the registry and restores the
      # env-derived `enabled` default.
      def self.reset! : Nil
        @@mutex.synchronize do
          @@entries.clear
          @@enabled_override = nil
        end
      end
    end

    # Mountable preview UI (see `Preview` for routes). `index` lists
    # registered previews; `show` renders the text/html parts in a
    # debug layout with the headers shown.
    class PreviewController < Saci::Controller
      def index
        unless Preview.enabled
          render text: "Not found", status: :not_found
          return
        end
        items = Preview.names.map do |name|
          %(<li><a href="/saci/mailers/#{h(name)}">#{h(name)}</a></li>)
        end.join("\n")
        render html: "<!doctype html><html><head><meta charset=\"utf-8\">" \
                     "<title>Mailer previews</title></head><body>" \
                     "<h1>Mailer previews</h1><ul>\n#{items}\n</ul></body></html>"
      end

      def show
        unless Preview.enabled
          render text: "Not found", status: :not_found
          return
        end
        name = params["name"]? || ""
        mail = Preview.find(name)
        if mail.nil?
          render text: "No such preview: #{name}", status: :not_found
          return
        end
        render html: debug_layout(name, mail)
      end

      private def debug_layout(name : String, mail : Mail) : String
        String.build do |io|
          io << "<!doctype html><html><head><meta charset=\"utf-8\">" \
                "<title>Preview: " << h(name) << "</title></head><body>"
          io << "<h1>Preview: " << h(name) << "</h1>"
          io << "<dl>"
          io << "<dt>From</dt><dd>" << h(mail.from) << "</dd>"
          io << "<dt>To</dt><dd>" << h(mail.to.join(", ")) << "</dd>"
          io << "<dt>Cc</dt><dd>" << h(mail.cc.join(", ")) << "</dd>" unless mail.cc.empty?
          io << "<dt>Subject</dt><dd>" << h(mail.subject) << "</dd>"
          io << "</dl>"
          io << "<h2>Text</h2><pre>" << h(mail.body_text) << "</pre>"
          if html = mail.body_html
            io << "<h2>HTML</h2><div class=\"saci-mail-preview\">" << html << "</div>"
          end
          io << "</body></html>"
        end
      end
    end
  end
end

require "./mailer/test_helpers"
