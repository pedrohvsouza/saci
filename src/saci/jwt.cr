require "base64"
require "json"
require "openssl/hmac"
require "crypto/subtle"

module Saci
  # Minimal, dependency-free JSON Web Token (JWT) support — HS256/HS384/
  # HS512 only (HMAC), matching the `jwt` shard's common surface without
  # pulling a dependency into the framework.
  #
  # ```
  # token = Saci::JWT.encode({"sub" => "42", "iss" => "saci"}, SECRET,
  #   algorithm: :hs256,
  #   headers: {"kid" => "2026-10"})
  #
  # payload = Saci::JWT.decode(token, SECRET)  # nil on any problem
  # payload = Saci::JWT.decode!(token, SECRET) # raises Saci::JWT::Error
  # payload["sub"].as_s                        # => "42"
  # ```
  #
  # Security properties:
  # * The `alg` header never selects the algorithm on its own: the caller
  #   passes an allow-list (`algorithms:`), and the header must name one of
  #   those. `none` is always rejected, even if a caller lists it.
  # * Signatures are compared in constant time (`Crypto::Subtle`).
  # * Base64url without padding is used on both sides.
  # * `exp`, `nbf`, `iat`, `iss`, `aud` and `sub` are validated when
  #   present (and when their `verify_*` switch is on). A small `leeway:`
  #   absorbs clock skew.
  #
  # `decode` returns the payload hash (or nil); use `decode_with_header`
  # when the header is needed too.
  module JWT
    class Error < Exception
    end

    class MalformedToken < Error
    end

    class InvalidSignature < Error
    end

    class InvalidAlgorithm < Error
    end

    class ExpiredSignature < Error
    end

    class NotYetValid < Error
    end

    class InvalidClaim < Error
    end

    # A verified token: decoded header + payload.
    struct Decoded
      getter header : Hash(String, JSON::Any)
      getter payload : Hash(String, JSON::Any)

      def initialize(@header : Hash(String, JSON::Any), @payload : Hash(String, JSON::Any))
      end

      def [](key : String) : JSON::Any
        payload[key]
      end

      def []?(key : String) : JSON::Any?
        payload[key]?
      end
    end

    ALGORITHMS = {
      hs256: {"HS256", OpenSSL::Algorithm::SHA256},
      hs384: {"HS384", OpenSSL::Algorithm::SHA384},
      hs512: {"HS512", OpenSSL::Algorithm::SHA512},
    }

    EMPTY_HEADERS = {} of String => String

    # Encodes *payload* as a compact JWS. *payload* may be any `Hash` whose
    # values are JSON-friendly (JSON::Any, strings, numbers, bools, nil or
    # anything with a useful `to_s`). *headers* adds custom JOSE headers
    # (`kid`, `cty`, ...); `alg`/`typ` are reserved.
    #
    # Raises `InvalidAlgorithm` for `none`/unknown algorithms.
    def self.encode(payload : Hash, key : String | Bytes, algorithm : Symbol = :hs256, headers : Hash = EMPTY_HEADERS) : String
      alg_name, digest_alg = algorithm_for(algorithm)

      header = {} of String => JSON::Any
      headers.each do |name, value|
        key_name = name.to_s
        if key_name.downcase == "alg"
          raise InvalidAlgorithm.new("the 'alg' header is set by the algorithm argument")
        end
        header[key_name] = json_any(value)
      end
      header["alg"] = JSON::Any.new(alg_name)
      header["typ"] = JSON::Any.new("JWT") unless header.has_key?("typ")

      payload_json = {} of String => JSON::Any
      payload.each { |name, value| payload_json[name.to_s] = json_any(value) }

      encoded_header = base64url_encode(header.to_json.to_slice)
      encoded_payload = base64url_encode(payload_json.to_json.to_slice)
      signing_input = "#{encoded_header}.#{encoded_payload}"
      encoded_signature = base64url_encode(hmac(digest_alg, key, signing_input))
      "#{signing_input}.#{encoded_signature}"
    end

    # Decodes and verifies *token*, returning the payload hash. Returns nil
    # for any malformed/expired/tampered token (use `decode!` to raise).
    #
    # *algorithms* is the allow-list. It defaults to `[:hs256]`; pass
    # `[:hs256, :hs384, :hs512]` to accept every supported family.
    def self.decode(token : String, key : String | Bytes, algorithms : Array(Symbol) = [:hs256],
                    verify_exp : Bool = true, verify_nbf : Bool = true, verify_iat : Bool = true,
                    issuer : String? = nil, audience : String? = nil, subject : String? = nil,
                    leeway : Time::Span = Time::Span.zero) : Hash(String, JSON::Any)?
      decode!(token, key, algorithms, verify_exp: verify_exp, verify_nbf: verify_nbf,
        verify_iat: verify_iat, issuer: issuer, audience: audience, subject: subject,
        leeway: leeway)
    rescue Error
      nil
    end

    # Single-algorithm convenience overload.
    def self.decode(token : String, key : String | Bytes, algorithms : Symbol,
                    verify_exp : Bool = true, verify_nbf : Bool = true, verify_iat : Bool = true,
                    issuer : String? = nil, audience : String? = nil, subject : String? = nil,
                    leeway : Time::Span = Time::Span.zero) : Hash(String, JSON::Any)?
      decode(token, key, [algorithms], verify_exp: verify_exp, verify_nbf: verify_nbf,
        verify_iat: verify_iat, issuer: issuer, audience: audience, subject: subject,
        leeway: leeway)
    end

    # Decodes and verifies *token*, raising a `Saci::JWT::Error` subclass on
    # failure. Never returns nil.
    def self.decode!(token : String, key : String | Bytes, algorithms : Array(Symbol) = [:hs256],
                     verify_exp : Bool = true, verify_nbf : Bool = true, verify_iat : Bool = true,
                     issuer : String? = nil, audience : String? = nil, subject : String? = nil,
                     leeway : Time::Span = Time::Span.zero) : Hash(String, JSON::Any)
      verify_token(token, key, algorithms, verify_exp, verify_nbf, verify_iat,
        issuer, audience, subject, leeway, Time.utc).payload
    end

    # Single-algorithm convenience overload.
    def self.decode!(token : String, key : String | Bytes, algorithms : Symbol,
                     verify_exp : Bool = true, verify_nbf : Bool = true, verify_iat : Bool = true,
                     issuer : String? = nil, audience : String? = nil, subject : String? = nil,
                     leeway : Time::Span = Time::Span.zero) : Hash(String, JSON::Any)
      decode!(token, key, [algorithms], verify_exp: verify_exp, verify_nbf: verify_nbf,
        verify_iat: verify_iat, issuer: issuer, audience: audience, subject: subject,
        leeway: leeway)
    end

    # Like `decode!`, but returns header + payload.
    def self.decode_with_header(token : String, key : String | Bytes, algorithms : Array(Symbol) = [:hs256],
                                verify_exp : Bool = true, verify_nbf : Bool = true, verify_iat : Bool = true,
                                issuer : String? = nil, audience : String? = nil, subject : String? = nil,
                                leeway : Time::Span = Time::Span.zero) : Decoded
      verify_token(token, key, algorithms, verify_exp, verify_nbf, verify_iat,
        issuer, audience, subject, leeway, Time.utc)
    end

    private def self.verify_token(token : String, key : String | Bytes, algorithms : Array(Symbol),
                                  verify_exp : Bool, verify_nbf : Bool, verify_iat : Bool,
                                  issuer : String?, audience : String?, subject : String?,
                                  leeway : Time::Span, now : Time) : Decoded
      allowed = {} of String => OpenSSL::Algorithm
      algorithms.each do |algorithm|
        if algorithm == :none
          raise InvalidAlgorithm.new("the 'none' algorithm is not allowed")
        end
        name, digest = algorithm_for(algorithm)
        allowed[name] = digest
      end
      raise InvalidAlgorithm.new("no algorithms allowed") if allowed.empty?

      parts = token.split('.')
      raise MalformedToken.new("a JWT must have three dot-separated segments") unless parts.size == 3
      encoded_header, encoded_payload, encoded_signature = parts
      if encoded_header.empty? || encoded_payload.empty? || encoded_signature.empty?
        raise MalformedToken.new("JWT segments must not be empty")
      end

      header = parse_object(base64url_decode(encoded_header), "header")
      payload = parse_object(base64url_decode(encoded_payload), "payload")

      alg = header["alg"]?.try(&.as_s?)
      raise MalformedToken.new("missing 'alg' header") if alg.nil?
      raise InvalidAlgorithm.new("the 'none' algorithm is not allowed") if alg.downcase == "none"

      digest_alg = allowed[alg.upcase]?
      raise InvalidAlgorithm.new("algorithm '#{alg}' is not allowed") if digest_alg.nil?

      signing_input = "#{encoded_header}.#{encoded_payload}"
      expected = hmac(digest_alg, key, signing_input)
      actual = base64url_decode(encoded_signature)
      unless Crypto::Subtle.constant_time_compare(expected, actual)
        raise InvalidSignature.new("signature verification failed")
      end

      leeway_seconds = leeway.total_seconds
      now_seconds = now.to_unix.to_f64

      if value = numeric_claim(payload, "exp")
        if verify_exp && now_seconds > value + leeway_seconds
          raise ExpiredSignature.new("token has expired")
        end
      end

      if value = numeric_claim(payload, "nbf")
        if verify_nbf && now_seconds + leeway_seconds < value
          raise NotYetValid.new("token is not valid yet")
        end
      end

      if value = numeric_claim(payload, "iat")
        if verify_iat && now_seconds + leeway_seconds < value
          raise InvalidClaim.new("'iat' is in the future")
        end
      end

      if wanted = issuer
        actual_issuer = payload["iss"]?.try(&.as_s?)
        unless actual_issuer && Crypto::Subtle.constant_time_compare(wanted, actual_issuer)
          raise InvalidClaim.new("'iss' does not match")
        end
      end

      if wanted = audience
        actual = payload["aud"]?
        matched = case raw = actual.try(&.raw)
                  when String
                    Crypto::Subtle.constant_time_compare(wanted, raw)
                  when Array
                    raw.any? do |entry|
                      candidate = entry.as_s?
                      candidate && Crypto::Subtle.constant_time_compare(wanted, candidate)
                    end
                  else
                    false
                  end
        raise InvalidClaim.new("'aud' does not match") unless matched
      end

      if wanted = subject
        actual_subject = payload["sub"]?.try(&.as_s?)
        unless actual_subject && Crypto::Subtle.constant_time_compare(wanted, actual_subject)
          raise InvalidClaim.new("'sub' does not match")
        end
      end

      Decoded.new(header, payload)
    end

    # Parses a numeric claim, rejecting non-numeric values outright.
    private def self.numeric_claim(payload : Hash(String, JSON::Any), name : String) : Float64?
      claim = payload[name]?
      return nil if claim.nil?
      raw = claim.raw
      case raw
      when Int
        raw.to_f64
      when Float
        raw
      else
        raise InvalidClaim.new("'#{name}' must be numeric")
      end
    end

    private def self.parse_object(bytes : Bytes, which : String) : Hash(String, JSON::Any)
      value = JSON.parse(String.new(bytes))
      hash = value.as_h?
      raise MalformedToken.new("JWT #{which} must be a JSON object") if hash.nil?
      hash
    rescue JSON::ParseException
      raise MalformedToken.new("JWT #{which} is not valid JSON")
    end

    private def self.algorithm_for(algorithm : Symbol) : Tuple(String, OpenSSL::Algorithm)
      case algorithm
      when :hs256 then {"HS256", OpenSSL::Algorithm::SHA256}
      when :hs384 then {"HS384", OpenSSL::Algorithm::SHA384}
      when :hs512 then {"HS512", OpenSSL::Algorithm::SHA512}
      when :none
        raise InvalidAlgorithm.new("the 'none' algorithm is not allowed")
      else
        raise InvalidAlgorithm.new("unsupported JWT algorithm: #{algorithm}")
      end
    end

    private def self.hmac(digest : OpenSSL::Algorithm, key : String | Bytes, data : String) : Bytes
      raise Error.new("JWT key must not be empty") if key.to_slice.empty?
      OpenSSL::HMAC.digest(digest, key, data)
    end

    # Converts common Crystal values to JSON::Any. Unknown objects fall back
    # to their string form, which keeps the API forgiving without requiring
    # a shard-specific serializer.
    private def self.json_any(value) : JSON::Any
      case value
      when JSON::Any
        value
      when String, Int32, Int64, Float64, Bool, Nil
        JSON::Any.new(value)
      when Int
        JSON::Any.new(value.to_i64)
      when Float
        JSON::Any.new(value)
      when Time
        JSON::Any.new(value.to_rfc3339)
      when Array
        JSON::Any.new(value.map { |item| json_any(item) })
      when Hash
        converted = {} of String => JSON::Any
        value.each { |name, item| converted[name.to_s] = json_any(item) }
        JSON::Any.new(converted)
      else
        JSON::Any.new(value.to_s)
      end
    end

    # Base64url without padding (RFC 7515 §2).
    def self.base64url_encode(data : Bytes) : String
      Base64.urlsafe_encode(data, false)
    end

    def self.base64url_decode(value : String) : Bytes
      raise MalformedToken.new("empty base64url segment") if value.empty?
      value.each_char do |char|
        unless char.ascii_alphanumeric? || char == '-' || char == '_'
          raise MalformedToken.new("invalid base64url character")
        end
      end
      padding = (4 - value.size % 4) % 4
      Base64.decode(value + "=" * padding)
    rescue ex : Base64::Error
      raise MalformedToken.new("invalid base64url encoding")
    end
  end
end
