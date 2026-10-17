require "mutex"

module Saci
  # General-purpose cache (`Rails.cache` equivalent).
  #
  # ```
  # Saci::Cache.write("greeting", "hello", expires_in: 60.seconds)
  # Saci::Cache.read("greeting")                    # => "hello"
  # Saci::Cache.fetch("expensive", expires_in: 5.minutes) { compute }
  #
  # # Multi-process deploys share entries over Redis — same vendored
  # # pure-socket RESP2 client as Cable/Throttle, no new link requirements:
  # Saci::Cache.store = Saci::Cache::RedisStore.new(ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379"))
  # ```
  #
  # The String fast-path (`read`/`write`/`fetch` with `String`) is the
  # primary API and the frozen contract another track (fragment caching)
  # builds on — do not rename it. Typed values (`Int64`, `Float64`,
  # `Bool`, `Time`, `Nil`) round-trip through secondary overloads
  # (`write` accepts them, `read_value`/`fetch_value` return them) via an
  # explicit type-tagged encoding (`"S:<raw>"`, `"I:<n>"`, `"F:<f>"`,
  # `"B:0|1"`, `"T:<unix_ns>"`, `"N:"`), so there is no `Marshal` and no
  # deserialization gadget surface. Values that arrive untagged (written
  # by another client) decode as plain `String`s.
  #
  # Fail behavior: `MemoryStore` never fails; `RedisStore` raises
  # `Saci::Cache::RedisDown` on connection failure (callers decide
  # fail-open — fragment caching rescues to a miss).
  module Cache
    # Raised by `RedisStore` when the Redis hop is unreachable (direct
    # calls surface it; module-level helpers let it propagate too —
    # rescue to a miss when fail-open is what you want).
    class RedisDown < Exception
    end

    # Every storable value. `Int`/`Float` (any width) are accepted by
    # `write` and normalized to `Int64`/`Float64`.
    alias Value = String | Int64 | Float64 | Bool | Time | Nil

    # Storage backend. `MemoryStore` is the default (single process);
    # `RedisStore` shares entries across processes.
    abstract class Store
      property namespace : String = ""

      abstract def read(key : String) : String?
      abstract def read_value(key : String) : Value
      abstract def write(key : String, value : String | Int | Float | Bool | Time | Nil, expires_in : Time::Span? = nil) : Bool
      abstract def delete(key : String) : Bool
      abstract def exist?(key : String) : Bool
      abstract def clear : Nil
      abstract def increment(key : String, by : Int = 1) : Int64
      abstract def fetch(key : String, expires_in : Time::Span? = nil, &block : -> String) : String
      abstract def fetch_value(key : String, expires_in : Time::Span? = nil, &block : -> Value) : Value

      # Prefixes `key` with the store namespace (`""` by default).
      protected def namespaced(key : String) : String
        ns = @namespace
        ns.empty? ? key : "#{ns}:#{key}"
      end

      # Shared type-tagged encoding (spec-pinned round-trips).
      protected def encode(value : Value) : String
        case value
        when String then "S:#{value}"
        when Int    then "I:#{value.to_i64}"
        when Float  then "F:#{value.to_f64}"
        when Bool   then value ? "B:1" : "B:0"
        when Time   then "T:#{value.to_unix_ns}"
        when Nil    then "N:"
        else             "S:#{value}"
        end
      end

      # Untagged or unknown-tag payloads decode as plain Strings, so
      # keys written by other clients stay readable.
      protected def decode(raw : String) : Value
        if raw.size >= 2 && raw[1] == ':'
          payload = raw[2..]
          case raw[0]
          when 'S' then return payload
          when 'I' then return payload.to_i64? || raw
          when 'F' then return payload.to_f64? || raw
          when 'B' then return payload == "1"
          when 'T'
            if ns = payload.to_i64?
              return Time.unix_ns(ns)
            end
            return raw
          when 'N' then return nil
          end
        end
        raw
      end

      # `Time::Span` → whole EX seconds (>= 1). Nil stays nil.
      protected def expiry_secs(expires_in : Time::Span?) : Int32?
        return nil if expires_in.nil?
        secs = expires_in.total_seconds.to_i
        secs < 1 ? 1 : secs.to_i32
      end
    end

    # In-process entries (the default backend). Mutex-guarded; entries
    # expire lazily (purged on read, plus amortized cleanup of
    # long-expired entries on write) and the table is capped at
    # `max_entries` with LRU eviction (reads refresh recency).
    class MemoryStore < Store
      private struct Entry
        getter value : Value
        getter expires_at : Time?

        def initialize(@value : Value, @expires_at : Time?)
        end

        def expired?(now : Time) : Bool
          if exp = @expires_at
            now >= exp
          else
            false
          end
        end
      end

      # Entries expired longer than this are swept on write (bounds
      # memory when keys are written but never re-read).
      SWEEP_AFTER = 1.hour

      def initialize(@max_entries : Int32 = 1000)
        @max_entries = 1 if @max_entries < 1
        @data = {} of String => Entry
        @mutex = Mutex.new
        @refreshing = Set(String).new
      end

      def read(key : String) : String?
        case v = read_value(key)
        when String then v
        when Nil    then nil
        else             nil
        end
      end

      def read_value(key : String) : Value
        full = namespaced(key)
        @mutex.synchronize do
          entry = @data[full]?
          return nil if entry.nil?
          if entry.expired?(Time.utc)
            @data.delete(full)
            return nil
          end
          touch(full, entry)
          entry.value
        end
      end

      def write(key : String, value : String | Int | Float | Bool | Time | Nil, expires_in : Time::Span? = nil) : Bool
        store_value = normalize(value)
        full = namespaced(key)
        now = Time.utc
        exp = expires_in.nil? ? nil : now + expires_in.not_nil!
        @mutex.synchronize do
          sweep_locked(now)
          unless @data.has_key?(full)
            while @data.size >= @max_entries
              @data.delete(@data.first_key)
            end
          end
          @data.delete(full)
          @data[full] = Entry.new(store_value, exp)
        end
        true
      end

      def delete(key : String) : Bool
        @mutex.synchronize do
          full = namespaced(key)
          return false unless @data.has_key?(full)
          @data.delete(full)
          true
        end
      end

      def exist?(key : String) : Bool
        @mutex.synchronize do
          full = namespaced(key)
          entry = @data[full]?
          return false if entry.nil?
          if entry.expired?(Time.utc)
            @data.delete(full)
            return false
          end
          true
        end
      end

      def clear : Nil
        @mutex.synchronize do
          @data.clear
          @refreshing.clear
        end
      end

      def increment(key : String, by : Int = 1) : Int64
        delta = by.to_i64
        @mutex.synchronize do
          full = namespaced(key)
          if entry = @data[full]?
            if entry.expired?(Time.utc)
              @data.delete(full)
            else
              case current = entry.value
              when Int
                total = current.to_i64 + delta
                updated = Entry.new(total, entry.expires_at)
                touch(full, updated)
                return total
              when String
                if n = current.to_i64?
                  total = n + delta
                  updated = Entry.new(total.to_s, entry.expires_at)
                  touch(full, updated)
                  return total
                end
                raise ArgumentError.new("cache: cannot increment non-numeric value for #{key.inspect}")
              else
                raise ArgumentError.new("cache: cannot increment non-numeric value for #{key.inspect}")
              end
            end
          end
          total = delta
          unless @data.has_key?(full)
            while @data.size >= @max_entries
              @data.delete(@data.first_key)
            end
          end
          @data.delete(full)
          @data[full] = Entry.new(total, nil)
          total
        end
      end

      def fetch(key : String, expires_in : Time::Span? = nil, &block : -> String) : String
        result = fetch_value(key, expires_in) { block.call }
        result.is_a?(String) ? result : write_through(key, result, expires_in, block)
      end

      def fetch_value(key : String, expires_in : Time::Span? = nil, &block : -> Value) : Value
        fetch_impl(key, expires_in, nil, &block)
      end

      # Stampede protection: when the entry expired within
      # `race_condition_ttl`, the stale value is served immediately and a
      # single background fiber refreshes it (concurrent fetchers keep
      # getting stale until the refresh lands instead of piling onto the
      # recomputation). Without the option (or past the grace window) a
      # miss recomputes synchronously. Redis-backed stores accept but
      # ignore the option (server-side TTLs drop stale values, so there
      # is nothing to serve) — see `RedisStore#fetch_value`.
      def fetch(key : String, expires_in : Time::Span? = nil, race_condition_ttl : Time::Span? = nil, &block : -> String) : String
        result = fetch_impl(key, expires_in, race_condition_ttl) { block.call }
        result.is_a?(String) ? result : write_through(key, result, expires_in, block)
      end

      def fetch_value(key : String, expires_in : Time::Span? = nil, race_condition_ttl : Time::Span? = nil, &block : -> Value) : Value
        fetch_impl(key, expires_in, race_condition_ttl, &block)
      end

      private def fetch_impl(key : String, expires_in : Time::Span?, race_condition_ttl : Time::Span?, &block : -> Value) : Value
        full = namespaced(key)
        now = Time.utc
        live : Value = nil
        found_live = false
        stale : Value = nil
        has_stale = false
        background = false
        @mutex.synchronize do
          if entry = @data[full]?
            if entry.expired?(now)
              if ttl = race_condition_ttl
                if exp = entry.expires_at
                  if now - exp <= ttl
                    stale = entry.value
                    has_stale = true
                    touch(full, entry)
                    unless @refreshing.includes?(full)
                      @refreshing << full
                      background = true
                    end
                  else
                    @data.delete(full)
                  end
                else
                  @data.delete(full)
                end
              else
                @data.delete(full)
              end
            else
              touch(full, entry)
              live = entry.value
              found_live = true
            end
          end
        end
        # The block never runs while the store mutex is held.
        return live if found_live
        if has_stale
          if background
            spawn do
              begin
                write(key, block.call, expires_in)
              rescue
              ensure
                @mutex.synchronize { @refreshing.delete(full) }
              end
            end
          end
          return stale
        end
        value = block.call
        write(key, value, expires_in)
        value
      end

      # A `fetch` (String) that found a live non-String entry treats it
      # as a miss: recompute through the String block and overwrite.
      private def write_through(key : String, _stale : Value, expires_in : Time::Span?, block : -> String) : String
        fresh = block.call
        write(key, fresh, expires_in)
        fresh
      end

      private def normalize(value : String | Int | Float | Bool | Time | Nil) : Value
        case value
        when Int   then value.to_i64
        when Float then value.to_f64
        else            value.as(Value)
        end
      end

      # Refresh LRU recency (must hold `@mutex`).
      private def touch(full : String, entry : Entry) : Nil
        @data.delete(full)
        @data[full] = entry
      end

      # Drop entries expired longer than `SWEEP_AFTER` (must hold `@mutex`).
      private def sweep_locked(now : Time) : Nil
        cutoff = now - SWEEP_AFTER
        @data.reject! do |_, entry|
          if exp = entry.expires_at
            exp < cutoff
          else
            false
          end
        end
      end
    end

    # Redis-backed entries shared across processes. Each entry is one key
    # (`"<prefix><namespace:><key>"`) holding the same type-tagged
    # encoding as `MemoryStore`; TTLs come from `expires_in` (`SET ...
    # EX`). Connection handling mirrors `Throttle::RedisStore` (lazy
    # connect, one immediate retry, then `RedisDown`).
    #
    # `increment` is read-modify-write (atomic per instance, not across
    # processes — use Throttle-style Lua counters when linearity
    # matters). `clear` deletes only keys written through that instance
    # (never FLUSHDB).
    class RedisStore < Store
      getter prefix : String

      @info : Cable::RedisWire::Info
      @conn : Cable::RedisWire::Conn?
      @keys : Set(String)

      def initialize(url : String = ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379"), @prefix : String = "saci:cache:")
        info = begin
          Cable::RedisWire.parse_url(url)
        rescue ex : Cable::RedisDown
          raise RedisDown.new(ex.message || "unreachable")
        end
        @info = info
        @mutex = Mutex.new
        @incr_mutex = Mutex.new
        @conn = nil
        @keys_mutex = Mutex.new
        @keys = Set(String).new
      end

      def read(key : String) : String?
        case v = read_value(key)
        when String then v
        else             nil
        end
      end

      def read_value(key : String) : Value
        raw = get(namespaced(key))
        raw.nil? ? nil : decode(raw)
      end

      def write(key : String, value : String | Int | Float | Bool | Time | Nil, expires_in : Time::Span? = nil) : Bool
        full = "#{@prefix}#{namespaced(key)}"
        payload = encode(normalize(value))
        if secs = expiry_secs(expires_in)
          with_conn &.call(["SET", full, payload, "EX", secs.to_s])
        else
          with_conn &.call(["SET", full, payload])
        end
        @keys_mutex.synchronize { @keys << full }
        true
      end

      def delete(key : String) : Bool
        full = "#{@prefix}#{namespaced(key)}"
        result = with_conn &.call(["DEL", full])
        @keys_mutex.synchronize { @keys.delete(full) }
        result == 1_i64
      end

      def exist?(key : String) : Bool
        result = with_conn &.call(["EXISTS", "#{@prefix}#{namespaced(key)}"])
        result == 1_i64
      end

      def clear : Nil
        keys = @keys_mutex.synchronize do
          copy = @keys.dup
          @keys.clear
          copy
        end
        return if keys.empty?
        begin
          with_conn &.call(["DEL"] + keys.to_a)
        rescue
        end
      end

      def increment(key : String, by : Int = 1) : Int64
        delta = by.to_i64
        # Own lock: `get`/`write` below take the connection mutex
        # themselves, so reusing it here would deadlock.
        @incr_mutex.synchronize do
          full = namespaced(key)
          raw = get(full)
          total = if raw.nil?
                    delta
                  else
                    case current = decode(raw)
                    when Int
                      current.to_i64 + delta
                    when String
                      if n = current.to_i64?
                        n + delta
                      else
                        raise ArgumentError.new("cache: cannot increment non-numeric value for #{key.inspect}")
                      end
                    else
                      raise ArgumentError.new("cache: cannot increment non-numeric value for #{key.inspect}")
                    end
                  end
          # Preserve the stored shape (String counters stay Strings so
          # `read` keeps hitting; integers stay tagged integers).
          if raw && decode(raw).is_a?(String)
            write(key, total.to_s)
          else
            write(key, total)
          end
          total
        end
      end

      def fetch(key : String, expires_in : Time::Span? = nil, &block : -> String) : String
        result = fetch_value(key, expires_in) { block.call }
        return result if result.is_a?(String)
        fresh = block.call
        write(key, fresh, expires_in)
        fresh
      end

      def fetch_value(key : String, expires_in : Time::Span? = nil, &block : -> Value) : Value
        fetch_value(key, expires_in, nil, &block)
      end

      # `race_condition_ttl` is accepted for API parity with
      # `MemoryStore` but has no effect here: server-side TTLs drop
      # expired values, so there is no stale value to serve — a miss
      # recomputes synchronously.
      def fetch_value(key : String, expires_in : Time::Span? = nil, race_condition_ttl : Time::Span? = nil, &block : -> Value) : Value
        hit = read_value(key)
        return hit unless hit.nil? && !exist?(key)
        # `read_value` returns nil both for misses and for stored Nils;
        # `exist?` disambiguates (a stored Nil is a hit).
        value = block.call
        write(key, value, expires_in)
        value
      end

      private def get(full : String) : String?
        result = with_conn &.call(["GET", "#{@prefix}#{full}"])
        result.as?(String)
      end

      private def normalize(value : String | Int | Float | Bool | Time | Nil) : Value
        case value
        when Int   then value.to_i64
        when Float then value.to_f64
        else            value.as(Value)
        end
      end

      private def with_conn(& : Cable::RedisWire::Conn -> Cable::RedisWire::RedisValue) : Cable::RedisWire::RedisValue
        @mutex.synchronize do
          begin
            conn = @conn ||= Cable::RedisWire::Conn.new(@info)
            return yield conn
          rescue ex : Cable::RedisDown
            begin
              @conn.try(&.close)
            rescue
            end
            @conn = nil
            # One immediate retry: covers call-right-after-restart.
            begin
              conn2 = Cable::RedisWire::Conn.new(@info)
            rescue ex2 : Cable::RedisDown
              raise RedisDown.new(ex2.message || "unreachable")
            end
            @conn = conn2
            begin
              return yield conn2
            rescue ex3 : Cable::RedisDown
              raise RedisDown.new(ex3.message || "unreachable")
            end
          end
        end
      end
    end

    @@store : Store = MemoryStore.new
    @@store_mutex = Mutex.new

    # Storage backend (default: in-process `MemoryStore`). Swap for
    # `RedisStore` to share entries across processes:
    # `Saci::Cache.store = Saci::Cache::RedisStore.new(url)`.
    def self.store : Store
      @@store_mutex.synchronize { @@store }
    end

    def self.store=(store : Store) : Nil
      @@store_mutex.synchronize { @@store = store }
    end

    # Key namespace (`"ns:key"`). Delegates to the current store (lives
    # there, so it survives `store` swaps only when set again).
    def self.namespace : String
      store.namespace
    end

    def self.namespace=(namespace : String) : Nil
      store.namespace = namespace
    end

    # Restores the default in-process store with a blank namespace (spec
    # isolation).
    def self.reset! : Nil
      @@store_mutex.synchronize { @@store = MemoryStore.new }
    end

    def self.read(key : String) : String?
      store.read(key)
    end

    def self.read_value(key : String) : Value
      store.read_value(key)
    end

    def self.write(key : String, value : String | Int | Float | Bool | Time | Nil, expires_in : Time::Span? = nil) : Bool
      store.write(key, value, expires_in)
    end

    def self.delete(key : String) : Bool
      store.delete(key)
    end

    def self.exist?(key : String) : Bool
      store.exist?(key)
    end

    def self.clear : Nil
      store.clear
    end

    def self.increment(key : String, by : Int = 1) : Int64
      store.increment(key, by)
    end

    def self.fetch(key : String, expires_in : Time::Span? = nil, &block : -> String) : String
      store.fetch(key, expires_in) { block.call }
    end

    def self.fetch_value(key : String, expires_in : Time::Span? = nil, &block : -> Value) : Value
      store.fetch_value(key, expires_in) { block.call }
    end
  end
end
