require "log"

module Saci
  # Central logger (`::Log` wrapper) plus request logging support.
  #
  # ```
  # Saci.logger.info { "booted" }
  # Saci.logger = ::Log.for("myapp") # swap in specs/apps
  #
  # Saci.tagged("worker-1") do
  #   Saci.logger.info { "[#{Saci.current_tags.join(" ")}] working" }
  # end
  # ```
  # Always a `BroadcastLogger` (even for a single sink), so `Saci.logger`
  # has one concrete type and block-dispatching stays simple.
  @@logger : BroadcastLogger = BroadcastLogger.new([::Log.for("saci")])
  @@logger_mutex = Mutex.new

  def self.logger : BroadcastLogger
    @@logger_mutex.synchronize { @@logger }
  end

  def self.logger=(log : ::Log) : Nil
    @@logger_mutex.synchronize { @@logger = BroadcastLogger.new([log]) }
  end

  # Fan out to several sinks: `Saci.logger = [Log.for("app"), Log.for("audit")]`.
  def self.logger=(logs : Array(::Log)) : Nil
    @@logger_mutex.synchronize { @@logger = BroadcastLogger.new(logs) }
  end

  def self.logger=(logger : BroadcastLogger) : Nil
    @@logger_mutex.synchronize { @@logger = logger }
  end

  # Rails-style globals delegating to existing components.
  def self.root : String
    ENV.fetch("SACI_ROOT", Dir.current)
  end

  def self.cache : Saci::Cache::Store
    Saci::Cache.store
  end

  def self.broadcast_logger(*logs : ::Log) : BroadcastLogger
    BroadcastLogger.new(logs.to_a)
  end

  # Emits the `Completed ...` request line in `Router#call`. Disable with
  # `Saci.log_requests = false` (framework specs do this to stay quiet).
  @@log_requests : Bool = true
  @@log_requests_mutex = Mutex.new

  def self.log_requests : Bool
    @@log_requests_mutex.synchronize { @@log_requests }
  end

  def self.log_requests=(value : Bool) : Nil
    @@log_requests_mutex.synchronize { @@log_requests = value }
  end

  # Parameter keys filtered from request logs (substring match). Defaults
  # match Rails' 12 keys (`passw` covers password/password_confirmation).
  @@filter_parameters : Array(String) = [
    "passw", "email", "secret", "token", "_key", "crypt",
    "salt", "certificate", "otp", "ssn", "cvv", "cvc",
  ]
  @@filter_mutex = Mutex.new

  def self.filter_parameters : Array(String)
    @@filter_mutex.synchronize { @@filter_parameters.dup }
  end

  def self.filter_parameters=(keys : Array(String)) : Nil
    @@filter_mutex.synchronize { @@filter_parameters = keys }
  end

  def self.filter_params(values : Hash(String, String)) : Hash(String, String)
    filters = filter_parameters.map(&.downcase)
    values.to_h do |key, value|
      {key, filters.any? { |f| key.downcase.includes?(f) } ? "[FILTERED]" : value}
    end
  end

  # Redirect URLs whose query string must not be logged (Rails
  # `config.filter_redirect`). Empty by default; add fragments or hosts.
  @@filter_redirect : Array(String) = [] of String
  @@filter_redirect_mutex = Mutex.new

  def self.filter_redirect : Array(String)
    @@filter_redirect_mutex.synchronize { @@filter_redirect.dup }
  end

  def self.filter_redirect=(patterns : Array(String)) : Nil
    @@filter_redirect_mutex.synchronize { @@filter_redirect = patterns }
  end

  def self.filter_redirect?(url : String) : Bool
    filters = filter_redirect
    !filters.empty? && filters.any? { |pattern| url.includes?(pattern) }
  end

  # Replaces filtered redirect URLs with `[FILTERED]` for log lines.
  def self.filter_redirect_value(url : String) : String
    filter_redirect?(url) ? "[FILTERED]" : url
  end

  # Fiber-local tag stack for correlating logs (`current_tags` reads it).
  @@tag_stacks = {} of UInt64 => Array(String)
  @@tag_mutex = Mutex.new

  def self.tagged(*tags : String, & : -> T) : T forall T
    key = Fiber.current.object_id
    stack = @@tag_mutex.synchronize { @@tag_stacks[key] ||= [] of String }
    stack.concat(tags.to_a)
    begin
      yield
    ensure
      @@tag_mutex.synchronize do
        tags.size.times { stack.pop? }
        @@tag_stacks.delete(key) if stack.empty?
      end
    end
  end

  def self.current_tags : Array(String)
    @@tag_mutex.synchronize { (@@tag_stacks[Fiber.current.object_id]? || [] of String).dup }
  end

  # Array form of `tagged` (Crystal cannot splat an `Array` into `*tags`).
  def self.tagged_list(tags : Array(String), & : -> T) : T forall T
    key = Fiber.current.object_id
    stack = @@tag_mutex.synchronize { @@tag_stacks[key] ||= [] of String }
    stack.concat(tags)
    begin
      yield
    ensure
      @@tag_mutex.synchronize do
        tags.size.times { stack.pop? }
        @@tag_stacks.delete(key) if stack.empty?
      end
    end
  end

  # Correlation id for logs/traces: unique enough, not a secret, so it uses
  # the fast PRNG instead of a getrandom syscall per request.
  def self.request_id : String
    Random.rand(UInt64::MAX).to_s(16).rjust(16, '0')
  end

  # FNV-1a 64-bit hex digest (pure Crystal). Used for ETags: stdlib
  # `Digest::*` links against OpenSSL symbols (`EVP_MD_size`, …) removed in
  # OpenSSL ≥ 3.2, so digests are unavailable wherever modern OpenSSL ships.
  def self.etag_digest(fragment : String) : String
    hash = 0xcbf29ce484222325_u64
    fragment.each_byte do |byte|
      hash ^= byte
      hash &*= 0x100000001b3_u64
    end
    hash.to_s(16).rjust(16, '0')
  end

  # From `APP_ENV`, defaulting to development. Read live (spec-friendly).
  def self.env : String
    ENV.fetch("APP_ENV", "development")
  end

  def self.development? : Bool
    env == "development"
  end

  def self.test? : Bool
    env == "test"
  end

  def self.production? : Bool
    env == "production"
  end

  def self.staging? : Bool
    env == "staging"
  end

  @@log_level : Symbol = :info
  @@log_level_mutex = Mutex.new

  def self.log_level : Symbol
    @@log_level_mutex.synchronize { @@log_level }
  end

  # Sets the logger severity (`:debug/:info/:notice/:warn/:error/:fatal`).
  def self.log_level=(level : Symbol) : Nil
    severity = case level
               when :debug  then ::Log::Severity::Debug
               when :info   then ::Log::Severity::Info
               when :notice then ::Log::Severity::Notice
               when :warn   then ::Log::Severity::Warn
               when :error  then ::Log::Severity::Error
               when :fatal  then ::Log::Severity::Fatal
               else              raise ArgumentError.new("Unknown log level #{level.inspect}")
               end
    @@log_level_mutex.synchronize { @@log_level = level }
    logger.level = severity
  end

  @@force_ssl : Bool = false
  @@force_ssl_mutex = Mutex.new

  # Redirects plain-HTTP requests to HTTPS (honors `X-Forwarded-Proto`,
  # skips localhost). Enable in production.
  def self.force_ssl : Bool
    @@force_ssl_mutex.synchronize { @@force_ssl }
  end

  def self.force_ssl=(value : Bool) : Nil
    @@force_ssl_mutex.synchronize { @@force_ssl = value }
  end

  # Explicit override; default follows the environment (detailed everywhere
  # except production).
  @@detailed_exceptions : Bool? = nil
  @@detailed_mutex = Mutex.new

  def self.show_detailed_exceptions? : Bool
    @@detailed_mutex.synchronize do
      v = @@detailed_exceptions
      v.nil? ? (env != "production" && env != "staging") : v
    end
  end

  def self.show_detailed_exceptions=(value : Bool?) : Nil
    @@detailed_mutex.synchronize { @@detailed_exceptions = value }
  end

  # Pure log-line builder (unit-tested; `Router#call` fills it in). Honors
  # `SACI_LOG_FORMAT=json` and the fiber-local tag stack.
  def self.request_log_line(method : String, path : String, status : Int32, elapsed_ms : Float64, params : Hash(String, String), request_id : String) : String
    filtered = filter_params(params)
    if log_json?
      {
        "time"        => Time.utc.to_rfc3339,
        "level"       => "INFO",
        "request_id"  => request_id,
        "method"      => method,
        "path"        => path,
        "status"      => status,
        "duration_ms" => elapsed_ms.round(2),
        "params"      => filtered,
        "tags"        => current_tags,
      }.to_json
    else
      tags = current_tags
      prefix = if tags.empty?
                 "[#{request_id}] "
               elsif tags.includes?(request_id)
                 "[#{tags.join("] [")}] "
               else
                 "[#{tags.join("] [")}] [#{request_id}] "
               end
      "#{prefix}Completed #{status} in #{elapsed_ms.round(1)}ms | #{method} #{path} | params=#{filtered.inspect}"
    end
  end
end

require "./support/core_ext"
require "./support/duration"
require "./support/structured_logging"
