require "./permissions_policy"
require "./csp_nonce"
require "./csp_check"

module Saci
  # Secure response headers, applied to every controller response unless
  # already set (so actions can override). Configure globally:
  #
  # ```
  # Saci::SecureHeaders.configure do |headers|
  #   headers["Content-Security-Policy"] = "default-src 'self'"
  #   headers.delete("X-Frame-Options")
  # end
  #
  # # replace the whole default set (Rails default_headers):
  # Saci::SecureHeaders.default_headers = {
  #   "Content-Security-Policy" => "default-src 'self'",
  # }
  # ```
  #
  # Extras: `permissions_policy`, `csp_nonce` interpolation (`'nonce'`
  # placeholder in a CSP value), conditional HSTS (when `Saci.force_ssl` or
  # `SecureHeaders.hsts = true`), and `regexp_timeout` (see below).
  #
  # The default CSP is `default-src 'self'`: inline `<style>`/`<script>`,
  # `style="..."` attributes and every external origin (Google Fonts, CDNs)
  # are blocked until the policy allows them. Generated apps spell the
  # policy out in `config/initializers/content_security_policy.cr`, and in
  # development each HTML response is checked against its policy, with a
  # log warning for markup the browser would block (`csp_check.cr`).
  module SecureHeaders
    DEFAULTS = {
      "X-Frame-Options"                   => "SAMEORIGIN",
      "X-Content-Type-Options"            => "nosniff",
      "X-Download-Options"                => "noopen",
      "X-Permitted-Cross-Domain-Policies" => "none",
      "Referrer-Policy"                   => "strict-origin-when-cross-origin",
      "Cross-Origin-Opener-Policy"        => "same-origin",
      "Cross-Origin-Resource-Policy"      => "same-site",
      "Content-Security-Policy"           => "default-src 'self'",
    }

    HSTS_HEADER = "Strict-Transport-Security"

    @@headers : Hash(String, String) = DEFAULTS.dup
    @@mutex = Mutex.new

    # nil = automatic (follows `Saci.force_ssl`); true/false force it.
    @@hsts : Bool? = nil
    @@hsts_max_age : Int32 = 31_536_000
    @@hsts_include_subdomains : Bool = true
    @@hsts_preload : Bool = false

    # Crystal's stdlib `Regexp` has no timeout/re2-style execution budget
    # (as of Crystal 1.22), so this setting is a documented no-op: it is
    # stored for configuration parity and future enforcement, but the
    # framework cannot interrupt a catastrophic backtrack. Keep user-supplied
    # patterns out of hot paths / bound input sizes instead.
    @@regexp_timeout : Time::Span? = nil

    def self.configure(& : Hash(String, String) ->) : Nil
      @@mutex.synchronize { yield @@headers }
    end

    def self.headers : Hash(String, String)
      @@mutex.synchronize { @@headers.dup }
    end

    def self.headers=(value : Hash(String, String)) : Nil
      @@mutex.synchronize { @@headers = value.dup }
    end

    # Rails `config.action_dispatch.default_headers` equivalent.
    def self.default_headers : Hash(String, String)
      headers
    end

    def self.default_headers=(value : Hash(String, String)) : Nil
      self.headers = value
    end

    # Restores every framework default (headers, permissions policy, HSTS
    # and nonce settings) — spec isolation.
    def self.reset! : Nil
      @@mutex.synchronize do
        @@headers = DEFAULTS.dup
        @@hsts = nil
        @@hsts_max_age = 31_536_000
        @@hsts_include_subdomains = true
        @@hsts_preload = false
        @@regexp_timeout = nil
        @@permissions_policy = {} of String => Array(String)
      end
    end

    # Applies defaults (and the configured permissions policy / HSTS) to a
    # response. Values already present are never overwritten, so actions and
    # filters keep the final word.
    def self.apply!(response : HTTP::Server::Response) : Nil
      # `HTTP::Server` reuses one Response per keep-alive connection; clear
      # the previous request's nonce so each request gets a fresh one.
      response.saci_csp_nonce = nil
      headers.each do |name, value|
        next if response.headers.has_key?(name)
        response.headers[name] = if name == CSP_HEADER
                                   interpolate_csp_nonce(value, response)
                                 else
                                   value
                                 end
      end
      apply_permissions_policy(response)
      apply_hsts(response)
    end

    def self.hsts : Bool?
      @@mutex.synchronize { @@hsts }
    end

    def self.hsts=(value : Bool?) : Nil
      @@mutex.synchronize { @@hsts = value }
    end

    def self.hsts_max_age : Int32
      @@mutex.synchronize { @@hsts_max_age }
    end

    def self.hsts_max_age=(seconds : Int32) : Nil
      raise ArgumentError.new("hsts_max_age must be positive") if seconds < 1
      @@mutex.synchronize { @@hsts_max_age = seconds }
    end

    def self.hsts_include_subdomains=(value : Bool) : Nil
      @@mutex.synchronize { @@hsts_include_subdomains = value }
    end

    def self.hsts_preload=(value : Bool) : Nil
      @@mutex.synchronize { @@hsts_preload = value }
    end

    # HSTS is only meaningful over HTTPS; without a request in `apply!` the
    # signal is `Saci.force_ssl` (or an explicit `hsts = true` for apps
    # behind a TLS-terminating proxy). Browsers ignore the header on plain
    # HTTP responses.
    def self.hsts_enabled? : Bool
      explicit = hsts
      explicit.nil? ? Saci.force_ssl : explicit
    end

    def self.apply_hsts(response : HTTP::Server::Response) : Nil
      return unless hsts_enabled?
      return if response.headers.has_key?(HSTS_HEADER)
      value = String.build do |io|
        io << "max-age=" << hsts_max_age
        io << "; includeSubDomains" if @@mutex.synchronize { @@hsts_include_subdomains }
        io << "; preload" if @@mutex.synchronize { @@hsts_preload }
      end
      response.headers[HSTS_HEADER] = value
    end

    def self.regexp_timeout : Time::Span?
      @@mutex.synchronize { @@regexp_timeout }
    end

    # Accepted for Rails parity (`Regexp.timeout`). Crystal cannot enforce a
    # regexp execution timeout, so this is a documented no-op — see the
    # comment on the class variable.
    def self.regexp_timeout=(value : Time::Span?) : Nil
      @@mutex.synchronize { @@regexp_timeout = value }
    end

    # Always false on Crystal 1.22 (stdlib cannot interrupt `Regexp`).
    def self.regexp_timeout_enforced? : Bool
      false
    end

    def self.cookies_same_site_protection : Symbol?
      Cookies.same_site_protection
    end

    def self.cookies_same_site_protection=(value : Symbol?) : Nil
      Cookies.same_site_protection = value
    end

    def self.cookies_rotations : Array(String)
      Cookies.rotations
    end

    def self.cookies_rotations=(values : Array(String)) : Nil
      Cookies.rotations = values
    end
  end

  # Per-action CSP escape hatch (F2 track — `Controller` reopened here so
  # `controller.cr` itself stays untouched).
  #
  # ```
  # class EmbedsController < Saci::Controller
  #   skip_csp only: [:show] # no CSP header on #show, default elsewhere
  # end
  #
  # class LegacyController < Saci::Controller
  #   csp false # no CSP header on any action
  # end
  #
  # class StrictController < Saci::Controller
  #   csp "default-src 'none'" # custom policy for every action
  # end
  # ```
  #
  # A policy containing the `'nonce'` placeholder (or `{{nonce}}`) gets a
  # per-request nonce interpolated by `SecureHeaders.apply!` / `csp`:
  #
  # ```
  # csp "script-src 'self' 'nonce'; object-src 'none'"
  # ```
  #
  # Headers are applied before filters run, so these are `before_action`s
  # that delete/overwrite the already-set header (still mutable until the
  # response closes). Setting `Content-Security-Policy` directly in an
  # action keeps working (`apply!` never overwrites).
  class Controller
    private def __saci_skip_csp_header : Nil
      response.headers.delete(SecureHeaders::CSP_HEADER)
    end

    private def __saci_set_csp_header(value : String) : Nil
      SecureHeaders.set_csp_header(response, value)
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
