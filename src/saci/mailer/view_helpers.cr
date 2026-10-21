require "html"
require "uri"

module Saci
  module Mailer
    # Small helpers for building mailer bodies (mailer actions are plain
    # Crystal code, so these are class-level helpers rather than template
    # helpers).
    module ViewHelpers
      # `<a href="mailto:...">...</a>` with URL-encoded query options.
      #
      # ```
      # mail_to("support@example.com", "Support", subject: "Help")
      # # => <a href="mailto:support@example.com?subject=Help">Support</a>
      # ```
      def mail_to(address : String, name : String? = nil, *,
                  subject : String? = nil, cc : String? = nil, bcc : String? = nil,
                  body : String? = nil, class_ : String? = nil) : String
        query = [] of String
        query << "subject=#{URI.encode_www_form(subject)}" if subject
        query << "cc=#{URI.encode_www_form(cc)}" if cc
        query << "bcc=#{URI.encode_www_form(bcc)}" if bcc
        query << "body=#{URI.encode_www_form(body)}" if body
        href = "mailto:#{address}"
        href += "?#{query.join('&')}" unless query.empty?
        klass = class_ ? %( class="#{HTML.escape(class_)}") : ""
        %(<a href="#{HTML.escape(href)}"#{klass}>#{HTML.escape(name || address)}</a>)
      end

      # Absolute URL for mailer bodies. Uses `Mailer.default_url_options`
      # unless `host:`/`protocol:` are passed:
      #
      # ```
      # mailer_url("/users/1") # => "https://example.com/users/1"
      # ```
      def mailer_url(path : String = "/", *, host : String? = nil, protocol : String? = nil) : String
        host ||= Mailer.default_host
        raise ArgumentError.new("mailer_url requires a host (set Saci::Mailer.default_host or pass host:)") if host.nil? || host.empty?
        scheme = protocol || Mailer.default_protocol
        clean_path = path.starts_with?("/") ? path : "/#{path}"
        root = host.includes?("://") ? host : "#{scheme}://#{host}"
        "#{root.rstrip('/')}#{clean_path}"
      end

      def mailer_path(path : String = "/") : String
        path.starts_with?("/") ? path : "/#{path}"
      end
    end

    @@default_host : String? = nil
    @@default_protocol : String = "https"
    @@url_options_mutex = Mutex.new

    def self.default_host : String?
      @@url_options_mutex.synchronize { @@default_host }
    end

    def self.default_host=(host : String?) : Nil
      @@url_options_mutex.synchronize { @@default_host = host }
    end

    def self.default_protocol : String
      @@url_options_mutex.synchronize { @@default_protocol }
    end

    def self.default_protocol=(protocol : String) : Nil
      @@url_options_mutex.synchronize { @@default_protocol = protocol }
    end

    def self.configure_url_options(*, host : String? = nil, protocol : String? = nil) : Nil
      @@url_options_mutex.synchronize do
        @@default_host = host if host
        @@default_protocol = protocol if protocol
      end
    end

    extend ViewHelpers
  end
end
