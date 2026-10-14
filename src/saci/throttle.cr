module Saci
  # Rack::Attack-style throttling (in-process fixed windows).
  #
  # ```
  # Saci::Throttle.throttle("logins/ip", limit: 5, period: 1.minute) do |ctx|
  #   ctx.request.path == "/login" ? Saci::Throttle.client_ip(ctx) : nil
  # end
  # Saci::Throttle.safelist { |ctx| Saci::Throttle.client_ip(ctx) == "127.0.0.1" }
  # Saci::Throttle.blocklist { |ctx| banned?(ctx) }
  # ```
  #
  # Throttled requests get 429 + `Retry-After`; blocklisted get 403. Counters
  # live in memory (single process — Redis sharding is roadmap).
  module Throttle
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
    # bucket => {count, window, period_secs}
    @@counts = {} of String => Tuple(Int32, Int64, Int64)
    @@mutex = Mutex.new

    def self.throttle(name : String | Symbol, limit : Int32, period : Time::Span, &discriminator : HTTP::Server::Context -> String?) : Nil
      @@mutex.synchronize { @@rules << Rule.new(name.to_s, limit, period, discriminator) }
    end

    def self.safelist(&rule : HTTP::Server::Context -> Bool) : Nil
      @@mutex.synchronize { @@safelists << rule }
    end

    def self.blocklist(&rule : HTTP::Server::Context -> Bool) : Nil
      @@mutex.synchronize { @@blocklists << rule }
    end

    # Clears rules, lists and counters (spec isolation).
    def self.reset! : Nil
      @@mutex.synchronize do
        @@rules.clear
        @@safelists.clear
        @@blocklists.clear
        @@counts.clear
      end
    end

    def self.clear_counts! : Nil
      @@mutex.synchronize { @@counts.clear }
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
    def self.check(context : HTTP::Server::Context) : Int32?
      return nil if safelisted?(context)
      rules = @@mutex.synchronize { @@rules.dup }
      now = Time.utc.to_unix
      rules.each do |rule|
        key = rule.key_for.call(context)
        next if key.nil?
        period_secs = rule.period.total_seconds.to_i
        period_secs = 1 if period_secs < 1
        window = now // period_secs
        bucket = "#{rule.name}:#{key}:#{window}"
        count = @@mutex.synchronize do
          @@counts.reject! { |_, entry| entry[1] < now // entry[2] - 1 }
          current = @@counts[bucket]?.try(&.[0]) || 0
          @@counts[bucket] = {current + 1, window, period_secs.to_i64}
          current + 1
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
