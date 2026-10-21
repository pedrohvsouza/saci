require "base64"
require "json"
require "db"
require "random/secure"

module Saci
  # Loaded session state: an optional server-side id plus the JSON data.
  struct SessionPayload
    getter id : String?
    getter data : Hash(String, JSON::Any)

    def initialize(@id : String?, @data : Hash(String, JSON::Any))
    end
  end

  # Pluggable session backend (`Saci::Session.store = ...`).
  #
  # The default is `CookieStore` — the historical Saci behavior (signed, or
  # AES-256-GCM encrypted when `Session.encrypt = true`, JSON payload in
  # `_saci_session`). `CacheStore` keeps only a signed session id in the
  # cookie and stores data in `Saci::Cache` (memory or Redis). `MemoryStore`
  # is a self-contained in-process store with lazy expiry/GC. `DatabaseStore`
  # uses a `saci_sessions` table (`id`, `data`, `updated_at` epoch milliseconds)
  # and works on SQLite/PostgreSQL/MySQL through `Saci::Record`'s adapter-aware
  # execution helpers.
  #
  # ```
  # Saci::Session.store = Saci::SessionStore::CookieStore.new(
  #   expire_after: 2.hours, secure: true, httponly: true,
  #   same_site: :lax, path: "/", domain: nil)
  #
  # Saci::Session.store = Saci::SessionStore::CacheStore.new(expire_after: 30.minutes)
  # Saci::Session.store = Saci::SessionStore::DatabaseStore.new # Saci::Record.connection
  # ```
  #
  # Cookie attributes (`secure`, `httponly`, `same_site`, `path`, `domain`)
  # apply to every store. `expire_after` sets both the server-side TTL and
  # the cookie expiry.
  abstract class SessionStore
    property expire_after : Time::Span?
    property secure : Bool
    property httponly : Bool
    property same_site : Symbol?
    property path : String
    property domain : String?

    def initialize(@expire_after : Time::Span? = nil, @secure : Bool = false,
                   @httponly : Bool = true, @same_site : Symbol? = :lax,
                   @path : String = "/", @domain : String? = nil)
      validate_same_site!(@same_site)
    end

    # Browser expiry for the session cookie; nil means a session cookie.
    def cookie_expires_at : Time?
      @expire_after.try { |span| Time.utc + span }
    end

    def self.generate_id : String
      Random::Secure.urlsafe_base64(32)
    end

    # 32 random bytes, URL-safe base64 (no padding).
    def generate_id : String
      SessionStore.generate_id
    end

    # Parses the cookie payload produced by `commit`. Returns nil for a
    # missing/tampered/expired session.
    abstract def load(payload : String?) : SessionPayload?

    # Persists `data` under `id` and returns the cookie payload to write.
    abstract def commit(id : String, data : Hash(String, JSON::Any)) : String

    # Removes the server-side session, if any.
    abstract def destroy(id : String?) : Nil

    # Removes every session owned by this store (specs/ops).
    abstract def clear : Nil

    # Drops expired entries, returning how many were removed.
    abstract def gc : Int32

    protected def encode_id(id : String) : String
      Secrets.sign("sid:#{id}")
    end

    protected def decode_id(payload : String?) : String?
      return nil unless payload
      raw = Secrets.verify_signed(payload)
      return nil unless raw && raw.starts_with?("sid:")
      id = raw[4..]
      id.empty? ? nil : id
    end

    protected def validate_same_site!(value : Symbol?) : Nil
      return if value.nil?
      unless {:lax, :strict, :none}.includes?(value)
        raise ArgumentError.new("Unknown SameSite #{value.inspect} (expected :lax, :strict, :none or nil)")
      end
    end

    # Historical cookie store: the payload is the session itself, signed or
    # (when `Session.encrypt` is on) AES-GCM encrypted.
    class CookieStore < SessionStore
      MAX_BYTES = 4096

      def load(payload : String?) : SessionPayload?
        return nil unless payload
        json = if Session.encrypt
                 begin
                   String.new(MessageEncryptor.decrypt_and_verify(Secrets.encrypted_key("session"), payload))
                 rescue
                   nil
                 end
               else
                 Secrets.verify_signed(payload)
               end
        return nil unless json
        data = JSON.parse(json).as_h
        SessionPayload.new(nil, data)
      rescue
        nil
      end

      def commit(id : String, data : Hash(String, JSON::Any)) : String
        json = data.to_json
        payload = if Session.encrypt
                    MessageEncryptor.encrypt_and_sign(Secrets.encrypted_key("session"), json.to_slice)
                  else
                    Secrets.sign(json)
                  end
        if payload.bytesize > MAX_BYTES
          raise CookieOverflow.new(
            "Session cookie exceeds #{MAX_BYTES} bytes — store less in the session " \
            "(or configure Saci::Session.store = Saci::SessionStore::CacheStore.new)")
        end
        payload
      end

      def destroy(id : String?) : Nil
      end

      def clear : Nil
      end

      def gc : Int32
        0
      end
    end

    # In-process sessions keyed by a signed id. Entries expire lazily (on
    # read) and `gc` removes them eagerly; no external dependency.
    class MemoryStore < SessionStore
      private struct Entry
        getter json : String
        getter expires_at : Time?

        def initialize(@json : String, @expires_at : Time?)
        end

        def expired?(now : Time) : Bool
          exp = @expires_at
          exp.nil? ? false : now >= exp
        end
      end

      @entries = {} of String => Entry
      @mutex = Mutex.new

      def load(payload : String?) : SessionPayload?
        id = decode_id(payload)
        return nil unless id
        json = @mutex.synchronize do
          if entry = @entries[id]?
            if entry.expired?(Time.utc)
              @entries.delete(id)
              nil
            else
              entry.json
            end
          end
        end
        return nil unless json
        SessionPayload.new(id, JSON.parse(json).as_h)
      rescue
        nil
      end

      def commit(id : String, data : Hash(String, JSON::Any)) : String
        json = data.to_json
        expires = @expire_after.try { |span| Time.utc + span }
        @mutex.synchronize { @entries[id] = Entry.new(json, expires) }
        encode_id(id)
      end

      def destroy(id : String?) : Nil
        return unless id
        @mutex.synchronize { @entries.delete(id) }
      end

      def clear : Nil
        @mutex.synchronize { @entries.clear }
      end

      def gc : Int32
        now = Time.utc
        @mutex.synchronize do
          before = @entries.size
          @entries.reject! { |_, entry| entry.expired?(now) }
          before - @entries.size
        end
      end
    end

    # Sessions in `Saci::Cache` (shared across processes with
    # `Saci::Cache::RedisStore`). The cache's own TTL performs expiry, so
    # `gc` is a no-op returning 0; replacing the cache drops sessions.
    class CacheStore < SessionStore
      def initialize(@cache : Cache::Store? = nil, @namespace : String = "session",
                     expire_after : Time::Span? = nil, secure : Bool = false,
                     httponly : Bool = true, same_site : Symbol? = :lax,
                     path : String = "/", domain : String? = nil)
        super(expire_after, secure, httponly, same_site, path, domain)
      end

      def load(payload : String?) : SessionPayload?
        id = decode_id(payload)
        return nil unless id
        raw = store.read(key_for(id))
        return nil unless raw
        SessionPayload.new(id, JSON.parse(raw).as_h)
      rescue
        nil
      end

      def commit(id : String, data : Hash(String, JSON::Any)) : String
        store.write(key_for(id), data.to_json, expires_in: @expire_after)
        encode_id(id)
      end

      def destroy(id : String?) : Nil
        return unless id
        store.delete(key_for(id))
      end

      # Cache entries are shared with the rest of the app; clearing the whole
      # cache here would delete unrelated fragments. Sessions expire by TTL.
      def clear : Nil
      end

      def gc : Int32
        0
      end

      private def store : Cache::Store
        @cache || Cache.store
      end

      private def key_for(id : String) : String
        "#{@namespace}:#{id}"
      end
    end

    # Database-backed sessions. Table shape (created lazily):
    #
    # ```sql
    # CREATE TABLE saci_sessions (
    #   id VARCHAR(255) PRIMARY KEY,
    #   data TEXT NOT NULL,
    #   updated_at BIGINT NOT NULL   -- epoch milliseconds
    # )
    # ```
    #
    # Pass a connection explicitly, or let the store use
    # `Saci::Record.connection`; `url:` opens (and owns) a raw `DB` handle
    # when the ORM is not configured. SQL identifiers are quoted per adapter
    # and placeholders are rewritten for PostgreSQL by `Saci::Record`.
    class DatabaseStore < SessionStore
      DEFAULT_TABLE = "saci_sessions"

      @table_ready = false
      @table_mutex = Mutex.new
      @owned_connection = false

      def initialize(connection : DB::Database | DB::Connection? = nil,
                     @table : String = DEFAULT_TABLE,
                     @adapter : Symbol? = nil,
                     url : String? = nil,
                     expire_after : Time::Span? = nil, secure : Bool = false,
                     httponly : Bool = true, same_site : Symbol? = :lax,
                     path : String = "/", domain : String? = nil)
        super(expire_after, secure, httponly, same_site, path, domain)
        @connection = connection
        if url
          @connection = DB.open(url)
          @owned_connection = true
          @adapter ||= Saci::Record.adapter_for_url(url)
        end
      end

      def load(payload : String?) : SessionPayload?
        id = decode_id(payload)
        return nil unless id
        ensure_table
        args = [] of Saci::Record::Value
        args << id
        sql = "SELECT #{quote("data")} FROM #{qualified_table} WHERE #{quote("id")} = ?"
        if cutoff = expiry_cutoff
          sql += " AND #{quote("updated_at")} >= ?"
          args << cutoff
        end
        raw = nil
        Saci::Record.query_compat(connection, sql, args) do |rs|
          rs.each { raw = rs.read(String) }
        end
        return nil unless raw
        SessionPayload.new(id, JSON.parse(raw.not_nil!).as_h)
      rescue
        nil
      end

      def commit(id : String, data : Hash(String, JSON::Any)) : String
        ensure_table
        json = data.to_json
        now = Time.utc.to_unix_ms
        update_args = [] of Saci::Record::Value
        update_args << json
        update_args << now
        update_args << id
        result = Saci::Record.exec_compat(connection,
          "UPDATE #{qualified_table} SET #{quote("data")} = ?, #{quote("updated_at")} = ? WHERE #{quote("id")} = ?",
          update_args)
        if result.rows_affected == 0
          insert_args = [] of Saci::Record::Value
          insert_args << id
          insert_args << json
          insert_args << now
          begin
            Saci::Record.exec_compat(connection,
              "INSERT INTO #{qualified_table} (#{quote("id")}, #{quote("data")}, #{quote("updated_at")}) VALUES (?, ?, ?)",
              insert_args)
          rescue
            # A concurrent request inserted the row between UPDATE and
            # INSERT; the row is equivalent, update it instead.
            Saci::Record.exec_compat(connection,
              "UPDATE #{qualified_table} SET #{quote("data")} = ?, #{quote("updated_at")} = ? WHERE #{quote("id")} = ?",
              update_args)
          end
        end
        encode_id(id)
      end

      def destroy(id : String?) : Nil
        return unless id
        ensure_table
        args = [] of Saci::Record::Value
        args << id
        Saci::Record.exec_compat(connection,
          "DELETE FROM #{qualified_table} WHERE #{quote("id")} = ?", args)
      end

      def clear : Nil
        ensure_table
        Saci::Record.exec_compat(connection, "DELETE FROM #{qualified_table}")
      end

      def gc : Int32
        cutoff = expiry_cutoff
        return 0 unless cutoff
        ensure_table
        args = [] of Saci::Record::Value
        args << cutoff
        result = Saci::Record.exec_compat(connection,
          "DELETE FROM #{qualified_table} WHERE #{quote("updated_at")} < ?", args)
        result.rows_affected.to_i32
      end

      # Closes a connection opened by `url:` (no-op for injected handles).
      def close : Nil
        @connection.try(&.close) if @owned_connection
      end

      private def connection : DB::Database | DB::Connection
        if conn = @connection
          return conn
        end
        begin
          @connection = Saci::Record.connection
          return @connection.not_nil!
        rescue ex
          if url = ENV["DATABASE_URL"]?
            opened = DB.open(url)
            @connection = opened
            @owned_connection = true
            @adapter ||= Saci::Record.adapter_for_url(url)
            return opened
          end
          raise "Saci::SessionStore::DatabaseStore: no database connection. " \
                "Assign Saci::Record.connection, pass `connection:`, or pass `url:`. (#{ex.message})"
        end
      end

      private def adapter : Symbol
        @adapter ||= Saci::Record.adapter_of(connection)
      end

      private def quote(identifier : String) : String
        Saci::Record.quote(identifier, adapter)
      end

      private def qualified_table : String
        quote(@table)
      end

      private def expiry_cutoff : Int64?
        @expire_after.try { |span| (Time.utc - span).to_unix_ms }
      end

      private def ensure_table : Nil
        return if @table_ready
        @table_mutex.synchronize do
          return if @table_ready
          Saci::Record.exec_compat(connection,
            "CREATE TABLE IF NOT EXISTS #{qualified_table} (" \
            "#{quote("id")} VARCHAR(255) PRIMARY KEY, " \
            "#{quote("data")} TEXT NOT NULL, " \
            "#{quote("updated_at")} BIGINT NOT NULL)")
          @table_ready = true
        end
      end
    end
  end
end
