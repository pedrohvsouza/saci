require "base64"
require "digest/sha256"
require "http/client"
require "json"
require "openssl"
require "uri"

module Saci
  module Mailer
    # Raised by HTTP delivery providers. `status` is nil for transport errors.
    class DeliveryError < Exception
      getter provider : String
      getter status : Int32?
      getter body : String?

      def initialize(@provider : String, message : String, @status : Int32? = nil, @body : String? = nil)
        super("#{@provider} delivery failed: #{message}")
      end
    end

    # Common interface for mail delivery adapters. SMTP keeps its existing
    # `Saci::Mailer::SMTP` implementation; HTTP providers implement this.
    abstract class DeliveryMethod
      abstract def deliver(mail : Mail) : Nil
    end

    # Shared HTTP plumbing: explicit timeouts, provider errors with response
    # bodies, and no leaked connections.
    abstract class HttpDeliveryMethod < DeliveryMethod
      private def post_json(url : String, headers : HTTP::Headers, body : String,
                            connect_timeout : Time::Span, read_timeout : Time::Span,
                            provider : String) : HTTP::Client::Response
        uri = URI.parse(url)
        client = HTTP::Client.new(uri)
        client.connect_timeout = connect_timeout
        client.read_timeout = read_timeout
        client.write_timeout = read_timeout
        begin
          response = client.exec("POST", uri.request_target, headers, body)
          unless response.success?
            raise DeliveryError.new(provider, "HTTP #{response.status_code}", response.status_code, response.body)
          end
          response
        rescue ex : DeliveryError
          raise ex
        rescue ex : IO::Error
          raise DeliveryError.new(provider, ex.message || ex.class.name)
        rescue ex : OpenSSL::SSL::Error
          raise DeliveryError.new(provider, ex.message || ex.class.name)
        ensure
          client.close rescue nil
        end
      end
    end

    # SMTP adapter exposed through the same interface as the HTTP providers.
    class SmtpDelivery < DeliveryMethod
      def initialize(@settings : SmtpSettings = Mailer.smtp_settings)
      end

      def deliver(mail : Mail) : Nil
        SMTP.deliver(mail, @settings)
      end
    end

    struct SendgridSettings
      property api_key : String?
      property endpoint : String
      property connect_timeout : Time::Span
      property read_timeout : Time::Span

      def initialize(@api_key : String? = nil,
                     @endpoint : String = "https://api.sendgrid.com/v3/mail/send",
                     @connect_timeout : Time::Span = 10.seconds,
                     @read_timeout : Time::Span = 30.seconds)
      end

      def resolved_api_key : String
        key = @api_key || ENV["SENDGRID_API_KEY"]?
        raise DeliveryError.new("sendgrid", "SENDGRID_API_KEY is not configured") if key.nil? || key.empty?
        key
      end
    end

    struct MailgunSettings
      property api_key : String?
      property domain : String?
      property api_base : String
      property connect_timeout : Time::Span
      property read_timeout : Time::Span

      def initialize(@api_key : String? = nil, @domain : String? = nil,
                     @api_base : String = "https://api.mailgun.net",
                     @connect_timeout : Time::Span = 10.seconds,
                     @read_timeout : Time::Span = 30.seconds)
      end

      def resolved_api_key : String
        key = @api_key || ENV["MAILGUN_API_KEY"]?
        raise DeliveryError.new("mailgun", "MAILGUN_API_KEY is not configured") if key.nil? || key.empty?
        key
      end

      def resolved_domain : String
        value = @domain || ENV["MAILGUN_DOMAIN"]?
        raise DeliveryError.new("mailgun", "MAILGUN_DOMAIN is not configured") if value.nil? || value.empty?
        value
      end

      def messages_url : String
        "#{@api_base.rstrip('/')}/v3/#{resolved_domain}/messages"
      end
    end

    struct PostmarkSettings
      property api_key : String?
      property endpoint : String
      property message_stream : String?
      property connect_timeout : Time::Span
      property read_timeout : Time::Span

      def initialize(@api_key : String? = nil,
                     @endpoint : String = "https://api.postmarkapp.com/email",
                     @message_stream : String? = nil,
                     @connect_timeout : Time::Span = 10.seconds,
                     @read_timeout : Time::Span = 30.seconds)
      end

      def resolved_api_key : String
        key = @api_key || ENV["POSTMARK_API_KEY"]?
        raise DeliveryError.new("postmark", "POSTMARK_API_KEY is not configured") if key.nil? || key.empty?
        key
      end
    end

    struct SesSettings
      property access_key_id : String?
      property secret_access_key : String?
      property session_token : String?
      property region : String?
      property endpoint : String?
      property sign_requests : Bool
      property connect_timeout : Time::Span
      property read_timeout : Time::Span

      def initialize(@access_key_id : String? = nil, @secret_access_key : String? = nil,
                     @session_token : String? = nil, @region : String? = nil,
                     @endpoint : String? = nil, @sign_requests : Bool = true,
                     @connect_timeout : Time::Span = 10.seconds,
                     @read_timeout : Time::Span = 30.seconds)
      end

      def resolved_region : String
        @region || ENV["AWS_REGION"]? || ENV["AWS_DEFAULT_REGION"]? || "us-east-1"
      end

      def resolved_endpoint : String
        @endpoint || "https://email.#{resolved_region}.amazonaws.com/v2/email/outbound-emails"
      end

      def resolved_access_key_id : String
        key = @access_key_id || ENV["AWS_ACCESS_KEY_ID"]?
        raise DeliveryError.new("ses", "AWS_ACCESS_KEY_ID is not configured (or set sign_requests: false)") if key.nil? || key.empty?
        key
      end

      def resolved_secret_access_key : String
        key = @secret_access_key || ENV["AWS_SECRET_ACCESS_KEY"]?
        raise DeliveryError.new("ses", "AWS_SECRET_ACCESS_KEY is not configured (or set sign_requests: false)") if key.nil? || key.empty?
        key
      end

      def resolved_session_token : String?
        @session_token || ENV["AWS_SESSION_TOKEN"]?
      end
    end

    class SendgridDelivery < HttpDeliveryMethod
      def initialize(@settings : SendgridSettings)
      end

      def deliver(mail : Mail) : Nil
        headers = HTTP::Headers{
          "Authorization" => "Bearer #{@settings.resolved_api_key}",
          "Content-Type"  => "application/json",
          "Accept"        => "application/json",
        }
        post_json(@settings.endpoint, headers, payload(mail),
          @settings.connect_timeout, @settings.read_timeout, "sendgrid")
      end

      # Public for tests/tooling and for callers that queue their own HTTP.
      def payload(mail : Mail) : String
        JSON.build do |json|
          json.object do
            json.field "personalizations" do
              json.array do
                json.object do
                  write_addresses(json, "to", mail.to)
                  write_addresses(json, "cc", mail.cc) unless mail.cc.empty?
                  write_addresses(json, "bcc", mail.bcc) unless mail.bcc.empty?
                end
              end
            end
            json.field "from" do
              json.object { json.field "email", mail.from }
            end
            if reply_to = mail.reply_to
              json.field "reply_to" do
                json.object { json.field "email", reply_to }
              end
            end
            json.field "subject", mail.subject
            json.field "content" do
              json.array do
                json.object do
                  json.field "type", "text/plain"
                  json.field "value", mail.body_text
                end
                if html = mail.body_html
                  json.object do
                    json.field "type", "text/html"
                    json.field "value", html
                  end
                end
              end
            end
            unless mail.headers.empty?
              json.field "headers" do
                json.object do
                  mail.headers.each { |name, value| json.field name, value }
                end
              end
            end
            write_attachments(json, mail)
          end
        end
      end

      private def write_addresses(json : JSON::Builder, key : String, addresses : Array(String)) : Nil
        json.field key do
          json.array do
            addresses.each do |address|
              json.object { json.field "email", address }
            end
          end
        end
      end

      private def write_attachments(json : JSON::Builder, mail : Mail) : Nil
        return if mail.attachments.empty?
        json.field "attachments" do
          json.array do
            mail.attachments.each do |attachment|
              json.object do
                json.field "content", Base64.strict_encode(attachment.content)
                json.field "filename", attachment.filename
                json.field "type", attachment.mime_type
                json.field "disposition", attachment.inline? ? "inline" : "attachment"
                if attachment.inline? && (cid = attachment.content_id)
                  json.field "content_id", cid
                end
              end
            end
          end
        end
      end
    end

    class MailgunDelivery < HttpDeliveryMethod
      def initialize(@settings : MailgunSettings)
      end

      def deliver(mail : Mail) : Nil
        boundary = "saci-#{Random::Secure.hex(12)}"
        headers = HTTP::Headers{
          "Authorization" => "Basic #{Base64.strict_encode("api:#{@settings.resolved_api_key}")}",
          "Content-Type"  => "multipart/form-data; boundary=#{boundary}",
          "Accept"        => "application/json",
        }
        post_json(@settings.messages_url, headers, form_body(mail, boundary),
          @settings.connect_timeout, @settings.read_timeout, "mailgun")
      end

      def form_body(mail : Mail, boundary : String = "saci-#{Random::Secure.hex(12)}") : String
        io = IO::Memory.new
        write_field(io, boundary, "from", mail.from)
        write_field(io, boundary, "to", mail.to.join(", "))
        write_field(io, boundary, "cc", mail.cc.join(", ")) unless mail.cc.empty?
        write_field(io, boundary, "bcc", mail.bcc.join(", ")) unless mail.bcc.empty?
        write_field(io, boundary, "subject", mail.subject)
        write_field(io, boundary, "text", mail.body_text)
        write_field(io, boundary, "html", mail.body_html.not_nil!) if mail.body_html
        write_field(io, boundary, "h:Reply-To", mail.reply_to.not_nil!) if mail.reply_to
        mail.headers.each { |name, value| write_field(io, boundary, "h:#{name}", value) }
        mail.attachments.each do |attachment|
          io << "--" << boundary << "\r\n"
          kind = attachment.inline? ? "inline" : "attachment"
          io << "Content-Disposition: form-data; name=\"" << kind
          io << "\"; filename=\"" << attachment.filename.gsub(/[\r\n"]/, "_") << "\"\r\n"
          io << "Content-Type: " << attachment.mime_type << "\r\n"
          if attachment.inline? && (cid = attachment.content_id)
            io << "Content-ID: <" << cid << ">\r\n"
          end
          io << "\r\n"
          io.write(attachment.content)
          io << "\r\n"
        end
        io << "--" << boundary << "--\r\n"
        io.to_s
      end

      private def write_field(io : IO, boundary : String, name : String, value : String) : Nil
        io << "--" << boundary << "\r\n"
        io << "Content-Disposition: form-data; name=\"" << name.gsub(/[\r\n"]/, "_") << "\"\r\n\r\n"
        io << value << "\r\n"
      end
    end

    class PostmarkDelivery < HttpDeliveryMethod
      def initialize(@settings : PostmarkSettings)
      end

      def deliver(mail : Mail) : Nil
        headers = HTTP::Headers{
          "X-Postmark-Server-Token" => @settings.resolved_api_key,
          "Content-Type"            => "application/json",
          "Accept"                  => "application/json",
        }
        post_json(@settings.endpoint, headers, payload(mail),
          @settings.connect_timeout, @settings.read_timeout, "postmark")
      end

      def payload(mail : Mail) : String
        JSON.build do |json|
          json.object do
            json.field "From", mail.from
            json.field "To", mail.to.join(", ")
            json.field "Cc", mail.cc.join(", ") unless mail.cc.empty?
            json.field "Bcc", mail.bcc.join(", ") unless mail.bcc.empty?
            json.field "Subject", mail.subject
            json.field "TextBody", mail.body_text
            json.field "HtmlBody", mail.body_html.not_nil! if mail.body_html
            json.field "ReplyTo", mail.reply_to.not_nil! if mail.reply_to
            if stream = @settings.message_stream
              json.field "MessageStream", stream
            end
            unless mail.headers.empty?
              json.field "Headers" do
                json.array do
                  mail.headers.each do |name, value|
                    json.object do
                      json.field "Name", name
                      json.field "Value", value
                    end
                  end
                end
              end
            end
            unless mail.attachments.empty?
              json.field "Attachments" do
                json.array do
                  mail.attachments.each do |attachment|
                    json.object do
                      json.field "Name", attachment.filename
                      json.field "Content", Base64.strict_encode(attachment.content)
                      json.field "ContentType", attachment.mime_type
                      if attachment.inline? && (cid = attachment.content_id)
                        json.field "ContentID", cid
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end

    class SesDelivery < HttpDeliveryMethod
      def initialize(@settings : SesSettings)
      end

      def deliver(mail : Mail) : Nil
        endpoint = @settings.resolved_endpoint
        uri = URI.parse(endpoint)
        body = payload(mail)
        headers = HTTP::Headers{
          "Content-Type" => "application/json",
          "Accept"       => "application/json",
        }
        if @settings.sign_requests
          AwsSigV4.sign(
            method: "POST", uri: uri, headers: headers, body: body,
            access_key_id: @settings.resolved_access_key_id,
            secret_access_key: @settings.resolved_secret_access_key,
            region: @settings.resolved_region, service: "ses",
            session_token: @settings.resolved_session_token
          )
        end
        post_json(endpoint, headers, body,
          @settings.connect_timeout, @settings.read_timeout, "ses")
      end

      def payload(mail : Mail) : String
        JSON.build do |json|
          json.object do
            json.field "FromEmailAddress", mail.from
            json.field "Destination" do
              json.object do
                json.field "ToAddresses" { json.array { mail.to.each { |address| json.string(address) } } }
                unless mail.cc.empty?
                  json.field "CcAddresses" { json.array { mail.cc.each { |address| json.string(address) } } }
                end
                unless mail.bcc.empty?
                  json.field "BccAddresses" { json.array { mail.bcc.each { |address| json.string(address) } } }
                end
              end
            end
            json.field "Content" do
              json.object do
                json.field "Raw" do
                  json.object do
                    json.field "Data", Base64.strict_encode(mail.to_mime)
                  end
                end
              end
            end
          end
        end
      end
    end

    # Minimal AWS Signature Version 4 implementation (no SDK/shard). SES is
    # the only service used here, but the helper is generic.
    module AwsSigV4
      def self.sign(*, method : String, uri : URI, headers : HTTP::Headers, body : String,
                    access_key_id : String, secret_access_key : String, region : String,
                    service : String, session_token : String? = nil,
                    now : Time = Time.utc) : Nil
        uri_path = uri.path.empty? ? "/" : uri.path
        query = canonical_query(uri.query)
        amz_date = now.to_s("%Y%m%dT%H%M%SZ")
        date_stamp = now.to_s("%Y%m%d")

        headers["Host"] = host_header(uri)
        headers["X-Amz-Date"] = amz_date
        headers["X-Amz-Security-Token"] = session_token if session_token

        signed_names = ["content-type", "host", "x-amz-date"]
        signed_names << "x-amz-security-token" if session_token
        signed_names.sort!

        canonical_headers = signed_names.map do |name|
          value = headers[name].strip.gsub(/\s+/, " ")
          "#{name}:#{value}\n"
        end.join
        signed_headers = signed_names.join(";")
        payload_hash = Digest::SHA256.hexdigest(body)

        canonical_request = "#{method}\n#{uri_path}\n#{query}\n" \
                            "#{canonical_headers}\n#{signed_headers}\n#{payload_hash}"
        scope = "#{date_stamp}/#{region}/#{service}/aws4_request"
        string_to_sign = "AWS4-HMAC-SHA256\n#{amz_date}\n#{scope}\n" \
                         "#{Digest::SHA256.hexdigest(canonical_request)}"

        k_date = hmac("AWS4#{secret_access_key}", date_stamp)
        k_region = hmac(k_date, region)
        k_service = hmac(k_region, service)
        k_signing = hmac(k_service, "aws4_request")
        signature = hmac(k_signing, string_to_sign).hexstring

        headers["Authorization"] = "AWS4-HMAC-SHA256 Credential=#{access_key_id}/#{scope}, " \
                                   "SignedHeaders=#{signed_headers}, Signature=#{signature}"
      end

      private def self.hmac(key : String | Bytes, data : String) : Bytes
        OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA256, key, data)
      end

      private def self.canonical_query(query : String?) : String
        return "" if query.nil? || query.empty?
        query.split('&').reject(&.empty?).map { |part| part.split('=', 2) }
          .sort_by { |pair| {pair[0], pair[1]? || ""} }
          .map { |pair| pair.size == 2 ? "#{pair[0]}=#{pair[1]}" : pair[0] }
          .join('&')
      end

      private def self.host_header(uri : URI) : String
        host = uri.host || raise ArgumentError.new("URI has no host")
        default_port = uri.scheme == "https" ? 443 : 80
        uri.port == default_port ? host : "#{host}:#{uri.port}"
      end
    end

    @@provider_mutex = Mutex.new
    @@sendgrid_settings = SendgridSettings.new
    @@mailgun_settings = MailgunSettings.new
    @@postmark_settings = PostmarkSettings.new
    @@ses_settings = SesSettings.new

    def self.sendgrid_settings : SendgridSettings
      @@provider_mutex.synchronize { @@sendgrid_settings }
    end

    def self.sendgrid_settings=(settings : SendgridSettings) : Nil
      @@provider_mutex.synchronize { @@sendgrid_settings = settings }
    end

    def self.mailgun_settings : MailgunSettings
      @@provider_mutex.synchronize { @@mailgun_settings }
    end

    def self.mailgun_settings=(settings : MailgunSettings) : Nil
      @@provider_mutex.synchronize { @@mailgun_settings = settings }
    end

    def self.postmark_settings : PostmarkSettings
      @@provider_mutex.synchronize { @@postmark_settings }
    end

    def self.postmark_settings=(settings : PostmarkSettings) : Nil
      @@provider_mutex.synchronize { @@postmark_settings = settings }
    end

    def self.ses_settings : SesSettings
      @@provider_mutex.synchronize { @@ses_settings }
    end

    def self.ses_settings=(settings : SesSettings) : Nil
      @@provider_mutex.synchronize { @@ses_settings = settings }
    end

    # Rails-style alias for `delivery_adapter`.
    def self.delivery_method : Symbol
      delivery_adapter
    end

    def self.delivery_method=(name : Symbol) : Nil
      self.delivery_adapter = name
    end

    def self.build_delivery_method(name : Symbol) : DeliveryMethod?
      case name
      when :smtp     then SmtpDelivery.new(smtp_settings)
      when :sendgrid then SendgridDelivery.new(sendgrid_settings)
      when :mailgun  then MailgunDelivery.new(mailgun_settings)
      when :postmark then PostmarkDelivery.new(postmark_settings)
      when :ses      then SesDelivery.new(ses_settings)
      else                nil
      end
    end
  end
end
