require "log"
require "json"
require "./notifications"

# Structured logging extensions loaded from `saci/logging.cr` (Router is
# already defined there). Provides request tags, JSON output, a broadcast
# logger, the default text/JSON backend, query logging and the slow-query
# hook.
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

    def initialize
    end

    def format(entry : ::Log::Entry, io : IO) : Nil
      JSON.build(io) do |json|
        json.object do
          json.field "time", entry.timestamp.to_rfc3339(fraction_digits: 6)
          json.field "level", entry.severity.label
          json.field "source", entry.source
          json.field "message", entry.message
          entry.data.each do |key, value|
            case raw = value.raw
            when Int, Float, Bool then json.field key.to_s, raw
            else                       json.field key.to_s, value.to_s
            end
          end
          if exception = entry.exception
            json.field "exception", "#{exception.class}: #{exception.message}"
          end
        end
      end
    end
  end

  def self.json_log_backend(io : IO = STDOUT) : ::Log::IOBackend
    ::Log::IOBackend.new(io, formatter: JsonLogFormatter.new)
  end

  # Timestamp format of text log lines: `2026/11/14 03:15:02.494236`.
  LOG_TIME_FORMAT = "%Y/%m/%d %H:%M:%S.%6N"

  # Whether log lines written to `io` get ANSI colors: only on a terminal,
  # never with `NO_COLOR`. `SACI_LOG_COLOR=1`/`0` forces it on or off.
  def self.log_color?(io : IO = STDOUT) : Bool
    case ENV["SACI_LOG_COLOR"]?.try(&.downcase)
    when "1", "true", "always" then return true
    when "0", "false", "never" then return false
    end
    return false if ENV["NO_COLOR"]?.presence
    io.tty?
  end

  # Text formatter for terminal logs:
  # `2026/11/14 03:15:02.494236 INFO  saci: Completed 200 in 1.2ms | ...`.
  # Query entries (source `saci.sql`) render Rails-style, with the
  # statement colored by kind.
  class TextLogFormatter
    include ::Log::Formatter

    RESET  = "\e[0m"
    BOLD   = "\e[1m"
    DIM    = "\e[2m"
    RED    = "\e[31m"
    GREEN  = "\e[32m"
    YELLOW = "\e[33m"
    BLUE   = "\e[34m"
    PURPLE = "\e[35m"
    CYAN   = "\e[36m"

    def initialize(@color : Bool = false)
    end

    def format(entry : ::Log::Entry, io : IO) : Nil
      paint(io, entry.timestamp.to_local.to_s(LOG_TIME_FORMAT), DIM)
      io << ' '
      paint(io, entry.severity.label.ljust(5), severity_color(entry.severity))
      io << ' '
      if entry.source == SQL_LOG_SOURCE
        format_query(entry, io)
      else
        unless entry.source.empty?
          paint(io, entry.source, DIM)
          io << ": "
        end
        io << entry.message
      end
      if exception = entry.exception
        io << '\n'
        paint(io, exception.inspect_with_backtrace, RED)
      end
    end

    private def format_query(entry : ::Log::Entry, io : IO) : Nil
      label = String.build do |str|
        str << "SQL"
        if duration = entry.data[:duration_ms]?.try(&.raw)
          str << " (" << duration << "ms)"
        end
      end
      paint(io, label, "#{BOLD}#{CYAN}")
      io << "  "
      paint(io, entry.message, "#{BOLD}#{sql_color(entry.message)}")
    end

    private def paint(io : IO, text : String, code : String) : Nil
      if @color
        io << code << text << RESET
      else
        io << text
      end
    end

    private def severity_color(severity : ::Log::Severity) : String
      case severity
      when .trace?, .debug? then CYAN
      when .info?, .notice? then GREEN
      when .warn?           then YELLOW
      else                       "#{BOLD}#{RED}"
      end
    end

    # Rails' palette: reads blue, inserts green, updates yellow, deletes
    # and rollbacks red, transactions cyan, everything else purple.
    private def sql_color(sql : String) : String
      verb = sql.sub(/\A\s*(?:\/\*.*?\*\/\s*)*/m, "").split(/\s/, 2).first?.try(&.upcase) || ""
      case verb
      when "SELECT", "WITH"                          then BLUE
      when "INSERT"                                  then GREEN
      when "UPDATE"                                  then YELLOW
      when "DELETE", "ROLLBACK"                      then RED
      when "BEGIN", "COMMIT", "SAVEPOINT", "RELEASE" then CYAN
      else                                                PURPLE
      end
    end
  end

  def self.text_log_backend(io : IO = STDOUT, color : Bool = log_color?(io)) : ::Log::IOBackend
    ::Log::IOBackend.new(io, formatter: TextLogFormatter.new(color))
  end

  # Installs the default backend for every source: text (colored on a
  # terminal) or JSON with `SACI_LOG_FORMAT=json`, at `LOG_LEVEL`
  # (*default_level* when unset). Runs when Saci is required; set
  # `SACI_LOG_SETUP=0` to keep Crystal's default, or call `Log.setup`
  # afterwards to override it.
  #
  # Under `crystal spec` it runs again before the suite with
  # `default_level: :none`. The spec runner calls `Log.setup_from_env`
  # just before the examples, which would otherwise swap in Crystal's
  # formatter halfway through the output. Specs stay quiet unless
  # `LOG_LEVEL` is set, as with plain `crystal spec`, and print Saci's
  # format when it is.
  def self.setup_logging(io : IO = STDOUT, default_level : ::Log::Severity = :info) : Nil
    backend = log_json? ? json_log_backend(io) : text_log_backend(io)
    ::Log.setup_from_env(backend: backend, default_level: default_level)
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

  # Source of the per-query log entries (`Log.for("saci.sql")`).
  SQL_LOG_SOURCE = "saci.sql"
  SQL_LOG        = ::Log.for(SQL_LOG_SOURCE)

  # Every SQL statement is logged (info, source `saci.sql`) unless this is
  # off: `Saci.log_queries = false` or `SACI_LOG_QUERIES=0`.
  @@log_queries : Bool = !%w(0 false off no).includes?(ENV["SACI_LOG_QUERIES"]?.try(&.downcase))
  @@log_queries_mutex = Mutex.new

  def self.log_queries : Bool
    @@log_queries_mutex.synchronize { @@log_queries }
  end

  def self.log_queries=(value : Bool) : Nil
    @@log_queries_mutex.synchronize { @@log_queries = value }
  end

  def self.log_query(sql : String, duration_ms : Float64, adapter : String? = nil) : Nil
    return unless log_queries
    SQL_LOG.info &.emit(sql, duration_ms: duration_ms.round(1), adapter: adapter.to_s)
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

# Query and slow-query logging listen to `sql.saci` (published by the ORM
# instrumentation) so the ORM never has to know about logging.
Saci::Notifications.subscribe("sql.saci") do |event|
  if sql = event["sql"]?.try(&.to_s)
    Saci.log_query(sql, event.duration, event["adapter"]?.try(&.to_s))
    Saci.log_slow_query(sql, event.duration.milliseconds)
  end
end

Saci.setup_logging unless ENV["SACI_LOG_SETUP"]? == "0"

# :nodoc:
module Saci::SpecLogging
  # Expanded once every file is required, so it sees `Spec` whether the
  # app's spec_helper requires "spec" before or after "saci".
  macro finished
    {% if @top_level.has_constant?("Spec") %}
      ::Spec.before_suite do
        Saci.setup_logging(default_level: :none) unless ENV["SACI_LOG_SETUP"]? == "0"
      end
    {% end %}
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
    def redirect_to(location : String, status : Int32 | Symbol = 302,
                    allow_other_host : Bool = false) : Nil
      if Saci.log_requests
        Saci.logger.info { "Redirected to #{Saci.filter_redirect_value(location)}" }
      end
      previous_def(location, status, allow_other_host)
    end
  end
end
