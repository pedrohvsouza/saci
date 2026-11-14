require "http/server"
require "http/server/handlers/websocket_handler"
require "./middleware"
require "./configuration"
require "./initializers"
require "./server_urls"

# Carries the unhandled exception from the router to `ShowExceptions`, which
# runs outside the router and would otherwise only see a 500 status.
class HTTP::Server::Context
  property saci_exception : Exception?
end

module Saci
  # Rails-like application boot (config.ru / `rails server` equivalent).
  #
  # ```
  # router = Saci::Router.new.draw do |r|
  #   r.get "/hello", HelloController, :index
  # end
  # app = Saci::Application.new(router)
  # app.listen(3000)
  # ```
  #
  # The request chain is:
  #
  # `HTTP::WebSocketHandler -> [enabled built-in middleware] -> [app middleware] -> Saci::Handler`
  #
  # Built-ins (host authorization, static files, CORS, compression, …) are
  # entries in `config.middleware`; they are skipped in the built chain while
  # disabled so they remain valid targets for `insert_before` / `swap`.
  # `TestSession` uses the same chain.
  class Application
    getter router : Router
    getter config : Configuration

    @booted : Bool = false

    # Handlers that must run after configured middleware but before the
    # router. Components (e.g. Action Mailbox ingress body buffering) register
    # here when they are mounted so both `listen` and custom configurations
    # (including `TestSession` with a private `Configuration`) see them.
    @@pre_router_handlers = [] of HTTP::Handler

    def self.add_pre_router_handler(handler : HTTP::Handler) : Nil
      @@pre_router_handlers << handler unless @@pre_router_handlers.any? { |h| h.class == handler.class }
    end

    def self.clear_pre_router_handlers : Nil
      @@pre_router_handlers.clear
    end

    def initialize(@router : Router, @config : Configuration = Saci.config)
    end

    # `saci routes --boot` runs the app with this set: once booted, the
    # app prints its real route table between the markers and exits
    # instead of binding a port. Routes added in loops or helpers, which
    # the static `saci routes` parser cannot see, show up this way.
    ROUTES_DUMP_ENV   = "SACI_ROUTES_DUMP"
    ROUTES_DUMP_BEGIN = "--- saci routes ---"
    ROUTES_DUMP_END   = "--- end saci routes ---"

    # Prints the route table and exits when `SACI_ROUTES_DUMP=1`.
    def dump_routes_if_requested : Nil
      return unless ENV[ROUTES_DUMP_ENV]? == "1"
      STDOUT.puts ROUTES_DUMP_BEGIN
      @router.route_rows.each { |verb, path, target| STDOUT.puts "#{verb}\t#{path}\t#{target}" }
      STDOUT.puts ROUTES_DUMP_END
      STDOUT.flush
      exit 0
    end

    # How many consecutive ports `bind!` tries before giving up.
    PORT_ATTEMPTS = 100

    # Binds the server and returns the port actually bound. When `port` is
    # already in use, tries the next ones (up to `PORT_ATTEMPTS`) instead of
    # crashing, and says which port it picked.
    def self.bind!(server : HTTP::Server, host : String, port : Int32, reuse_port : Bool = false) : Int32
      candidate = port
      loop do
        begin
          bound = server.bind_tcp(host, candidate, reuse_port: reuse_port).port
          STDERR.puts "warning: #{host}:#{port} is already in use; listening on port #{bound} instead." if candidate != port
          return bound
        rescue ex : Socket::BindError
          raise ex unless address_in_use?(ex)
          candidate += 1
          if port == 0 || candidate > 65535 || candidate - port >= PORT_ATTEMPTS
            STDERR.puts "error: #{host}:#{port} and the next #{PORT_ATTEMPTS - 1} ports are all in use."
            exit 1
          end
        end
      end
    end

    def self.address_in_use?(ex : Socket::BindError) : Bool
      ex.os_error == Errno::EADDRINUSE || ex.message.to_s.includes?("Address already in use")
    end

    # Runs the initializer lifecycle exactly once. `listen` calls this; tests
    # that build the handler chain manually can call it explicitly.
    def boot : self
      unless @booted
        @booted = true
        Initializers.run!
      end
      self
    end

    def booted? : Bool
      @booted
    end

    def middleware : Middleware::Stack
      @config.middleware
    end

    # Re-runs `to_prepare` callbacks (reload hook).
    def reload! : Nil
      Initializers.run_to_prepare!
    end

    # Full handler chain as an array. Kept as a class method for backward
    # compatibility with code that did `HTTP::Server.new(Application.handlers(router))`.
    def self.handlers(router : Router) : Array(HTTP::Handler)
      new(router).handlers
    end

    def self.handlers(router : Router, config : Configuration) : Array(HTTP::Handler)
      new(router, config).handlers
    end

    # Full handler chain: websocket upgrades first (no-op for plain HTTP),
    # then enabled built-ins + app middleware, then the router. Shared by
    # `listen` and `TestSession` so tests exercise the exact production stack.
    def handlers : Array(HTTP::Handler)
      HTTP::WebSocket.read_buffer_size = @config.websocket_buffer_size
      ws = Saci::WebSocketHandler.new { |socket, ctx| @router.dispatch_ws(ctx, socket) }
      chain = [ws.as(HTTP::Handler)]
      chain.concat(@config.middleware.handlers(skip_disabled: true))
      chain.concat(@@pre_router_handlers)
      chain << Handler.new(@router).as(HTTP::Handler)
      chain
    end

    # A single linked handler (what `HTTP::Server#initialize` ultimately builds
    # from the array above). Rebuilt on each call so configuration changes take
    # effect without restarting in development.
    def handler : HTTP::Handler
      chain = handlers
      chain.each_with_index do |entry, index|
        entry.next = index + 1 < chain.size ? chain[index + 1] : nil
      end
      chain.first
    end

    def listen(port : Int32 = 3000, host : String = "127.0.0.1") : Nil
      boot
      Saci::GCTuner.start_from_env
      server = Saci::HTTPServer.new(handler, @config.socket_buffer_size)
      if size = @config.max_headers_size
        server.max_headers_size = size
      end
      if size = @config.max_request_line_size
        server.max_request_line_size = size
      end
      dump_routes_if_requested
      port = Application.bind!(server, host, port)
      print Saci::ServerUrls.banner(host, port)
      puts (@router.routes_table + @router.ws_routes_table).join("\n")
      server.listen
    end
  end

  # Terminal handler: forwards to the router. Kept as a named class because
  # apps may reference it when ordering middleware.
  class Handler
    include HTTP::Handler

    def initialize(@router : Router)
    end

    def call(context : HTTP::Server::Context) : Nil
      @router.call(context)
    end
  end

  # Hook the optional error reporter into the router's existing server-error
  # path without changing its response contract. `previous_def` preserves the
  # development detail page / JSON fallback exactly as before.
  class Router
    private def render_server_error(context : HTTP::Server::Context, request : HTTP::Request, path : String, ex : Exception) : Nil
      # Make the exception available to `ShowExceptions` (which only sees the
      # response after the router has handled it) and notify the reporter.
      context.saci_exception = ex
      Saci.report_error(ex)
      previous_def
    end
  end
end
