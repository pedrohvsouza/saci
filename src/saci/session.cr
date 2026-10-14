module Saci
  # Values storable in sessions/flash (JSON-round-trippable scalars).
  alias SessionValue = String | Int32 | Int64 | Float64 | Bool | Nil

  # Cookie-store session (`session[:user_id]`), HMAC-signed with the app
  # secret by default, AES-256-GCM encrypted when `Session.encrypt = true`.
  # Loaded lazily; written back only when mutated. Enabling encryption
  # invalidates previously signed sessions (no downgrade fallback) — turn
  # it on before launch (generated production envs do).
  class Session
    COOKIE_KEY = "_saci_session"
    MAX_BYTES  = 4096

    @@encrypt : Bool = false
    @@encrypt_mutex = Mutex.new

    # Whether session payloads are encrypted (opaque to clients) rather
    # than merely signed (readable, tamper-evident). Read live, so specs
    # and `APP_ENV` switches can toggle it freely.
    def self.encrypt : Bool
      @@encrypt_mutex.synchronize { @@encrypt }
    end

    def self.encrypt=(value : Bool) : Nil
      @@encrypt_mutex.synchronize { @@encrypt = value }
    end

    @data : Hash(String, JSON::Any)?
    @dirty : Bool = false

    def initialize(@cookies : CookieJar)
    end

    def [](key : String | Symbol) : JSON::Any?
      load_data[key.to_s]?
    end

    def []=(key : String | Symbol, value : SessionValue) : Nil
      load_data[key.to_s] = Session.wrap(value)
      @dirty = true
    end

    def []=(key : String | Symbol, value : JSON::Any) : Nil
      load_data[key.to_s] = value
      @dirty = true
    end

    def delete(key : String | Symbol) : Nil
      load_data.delete(key.to_s)
      @dirty = true
    end

    # Removes and returns the value, if present.
    def take(key : String | Symbol) : JSON::Any?
      data = load_data
      if data.has_key?(key.to_s)
        @dirty = true
        data.delete(key.to_s)
      end
    end

    def clear : Nil
      load_data.clear
      @dirty = true
    end

    def string(key : String | Symbol) : String?
      raw = self[key].try(&.raw)
      raw.nil? ? nil : raw.to_s
    end

    def int(key : String | Symbol) : Int64?
      case raw = self[key].try(&.raw)
      when Nil    then nil
      when Int    then raw.to_i64
      when String then raw.to_i64?
      when Bool   then raw ? 1_i64 : 0_i64
      else             nil
      end
    end

    def bool(key : String | Symbol) : Bool?
      case raw = self[key].try(&.raw)
      when Nil    then nil
      when Bool   then raw
      when Int    then raw != 0
      when String then !{"false", "f", "no", "n", "0", ""}.includes?(raw.strip.downcase)
      else             nil
      end
    end

    def touched? : Bool
      @dirty
    end

    # Persists the session when mutated. Called by dispatch; raises
    # `CookieOverflow` past the 4KB cookie limit (like Rails).
    def commit! : Nil
      return unless @dirty
      encoded = if self.class.encrypt
                  MessageEncryptor.encrypt_and_sign(Secrets.encrypted_key("session"), load_data.to_json.to_slice)
                else
                  Secrets.sign(load_data.to_json)
                end
      if encoded.bytesize > MAX_BYTES
        raise CookieOverflow.new("Session cookie exceeds #{MAX_BYTES} bytes — store less in session")
      end
      @cookies.write(COOKIE_KEY, encoded, httponly: true, samesite: :lax)
    end

    def self.wrap(value : SessionValue) : JSON::Any
      case value
      when String       then JSON::Any.new(value)
      when Int32, Int64 then JSON::Any.new(value.to_i64)
      when Float64      then JSON::Any.new(value)
      when Bool         then JSON::Any.new(value)
      when Nil          then JSON::Any.new(nil)
      else                   raise "unreachable session value"
      end
    end

    private def load_data : Hash(String, JSON::Any)
      @data ||= begin
        raw = @cookies[COOKIE_KEY]
        json = if raw
                 if self.class.encrypt
                   begin
                     String.new(MessageEncryptor.decrypt_and_verify(Secrets.encrypted_key("session"), raw))
                   rescue
                     nil
                   end
                 else
                   Secrets.verify_signed(raw)
                 end
               end
        if json
          JSON.parse(json).as_h
        else
          {} of String => JSON::Any
        end
      rescue
        {} of String => JSON::Any
      end
    end
  end

  # Rails-like flash: `flash[:notice] = "x"` survives one redirect,
  # `flash.now` is visible only in the current request.
  class Flash
    def initialize(@session : Session)
      @now = {} of String => JSON::Any
      @next = {} of String => JSON::Any
      if stored = @session.take("_flash")
        stored.as_h?.try { |hash| hash.each { |key, value| @now[key] = value } }
      end
    end

    def [](key : String | Symbol) : JSON::Any?
      @now[key.to_s]? || @next[key.to_s]?
    end

    def []=(key : String | Symbol, value : SessionValue) : Nil
      @next[key.to_s] = Session.wrap(value)
    end

    def now : NowFlash
      @now_flash ||= NowFlash.new(@now)
    end

    def clear : Nil
      @now.clear
      @next.clear
    end

    def empty? : Bool
      @now.empty? && @next.empty?
    end

    # Carries new entries into the session for the next request.
    def commit! : Nil
      @session["_flash"] = JSON::Any.new(@next) unless @next.empty?
    end

    class NowFlash
      def initialize(@store : Hash(String, JSON::Any))
      end

      def [](key : String | Symbol) : JSON::Any?
        @store[key.to_s]?
      end

      def []=(key : String | Symbol, value : SessionValue) : Nil
        @store[key.to_s] = Session.wrap(value)
      end
    end
  end
end
