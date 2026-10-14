module Saci
  # Rails-like router (ActionDispatch equivalent).
  #
  # ```
  # router = Saci::Router.new
  # router.draw do |r|
  #   r.get "/hello", HelloController, :index
  #   r.post "/users", UsersController, :create
  #   r.resources "posts", PostsController
  #   r.resources "stories", StoriesController do |s|
  #     s.member do |m|
  #       m.post :upvote   # POST /stories/:id/upvote -> #upvote
  #       m.post :flag
  #     end
  #     s.collection do |c|
  #       c.get :search    # GET /stories/search -> #search
  #     end
  #   end
  #   r.get "/t/:tag", HomeController, :tag, constraints: {"tag" => /[^,.\/]+/}
  #   r.redirect("/u/:username", to: "/~%{username}", status: 301)
  #   r.get "/top(/:length(/page/:page))", HomeController, :top
  #   r.get "/domains/:id(.:format)", HomeController, :for_domain
  #   r.root HomeController, :index
  #   r.namespace(:mod, mod: "Mod") do |m|
  #     m.get "/stats", Mod::StatsController, :index
  #   end
  #   r.get("/ping") { |ctx, params| ctx.response.print("pong") }
  #   r.websocket("/live") { |ws, ctx, params| ws.send("hi") }
  #   r.cable "/cable", ChatChannel
  #   r.fallback ErrorsController, :not_found
  # end
  # ```
  #
  # Routes map to `ControllerClass, :action`. Dispatch itself is fully
  # static (see `Saci::Controller`): the router stores the controller
  # *class* and the action *name*, instantiates the controller per
  # request, runs before filters, then calls `call_action`, which every
  # controller subclass implements via compiler-generated code.
  #
  # Segment notes:
  # * `:name` matches one path segment (`[^/]+`); it may sit inside a
  #   larger segment (`/~:username`, `/avatars/:size.png`).
  # * `*name` matches the rest of the path (wildcard).
  # * `(...)` groups are optional: each route expands to every combination
  #   (most specific first), so `/top(/:length(/page/:page))` serves `/top`,
  #   `/top/3`, and `/top/3/page/2`. `(.:format)` fills `params["format"]`
  #   (`?format=` works everywhere too).
  # * `constraints:` (per route) and the `constraints` block scope segments
  #   to a Regex, e.g. `{"tag" => /[^,.\/]+/}`.
  # * `defaults:` fills params unconditionally, e.g. `{"format" => "rss"}`.
  class Router
    alias Handler = Proc(HTTP::Server::Context, Params, Nil)
    alias WsHandler = Proc(HTTP::WebSocket, HTTP::Server::Context, Params, Nil)

    struct Route
      getter http_method : String
      getter pattern : String
      getter regex : Regex
      getter param_names : Array(String)
      getter handler : Handler
      getter defaults : Hash(String, String)

      def initialize(@http_method, @pattern, @regex, @param_names, @handler, @defaults = {} of String => String)
      end
    end

    # Scope for the `resources ... do |s|` block: `member`/`collection`
    # route builders plus nested `resources` (`/stories/:story_id/...`).
    class ResourceScope
      def initialize(@router : Router, @name : String, @base : String, @controller : Controller.class, @constraints : Hash(String, Regex)?, @defaults : Hash(String, String)?)
      end

      def member(& : MemberScope ->) : Nil
        yield MemberScope.new(@router, @base, @controller, @constraints, @defaults)
      end

      def collection(& : CollectionScope ->) : Nil
        yield CollectionScope.new(@router, @base, @controller, @constraints, @defaults)
      end

      def resources(name : String, controller : Controller.class, only : Array(Symbol)? = nil, except : Array(Symbol)? = nil) : Nil
        @router.resources(nested_base(name), controller, only: only, except: except, constraints: @constraints, defaults: @defaults)
      end

      def resources(name : String, controller : Controller.class, only : Array(Symbol)? = nil, except : Array(Symbol)? = nil, &block : ResourceScope ->) : Nil
        nested = nested_base(name)
        @router.resources(nested, controller, only: only, except: except, constraints: @constraints, defaults: @defaults) do |scope|
          yield scope
        end
      end

      private def nested_base(name : String) : String
        clean = name.starts_with?("/") ? name[1..] : name
        "#{@base}/:#{Router.singularize(@name)}_id/#{clean}"
      end
    end

    # `POST /base/:id/upvote`-style member routes (`m.post :upvote` maps to
    # `#upvote` on the resource's controller).
    class MemberScope
      def initialize(@router : Router, @base : String, @controller : Controller.class, @constraints : Hash(String, Regex)?, @defaults : Hash(String, String)?)
      end

      def get(name : Symbol, action : Symbol? = nil) : Nil
        @router.get("#{@base}/:id/#{name}", @controller, action || name, constraints: @constraints, defaults: @defaults)
      end

      def post(name : Symbol, action : Symbol? = nil) : Nil
        @router.post("#{@base}/:id/#{name}", @controller, action || name, constraints: @constraints, defaults: @defaults)
      end

      def put(name : Symbol, action : Symbol? = nil) : Nil
        @router.put("#{@base}/:id/#{name}", @controller, action || name, constraints: @constraints, defaults: @defaults)
      end

      def patch(name : Symbol, action : Symbol? = nil) : Nil
        @router.patch("#{@base}/:id/#{name}", @controller, action || name, constraints: @constraints, defaults: @defaults)
      end

      def delete(name : Symbol, action : Symbol? = nil) : Nil
        @router.delete("#{@base}/:id/#{name}", @controller, action || name, constraints: @constraints, defaults: @defaults)
      end

      # Custom member paths (`m.post("preview", OtherController, :show)`
      # -> `POST base/:id/preview`).
      def get(path : String, controller : Controller.class, action : Symbol) : Nil
        @router.get("#{@base}/:id/#{MemberScope.clean(path)}", controller, action, constraints: @constraints, defaults: @defaults)
      end

      def post(path : String, controller : Controller.class, action : Symbol) : Nil
        @router.post("#{@base}/:id/#{MemberScope.clean(path)}", controller, action, constraints: @constraints, defaults: @defaults)
      end

      def put(path : String, controller : Controller.class, action : Symbol) : Nil
        @router.put("#{@base}/:id/#{MemberScope.clean(path)}", controller, action, constraints: @constraints, defaults: @defaults)
      end

      def patch(path : String, controller : Controller.class, action : Symbol) : Nil
        @router.patch("#{@base}/:id/#{MemberScope.clean(path)}", controller, action, constraints: @constraints, defaults: @defaults)
      end

      def delete(path : String, controller : Controller.class, action : Symbol) : Nil
        @router.delete("#{@base}/:id/#{MemberScope.clean(path)}", controller, action, constraints: @constraints, defaults: @defaults)
      end

      def self.clean(path : String) : String
        path.starts_with?("/") ? path[1..] : path
      end
    end

    # `GET /base/search`-style collection routes.
    class CollectionScope
      def initialize(@router : Router, @base : String, @controller : Controller.class, @constraints : Hash(String, Regex)?, @defaults : Hash(String, String)?)
      end

      def get(name : Symbol, action : Symbol? = nil) : Nil
        @router.get("#{@base}/#{name}", @controller, action || name, constraints: @constraints, defaults: @defaults)
      end

      def post(name : Symbol, action : Symbol? = nil) : Nil
        @router.post("#{@base}/#{name}", @controller, action || name, constraints: @constraints, defaults: @defaults)
      end

      def put(name : Symbol, action : Symbol? = nil) : Nil
        @router.put("#{@base}/#{name}", @controller, action || name, constraints: @constraints, defaults: @defaults)
      end

      def patch(name : Symbol, action : Symbol? = nil) : Nil
        @router.patch("#{@base}/#{name}", @controller, action || name, constraints: @constraints, defaults: @defaults)
      end

      def delete(name : Symbol, action : Symbol? = nil) : Nil
        @router.delete("#{@base}/#{name}", @controller, action || name, constraints: @constraints, defaults: @defaults)
      end

      def get(path : String, controller : Controller.class, action : Symbol) : Nil
        @router.get("#{@base}/#{MemberScope.clean(path)}", controller, action, constraints: @constraints, defaults: @defaults)
      end

      def post(path : String, controller : Controller.class, action : Symbol) : Nil
        @router.post("#{@base}/#{MemberScope.clean(path)}", controller, action, constraints: @constraints, defaults: @defaults)
      end

      def put(path : String, controller : Controller.class, action : Symbol) : Nil
        @router.put("#{@base}/#{MemberScope.clean(path)}", controller, action, constraints: @constraints, defaults: @defaults)
      end

      def patch(path : String, controller : Controller.class, action : Symbol) : Nil
        @router.patch("#{@base}/#{MemberScope.clean(path)}", controller, action, constraints: @constraints, defaults: @defaults)
      end

      def delete(path : String, controller : Controller.class, action : Symbol) : Nil
        @router.delete("#{@base}/#{MemberScope.clean(path)}", controller, action, constraints: @constraints, defaults: @defaults)
      end
    end

    getter routes : Array(Route)

    # NOTE(auth track): moved here from #initialize — ivar type declarations
    # are only legal at class level (was a compile error). No behavior change.
    @fallback : Handler?

    def initialize
      @routes = [] of Route
      @ws_routes = [] of Tuple(Regex, Array(String), String, WsHandler)
      @prefix_stack = [] of String
      @module_stack = [] of String
      @constraints_stack = [] of Hash(String, Regex)
      @fallback = nil
    end

    # DSL entrypoint: `router.draw { |r| r.get ... }`
    def draw(&block : self ->) : self
      yield self
      self
    end

    # Low-level registration. Also powers plain block routes:
    #   r.add("GET", "/ping") { |ctx, params| ctx.response.print("pong") }
    # Patterns with `(...)` optional groups expand to one route per
    # combination (most specific first).
    def add(http_method : String, pattern : String, constraints : Hash(String, Regex)? = nil, defaults : Hash(String, String)? = nil, &handler : HTTP::Server::Context, Params ->) : Nil
      merged = merge_constraints(constraints)
      ds = defaults || {} of String => String
      self.class.expand_optional(normalize_pattern(pattern)).each do |full|
        full = full.gsub(/\/+/, "/")
        regex, names = self.class.compile(full, merged)
        @routes << Route.new(http_method.upcase, full, regex, names, Handler.new { |ctx, p| handler.call(ctx, p); nil }, ds)
      end
    end

    # -- controller routes -------------------------------------------------

    def get(path : String, controller : Controller.class, action : Symbol, constraints : Hash(String, Regex)? = nil, defaults : Hash(String, String)? = nil) : Nil
      add("GET", path, constraints, defaults) do |ctx, params|
        dispatch(controller, action, ctx, params)
      end
    end

    def post(path : String, controller : Controller.class, action : Symbol, constraints : Hash(String, Regex)? = nil, defaults : Hash(String, String)? = nil) : Nil
      add("POST", path, constraints, defaults) do |ctx, params|
        dispatch(controller, action, ctx, params)
      end
    end

    def put(path : String, controller : Controller.class, action : Symbol, constraints : Hash(String, Regex)? = nil, defaults : Hash(String, String)? = nil) : Nil
      add("PUT", path, constraints, defaults) do |ctx, params|
        dispatch(controller, action, ctx, params)
      end
    end

    def patch(path : String, controller : Controller.class, action : Symbol, constraints : Hash(String, Regex)? = nil, defaults : Hash(String, String)? = nil) : Nil
      add("PATCH", path, constraints, defaults) do |ctx, params|
        dispatch(controller, action, ctx, params)
      end
    end

    def delete(path : String, controller : Controller.class, action : Symbol, constraints : Hash(String, Regex)? = nil, defaults : Hash(String, String)? = nil) : Nil
      add("DELETE", path, constraints, defaults) do |ctx, params|
        dispatch(controller, action, ctx, params)
      end
    end

    # Plain block routes sharing the verb (overloads by arity/block).
    def get(path : String, constraints : Hash(String, Regex)? = nil, defaults : Hash(String, String)? = nil, &handler : HTTP::Server::Context, Params ->) : Nil
      add("GET", path, constraints, defaults, &handler)
    end

    def post(path : String, constraints : Hash(String, Regex)? = nil, defaults : Hash(String, String)? = nil, &handler : HTTP::Server::Context, Params ->) : Nil
      add("POST", path, constraints, defaults, &handler)
    end

    def put(path : String, constraints : Hash(String, Regex)? = nil, defaults : Hash(String, String)? = nil, &handler : HTTP::Server::Context, Params ->) : Nil
      add("PUT", path, constraints, defaults, &handler)
    end

    def patch(path : String, constraints : Hash(String, Regex)? = nil, defaults : Hash(String, String)? = nil, &handler : HTTP::Server::Context, Params ->) : Nil
      add("PATCH", path, constraints, defaults, &handler)
    end

    def delete(path : String, constraints : Hash(String, Regex)? = nil, defaults : Hash(String, String)? = nil, &handler : HTTP::Server::Context, Params ->) : Nil
      add("DELETE", path, constraints, defaults, &handler)
    end

    def root(controller : Controller.class, action : Symbol) : Nil
      get("/", controller, action)
    end

    # Rails-style `resources`. Generates:
    #   GET    /name          -> index
    #   GET    /name/new      -> new
    #   GET    /name/:id      -> show
    #   POST   /name          -> create
    #   PUT    /name/:id      -> update
    #   PATCH  /name/:id      -> update
    #   DELETE /name/:id      -> destroy
    #   GET    /name/:id/edit -> edit
    # (`new` registers before `show` so `/name/new` wins over `/:id`.)
    # With a block, `member`/`collection` routes and nested resources:
    #   r.resources "stories", StoriesController do |s|
    #     s.member { |m| m.post :upvote }
    #     s.collection { |c| c.get :search }
    #     s.resources "suggestions", SuggestionsController, only: [:new, :create]
    #   end
    def resources(name : String, controller : Controller.class, only : Array(Symbol)? = nil, except : Array(Symbol)? = nil, constraints : Hash(String, Regex)? = nil, defaults : Hash(String, String)? = nil) : Nil
      base_resources(name, controller, only, except, constraints, defaults)
    end

    def resources(name : String, controller : Controller.class, only : Array(Symbol)? = nil, except : Array(Symbol)? = nil, constraints : Hash(String, Regex)? = nil, defaults : Hash(String, String)? = nil, &block : ResourceScope ->) : Nil
      # Member/collection routes register first so e.g. GET /base/search
      # wins over GET /base/:id (Rails order).
      base = name.starts_with?("/") ? name : "/" + name
      yield ResourceScope.new(self, name, base, controller, constraints, defaults)
      base_resources(name, controller, only, except, constraints, defaults)
    end

    private def base_resources(name : String, controller : Controller.class, only : Array(Symbol)?, except : Array(Symbol)?, constraints : Hash(String, Regex)?, defaults : Hash(String, String)?) : String
      actions = [:index, :new, :show, :create, :update, :destroy, :edit]
      actions = actions & only if only
      actions = actions - except if except
      base = name.starts_with?("/") ? name : "/" + name
      if actions.includes?(:index)
        get(base, controller, :index, constraints: constraints, defaults: defaults)
      end
      if actions.includes?(:new)
        get("#{base}/new", controller, :new, constraints: constraints, defaults: defaults)
      end
      if actions.includes?(:show)
        get("#{base}/:id", controller, :show, constraints: constraints, defaults: defaults)
      end
      if actions.includes?(:create)
        post(base, controller, :create, constraints: constraints, defaults: defaults)
      end
      if actions.includes?(:update)
        put("#{base}/:id", controller, :update, constraints: constraints, defaults: defaults)
        patch("#{base}/:id", controller, :update, constraints: constraints, defaults: defaults)
      end
      if actions.includes?(:destroy)
        delete("#{base}/:id", controller, :destroy, constraints: constraints, defaults: defaults)
      end
      if actions.includes?(:edit)
        get("#{base}/:id/edit", controller, :edit, constraints: constraints, defaults: defaults)
      end
      base
    end

    # Prefix all routes inside the block (like Rails `namespace`/`scope`).
    # `mod:` records the Crystal module holding the controllers
    # (documentation for readers; pass fully-qualified classes explicitly):
    #   r.namespace(:mod, mod: "Mod") do |m|
    #     m.get "/stats", Mod::StatsController, :index   # -> /mod/stats
    #   end
    def namespace(prefix : String | Symbol, mod : String? = nil, &block : self ->) : Nil
      @prefix_stack << normalize_prefix(prefix.to_s)
      @module_stack << mod if mod
      yield self
    ensure
      @prefix_stack.pop
      @module_stack.pop if mod
    end

    def scope(prefix : String | Symbol, &block : self ->) : Nil
      namespace(prefix, &block)
    end

    # Block-scoped default segment constraints
    # (Rails `constraints id: /.../ do`):
    #   r.constraints({"id" => /[^\/]+/}) do |c|
    #     c.get "/domains/:id", HomeController, :for_domain
    #   end
    # Per-route `constraints:` override block defaults per segment.
    def constraints(mapping : Hash(String, Regex), &block : self ->) : Nil
      @constraints_stack << mapping
      yield self
    ensure
      @constraints_stack.pop
    end

    # Redirect route (Rails `to: redirect(...)` as a first-class DSL).
    # Placeholders take path params in both `:name` and `%{name}` styles:
    #   r.redirect("/upvoted", to: "/upvoted/stories")
    #   r.redirect("/u/:username", to: "/~%{username}", status: 301)
    def redirect(from : String, *, to : String, status : Int32 | Symbol = 302, constraints : Hash(String, Regex)? = nil) : Nil
      code = status.is_a?(Symbol) ? Controller.status_code_for(status) : status
      get(from, constraints: constraints) do |ctx, params|
        location = self.class.interpolate(to, params)
        ctx.response.status_code = code
        ctx.response.headers["Location"] = location
        ctx.response.content_type = "text/plain"
        ctx.response.print("Redirecting to #{location}")
      end
    end

    # Catch-all for otherwise unmatched requests (any method/path).
    # Register last; a plain `get "/*path"` route works too but only for GET.
    def fallback(controller : Controller.class, action : Symbol) : Nil
      @fallback = Handler.new { |ctx, p| dispatch(controller, action, ctx, p); nil }
    end

    def fallback(&handler : HTTP::Server::Context, Params ->) : Nil
      @fallback = Handler.new { |ctx, p| handler.call(ctx, p); nil }
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
          path_params = route.defaults.dup
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
      begin
        if ctrl.run_before_filters(action)
          unless ctrl.performed?
            ctrl.call_action(action)
          end
        end
      rescue ex : ActionNotFound
        ctx.response.status_code = 500
        ctx.response.content_type = "application/json"
        ctx.response.print({error: ex.message}.to_json)
        return
      rescue ex : Exception
        raise ex unless ctrl.run_rescue(ex)
      end
      ctrl.run_after_filters(action)
      # Persist session/flash (headers flush lazily at close, so this is
      # safe even after the action rendered).
      ctrl.persist_session!
      unless ctrl.performed?
        ctx.response.status_code = 500
        ctx.response.content_type = "application/json"
        ctx.response.print({error: "No response from action #{controller}##{action} (missing render/redirect?)"}.to_json)
      end
    end

    def find(method : String, path : String) : {Route, Hash(String, String)}?
      @routes.each do |route|
        next unless route.http_method == method.upcase
        if m = route.regex.match(path)
          path_params = route.defaults.dup
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
          rescue ex : Exception
            handle_handler_error(context, request, path, ex)
          end
        else
          context.response.status_code = 404
          context.response.content_type = "application/json"
          context.response.print({error: "Not Found: #{method} #{path}"}.to_json)
        end
      elsif fb = @fallback
        params = Params.build(request, {} of String => String)
        logged_params = params.to_h
        begin
          fb.call(context, params)
        rescue ex : Exception
          handle_handler_error(context, request, path, ex)
        end
      else
        context.response.status_code = 404
        context.response.content_type = "application/json"
        context.response.print({error: "Not Found: #{request.method} #{path}"}.to_json)
      end
      log_request(context, request, path, started, logged_params, request_id)
    end

    private def handle_handler_error(context : HTTP::Server::Context, request : HTTP::Request, path : String, ex : Exception) : Nil
      case ex
      when ParameterMissing
        context.response.status_code = 400
        context.response.content_type = "application/json"
        context.response.print({error: ex.message}.to_json)
      when InvalidAuthenticityToken
        context.response.status_code = 422
        context.response.content_type = "application/json"
        context.response.print({error: ex.message}.to_json)
      when Controller::UnknownFormat
        context.response.status_code = 406
        context.response.content_type = "application/json"
        context.response.print({error: ex.message}.to_json)
      else
        render_server_error(context, request, path, ex)
      end
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

    private def merge_constraints(own : Hash(String, Regex)?) : Hash(String, Regex)?
      return own if @constraints_stack.empty?
      merged = {} of String => Regex
      @constraints_stack.each do |mapping|
        mapping.each { |k, v| merged[k] = v }
      end
      own.try(&.each { |k, v| merged[k] = v })
      merged
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

    # Expands `(...)` optional groups to every combination, most specific
    # first (so `/d/:id(.:format)` registers the `:format` route before the
    # bare one — first match wins).
    def self.expand_optional(pattern : String) : Array(String)
      m = pattern.match(/\(([^()]+)\)/)
      return [pattern] unless m
      inner = m[1]
      with_inner = pattern.sub(m[0], inner)
      without = pattern.sub(m[0], "")
      (expand_optional(with_inner) + expand_optional(without)).sort_by!(&.size).reverse!
    end

    # Fills `:name` and `%{name}` placeholders from params (missing keys
    # keep their literal text).
    def self.interpolate(target : String, params : Params) : String
      interpolate_colons(interpolate_percents(target, params), params)
    end

    private def self.interpolate_percents(target : String, params : Params) : String
      String.build do |io|
        last = 0
        target.scan(/%\{([A-Za-z_][A-Za-z0-9_]*)\}/) do |m|
          io << target[last...m.begin(0)]
          io << URI.encode_path_segment(params[m[1]]? || m[0])
          last = m.end(0)
        end
        io << target[last..]
      end
    end

    private def self.interpolate_colons(target : String, params : Params) : String
      String.build do |io|
        last = 0
        target.scan(/(^|[^A-Za-z0-9_%}]):([A-Za-z_][A-Za-z0-9_]*)/) do |m|
          io << target[last...m.begin(0)]
          io << m[1]
          io << URI.encode_path_segment(params[m[2]]? || ":#{m[2]}")
          last = m.end(0)
        end
        io << target[last..]
      end
    end

    # `"stories"` -> `"story"` (nested resource parent param naming).
    def self.singularize(word : String) : String
      w = word.split("/").last
      if w.ends_with?("ies") && w.size > 3
        w[0...-3] + "y"
      elsif w.ends_with?("s") && w.size > 1
        w[0...-1]
      else
        w
      end
    end

    def self.compile(pattern : String, constraints : Hash(String, Regex)? = nil) : {Regex, Array(String)}
      names = [] of String
      parts = pattern.split("/").map do |seg|
        compile_segment(seg, names, constraints)
      end
      {Regex.new("^" + parts.join("/") + "$"), names}
    end

    private def self.compile_segment(seg : String, names : Array(String), constraints : Hash(String, Regex)?) : String
      return Regex.escape(seg) unless seg.includes?(':') || seg.includes?('*')
      io = IO::Memory.new
      i = 0
      while i < seg.size
        c = seg[i]
        if c == ':' && i + 1 < seg.size && (seg[i + 1].ascii_letter? || seg[i + 1] == '_')
          j = i + 1
          while j < seg.size && (seg[j].alphanumeric? || seg[j] == '_')
            j += 1
          end
          name = seg[i + 1...j]
          names << name unless names.includes?(name)
          if cstr = constraints.try(&.[name]?)
            io << "(?<#{name}>#{cstr.source})"
          else
            io << "(?<#{name}>[^/]+)"
          end
          i = j
        elsif c == '*'
          j = i + 1
          while j < seg.size && (seg[j].alphanumeric? || seg[j] == '_')
            j += 1
          end
          name = j > i + 1 ? seg[i + 1...j] : "splat"
          names << name unless names.includes?(name)
          io << "(?<#{name}>.*)"
          i = j
        else
          io << Regex.escape(c.to_s)
          i += 1
        end
      end
      io.to_s
    end
  end
end
