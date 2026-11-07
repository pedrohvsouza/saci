require "./exceptions"
require "./middleware"
require "./config_file"
require "./deploy"

module Saci
  # Central application configuration (`Rails.application.config` equivalent).
  #
  # ```
  # Saci.configure do |config|
  #   config.hosts = ["example.com", "www.example.com"]
  #   config.assume_ssl = true
  #   config.force_ssl = true
  #   config.healthcheck_path = "/up"
  #   config.max_request_body = 10.megabytes
  #   config.middleware.use AuditHandler.new
  # end
  # ```
  #
  # The existing module-level setters remain valid and share the same storage:
  # `Saci.force_ssl = true` and `Saci.config.force_ssl = true` are equivalent.
  # `Saci.configure` is the preferred place for new settings.
  class Configuration
    # HTTP host allowlist. Empty means "allow every host" (historical Saci
    # behaviour). Setting `host_authorization = false` disables the middleware
    # even when hosts are present.
    property hosts : Array(String) = [] of String
    property host_authorization : Bool = true

    # Proxy addresses (IPs or CIDR blocks) allowed to supply
    # `X-Forwarded-For`. Empty disables `RemoteIp`.
    property trusted_proxies : Array(String) = [] of String

    # Trust a TLS-terminating proxy that does not forward
    # `X-Forwarded-Proto`. Only enable behind such a proxy.
    property assume_ssl : Bool = false

    # Built-in static file serving. Disabled automatically when the root does
    # not exist; set `enabled = false` to turn it off explicitly.
    property public_file_server : Middleware::Static::Settings = Middleware::Static::Settings.new

    # Built-in response compression (opt-in).
    property compression : Middleware::Compression::Settings = Middleware::Compression::Settings.new

    # Built-in CORS. Configure through `config.cors do |cors| ... end`.
    property cors : Middleware::CORS::Settings = Middleware::CORS::Settings.new

    # HSTS / secure-cookie knobs used when `force_ssl` or `assume_ssl` is on.
    property ssl_options : Middleware::SSL::Settings = Middleware::SSL::Settings.new

    # `GET` path for the liveness endpoint; `nil` disables it.
    property healthcheck_path : String? = "/up"
    property silence_healthcheck_path : Bool = true

    # Maximum request body in bytes; `nil` means no framework limit.
    @max_request_body : Int64? = nil
    # Per-socket read/write buffer for the HTTP server (`Saci::HTTPServer`).
    # Small buffers keep idle WebSocket connections cheap. 4000 (not 4096)
    # on purpose: the GC rounds a 4096-byte block plus its header up to two
    # pages, so 4096 would cost 8 KiB per buffer. `nil` restores the
    # stdlib's 32 KiB.
    property socket_buffer_size : Int32? = 4000
    # Read buffer of each `HTTP::WebSocket` (stdlib: 4096, i.e. two pages
    # once the GC header is added). Larger messages are still assembled
    # across reads.
    property websocket_buffer_size : Int32 = 2000
    # Optional stdlib HTTP server limits (applied by `Application#listen`).
    @max_headers_size : Int32? = nil
    @max_request_line_size : Int32? = nil

    # These are deployment knobs. Crystal 1.22's `HTTP::Server` does not expose
    # read/idle timeout setters, so Saci stores them for documentation and
    # proxy/container configuration instead of pretending to enforce them.
    property request_timeout : Time::Span? = nil
    property keep_alive_timeout : Time::Span? = nil

    # Custom error-page callable. When nil, production uses the built-in
    # HTML/text pages (controlled by `default_error_pages`); development keeps
    # the router's detailed page. Setters accept the documented 3-argument
    # form plus 2- and 1-argument conveniences.
    @exceptions_app : Exceptions::App? = nil
    property default_error_pages : Bool = true

    # Extra request-log tags for apps that use `Saci.tagged`; automatic request
    # tagging is intentionally not installed by this middleware.
    property log_tags : Array(String) = [] of String

    # The full middleware stack (built-ins first, then app middleware).
    getter middleware : Middleware::Stack

    def initialize
      @middleware = Middleware::Stack.new
      @middleware.use(Middleware::RemoteIp.new(self))
      @middleware.use(Middleware::HostAuthorization.new(self))
      @middleware.use(Middleware::SSL.new(self))
      @middleware.use(Middleware::Static.new(self))
      @middleware.use(Middleware::HealthCheck.new(self))
      @middleware.use(Middleware::CORS.new(self))
      @middleware.use(Middleware::RequestBodyLimit.new(self))
      @middleware.use(Middleware::ShowExceptions.new(self))
      @middleware.use(Middleware::Compression.new(self))
    end

    # These delegate so `Saci.force_ssl = ...` and `config.force_ssl = ...`
    # cannot drift apart.

    def log_level : Symbol
      Saci.log_level
    end

    def log_level=(value : Symbol) : Symbol
      Saci.log_level = value
      value
    end

    def force_ssl : Bool
      Saci.force_ssl
    end

    def force_ssl=(value : Bool) : Bool
      Saci.force_ssl = value
      value
    end

    def log_requests : Bool
      Saci.log_requests
    end

    def log_requests=(value : Bool) : Bool
      Saci.log_requests = value
      value
    end

    def filter_parameters : Array(String)
      Saci.filter_parameters
    end

    def filter_parameters=(keys : Array(String)) : Array(String)
      Saci.filter_parameters = keys
      keys
    end

    def show_detailed_exceptions : Bool
      Saci.show_detailed_exceptions?
    end

    def show_detailed_exceptions=(value : Bool?) : Bool?
      Saci.show_detailed_exceptions = value
      value
    end

    def error_reporter : Proc(Exception, Nil)?
      Saci.error_reporter
    end

    def error_reporter=(reporter : Nil) : Nil
      Saci.error_reporter = nil
    end

    def error_reporter=(reporter : Proc(Exception, T)) : Nil forall T
      Saci.error_reporter = reporter
    end

    def exceptions_app : Exceptions::App?
      @exceptions_app
    end

    def exceptions_app=(app : Nil) : Nil
      @exceptions_app = nil
    end

    def exceptions_app=(app : Proc(HTTP::Server::Context, Int32, Exception?, T)) : Nil forall T
      @exceptions_app = Exceptions::App.new do |context, status, exception|
        app.call(context, status, exception)
        nil
      end
    end

    def exceptions_app=(app : Proc(HTTP::Server::Context, Int32, T)) : Nil forall T
      @exceptions_app = Exceptions::App.new do |context, status, _exception|
        app.call(context, status)
        nil
      end
    end

    def exceptions_app=(app : Proc(HTTP::Server::Context, T)) : Nil forall T
      @exceptions_app = Exceptions::App.new do |context, _status, _exception|
        app.call(context)
        nil
      end
    end

    def max_request_body : Int64?
      @max_request_body
    end

    def max_request_body=(value : Int?) : Int64?
      @max_request_body = value.try(&.to_i64)
    end

    def max_headers_size : Int32?
      @max_headers_size
    end

    def max_headers_size=(value : Int?) : Int32?
      @max_headers_size = value.try(&.to_i32)
    end

    def max_request_line_size : Int32?
      @max_request_line_size
    end

    def max_request_line_size=(value : Int?) : Int32?
      @max_request_line_size = value.try(&.to_i32)
    end

    def cors(& : Middleware::CORS::Settings ->) : Middleware::CORS::Settings
      yield @cors
      @cors
    end

    def public_file_server(& : Middleware::Static::Settings ->) : Middleware::Static::Settings
      yield @public_file_server
      @public_file_server
    end

    def compression(& : Middleware::Compression::Settings ->) : Middleware::Compression::Settings
      yield @compression
      @compression
    end

    def ssl(& : Middleware::SSL::Settings ->) : Middleware::SSL::Settings
      yield @ssl_options
      @ssl_options
    end

    def use(handler : HTTP::Handler) : Middleware::Stack
      @middleware.use(handler)
    end

    def use(klass : T.class, **options) forall T
      @middleware.use(klass, **options)
    end

    # `Saci.config_for(:database)` reads `config/database.yml` for the current
    # `APP_ENV`. A missing file returns an empty section, so env-var defaults
    # keep working for apps that never create these files.
    def config_for(name : String | Symbol, env : String = Saci.env, dir : String = "config", path : String? = nil) : ConfigFile::Section
      ConfigFile.config_for(name, env: env, dir: dir, path: path)
    end

    def config_for!(name : String | Symbol, env : String = Saci.env, dir : String = "config", path : String? = nil) : ConfigFile::Section
      ConfigFile.config_for!(name, env: env, dir: dir, path: path)
    end
  end

  # Process-wide configuration. Apps normally mutate this in `src/<app>.cr`
  # (or via `Saci.configure`); specs can build a private `Configuration` and
  # pass it to `Saci::Application` / `Saci::TestSession`.
  @@config : Configuration = Configuration.new
  @@config_mutex = Mutex.new

  def self.config : Configuration
    @@config_mutex.synchronize { @@config }
  end

  def self.configuration : Configuration
    config
  end

  def self.config=(value : Configuration) : Configuration
    @@config_mutex.synchronize { @@config = value }
  end

  def self.configure(& : Configuration ->) : Configuration
    current = config
    yield current
    current
  end

  # Rebuilds a pristine global configuration. Useful in specs; middleware
  # instances registered on the old object are intentionally discarded.
  def self.reset_configuration! : Configuration
    self.config = Configuration.new
  end

  # Convenience delegators for the most common configuration knobs.
  def self.hosts : Array(String)
    config.hosts
  end

  def self.hosts=(hosts : Array(String)) : Array(String)
    config.hosts = hosts
  end

  def self.middleware : Middleware::Stack
    config.middleware
  end

  # Rails-like `Rails.application.config_for(:database)` convenience.
  def self.config_for(name : String | Symbol, env : String = Saci.env, dir : String = "config", path : String? = nil) : ConfigFile::Section
    config.config_for(name, env: env, dir: dir, path: path)
  end

  def self.config_for!(name : String | Symbol, env : String = Saci.env, dir : String = "config", path : String? = nil) : ConfigFile::Section
    config.config_for!(name, env: env, dir: dir, path: path)
  end
end
