module Saci
  # Secure response headers, applied to every controller response unless
  # already set (so actions can override). Configure globally:
  #
  # ```
  # Saci::SecureHeaders.configure do |headers|
  #   headers["Content-Security-Policy"] = "default-src 'self'"
  #   headers.delete("X-Frame-Options")
  # end
  # ```
  module SecureHeaders
    DEFAULTS = {
      "X-Frame-Options"         => "SAMEORIGIN",
      "X-Content-Type-Options"  => "nosniff",
      "Referrer-Policy"         => "strict-origin-when-cross-origin",
      "Content-Security-Policy" => "default-src 'self'",
    }

    @@headers : Hash(String, String) = DEFAULTS.dup
    @@mutex = Mutex.new

    def self.configure(& : Hash(String, String) ->) : Nil
      @@mutex.synchronize { yield @@headers }
    end

    def self.headers : Hash(String, String)
      @@mutex.synchronize { @@headers.dup }
    end

    def self.reset! : Nil
      @@mutex.synchronize { @@headers = DEFAULTS.dup }
    end

    def self.apply!(response : HTTP::Server::Response) : Nil
      headers.each do |name, value|
        response.headers[name] = value unless response.headers.has_key?(name)
      end
    end
  end

  # Per-action CSP escape hatch (F2 track — `Controller` reopened here so
  # `controller.cr` itself stays untouched).
  #
  # ```
  # class EmbedsController < Saci::Controller
  #   skip_csp only: [:show]   # no CSP header on #show, default elsewhere
  # end
  #
  # class LegacyController < Saci::Controller
  #   csp false                # no CSP header on any action
  # end
  #
  # class StrictController < Saci::Controller
  #   csp "default-src 'none'" # custom policy for every action
  # end
  # ```
  #
  # Headers are applied before filters run, so these are `before_action`s
  # that delete/overwrite the already-set header (still mutable until the
  # response closes). Setting `Content-Security-Policy` directly in an
  # action keeps working (`apply!` never overwrites).
  class Controller
    private def __saci_skip_csp_header : Nil
      response.headers.delete("Content-Security-Policy")
    end

    private def __saci_set_csp_header(value : String) : Nil
      response.headers["Content-Security-Policy"] = value
    end

    macro skip_csp(only = nil, except = nil)
      before_action :__saci_skip_csp_header, only: {{only}}, except: {{except}}
    end

    macro csp(policy)
      {% if policy.stringify == "false" %}
        before_action :__saci_skip_csp_header
      {% else %}
        private def __saci_csp_override_for_{{@type.name.stringify.gsub(/::/, "_").id}} : Nil
          __saci_set_csp_header({{policy}})
        end
        before_action :__saci_csp_override_for_{{@type.name.stringify.gsub(/::/, "_").id}}
      {% end %}
    end
  end
end
