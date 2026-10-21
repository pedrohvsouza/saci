require "./session_store"

module Saci
  # Values storable in sessions/flash (JSON-round-trippable scalars).
  alias SessionValue = String | Int32 | Int64 | Float64 | Bool | Nil

  # Cookie/`SessionStore`-backed session (`session[:user_id]`).
  #
  # The default store is `SessionStore::CookieStore`: the whole payload lives
  # in `_saci_session`, HMAC-signed with the app secret (AES-256-GCM encrypted
  # when `Session.encrypt = true`). Loaded lazily; written back only when
  # mutated. Enabling encryption invalidates previously signed sessions (no
  # downgrade fallback) — turn it on before launch (generated production envs
  # do).
  #
  # Server-side stores (`SessionStore::CacheStore`, `MemoryStore`,
  # `DatabaseStore`) keep only a signed session id in the cookie:
  #
  # ```
  # Saci::Session.store = Saci::SessionStore::CacheStore.new(expire_after: 2.hours)
  # # from a boot initializer:
  # # Saci::Session.store = Saci::SessionStore::DatabaseStore.new
  # ```
  #
  # # Session fixation
  #
  # `clear` rotates the session id and deletes the old server-side record.
  # `Controller#reset_session` calls it, and `Controller#login` already calls
  # `reset_session` before writing the user id — so logging in never reuses a
  # pre-authentication id. Call `session.rotate_id` explicitly in custom
  # authentication flows that do not use `Saci::Auth#login`.
  class Session
    COOKIE_KEY = "_saci_session"
    MAX_BYTES  = 4096

    @@encrypt : Bool = false
    @@encrypt_mutex = Mutex.new
    @@store : SessionStore = SessionStore::CookieStore.new
    @@store_mutex = Mutex.new

    # Whether session payloads are encrypted (opaque to clients) rather
    # than merely signed (readable, tamper-evident). Read live, so specs
    # and `APP_ENV` switches can toggle it freely.
    def self.encrypt : Bool
      @@encrypt_mutex.synchronize { @@encrypt }
    end

    def self.encrypt=(value : Bool) : Nil
      @@encrypt_mutex.synchronize { @@encrypt = value }
    end

    # Active session backend. Defaults to the historical encrypted/signed
    # cookie store; assign once during boot (before serving requests).
    def self.store : SessionStore
      @@store_mutex.synchronize { @@store }
    end

    def self.store=(store : SessionStore) : Nil
      @@store_mutex.synchronize { @@store = store }
    end

    # Restores the default cookie store (spec isolation).
    def self.reset! : Nil
      @@store_mutex.synchronize { @@store = SessionStore::CookieStore.new }
    end

    def self.generate_id : String
      SessionStore.generate_id
    end

    # Convenience delegates to the active store (configure before boot).
    def self.expire_after : Time::Span?
      store.expire_after
    end

    def self.expire_after=(value : Time::Span?) : Nil
      store.expire_after = value
    end

    def self.secure=(value : Bool) : Nil
      store.secure = value
    end

    def self.httponly=(value : Bool) : Nil
      store.httponly = value
    end

    def self.same_site=(value : Symbol?) : Nil
      store.same_site = value
    end

    def self.path=(value : String) : Nil
      store.path = value
    end

    def self.domain=(value : String?) : Nil
      store.domain = value
    end

    # Runs backend garbage collection (DB/Memory stores; cache TTLs do it
    # themselves). Safe to call periodically, e.g. from a recurring job.
    def self.gc : Int32
      store.gc
    end

    @data : Hash(String, JSON::Any)?
    @id : String?
    @loaded : Bool = false
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

    # Clears the data and rotates the session id (session-fixation defense).
    # The old server-side record is deleted; `commit!` writes an empty
    # session under the new id.
    def clear : Nil
      load_data.clear
      rotate_id
      @dirty = true
    end

    # Generates and returns a new session id, discarding the old backend
    # record. The new id is persisted on the next `commit!`.
    def rotate_id : String
      old_id = @id
      @id = self.class.generate_id
      self.class.store.destroy(old_id) if old_id
      @dirty = true
      @id.not_nil!
    end

    def regenerate_id : String
      rotate_id
    end

    # Session id (server-side stores use it as their key; the cookie store
    # exposes a stable per-request identifier but has no server state).
    def id : String?
      @id ||= self.class.generate_id
    end

    def key?(key : String | Symbol) : Bool
      load_data.has_key?(key.to_s)
    end

    def loaded? : Bool
      @loaded
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

    # Persists the session when mutated. Called by dispatch; the cookie
    # store raises `CookieOverflow` past the 4KB cookie limit (like Rails),
    # while server-side stores only put a short signed id in the cookie.
    def commit! : Nil
      return unless @dirty
      data = load_data
      id = @id ||= self.class.generate_id
      store = self.class.store
      payload = store.commit(id, data)
      if payload.bytesize > MAX_BYTES
        raise CookieOverflow.new("Session cookie exceeds #{MAX_BYTES} bytes — store less in session")
      end
      @cookies.write(COOKIE_KEY, payload,
        expires: store.cookie_expires_at,
        secure: store.secure,
        httponly: store.httponly,
        samesite: store.same_site,
        path: store.path,
        domain: store.domain)
      @dirty = false
    end

    # Rails-style alias used by integrations that persist explicitly.
    def persist! : Nil
      commit!
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
      return @data.not_nil! if @data
      raw = @cookies[COOKIE_KEY]
      if payload = self.class.store.load(raw)
        @id = payload.id
        @data = payload.data
      else
        @data = {} of String => JSON::Any
      end
      @loaded = true
      @data.not_nil!
    rescue
      @data = {} of String => JSON::Any
      @loaded = true
      @data.not_nil!
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
