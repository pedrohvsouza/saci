require "log"
require "json"
require "./notifications"

# Structured logging extensions loaded from `saci/logging.cr` (Router is
# already defined there). Provides request tags, JSON output, a broadcast
# logger, and the slow-query hook.
module Saci
  # `:json` when `SACI_LOG_FORMAT=json`, otherwise `:text`.
  def self.log_format : Symbol
    ENV["SACI_LOG_FORMAT"]?.try(&.downcase) == "json" ? :json : :text
  end

  def self.log_json? : Bool
    log_format == :json
  end

  # Request tags applied to every log line emitted while a request runs.
  # Supported symbols: :request_id, :remote_ip, :method, :path, :route.
  @@log_tags : Array(String | Symbol) = [:request_id, :remote_ip, :method, :path] of String | Symbol
  @@log_tags_mutex = Mutex.new

  def self.log_tags : Array(String | Symbol)
    @@log_tags_mutex.synchronize { @@log_tags.dup }
  end

  def self.log_tags=(tags : Array(String | Symbol)) : Nil
    @@log_tags_mutex.synchronize { @@log_tags = tags.dup }
  end

  def self.request_tags(context : HTTP::Server::Context, request_id : String? = nil, path : String? = nil) : Array(String)
    log_tags.compact_map do |tag|
      case tag
      when Symbol
        case tag
        when :request_id
          request_id || context.request.headers["X-Request-Id"]?
        when :remote_ip
          case address = context.request.remote_address
          when Socket::IPAddress then address.address
          else                        address.to_s
          end
        when :method
          context.request.method
        when :path, :route
          path || context.request.path
        else
          nil
        end
      else
        tag
      end
    end
  end

  # JSON formatter for `Log::IOBackend`:
  # `Log::IOBackend.new(STDOUT, formatter: Saci::JsonLogFormatter.new)`.
  class JsonLogFormatter
    include ::Log::Formatter

    def format(entry : ::Log::Entry, io : IO) : Nil
      payload = {
        "time"    => entry.timestamp.to_rfc3339,
        "level"   => entry.severity.label,
        "source"  => entry.source,
        "message" => entry.message,
      } of String => String
      if exception = entry.exception
        payload["exception"] = "#{exception.class}: #{exception.message}"
      end
      io << payload.to_json
    end
  end

  def self.json_log_backend(io : IO = STDOUT) : ::Log::IOBackend
    ::Log::IOBackend.new(io, formatter: JsonLogFormatter.new)
  end

  # Logger that fans out to several sinks (Rails `BroadcastLogger`). This is a
  # standalone facade (not a `::Log` subclass) so `Saci.logger` keeps working
  # through a small union type.
  class BroadcastLogger
    getter loggers : Array(::Log)
    forward_missing_to @loggers.first

    def initialize(@loggers : Array(::Log))
    end

    {% for method in %w(trace debug info notice warn error fatal) %}
      def {{method.id}}(*, exception : Exception) : Nil
        @loggers.each { |logger| logger.{{method.id}}(exception: exception) }
      end

      def {{method.id}}(*, exception : Exception? = nil, &block : -> String) : Nil
        @loggers.each { |logger| logger.{{method.id}}(exception: exception) { block.call } }
      end
    {% end %}

    def level : ::Log::Severity
      @loggers.first?.try(&.level) || ::Log::Severity::Info
    end

    def level=(value : ::Log::Severity) : ::Log::Severity
      @loggers.each(&.level = value)
      value
    end

    def loggers=(logs : Array(::Log)) : Nil
      @loggers = logs
    end
  end

  @@slow_query_threshold : Time::Span = 200.milliseconds
  @@slow_query_mutex = Mutex.new
  @@slow_query_handler : Proc(String, Time::Span, Nil)? = nil

  def self.slow_query_threshold : Time::Span
    @@slow_query_mutex.synchronize { @@slow_query_threshold }
  end

  def self.slow_query_threshold=(threshold : Time::Span) : Nil
    @@slow_query_mutex.synchronize { @@slow_query_threshold = threshold }
  end

  def self.on_slow_query(&handler : String, Time::Span ->) : Nil
    @@slow_query_mutex.synchronize { @@slow_query_handler = ->(sql : String, duration : Time::Span) { handler.call(sql, duration); nil } }
  end

  def self.reset_slow_query_handler! : Nil
    @@slow_query_mutex.synchronize { @@slow_query_handler = nil }
  end

  # Called by the SQL instrumentation; logs plus invokes the optional hook.
  def self.log_slow_query(sql : String, duration : Time::Span) : Nil
    threshold = slow_query_threshold
    return if duration < threshold
    handler = @@slow_query_mutex.synchronize { @@slow_query_handler }
    logger.warn { "Slow query #{duration.total_milliseconds.round(1)}ms: #{sql}" }
    handler.try(&.call(sql, duration))
  end
end

# Slow-query logging listens to `sql.saci` (published by the ORM
# instrumentation) so the ORM never has to know about logging.
Saci::Notifications.subscribe("sql.saci") do |event|
  if sql = event["sql"]?.try(&.to_s)
    Saci.log_slow_query(sql, event.duration.milliseconds)
  end
end

module Saci
  class Router
    # Establishes automatic request tags around dispatch. The request id is
    # written to the request header *before* the original `call` runs, so the
    # router's own id and `X-Request-Id` response header stay consistent.
    def call(context : HTTP::Server::Context) : Nil
      request = context.request
      request_id = request.headers["X-Request-Id"]? || Saci.request_id
      request.headers["X-Request-Id"] = request_id
      tags = Saci.request_tags(context, request_id, request.path || "/")
      if tags.empty?
        previous_def
      else
        Saci.tagged_list(tags) { previous_def }
      end
    end
  end

  class Controller
    # Redirect log line with `Saci.filter_redirect` applied to the target.
    def redirect_to(location : String, status : Int32 | Symbol = 302) : Nil
      if Saci.log_requests
        Saci.logger.info { "Redirected to #{Saci.filter_redirect_value(location)}" }
      end
      previous_def
    end
  end
end
