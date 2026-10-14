module Saci
  # Rails-like router (ActionDispatch equivalent).
  #
  # ```
  # router = Saci::Router.new
  # router.draw do |r|
  #   r.get "/hello", HelloController, :index
  #   r.post "/users", UsersController, :create
  #   r.resources "posts", PostsController
  #   r.root HomeController, :index
  #   r.namespace("/api") do |api|
  #     api.get "/status", StatusController, :show
  #   end
  #   r.get("/ping") { |ctx, params| ctx.response.print("pong") }
  #   r.websocket("/live") { |ws, ctx, params| ws.send("hi") }
  #   r.cable "/cable", ChatChannel
  # end
  # ```
  #
  # Routes map to `ControllerClass, :action`. Dispatch itself is fully
  # static (see `Saci::Controller`): the router stores the controller
  # *class* and the action *name*, instantiates the controller per
  # request, runs before filters, then calls `call_action`, which every
  # controller subclass implements via compiler-generated code.
  class Router
    alias Handler = Proc(HTTP::Server::Context, Params, Nil)
    alias WsHandler = Proc(HTTP::WebSocket, HTTP::Server::Context, Params, Nil)

    struct Route
      getter http_method : String
      getter pattern : String
      getter regex : Regex
      getter param_names : Array(String)
      getter handler : Handler

      def initialize(@http_method, @pattern, @regex, @param_names, @handler)
      end
    end

    getter routes : Array(Route)

    def initialize
      @routes = [] of Route
      @ws_routes = [] of Tuple(Regex, Array(String), String, WsHandler)
      @prefix_stack = [] of String
    end

    # DSL entrypoint: `router.draw { |r| r.get ... }`
    def draw(&block : self ->) : self
      yield self
      self
    end

    # Low-level registration. Also powers plain block routes:
    #   r.add("GET", "/ping") { |ctx, params| ctx.response.print("pong") }
    def add(http_method : String, pattern : String, &handler : HTTP::Server::Context, Params ->) : Nil
      full = normalize_pattern(pattern)
      regex, names = self.class.compile(full)
      @routes << Route.new(http_method.upcase, full, regex, names, Handler.new { |ctx, p| handler.call(ctx, p); nil })
    end

    # -- controller routes -------------------------------------------------

    def get(path : String, controller : Controller.class, action : Symbol) : Nil
      add("GET", path) do |ctx, params|
        dispatch(controller, action, ctx, params)
      end
    end

    def post(path : String, controller : Controller.class, action : Symbol) : Nil
      add("POST", path) do |ctx, params|
        dispatch(controller, action, ctx, params)
      end
    end

    def put(path : String, controller : Controller.class, action : Symbol) : Nil
      add("PUT", path) do |ctx, params|
        dispatch(controller, action, ctx, params)
      end
    end

    def patch(path : String, controller : Controller.class, action : Symbol) : Nil
      add("PATCH", path) do |ctx, params|
        dispatch(controller, action, ctx, params)
      end
    end

    def delete(path : String, controller : Controller.class, action : Symbol) : Nil
      add("DELETE", path) do |ctx, params|
        dispatch(controller, action, ctx, params)
      end
    end

    # Plain block routes sharing the verb (overloads by arity/block).
    def get(path : String, &handler : HTTP::Server::Context, Params ->) : Nil
      add("GET", path, &handler)
    end

    def post(path : String, &handler : HTTP::Server::Context, Params ->) : Nil
      add("POST", path, &handler)
    end

    def put(path : String, &handler : HTTP::Server::Context, Params ->) : Nil
      add("PUT", path, &handler)
    end

    def patch(path : String, &handler : HTTP::Server::Context, Params ->) : Nil
      add("PATCH", path, &handler)
    end

    def delete(path : String, &handler : HTTP::Server::Context, Params ->) : Nil
      add("DELETE", path, &handler)
    end

    def root(controller : Controller.class, action : Symbol) : Nil
      get("/", controller, action)
    end

    # Rails-style `resources`. Generates:
    #   GET    /name          -> index
    #   GET    /name/:id      -> show
    #   POST   /name          -> create
    #   PUT    /name/:id      -> update
    #   PATCH  /name/:id      -> update
    #   DELETE /name/:id      -> destroy
    def resources(name : String, controller : Controller.class, only : Array(Symbol)? = nil, except : Array(Symbol)? = nil) : Nil
      actions = [:index, :show, :create, :update, :destroy]
      actions = actions & only if only
      actions = actions - except if except
      base = name.starts_with?("/") ? name : "/" + name
      if actions.includes?(:index)
        get(base, controller, :index)
      end
      if actions.includes?(:show)
        get("#{base}/:id", controller, :show)
      end
      if actions.includes?(:create)
        post(base, controller, :create)
      end
      if actions.includes?(:update)
        put("#{base}/:id", controller, :update)
        patch("#{base}/:id", controller, :update)
      end
      if actions.includes?(:destroy)
        delete("#{base}/:id", controller, :destroy)
      end
    end

    # Prefix all routes inside the block (like Rails `namespace`/`scope`).
    def namespace(prefix : String, &block : self ->) : Nil
      @prefix_stack << normalize_prefix(prefix)
      yield self
    ensure
      @prefix_stack.pop
    end

    def scope(prefix : String, &block : self ->) : Nil
      namespace(prefix, &block)
    end

    # -- websocket routes ------------------------------------------------------
    #
    # Raw socket route (escape hatch):
    #   r.websocket("/live") { |ws, ctx, params| ws.send("hi") }
    #
    # ActionCable-style multiplexed endpoint:
    #   r.cable "/cable", ChatChannel, NotificationsChannel
    def websocket(path : String, &handler : HTTP::WebSocket, HTTP::Server::Context, Params ->) : Nil
      full = normalize_pattern(path)
      regex, names = self.class.compile(full)
      @ws_routes << {regex, names, full, WsHandler.new { |ws, ctx, p| handler.call(ws, ctx, p); nil }}
    end

    def cable(path : String, *channels : Cable::Channel.class, server : Cable::Server? = nil) : Nil
      srv = server || Cable.server
      registry = {} of String => Cable::Channel.class
      channels.each { |c| registry[c.name] = c }
      websocket(path) do |socket, _ctx, params|
        Cable.handle(socket, params, registry, srv)
      end
    end

    def ws_routes_table : Array(String)
      @ws_routes.map { |(_, _, pattern, _)| "WS     #{pattern}" }
    end

    def find_ws(path : String) : {WsHandler, Hash(String, String)}?
      @ws_routes.each do |regex, names, _, handler|
        if m = regex.match(path)
          path_params = {} of String => String
          names.each do |name|
            path_params[name] = URI.decode(m[name]? || "")
          end
          return {handler, path_params}
        end
      end
      nil
    end

    # First route matching the path regardless of HTTP method (used to read
    # `_method` overrides before final dispatch).
    def find_path(path : String) : {Route, Hash(String, String)}?
      @routes.each do |route|
        if m = route.regex.match(path)
          path_params = {} of String => String
          route.param_names.each do |name|
            path_params[name] = URI.decode(m[name]? || "")
          end
          return {route, path_params}
        end
      end
      nil
    end

    # Rails-style `Rack::MethodOverride`: POST forms tunnel PUT/PATCH/DELETE
    # through a hidden `_method` param (also what `form_with`/`link_to` emit).
    def override_method(request : HTTP::Request, params : Params) : String?
      return nil unless request.method == "POST"
      case params["_method"]?.try(&.upcase)
      when "PUT", "PATCH", "DELETE" then params["_method"].upcase
      else                               nil
      end
    end

    # Invoked by the websocket handler after the upgrade handshake.
    def dispatch_ws(context : HTTP::Server::Context, socket : HTTP::WebSocket) : Nil
      path = context.request.path || "/"
      if found = find_ws(path)
        handler, path_params = found
        params = Params.build(context.request, path_params)
        begin
          handler.call(socket, context, params)
        rescue
          begin
            socket.close
          rescue
          end
        end
      else
        begin
          socket.close
        rescue
        end
      end
    end

    # -- dispatch -----------------------------------------------------------

    private def dispatch(controller : Controller.class, action : Symbol, ctx : HTTP::Server::Context, params : Params) : Nil
      ctrl = controller.new(ctx, params, action)
      # Secure defaults first so filters/actions can still override them.
      SecureHeaders.apply!(ctx.response)
      if ctrl.run_before_filters(action)
        unless ctrl.performed?
          ctrl.call_action(action)
        end
      end
      # Persist session/flash (headers flush lazily at close, so this is
      # safe even after the action rendered).
      ctrl.persist_session!
      unless ctrl.performed?
        ctx.response.status_code = 500
        ctx.response.content_type = "application/json"
        ctx.response.print({error: "No response from action #{controller}##{action} (missing render/redirect?)"}.to_json)
      end
    rescue ex : ActionNotFound
      ctx.response.status_code = 500
      ctx.response.content_type = "application/json"
      ctx.response.print({error: ex.message}.to_json)
    end

    def find(method : String, path : String) : {Route, Hash(String, String)}?
      @routes.each do |route|
        next unless route.http_method == method.upcase
        if m = route.regex.match(path)
          path_params = {} of String => String
          route.param_names.each do |name|
            path_params[name] = URI.decode(m[name]? || "")
          end
          return {route, path_params}
        end
      end
      nil
    end

    def call(context : HTTP::Server::Context) : Nil
      request = context.request
      path = request.path || "/"
      started = Time.instant
      request_id = request.headers["X-Request-Id"]? || Saci.request_id
      context.response.headers["X-Request-Id"] = request_id
      logged_params = {} of String => String
      if Throttle.blocked?(context)
        context.response.status_code = 403
        context.response.content_type = "application/json"
        context.response.print({error: "Forbidden"}.to_json)
      elsif retry_after = Throttle.check(context)
        context.response.status_code = 429
        context.response.content_type = "application/json"
        context.response.headers["Retry-After"] = retry_after.to_s
        context.response.print({error: "Too many requests"}.to_json)
      elsif Saci.force_ssl && !https_request?(request) && !local_request?(request)
        host = request.headers["Host"]? || "localhost"
        query = request.query.try { |q| "?#{q}" } || ""
        context.response.status_code = 301
        context.response.headers["Location"] = "https://#{host}#{path}#{query}"
      elsif path_match = (find(request.method, path) || find_path(path))
        _, path_params = path_match
        params = Params.build(request, path_params)
        logged_params = params.to_h
        method = override_method(request, params) || request.method
        if found = find(method, path)
          route, _ = found
          begin
            route.handler.call(context, params)
          rescue ex : ParameterMissing
            context.response.status_code = 400
            context.response.content_type = "application/json"
            context.response.print({error: ex.message}.to_json)
          rescue ex : InvalidAuthenticityToken
            context.response.status_code = 422
            context.response.content_type = "application/json"
            context.response.print({error: ex.message}.to_json)
          rescue ex
            render_server_error(context, request, path, ex)
          end
        else
          context.response.status_code = 404
          context.response.content_type = "application/json"
          context.response.print({error: "Not Found: #{method} #{path}"}.to_json)
        end
      else
        context.response.status_code = 404
        context.response.content_type = "application/json"
        context.response.print({error: "Not Found: #{request.method} #{path}"}.to_json)
      end
      log_request(context, request, path, started, logged_params, request_id)
    end

    private def render_server_error(context : HTTP::Server::Context, request : HTTP::Request, path : String, ex : Exception) : Nil
      context.response.status_code = 500
      if Saci.show_detailed_exceptions?
        context.response.content_type = "text/html; charset=utf-8"
        backtrace = (ex.backtrace? || [] of String).first(15).map { |line| HTML.escape(line) }.join("<br>")
        context.response.print(<<-HTML)
          <html><head><title>#{HTML.escape(ex.class.to_s)} (Saci dev page)</title></head>
          <body style="font-family: monospace; padding: 2em">
          <h1>#{HTML.escape(ex.class.to_s)}</h1>
          <p><strong>#{HTML.escape(request.method)} #{HTML.escape(path)}</strong></p>
          <p>#{HTML.escape(ex.message || "")}</p>
          <pre>#{backtrace}</pre>
          </body></html>
          HTML
      else
        context.response.content_type = "application/json"
        context.response.print({error: "Internal Server Error"}.to_json)
      end
    end

    private def https_request?(request : HTTP::Request) : Bool
      request.headers["X-Forwarded-Proto"]?.try(&.downcase) == "https"
    end

    private def local_request?(request : HTTP::Request) : Bool
      host = (request.headers["Host"]? || "").split(":").first.downcase
      {"localhost", "127.0.0.1", "::1"}.includes?(host)
    end

    private def log_request(context : HTTP::Server::Context, request : HTTP::Request, path : String, started : Time::Instant, params : Hash(String, String), request_id : String) : Nil
      return unless Saci.log_requests
      elapsed = (Time.instant - started).total_milliseconds
      Saci.logger.info { Saci.request_log_line(request.method, path, context.response.status_code, elapsed, params, request_id) }
    end

    def routes_table : Array(String)
      @routes.map { |r| "#{r.http_method.ljust(6)} #{r.pattern}" }
    end

    # -- internals ----------------------------------------------------------

    protected def current_prefix : String
      @prefix_stack.join("")
    end

    private def normalize_pattern(pattern : String) : String
      full = current_prefix + pattern
      full = "/" + full unless full.starts_with?("/")
      full = full.gsub(/\/+/, "/")
      full = "/" if full.empty?
      full
    end

    private def normalize_prefix(prefix : String) : String
      p = prefix.starts_with?("/") ? prefix : "/" + prefix
      p.ends_with?("/") ? p[0...-1] : p
    end

    def self.compile(pattern : String) : {Regex, Array(String)}
      names = [] of String
      parts = pattern.split("/").map do |seg|
        if seg.starts_with?(":")
          name = seg[1..]
          names << name
          "(?<#{name}>[^/]+)"
        elsif seg.starts_with?("*")
          name = seg[1..].empty? ? "splat" : seg[1..]
          names << name
          "(?<#{name}>.*)"
        else
          Regex.escape(seg)
        end
      end
      {Regex.new("^" + parts.join("/") + "$"), names}
    end
  end
end
