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
  class Application
    getter router : Router

    def initialize(@router : Router)
    end

    # Full handler chain: websocket upgrades first (no-op for plain HTTP),
    # then the router. Shared by `listen` and `TestSession` so tests
    # exercise the exact production stack.
    def self.handlers(router : Router) : Array(HTTP::Handler)
      ws = HTTP::WebSocketHandler.new { |socket, ctx| router.dispatch_ws(ctx, socket) }
      [ws.as(HTTP::Handler), Handler.new(router).as(HTTP::Handler)]
    end

    def handler : HTTP::Handler
      Saci::Handler.new(@router)
    end

    def listen(port : Int32 = 3000, host : String = "127.0.0.1") : Nil
      server = HTTP::Server.new(Application.handlers(@router))
      puts "Saci listening on http://#{host}:#{port}"
      puts (@router.routes_table + @router.ws_routes_table).join("\n")
      server.bind_tcp(host, port)
      server.listen
    end
  end

  class Handler
    include HTTP::Handler

    def initialize(@router : Router)
    end

    def call(context : HTTP::Server::Context) : Nil
      @router.call(context)
    end
  end
end
