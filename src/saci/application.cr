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
      print Saci::ServerUrls.banner(host, port)
      puts (@router.routes_table + @router.ws_routes_table).join("\n")
      server.bind_tcp(host, port)
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
