require "base64"
require "json"
require "openssl/hmac"
require "crypto/subtle"

module Saci
  # Cookie configuration shared by every `CookieJar` (Rails
  # `config.action_dispatch.cookies_*` equivalent).
  #
  # ```
  # Saci::Cookies.serializer = :json          # default (:json / :hybrid)
  # Saci::Cookies.same_site_protection = :lax # default for plain cookies
  # Saci::Cookies.rotations = [old_secret]    # previous SECRET_KEY_BASEs
  # Saci::Cookies.max_value_bytes = 4096
  # ```
  #
  # Serializers:
  # * `:json` — values are JSON strings, both readable and unambiguous.
  # * `:hybrid` — writes JSON but also reads legacy raw values (use while
  #   migrating an app that wrote cookies before the serializer existed).
  # * `:marshal` — **not supported**: Crystal has no `Marshal`, and accepting
  #   Ruby-marshalled payloads would create a deserialization gadget surface.
  #   Assigning it raises `ArgumentError`.
  #
  # Rotations are previous `SECRET_KEY_BASE` values. Signed and encrypted
  # cookies verify against the current secret first, then every rotation;
  # when an old secret is used the jar rewrites the cookie with the current
  # secret (Rails' rotate-on-read behavior, next write uses the new secret).
  module Cookies
    MAX_VALUE_BYTES   = 4096
    DEFAULT_PURPOSE   = "cookie"
    SERIALIZERS       = [:json, :hybrid]
    UNSUPPORTED       = [:marshal]
    PURPOSE_SEPARATOR = "\u0000"

    @@mutex = Mutex.new
    @@serializer : Symbol = :json
    @@same_site_protection : Symbol? = :lax
    @@rotations = [] of String
    @@max_value_bytes : Int32 = MAX_VALUE_BYTES

    def self.serializer : Symbol
      @@mutex.synchronize { @@serializer }
    end

    def self.serializer=(mode : Symbol) : Nil
      normalized = normalize_serializer(mode)
      @@mutex.synchronize { @@serializer = normalized }
    end

    def self.serializer=(mode : String) : Nil
      self.serializer = normalize_serializer(mode)
    end

    # `nil` emits no SameSite attribute; `:lax`/`:strict`/`:none` otherwise.
    def self.same_site_protection : Symbol?
      @@mutex.synchronize { @@same_site_protection }
    end

    def self.same_site_protection=(value : Symbol?) : Nil
      validate_same_site!(value)
      @@mutex.synchronize { @@same_site_protection = value }
    end

    # Rails-style alias (`config.action_dispatch.cookies_same_site_protection`).
    def self.cookies_same_site_protection : Symbol?
      same_site_protection
    end

    def self.cookies_same_site_protection=(value : Symbol?) : Nil
      self.same_site_protection = value
    end

    # Previous secrets, oldest or newest first (order is irrelevant — all are
    # tried after the current secret).
    def self.rotations : Array(String)
      @@mutex.synchronize { @@rotations.dup }
    end

    def self.rotations=(values : Array(String)) : Nil
      @@mutex.synchronize { @@rotations = values.reject(&.empty?).dup }
    end

    # Rails-style alias (`config.action_dispatch.cookies_rotations`).
    def self.cookies_rotations : Array(String)
      rotations
    end

    def self.cookies_rotations=(values : Array(String)) : Nil
      self.rotations = values
    end

    def self.max_value_bytes : Int32
      @@mutex.synchronize { @@max_value_bytes }
    end

    def self.max_value_bytes=(value : Int32) : Nil
      raise ArgumentError.new("Cookies.max_value_bytes must be positive") if value < 1
      @@mutex.synchronize { @@max_value_bytes = value }
    end

    def self.reset! : Nil
      @@mutex.synchronize do
        @@serializer = :json
        @@same_site_protection = :lax
        @@rotations = [] of String
        @@max_value_bytes = MAX_VALUE_BYTES
      end
    end

    def self.normalize_serializer(mode : Symbol | String) : Symbol
      case mode
      when Symbol
        return mode if SERIALIZERS.includes?(mode)
        if UNSUPPORTED.includes?(mode)
          raise ArgumentError.new(
            "Cookie serializer #{mode.inspect} is not supported: Crystal has no Marshal. " \
            "Use :json (default) or :hybrid (JSON writes, legacy raw reads).")
        end
      when String
        case mode.downcase
        when "json"   then return :json
        when "hybrid" then return :hybrid
        when "marshal"
          raise ArgumentError.new(
            "Cookie serializer :marshal is not supported: Crystal has no Marshal. " \
            "Use :json (default) or :hybrid (JSON writes, legacy raw reads).")
        end
      end
      raise ArgumentError.new("Unknown cookie serializer #{mode.inspect} (expected :json or :hybrid)")
    end

    # `:marshal` is documented as unsupported; this helper makes that
    # explicit for callers that accept a serializer from configuration.
    def self.serializer_supported?(mode : Symbol | String) : Bool
      normalize_serializer(mode)
      true
    rescue ArgumentError
      false
    end

    def self.serialize(value : String, mode : Symbol) : String
      case normalize_serializer(mode)
      when :json, :hybrid then value.to_json
      else                     raise "unreachable cookie serializer"
      end
    end

    def self.deserialize(raw : String, mode : Symbol) : String?
      case normalize_serializer(mode)
      when :json
        parse_json_string(raw)
      when :hybrid
        parse_json_string(raw) || raw
      else
        nil
      end
    end

    private def self.parse_json_string(raw : String) : String?
      JSON.parse(raw).as_s?
    rescue
      nil
    end

    # Purpose scoping for signatures. The default `"cookie"` purpose keeps
    # the historical unscoped signature so previously issued signed cookies
    # remain readable; named purposes are scoped.
    private def self.scoped_payload(payload : String, purpose : String) : String
      purpose == DEFAULT_PURPOSE ? payload : "#{purpose}#{PURPOSE_SEPARATOR}#{payload}"
    end

    private def self.unscoped_payload(payload : String, purpose : String) : String?
      return payload if purpose == DEFAULT_PURPOSE
      prefix = "#{purpose}#{PURPOSE_SEPARATOR}"
      return nil unless payload.starts_with?(prefix)
      payload[prefix.bytesize..]
    end

    def self.sign(payload : String, purpose : String = DEFAULT_PURPOSE) : String
      sign_with_secret(payload, Secrets.secret_key_base, purpose)
    end

    # Exposed for rotation migrations/tests: signs `payload` with an
    # arbitrary previous secret using the same wire format as `Secrets.sign`.
    def self.sign_with_secret(payload : String, secret : String, purpose : String = DEFAULT_PURPOSE) : String
      encoded = Base64.urlsafe_encode(scoped_payload(payload, purpose), false)
      "#{encoded}--#{OpenSSL::HMAC.hexdigest(:sha256, secret, encoded)}"
    end

    # Verifies with the current secret, then rotations. Returns the payload
    # plus whether an old secret was used (so jars can rotate on read).
    def self.verify_signed_with_rotation(raw : String, purpose : String = DEFAULT_PURPOSE) : Tuple(String, Bool)?
      if payload = verify_signed_with_secret(raw, Secrets.secret_key_base, purpose)
        return {payload, false}
      end
      rotations.each do |secret|
        if payload = verify_signed_with_secret(raw, secret, purpose)
          return {payload, true}
        end
      end
      nil
    end

    def self.verify_signed(raw : String, purpose : String = DEFAULT_PURPOSE) : String?
      verify_signed_with_rotation(raw, purpose).try(&.[0])
    end

    # Returns the payload when `raw` was signed with `secret`, else nil.
    def self.verify_signed_with_secret(raw : String, secret : String, purpose : String = DEFAULT_PURPOSE) : String?
      # Signature is fixed-width SHA256 hex; split from the right so "--"
      # inside the payload encoding cannot confuse parsing.
      return nil if raw.bytesize < 67
      signature = raw[-64..]
      return nil unless raw[-66...-64] == "--"
      encoded = raw[0...-66]
      return nil if encoded.empty?
      expected = OpenSSL::HMAC.hexdigest(:sha256, secret, encoded)
      return nil unless Crypto::Subtle.constant_time_compare(expected, signature)
      unscoped_payload(String.new(Base64.decode(encoded)), purpose)
    rescue
      nil
    end

    # Derives the same 32-byte purpose key as `Secrets.encrypted_key`, but
    # for a rotation secret.
    def self.derive_key(secret : String, purpose : String = DEFAULT_PURPOSE) : Bytes
      OpenSSL::HMAC.digest(:sha256, secret, "saci-encrypted-v1/#{purpose}")
    end

    def self.encrypt(payload : String, purpose : String = DEFAULT_PURPOSE) : String
      MessageEncryptor.encrypt_and_sign(Secrets.encrypted_key(purpose), payload.to_slice)
    end

    def self.encrypt_with_secret(payload : String, secret : String, purpose : String = DEFAULT_PURPOSE) : String
      MessageEncryptor.encrypt_and_sign(derive_key(secret, purpose), payload.to_slice)
    end

    # Ciphertexts already verified with the current key, and their
    # plaintext: a browser sends the same session cookie on every request,
    # and each AES-GCM open costs a full OpenSSL cipher setup. Only exact
    # ciphertexts that decrypted under the key in use are served from here
    # (the key is part of the entry, so a new secret misses), and only for
    # the primary secret.
    DECRYPTED_CACHE_SIZE = 8192
    @@decrypted = {} of {String, String} => {Bytes, String}
    @@decrypted_mutex = Mutex.new

    def self.decrypt_with_rotation(raw : String, purpose : String = DEFAULT_PURPOSE) : Tuple(String, Bool)?
      key = Secrets.encrypted_key(purpose)
      cache_key = {purpose, raw}
      if hit = @@decrypted_mutex.synchronize { @@decrypted[cache_key]? }
        return {hit[1], false} if hit[0] == key
      end
      begin
        plaintext = String.new(MessageEncryptor.decrypt_and_verify(key, raw))
        @@decrypted_mutex.synchronize do
          @@decrypted.clear if @@decrypted.size >= DECRYPTED_CACHE_SIZE
          @@decrypted[cache_key] = {key, plaintext}
        end
        return {plaintext, false}
      rescue
      end
      rotations.each do |secret|
        begin
          return {String.new(MessageEncryptor.decrypt_and_verify(derive_key(secret, purpose), raw)), true}
        rescue
        end
      end
      nil
    end

    def self.decrypt(raw : String, purpose : String = DEFAULT_PURPOSE) : String?
      decrypt_with_rotation(raw, purpose).try(&.[0])
    end

    private def self.validate_same_site!(value : Symbol?) : Nil
      return if value.nil?
      unless {:lax, :strict, :none}.includes?(value)
        raise ArgumentError.new("Unknown SameSite #{value.inspect} (expected :lax, :strict, :none or nil)")
      end
    end
  end

  # Rails-like cookie jar, exposed as `cookies` in controllers.
  #
  # ```
  # cookies[:theme] = "dark"
  # cookies.write(:theme, "dark", expires: 30.days, secure: true)
  # cookies.signed[:user_id] = user.id.to_s
  # cookies.signed(purpose: "remember", serializer: :hybrid)[:token] = "abc"
  # cookies.encrypted[:token] = "secret-value"
  # cookies.permanent[:ref] = "campaign"
  # cookies.delete(:theme)
  # ```
  class CookieJar
    def initialize(@request : HTTP::Request, @response : HTTP::Server::Response)
    end

    def [](name : String | Symbol) : String?
      @request.cookies[name.to_s]?.try(&.value)
    end

    def []=(name : String | Symbol, value : String) : Nil
      write(name, value)
    end

    # `samesite: nil` uses `Cookies.same_site_protection` (default `:lax`);
    # pass `:strict` / `:none` to override for a single cookie.
    def write(name : String | Symbol, value : String, expires : Time? = nil, path : String = "/", domain : String? = nil, secure : Bool = false, httponly : Bool = true, samesite : Symbol? = nil) : Nil
      limit = Cookies.max_value_bytes
      if value.bytesize > limit
        raise CookieOverflow.new(
          "Cookie #{name} value is #{value.bytesize} bytes; the configured maximum is #{limit} bytes. " \
          "Store less data, or move the payload to a server-side store (e.g. Saci::Session.store = Saci::SessionStore::CacheStore.new).")
      end
      same_site = samesite.nil? ? Cookies.same_site_protection : samesite
      cookie = HTTP::Cookie.new(name.to_s, value, path: path, expires: expires, domain: domain, secure: secure, http_only: httponly, samesite: same_site_value(same_site))
      @response.cookies << cookie
    end

    def delete(name : String | Symbol) : Nil
      cookie = HTTP::Cookie.new(name.to_s, "", path: "/", expires: Time.utc - 1.day)
      @response.cookies << cookie
    end

    def signed(purpose : String = Cookies::DEFAULT_PURPOSE, serializer : Symbol? = nil) : SignedJar
      SignedJar.new(self, purpose, serializer)
    end

    def encrypted(purpose : String = Cookies::DEFAULT_PURPOSE, serializer : Symbol? = nil) : EncryptedJar
      EncryptedJar.new(self, purpose, serializer)
    end

    # Twenty-year cookies (Rails `cookies.permanent`).
    def permanent : PermanentJar
      PermanentJar.new(self)
    end

    private def same_site_value(value : Symbol?) : HTTP::Cookie::SameSite?
      case value
      when nil     then nil
      when :lax    then HTTP::Cookie::SameSite::Lax
      when :strict then HTTP::Cookie::SameSite::Strict
      when :none   then HTTP::Cookie::SameSite::None
      else              raise ArgumentError.new("Unknown samesite #{value.inspect} (expected :lax, :strict or :none)")
      end
    end
  end

  # Plain cookies with a twenty-year expiry.
  class PermanentJar
    TWENTY_YEARS = 20 * 365 * 24 * 60 * 60

    def initialize(@jar : CookieJar)
    end

    def [](name : String | Symbol) : String?
      @jar[name]
    end

    def []=(name : String | Symbol, value : String) : Nil
      @jar.write(name, value, expires: Time.utc + TWENTY_YEARS.seconds)
    end

    def delete(name : String | Symbol) : Nil
      @jar.delete(name)
    end
  end

  # HMAC-signed cookies (`cookies.signed`). Tampered values read as nil.
  # Values are serialized with `Cookies.serializer` unless `serializer:` is
  # passed. A `purpose:` scopes the signature so one jar cannot read values
  # from another.
  class SignedJar
    def initialize(@jar : CookieJar, @purpose : String = Cookies::DEFAULT_PURPOSE, @serializer : Symbol? = nil)
    end

    def [](name : String | Symbol) : String?
      raw = @jar[name.to_s]
      return nil unless raw
      found = Cookies.verify_signed_with_rotation(raw, @purpose)
      return nil unless found
      value = Cookies.deserialize(found[0], serializer)
      rotate_on_read(name, value) if found[1] && value
      value
    end

    def []=(name : String | Symbol, value : String) : Nil
      @jar.write(name.to_s, Cookies.sign(Cookies.serialize(value, serializer), @purpose))
    end

    def delete(name : String | Symbol) : Nil
      @jar.delete(name)
    end

    private def serializer : Symbol
      Cookies.normalize_serializer(@serializer || Cookies.serializer)
    end

    private def rotate_on_read(name : String | Symbol, value : String) : Nil
      self[name] = value
    end
  end

  # AES-256-GCM encrypted cookies (`cookies.encrypted`). Values are opaque
  # to the client; tampered or undecryptable values read as nil. Keyed per
  # purpose (`"cookie"` by default), so session payloads never decrypt as
  # cookies. Old rotation secrets are accepted and the value is re-encrypted
  # with the current secret on read.
  class EncryptedJar
    def initialize(@jar : CookieJar, @purpose : String = Cookies::DEFAULT_PURPOSE, @serializer : Symbol? = nil)
    end

    def [](name : String | Symbol) : String?
      raw = @jar[name.to_s]
      return nil unless raw
      found = Cookies.decrypt_with_rotation(raw, @purpose)
      return nil unless found
      value = Cookies.deserialize(found[0], serializer)
      rotate_on_read(name, value) if found[1] && value
      value
    end

    def []=(name : String | Symbol, value : String) : Nil
      @jar.write(name.to_s, Cookies.encrypt(Cookies.serialize(value, serializer), @purpose))
    end

    def delete(name : String | Symbol) : Nil
      @jar.delete(name)
    end

    private def serializer : Symbol
      Cookies.normalize_serializer(@serializer || Cookies.serializer)
    end

    private def rotate_on_read(name : String | Symbol, value : String) : Nil
      self[name] = value
    end
  end
end
