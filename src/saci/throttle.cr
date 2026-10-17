require "set"

module Saci
  # Rack::Attack-style throttling (fixed windows, in-process by default,
  # Redis-shared across processes with `Throttle::RedisStore`).
  #
  # ```
  # Saci::Throttle.throttle("logins/ip", limit: 5, period: 1.minute) do |ctx|
  #   ctx.request.path == "/login" ? Saci::Throttle.client_ip(ctx) : nil
  # end
  # Saci::Throttle.safelist { |ctx| Saci::Throttle.client_ip(ctx) == "127.0.0.1" }
  # Saci::Throttle.blocklist { |ctx| banned?(ctx) }
  #
  # # Multi-process deploys (kills the sticky-session caveat):
  # Saci::Throttle.store = Saci::Throttle::RedisStore.new(ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379"))
  # ```
  #
  # Throttled requests get 429 + `Retry-After`; blocklisted get 403.
  #
  # Degradation is fail-open: when the store is unreachable the request
  # is allowed and a warning goes to STDERR (availability over strict
  # limiting — a Redis outage must not turn into a self-inflicted
  # site-wide 429/500). Fail-closed (reject when the store is down)
  # would be safer against abuse bursts but risks a full outage; apps
  # that prefer it can subclass `Store` and raise in `check`.
  module Throttle
    # Raised when the Redis store is unreachable. `check` never
    # propagates it (fail-open, see above); it surfaces from direct
    # `RedisStore#increment` calls.
    class RedisDown < Exception
    end

    # Counter backend. `MemoryStore` is the default (single process);
    # `RedisStore` shares fixed windows across processes.
    abstract class Store
      # Increments the fixed-window bucket, creating it with a TTL when
      # new. Returns the new count. `bucket` already encodes
      # `"<rule>:<key>:<window>"`; `ttl_secs` is the seconds left in the
      # window (>= 1). Must never raise on normal operation; connection
      # failures surface as `Cable::RedisDown`/`Throttle::RedisDown`
      # ( callers degrade to fail-open).
      abstract def increment(bucket : String, window : Int64, period_secs : Int64, ttl_secs : Int32) : Int32

      # Best-effort reset of all counters (spec isolation); never raises.
      def clear : Nil
      end
    end

    # In-process fixed windows (the historical behavior, now behind the
    # `Store` interface so `check` is backend-agnostic).
    class MemoryStore < Store
      def initialize
        # bucket => {count, window, period_secs}
        @counts = {} of String => Tuple(Int32, Int64, Int64)
        @mutex = Mutex.new
      end

      def increment(bucket : String, window : Int64, period_secs : Int64, ttl_secs : Int32) : Int32
        @mutex.synchronize do
          now = Time.utc.to_unix
          @counts.reject! { |_, entry| entry[1] < now // entry[2] - 1 }
          current = @counts[bucket]?.try(&.[0]) || 0
          @counts[bucket] = {current + 1, window, period_secs}
          current + 1
        end
      end

      def clear : Nil
        @mutex.synchronize { @counts.clear }
      end
    end

    # Redis-backed fixed windows shared across processes. Each bucket is
    # one key (`"<prefix><rule>:<key>:<window>"`) bumped by an
    # INCR + conditional EXPIRE Lua script, so the increment and the TTL
    # assignment are atomic (no lost expirations under concurrency).
    # Keys rotate every window; the TTL (time left in the window) lets
    # them expire on their own.
    class RedisStore < Store
      INCR_SCRIPT = "local c = redis.call('INCR', KEYS[1]); if c == 1 then redis.call('EXPIRE', KEYS[1], ARGV[1]) end; return c"

      getter prefix : String

      @info : Cable::RedisWire::Info
      @conn : Cable::RedisWire::Conn?
      @keys : Set(String)

      def initialize(url : String = ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379"), @prefix : String = "saci:throttle:")
        @info = Cable::RedisWire.parse_url(url)
        @mutex = Mutex.new
        @conn = nil
        @keys_mutex = Mutex.new
        @keys = Set(String).new
      end

      def increment(bucket : String, window : Int64, period_secs : Int64, ttl_secs : Int32) : Int32
        key = "#{@prefix}#{bucket}"
        begin
          result = with_conn &.call("EVAL", INCR_SCRIPT, "1", key, ttl_secs.to_s)
        rescue ex : Cable::RedisDown
          raise RedisDown.new(ex.message || "unreachable")
        end
        count = result.as?(Int64).try(&.to_i)
        raise RedisDown.new("redis: unexpected EVAL reply #{result.inspect}") if count.nil?
        @keys_mutex.synchronize { @keys << key }
        count
      end

      # Deletes keys written through this instance (best-effort, never
      # raises — a store outage during reset must not fail specs).
      # Other instances' keys and unrelated data are untouched
      # (no FLUSHDB, ever).
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
            # One immediate retry: covers check-right-after-restart.
            conn2 = Cable::RedisWire::Conn.new(@info)
            @conn = conn2
            return yield conn2
          end
        end
      end
    end

    struct Rule
      getter name : String
      getter limit : Int32
      getter period : Time::Span
      getter key_for : HTTP::Server::Context -> String?

      def initialize(@name : String, @limit : Int32, @period : Time::Span, @key_for : HTTP::Server::Context -> String?)
      end
    end

    @@rules = [] of Rule
    @@safelists = [] of (HTTP::Server::Context -> Bool)
    @@blocklists = [] of (HTTP::Server::Context -> Bool)
    @@mutex = Mutex.new
    @@store : Store = MemoryStore.new
    @@store_mutex = Mutex.new

    # Counter backend (default: in-process `MemoryStore`). Swap for
    # `RedisStore` to share windows across processes:
    # `Saci::Throttle.store = Saci::Throttle::RedisStore.new(url)`.
    def self.store : Store
      @@store_mutex.synchronize { @@store }
    end

    def self.store=(store : Store) : Nil
      @@store_mutex.synchronize { @@store = store }
    end

    def self.throttle(name : String | Symbol, limit : Int32, period : Time::Span, &discriminator : HTTP::Server::Context -> String?) : Nil
      @@mutex.synchronize { @@rules << Rule.new(name.to_s, limit, period, discriminator) }
    end

    # Multi-window helper: registers one rule per window sharing the same
    # discriminator (lobsters-style stacked globals, e.g. 4/s + 30/m).
    # Rule names are `"#{name}/#{index}"` so counters stay independent.
    #
    # ```
    # Saci::Throttle.multi("global", windows: [
    #   {limit: 4, period: 1.second},
    #   {limit: 30, period: 1.minute},
    # ]) { |ctx| Saci::Throttle.client_ip(ctx) }
    # ```
    def self.multi(name : String | Symbol, windows : Array(NamedTuple(limit: Int32, period: Time::Span)), &discriminator : HTTP::Server::Context -> String?) : Nil
      base = name.to_s
      windows.each_with_index do |w, i|
        throttle("#{base}/#{i}", limit: w[:limit], period: w[:period], &discriminator)
      end
    end

    # Convenience for lobsters' login throttle (POST /login* per IP).
    # Keeps the single-window `throttle` API untouched.
    def self.throttle_login(limit : Int32 = 4, period : Time::Span = 1.minute, name : String | Symbol = "login") : Nil
      throttle(name, limit: limit, period: period) do |ctx|
        path = ctx.request.path || ""
        if ctx.request.method == "POST" && path.starts_with?("/login")
          client_ip(ctx)
        else
          nil
        end
      end
    end

    def self.safelist(&rule : HTTP::Server::Context -> Bool) : Nil
      @@mutex.synchronize { @@safelists << rule }
    end

    def self.blocklist(&rule : HTTP::Server::Context -> Bool) : Nil
      @@mutex.synchronize { @@blocklists << rule }
    end

    # Clears rules, lists and counters (spec isolation).
    def self.reset! : Nil
      store = @@store_mutex.synchronize { @@store }
      @@mutex.synchronize do
        @@rules.clear
        @@safelists.clear
        @@blocklists.clear
      end
      store.clear
    end

    def self.clear_counts! : Nil
      store = @@store_mutex.synchronize { @@store }
      store.clear
    end

    def self.client_ip(context : HTTP::Server::Context) : String
      if forwarded = context.request.headers["X-Forwarded-For"]?
        first = forwarded.split(",").first.strip
        return first unless first.empty?
      end
      case addr = context.remote_address
      when Socket::IPAddress then addr.address
      when Nil               then "unknown"
      else                        addr.to_s
      end
    end

    def self.blocked?(context : HTTP::Server::Context) : Bool
      lists = @@mutex.synchronize { @@blocklists.dup }
      lists.any? { |rule| rule.call(context) }
    end

    def self.safelisted?(context : HTTP::Server::Context) : Bool
      lists = @@mutex.synchronize { @@safelists.dup }
      lists.any? { |rule| rule.call(context) }
    end

    # Returns nil when allowed, or seconds until retry when throttled.
    # Safelist/blocklist behavior is backend-independent. A dead store
    # is fail-open (STDERR warning, request allowed — see module docs).
    def self.check(context : HTTP::Server::Context) : Int32?
      return nil if safelisted?(context)
      rules = @@mutex.synchronize { @@rules.dup }
      store = @@store_mutex.synchronize { @@store }
      now = Time.utc.to_unix
      rules.each do |rule|
        key = rule.key_for.call(context)
        next if key.nil?
        period_secs = rule.period.total_seconds.to_i
        period_secs = 1 if period_secs < 1
        window = now // period_secs
        bucket = "#{rule.name}:#{key}:#{window}"
        ttl = ((window + 1) * period_secs - now).to_i
        ttl = 1 if ttl < 1
        count = begin
          store.increment(bucket, window, period_secs.to_i64, ttl)
        rescue ex : Exception
          STDERR.puts("warning: saci throttle store unreachable (#{ex.message}); allowing request (fail-open)")
          next
        end
        if count > rule.limit
          retry_after = (window + 1) * period_secs - now
          return retry_after > 0 ? retry_after.to_i : 0
        end
      end
      nil
    end
  end
end
