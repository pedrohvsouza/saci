module Saci
  # Rails-like cookie jar, exposed as `cookies` in controllers.
  #
  # ```
  # cookies[:theme] = "dark"
  # cookies.write(:theme, "dark", expires: 30.days, secure: true)
  # cookies.signed[:user_id] = user.id.to_s
  # cookies.encrypted[:token] = "secret-value"
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

    def write(name : String | Symbol, value : String, expires : Time? = nil, path : String = "/", domain : String? = nil, secure : Bool = false, httponly : Bool = true, samesite : Symbol? = nil) : Nil
      cookie = HTTP::Cookie.new(name.to_s, value, path: path, expires: expires, domain: domain, secure: secure, http_only: httponly, samesite: same_site(samesite))
      @response.cookies << cookie
    end

    def delete(name : String | Symbol) : Nil
      cookie = HTTP::Cookie.new(name.to_s, "", path: "/", expires: Time.utc - 1.day)
      @response.cookies << cookie
    end

    def signed : SignedJar
      SignedJar.new(self)
    end

    def encrypted : EncryptedJar
      EncryptedJar.new(self)
    end

    private def same_site(value : Symbol?) : HTTP::Cookie::SameSite?
      case value
      when nil     then nil
      when :lax    then HTTP::Cookie::SameSite::Lax
      when :strict then HTTP::Cookie::SameSite::Strict
      when :none   then HTTP::Cookie::SameSite::None
      else              raise ArgumentError.new("Unknown samesite #{value.inspect} (expected :lax, :strict or :none)")
      end
    end
  end

  # HMAC-signed cookies (`cookies.signed`). Tampered values read as nil.
  class SignedJar
    def initialize(@jar : CookieJar)
    end

    def [](name : String | Symbol) : String?
      raw = @jar[name.to_s]
      raw ? Secrets.verify_signed(raw) : nil
    end

    def []=(name : String | Symbol, value : String) : Nil
      @jar.write(name.to_s, Secrets.sign(value))
    end

    def delete(name : String | Symbol) : Nil
      @jar.delete(name)
    end
  end

  # AES-256-GCM encrypted cookies (`cookies.encrypted`). Values are opaque
  # to the client; tampered or undecryptable values read as nil. Keyed per
  # purpose (`"cookie"`), so session payloads never decrypt as cookies.
  class EncryptedJar
    def initialize(@jar : CookieJar, @purpose : String = "cookie")
    end

    def [](name : String | Symbol) : String?
      raw = @jar[name.to_s]
      return nil unless raw
      String.new(MessageEncryptor.decrypt_and_verify(Secrets.encrypted_key(@purpose), raw))
    rescue
      nil
    end

    def []=(name : String | Symbol, value : String) : Nil
      @jar.write(name.to_s, MessageEncryptor.encrypt_and_sign(Secrets.encrypted_key(@purpose), value.to_slice))
    end

    def delete(name : String | Symbol) : Nil
      @jar.delete(name)
    end
  end
end
