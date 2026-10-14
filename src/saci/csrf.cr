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
  # needed). A random token lives in the `saci_csrf` cookie; state-changing
  # requests must echo it back via the `authenticity_token` param or the
  # `X-CSRF-Token` header. See `Controller#verify_authenticity_token` and
  # the `protect_from_forgery` macro.
  module CSRF
    COOKIE_NAME  = "saci_csrf"
    PARAM_NAME   = "authenticity_token"
    HEADER_NAME  = "X-CSRF-Token"
    TOKEN_BYTES  = 32
    SAFE_METHODS = ["GET", "HEAD", "OPTIONS", "TRACE"]

    def self.safe_method?(method : String) : Bool
      SAFE_METHODS.includes?(method.upcase)
    end

    def self.generate_token : String
      bytes = Bytes.new(TOKEN_BYTES)
      Random::Secure.random_bytes(bytes)
      Base64.urlsafe_encode(bytes, false)
    end

    # Timing-safe comparison (never `==` secrets).
    def self.tokens_match?(a : String?, b : String?) : Bool
      return false if a.nil? || b.nil? || a.empty? || b.empty?
      Crypto::Subtle.constant_time_compare(a, b)
    end

    def self.cookie_token(request : HTTP::Request) : String?
      request.cookies[COOKIE_NAME]?.try(&.value)
    end

    def self.request_token(request : HTTP::Request, params : Saci::Params) : String?
      request.headers[HEADER_NAME]? || params[PARAM_NAME]?
    end

    def self.verified?(request : HTTP::Request, params : Saci::Params) : Bool
      return true if safe_method?(request.method)
      tokens_match?(cookie_token(request), request_token(request, params))
    end

    def self.set_cookie(response : HTTP::Server::Response, token : String) : Nil
      cookie = HTTP::Cookie.new(COOKIE_NAME, token, path: "/", samesite: HTTP::Cookie::SameSite::Lax)
      response.cookies << cookie
    end
  end
end
