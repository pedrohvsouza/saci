require "base64"
require "random/secure"
require "openssl/hmac"
require "crypto/subtle"

module Saci
  class InvalidAuthenticityToken < Exception
    def initialize
      super("ActionController::InvalidAuthenticityToken")
    end
  end

  # Double-submit-cookie CSRF protection (stateless — no session store
  # needed). A random global token lives in the `saci_csrf` cookie
  # (HttpOnly, Secure over HTTPS, issued only when a page asks for the
  # token through `form_authenticity_token`, so form-less GETs never set
  # it);
  # state-changing requests must echo it back via the `authenticity_token`
  # param or the `X-CSRF-Token` header. See `Controller#verify_authenticity_token`
  # and the `protect_from_forgery` macro.
  #
  # Two token shapes are accepted (constant-time comparisons throughout):
  #
  # * the global token itself (historical behavior), and
  # * a masked one-time-pad token produced by `mask` / `form_token`. Unmasking
  #   yields either the global token (global masked token) or
  #   `"<global>|<action>"` (per-form token). This keeps real tokens out of
  #   HTML/response bodies that might leak them (BREACH mitigation).
  #
  # ```
  # # per-form token (Controller helper, new API):
  # form_authenticity_token(form_options: {"action" => "posts#create"})
  # per_form_authenticity_token("posts#create")
  #
  # # verify with action binding when the controller knows its action:
  # Saci::CSRF.verified_for?(request, params, "posts#create")
  # ```
  module CSRF
    COOKIE_NAME      = "saci_csrf"
    PARAM_NAME       = "authenticity_token"
    HEADER_NAME      = "X-CSRF-Token"
    TOKEN_BYTES      = 32
    SAFE_METHODS     = ["GET", "HEAD", "OPTIONS", "TRACE"]
    ACTION_SEPARATOR = "|"

    @@per_form_csrf_tokens : Bool = false
    @@mutex = Mutex.new

    # Per-fiber issued-token cache: `form_authenticity_token` runs before the
    # browser can send back the cookie it just set, so without this every call
    # in one request generated a fresh token (multi-form pages then shipped
    # forms whose token did not match the last Set-Cookie). Keyed by
    # `Fiber` -> {request, token}, so it never grows past the number of server
    # fibers and resets with each new request.
    @@issued = {} of UInt64 => Tuple(HTTP::Request, String)
    @@pending = {} of UInt64 => HTTP::Request

    # Rails compatibility switch. Saci always accepts both global and
    # per-form tokens; this setting is exposed so apps can generate per-form
    # tokens by default in their own form helpers.
    def self.per_form_csrf_tokens : Bool
      @@mutex.synchronize { @@per_form_csrf_tokens }
    end

    def self.per_form_csrf_tokens=(value : Bool) : Nil
      @@mutex.synchronize { @@per_form_csrf_tokens = value }
    end

    def self.reset! : Nil
      @@mutex.synchronize do
        @@per_form_csrf_tokens = false
        @@issued.clear
        @@pending.clear
      end
    end

    def self.safe_method?(method : String) : Bool
      SAFE_METHODS.includes?(method.upcase)
    end

    def self.generate_token : String
      bytes = Bytes.new(TOKEN_BYTES)
      Random::Secure.random_bytes(bytes)
      Base64.urlsafe_encode(bytes, false)
    end

    # Timing-safe comparison (never `==` secrets). Blank tokens never match.
    def self.tokens_match?(a : String?, b : String?) : Bool
      return false if a.nil? || b.nil? || a.empty? || b.empty?
      return false unless a.bytesize == b.bytesize
      Crypto::Subtle.constant_time_compare(a, b)
    end

    # One-time-pad mask: `base64(pad || pad XOR token)`.
    def self.mask(token : String) : String
      data = token.to_slice
      pad = Bytes.new(data.size)
      Random::Secure.random_bytes(pad)
      masked = Bytes.new(data.size)
      data.size.times { |i| masked[i] = data[i] ^ pad[i] }
      Base64.urlsafe_encode(pad + masked, false)
    end

    # Reverses `mask`; nil for malformed input.
    def self.unmask(masked : String) : String?
      raw = Base64.decode(masked)
      return nil if raw.size < 2 || raw.size.odd?
      half = raw.size // 2
      pad = raw[0, half]
      masked_bytes = raw[half, half]
      result = Bytes.new(half)
      half.times { |i| result[i] = masked_bytes[i] ^ pad[i] }
      String.new(result)
    rescue
      nil
    end

    # Masked global token (unmasks to the cookie token).
    def self.masked_token(global_token : String) : String
      mask(global_token)
    end

    # Masked per-form token. `action` is an app-chosen scope such as
    # `"posts#create"`; it is embedded so `verified_for?` can bind the token
    # to one form.
    def self.per_form_token(global_token : String, action : String) : String
      mask("#{global_token}#{ACTION_SEPARATOR}#{action}")
    end

    # Masked token, optionally action-scoped (the generic helper used by the
    # `form_authenticity_token(form_options:)` overload).
    def self.form_token(global_token : String, action : String? = nil) : String
      action && !action.empty? ? per_form_token(global_token, action) : masked_token(global_token)
    end

    # The token for this client/request: the cookie value, or the token
    # issued earlier in this same request (see the issued-token cache above).
    def self.cookie_token(request : HTTP::Request) : String?
      fiber_key = Fiber.current.object_id
      @@mutex.synchronize do
        if entry = @@issued[fiber_key]?
          return entry[1] if entry[0].same?(request)
          @@issued.delete(fiber_key)
        end
        @@pending[fiber_key] = request
      end
      raw_cookie_token(request)
    end

    def self.raw_cookie_token(request : HTTP::Request) : String?
      request.cookies[COOKIE_NAME]?.try(&.value)
    end

    def self.request_token(request : HTTP::Request, params : Saci::Params) : String?
      request.headers[HEADER_NAME]? || params[PARAM_NAME]?
    end

    def self.verified?(request : HTTP::Request, params : Saci::Params) : Bool
      return true if safe_method?(request.method)
      verified_token?(raw_cookie_token(request), request_token(request, params))
    end

    # Action-bound verification (per-form tokens only). Returns true for a
    # safe method, a raw global token, a masked global token, or a per-form
    # token whose embedded action equals `action`.
    def self.verified_for?(request : HTTP::Request, params : Saci::Params, action : String) : Bool
      return true if safe_method?(request.method)
      global = raw_cookie_token(request)
      supplied = request_token(request, params)
      return false unless global && supplied
      return true if tokens_match?(global, supplied)
      return false unless unmasked = unmask(supplied)
      return true if tokens_match?(global, unmasked)
      tokens_match?("#{global}#{ACTION_SEPARATOR}#{action}", unmasked)
    end

    # Public for adapters/tests: does `supplied` authenticate against the
    # session's global `cookie` token?
    def self.verified_token?(cookie : String?, supplied : String?) : Bool
      return false if cookie.nil? || supplied.nil?
      return false if cookie.empty? || supplied.empty?
      # Historical raw global token.
      return true if tokens_match?(cookie, supplied)
      return false unless unmasked = unmask(supplied)
      # Masked global token.
      return true if tokens_match?(cookie, unmasked)
      # Masked per-form token: "<global>|<action>"; the global prefix is
      # compared in constant time.
      per_form_matches?(cookie, unmasked)
    end

    # Issues the token cookie. It is always `HttpOnly` (the token reaches
    # pages through forms and `csrf_meta_tags`, never through JavaScript
    # reading the cookie) and `Secure` when *secure* is true — see
    # `secure_request?`.
    def self.set_cookie(response : HTTP::Server::Response, token : String, secure : Bool = false) : Nil
      fiber_key = Fiber.current.object_id
      @@mutex.synchronize do
        if request = @@pending.delete(fiber_key)
          @@issued[fiber_key] = {request, token}
        end
      end
      cookie = HTTP::Cookie.new(COOKIE_NAME, token, path: "/", secure: secure, http_only: true,
        samesite: HTTP::Cookie::SameSite::Lax)
      response.cookies << cookie
    end

    # HTTPS requests (including TLS terminated by a proxy that sends
    # `X-Forwarded-Proto: https`) and apps that force or assume SSL get a
    # `Secure` cookie.
    def self.secure_request?(request : HTTP::Request) : Bool
      request.ssl? || Saci.force_ssl || Saci.config.assume_ssl
    end

    private def self.per_form_matches?(cookie : String, unmasked : String) : Bool
      prefix = "#{cookie}#{ACTION_SEPARATOR}"
      return false unless unmasked.bytesize > prefix.bytesize
      Crypto::Subtle.constant_time_compare(prefix, unmasked[0, prefix.bytesize])
    end
  end
end

require "./csrf_helpers"
