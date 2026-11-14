require "./route_helpers"
require "./routes_macro"

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
  #       m.post :upvote # POST /stories/:id/upvote -> #upvote
  #       m.post :flag
  #     end
  #     s.collection do |c|
  #       c.get :search # GET /stories/search -> #search
  #     end
  #   end
  #   r.get "/t/:tag", HomeController, :tag, constraints: {"tag" => /[^,.\/]+/}
  #   r.redirect("/u/:username", to: "/~%{username}", status: 301)
  #   r.get "/top(/:length(/page/:page))", HomeController, :top
  #   r.get "/domains/:id(.:format)", HomeController, :for_domain
  #   r.root HomeController, :index
  #   r.resources "posts", PostsController, as: :articles
  #   r.get "/health", HealthController, :show, as: :health
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
  #   larger segment with static prefix/suffix literals anywhere in the
  #   segment (`/~:username`, `/@:username`, `/avatars/:username_size.png`
  #   where `.png` is a literal suffix, `/:name.json`, `:a_:b` multi-param).
  #   The parser splits each segment on `:` keeping prefix/suffix literals
  #   (escaped) around each `(?<name>[^/]+)` capture.
  # * `*name` matches the rest of the path (wildcard).
  # * `(...)` groups are optional: each route expands to every combination
  #   (most specific first), so `/top(/:length(/page/:page))` serves `/top`,
  #   `/top/3`, and `/top/3/page/2`. `(.:format)` fills `params["format"]`
  #   (`?format=` works everywhere too).
  # * `constraints:` (per route) and the `constraints` block scope segments
  #   to a Regex, e.g. `{"tag" => /[^,.\/]+/}`.
  # * `defaults:` fills params unconditionally, e.g. `{"format" => "rss"}`.
  #
  # Named routes: every declaration accepts `as:` and registers a name in
  # the runtime registry (`router.path_for("post", 1)`). `resources`,
  # `resource`, `namespace`, `root`, `member` and `collection` generate
  # Rails-style names (`posts_path`, `new_post_path`, `edit_post_path`,
  # `post_comments_path`, `admin_posts_path`, `search_posts_path`, ...).
  # Compile-time `posts_path` methods are generated separately by
  # `Saci::Routes.define` (see `routes_macro.cr`); Crystal cannot create
  # methods from a runtime `draw` block.
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
      getter name : String?
      getter controller : (Controller.class | Nil)
      getter action : Symbol?

      def initialize(@http_method, @pattern, @regex, @param_names, @handler, @defaults = {} of String => String, @name = nil, @controller = nil, @action = nil)
      end

      # Aliases used by introspection consumers (`saci routes --expanded`).
      def path : String
        @pattern
      end

      def method : String
        @http_method
      end

      def verb : String
        @http_method
      end

      def helper_name : String?
        @name
      end

      def required_param_names : Array(String)
        RouteHelpers.required_param_names(@pattern)
      end

      def inspect(io : IO) : Nil
        io << @http_method << ' ' << @pattern
        io << " (" << @name << ')' if @name
        io << " -> " << @controller << '#' << @action if @controller && @action
      end
    end

    # A name -> path template entry. One entry may be used by several verbs
    # (`posts` is both GET index and POST create) and by several Route
    # objects (`post` is show/update/destroy).
    class NamedRoute
      getter name : String
      getter pattern : String
      getter http_methods : Array(String)
      getter controller : (Controller.class | Nil)
      getter action : Symbol?
      getter defaults : Hash(String, String)
      getter direct : Proc(Hash(String, String), String)?
      getter direct_required : Array(String)

      def initialize(@name, @pattern, @http_methods, @controller, @action, @defaults, @direct = nil,
                     @direct_required = [] of String)
      end

      def required_param_names : Array(String)
        RouteHelpers.required_param_names(@pattern)
      end

      def param_names : Array(String)
        RouteHelpers.param_names(@pattern)
      end

      def inspect(io : IO) : Nil
        io << @name << " => " << @pattern
      end
    end

    # Structured result returned by `recognize_path`. Controllers/views can
    # use it for 404 debugging or route-aware links.
    struct RecognizedRoute
      getter name : String?
      getter http_method : String
      getter pattern : String
      getter controller : (Controller.class | Nil)
      getter action : Symbol?
      getter params : Hash(String, String)

      def initialize(@name, @http_method, @pattern, @controller, @action, @params)
      end

      def path : String
        @pattern
      end

      def method : String
        @http_method
      end

      def verb : String
        @http_method
      end

      def inspect(io : IO) : Nil
        io << @http_method << ' ' << @pattern
        io << " (" << @name << ')' if @name
        io << " -> " << @controller << '#' << @action if @controller && @action
        io << " " << @params
      end
    end

    # Scope for the `resources ... do |s|` block: `member`/`collection`
    # route builders plus nested `resources` (`/stories/:story_id/...`).
    #
    # Naming state is carried separately from the path so nested routes get
    # Rails names (`post_comments_path`, `post_comment_path`) even though
    # the path is `/posts/:post_id/comments`.
    class ResourceScope
      def initialize(@router : Router, @path_name : String, @base : String, @controller : Controller.class,
                     @constraints : Hash(String, Regex)?, @defaults : Hash(String, String)?,
                     @name_base : String, @singular_base : String, @shallow : Bool = false)
      end

      def member(& : MemberScope ->) : Nil
        yield MemberScope.new(@router, @base, @controller, @constraints, @defaults, @singular_base, @shallow)
      end

      def collection(& : CollectionScope ->) : Nil
        yield CollectionScope.new(@router, @base, @controller, @constraints, @defaults, @name_base)
      end

      # Rails `shallow do ... end`: member routes of descendants lose the
      # parent prefix (`/comments/:id` instead of `/posts/:post_id/comments/:id`).
      def shallow(& : ResourceScope ->) : Nil
        yield ResourceScope.new(@router, @path_name, @base, @controller, @constraints, @defaults,
          @name_base, @singular_base, true)
      end

      def resources(name : String, controller : Controller.class, only : Array(Symbol)? = nil, except : Array(Symbol)? = nil,
                    as name_as : String | Symbol? = nil, shallow : Bool = false, path : String? = nil,
                    constraints : Hash(String, Regex)? = nil, defaults : Hash(String, String)? = nil) : Nil
        child_path = path || name
        nested = nested_base(child_path)
        child_key = name_as ? name_as.to_s : Router.route_key(name)
        child_plural = "#{@singular_base}_#{child_key}"
        child_singular = "#{@singular_base}_#{Router.singularize(child_key)}"
        @router.resources(nested, controller, only: only, except: except, as: child_plural,
          shallow: shallow || @shallow, constraints: constraints || @constraints, defaults: defaults || @defaults,
          name_base: child_plural, singular_base: child_singular, path_name: name)
      end

      def resources(name : String, controller : Controller.class, only : Array(Symbol)? = nil, except : Array(Symbol)? = nil,
                    as name_as : String | Symbol? = nil, shallow : Bool = false, path : String? = nil,
                    constraints : Hash(String, Regex)? = nil, defaults : Hash(String, String)? = nil, &block : ResourceScope ->) : Nil
        child_path = path || name
        nested = nested_base(child_path)
        child_key = name_as ? name_as.to_s : Router.route_key(name)
        child_plural = "#{@singular_base}_#{child_key}"
        child_singular = "#{@singular_base}_#{Router.singularize(child_key)}"
        @router.resources(nested, controller, only: only, except: except, as: child_plural,
          shallow: shallow || @shallow, constraints: constraints || @constraints, defaults: defaults || @defaults,
          name_base: child_plural, singular_base: child_singular, path_name: name) do |scope|
          yield scope
        end
      end

      def resource(name : String, controller : Controller.class, only : Array(Symbol)? = nil, except : Array(Symbol)? = nil,
                   as name_as : String | Symbol? = nil, path : String? = nil,
                   constraints : Hash(String, Regex)? = nil, defaults : Hash(String, String)? = nil) : Nil
        child_path = path || name
        child_key = name_as ? name_as.to_s : Router.singularize(Router.route_key(name))
        child_name = "#{@singular_base}_#{child_key}"
        @router.resource(nested_base(child_path), controller, only: only, except: except, as: child_name,
          constraints: constraints || @constraints, defaults: defaults || @defaults, name_base: child_name, path_name: name)
      end

      def resource(name : String, controller : Controller.class, only : Array(Symbol)? = nil, except : Array(Symbol)? = nil,
                   as name_as : String | Symbol? = nil, path : String? = nil,
                   constraints : Hash(String, Regex)? = nil, defaults : Hash(String, String)? = nil, &block : ResourceScope ->) : Nil
        child_path = path || name
        child_key = name_as ? name_as.to_s : Router.singularize(Router.route_key(name))
        child_name = "#{@singular_base}_#{child_key}"
        @router.resource(nested_base(child_path), controller, only: only, except: except, as: child_name,
          constraints: constraints || @constraints, defaults: defaults || @defaults, name_base: child_name, path_name: name) do |scope|
          yield scope
        end
      end

      def concerns(*names : Symbol) : Nil
        names.each { |name| @router.apply_concern(name, self) }
      end

      private def nested_base(name : String) : String
        clean = name.starts_with?("/") ? name[1..] : name
        "#{@base}/:#{Router.singularize(@path_name)}_id/#{clean}"
      end
    end

    # `POST /base/:id/upvote`-style member routes (`m.post :upvote` maps to
    # `#upvote` on the resource's controller). `as:` overrides the generated
    # helper name; the Rails default is `upvote_post` (nested: `upvote_post`).
    class MemberScope
      def initialize(@router : Router, @base : String, @controller : Controller.class,
                     @constraints : Hash(String, Regex)?, @defaults : Hash(String, String)?,
                     @singular_base : String, @shallow : Bool = false)
      end

      def get(name : Symbol, action : Symbol? = nil, as name_as : String | Symbol? = nil) : Nil
        add("GET", name, action || name, name_as)
      end

      def post(name : Symbol, action : Symbol? = nil, as name_as : String | Symbol? = nil) : Nil
        add("POST", name, action || name, name_as)
      end

      def put(name : Symbol, action : Symbol? = nil, as name_as : String | Symbol? = nil) : Nil
        add("PUT", name, action || name, name_as)
      end

      def patch(name : Symbol, action : Symbol? = nil, as name_as : String | Symbol? = nil) : Nil
        add("PATCH", name, action || name, name_as)
      end

      def delete(name : Symbol, action : Symbol? = nil, as name_as : String | Symbol? = nil) : Nil
        add("DELETE", name, action || name, name_as)
      end

      # Custom member paths (`m.post("preview", OtherController, :show)`
      # -> `POST base/:id/preview`).
      def get(path : String, controller : Controller.class, action : Symbol, as name_as : String | Symbol? = nil) : Nil
        add_custom("GET", path, controller, action, name_as)
      end

      def post(path : String, controller : Controller.class, action : Symbol, as name_as : String | Symbol? = nil) : Nil
        add_custom("POST", path, controller, action, name_as)
      end

      def put(path : String, controller : Controller.class, action : Symbol, as name_as : String | Symbol? = nil) : Nil
        add_custom("PUT", path, controller, action, name_as)
      end

      def patch(path : String, controller : Controller.class, action : Symbol, as name_as : String | Symbol? = nil) : Nil
        add_custom("PATCH", path, controller, action, name_as)
      end

      def delete(path : String, controller : Controller.class, action : Symbol, as name_as : String | Symbol? = nil) : Nil
        add_custom("DELETE", path, controller, action, name_as)
      end

      def self.clean(path : String) : String
        path.starts_with?("/") ? path[1..] : path
      end

      private def add(verb : String, name : Symbol, action : Symbol, name_as : String | Symbol?) : Nil
        helper = name_as ? name_as.to_s : "#{name}_#{@singular_base}"
        @router.add_controller_route(verb, "#{@base}/:id/#{name}", @controller, action, @constraints, @defaults, helper)
      end

      private def add_custom(verb : String, path : String, controller : Controller.class, action : Symbol, name_as : String | Symbol?) : Nil
        helper = name_as ? name_as.to_s : nil
        @router.add_controller_route(verb, "#{@base}/:id/#{MemberScope.clean(path)}", controller, action, @constraints, @defaults, helper)
      end
    end

    # `GET /base/search`-style collection routes (Rails name: `search_posts`).
    class CollectionScope
      def initialize(@router : Router, @base : String, @controller : Controller.class,
                     @constraints : Hash(String, Regex)?, @defaults : Hash(String, String)?,
                     @name_base : String)
      end

      def get(name : Symbol, action : Symbol? = nil, as name_as : String | Symbol? = nil) : Nil
        add("GET", name, action || name, name_as)
      end

      def post(name : Symbol, action : Symbol? = nil, as name_as : String | Symbol? = nil) : Nil
        add("POST", name, action || name, name_as)
      end

      def put(name : Symbol, action : Symbol? = nil, as name_as : String | Symbol? = nil) : Nil
        add("PUT", name, action || name, name_as)
      end

      def patch(name : Symbol, action : Symbol? = nil, as name_as : String | Symbol? = nil) : Nil
        add("PATCH", name, action || name, name_as)
      end

      def delete(name : Symbol, action : Symbol? = nil, as name_as : String | Symbol? = nil) : Nil
        add("DELETE", name, action || name, name_as)
      end

      def get(path : String, controller : Controller.class, action : Symbol, as name_as : String | Symbol? = nil) : Nil
        add_custom("GET", path, controller, action, name_as)
      end

      def post(path : String, controller : Controller.class, action : Symbol, as name_as : String | Symbol? = nil) : Nil
        add_custom("POST", path, controller, action, name_as)
      end

      def put(path : String, controller : Controller.class, action : Symbol, as name_as : String | Symbol? = nil) : Nil
        add_custom("PUT", path, controller, action, name_as)
      end

      def patch(path : String, controller : Controller.class, action : Symbol, as name_as : String | Symbol? = nil) : Nil
        add_custom("PATCH", path, controller, action, name_as)
      end

      def delete(path : String, controller : Controller.class, action : Symbol, as name_as : String | Symbol? = nil) : Nil
        add_custom("DELETE", path, controller, action, name_as)
      end

      private def add(verb : String, name : Symbol, action : Symbol, name_as : String | Symbol?) : Nil
        helper = name_as ? name_as.to_s : "#{name}_#{@name_base}"
        @router.add_controller_route(verb, "#{@base}/#{name}", @controller, action, @constraints, @defaults, helper)
      end

      private def add_custom(verb : String, path : String, controller : Controller.class, action : Symbol, name_as : String | Symbol?) : Nil
        helper = name_as ? name_as.to_s : nil
        @router.add_controller_route(verb, "#{@base}/#{MemberScope.clean(path)}", controller, action, @constraints, @defaults, helper)
      end
    end

    getter routes : Array(Route)
    getter named_routes : Hash(String, NamedRoute)
    getter direct_routes : Hash(String, NamedRoute)
    getter ws_routes : Array(Tuple(Regex, Array(String), String, WsHandler))
    getter default_url_options : Hash(String, String)
    getter mounted_routers : Array(Tuple(String, Router))

    @fallback : Handler?

    def initialize
      @routes = [] of Route
      @ws_routes = [] of Tuple(Regex, Array(String), String, WsHandler)
      @prefix_stack = [] of String
      @module_stack = [] of String
      @name_prefix_stack = [] of String
      @constraints_stack = [] of Hash(String, Regex)
      @defaults_stack = [] of Hash(String, String)
      @named_routes = {} of String => NamedRoute
      @direct_routes = {} of String => NamedRoute
      @concerns = {} of String => Proc(ResourceScope, Nil)
      @resolved = {} of String => String
      @mounted_routers = [] of Tuple(String, Router)
      @default_url_options = {} of String => String
      @fallback = nil
    end

    def draw(&block : self ->) : self
      yield self
      # Controllers/views resolve helpers through the most recently drawn
      # router. Explicit `Saci::Routes.current_router = router` always wins.
      Saci::Routes.current_router = self
      self
    end

    # Low-level registration. Also powers plain block routes:
    #   r.add("GET", "/ping") { |ctx, params| ctx.response.print("pong") }
    # Patterns with `(...)` optional groups expand to one route per
    # combination (most specific first).
    def add(http_method : String, pattern : String, constraints : Hash(String, Regex)? = nil, defaults : Hash(String, String)? = nil,
            name : String? = nil, controller : (Controller.class | Nil) = nil, action : Symbol? = nil,
            &handler : HTTP::Server::Context, Params ->) : Nil
      merged = merge_constraints(constraints)
      ds = merge_defaults(defaults)
      full_pattern = normalize_pattern(pattern)
      self.class.expand_optional(full_pattern).each do |full|
        full = full.gsub(/\/+/, "/")
        regex, names = self.class.compile(full, merged)
        @routes << Route.new(http_method.upcase, full, regex, names, Handler.new { |ctx, p| handler.call(ctx, p); nil }, ds,
          name, controller, action)
      end
      register_named(name, full_pattern, http_method, controller, action, ds) if name
    end

    # Controller route with a name, for scopes (member/collection) that do
    # not want to repeat the dispatch block.
    def add_controller_route(http_method : String, pattern : String, controller : Controller.class, action : Symbol,
                             constraints : Hash(String, Regex)? = nil, defaults : Hash(String, String)? = nil,
                             name : String? = nil) : Nil
      add(http_method, pattern, constraints, defaults, name: name, controller: controller, action: action) do |ctx, params|
        dispatch(controller, action, ctx, params)
      end
    end

    # Adds a route and registers its helper name in one call. Public route
    # methods below use `as:`; this lower-level form is for custom scopes.
    def add_named(http_method : String, pattern : String, name : String | Symbol,
                  controller : (Controller.class | Nil) = nil, action : Symbol? = nil,
                  constraints : Hash(String, Regex)? = nil, defaults : Hash(String, String)? = nil,
                  &handler : HTTP::Server::Context, Params ->) : Nil
      add(http_method, pattern, constraints, defaults, name: name.to_s, controller: controller, action: action, &handler)
    end

    def get(path : String, controller : Controller.class, action : Symbol, constraints : Hash(String, Regex)? = nil,
            defaults : Hash(String, String)? = nil, as name_as : String | Symbol? = nil) : Nil
      add("GET", path, constraints, defaults, name: normalize_name(name_as), controller: controller, action: action) do |ctx, params|
        dispatch(controller, action, ctx, params)
      end
    end

    def post(path : String, controller : Controller.class, action : Symbol, constraints : Hash(String, Regex)? = nil,
             defaults : Hash(String, String)? = nil, as name_as : String | Symbol? = nil) : Nil
      add("POST", path, constraints, defaults, name: normalize_name(name_as), controller: controller, action: action) do |ctx, params|
        dispatch(controller, action, ctx, params)
      end
    end

    def put(path : String, controller : Controller.class, action : Symbol, constraints : Hash(String, Regex)? = nil,
            defaults : Hash(String, String)? = nil, as name_as : String | Symbol? = nil) : Nil
      add("PUT", path, constraints, defaults, name: normalize_name(name_as), controller: controller, action: action) do |ctx, params|
        dispatch(controller, action, ctx, params)
      end
    end

    def patch(path : String, controller : Controller.class, action : Symbol, constraints : Hash(String, Regex)? = nil,
              defaults : Hash(String, String)? = nil, as name_as : String | Symbol? = nil) : Nil
      add("PATCH", path, constraints, defaults, name: normalize_name(name_as), controller: controller, action: action) do |ctx, params|
        dispatch(controller, action, ctx, params)
      end
    end

    def delete(path : String, controller : Controller.class, action : Symbol, constraints : Hash(String, Regex)? = nil,
               defaults : Hash(String, String)? = nil, as name_as : String | Symbol? = nil) : Nil
      add("DELETE", path, constraints, defaults, name: normalize_name(name_as), controller: controller, action: action) do |ctx, params|
        dispatch(controller, action, ctx, params)
      end
    end

    # Plain block routes sharing the verb (overloads by arity/block).
    def get(path : String, constraints : Hash(String, Regex)? = nil, defaults : Hash(String, String)? = nil,
            as name_as : String | Symbol? = nil, &handler : HTTP::Server::Context, Params ->) : Nil
      add("GET", path, constraints, defaults, name: normalize_name(name_as), &handler)
    end

    def post(path : String, constraints : Hash(String, Regex)? = nil, defaults : Hash(String, String)? = nil,
             as name_as : String | Symbol? = nil, &handler : HTTP::Server::Context, Params ->) : Nil
      add("POST", path, constraints, defaults, name: normalize_name(name_as), &handler)
    end

    def put(path : String, constraints : Hash(String, Regex)? = nil, defaults : Hash(String, String)? = nil,
            as name_as : String | Symbol? = nil, &handler : HTTP::Server::Context, Params ->) : Nil
      add("PUT", path, constraints, defaults, name: normalize_name(name_as), &handler)
    end

    def patch(path : String, constraints : Hash(String, Regex)? = nil, defaults : Hash(String, String)? = nil,
              as name_as : String | Symbol? = nil, &handler : HTTP::Server::Context, Params ->) : Nil
      add("PATCH", path, constraints, defaults, name: normalize_name(name_as), &handler)
    end

    def delete(path : String, constraints : Hash(String, Regex)? = nil, defaults : Hash(String, String)? = nil,
               as name_as : String | Symbol? = nil, &handler : HTTP::Server::Context, Params ->) : Nil
      add("DELETE", path, constraints, defaults, name: normalize_name(name_as), &handler)
    end

    # `root` is always named `root` (`admin_root` inside a namespace).
    def root(controller : Controller.class, action : Symbol, as name_as : String | Symbol? = nil) : Nil
      helper = name_as ? normalize_name(name_as) : prefixed_name("root")
      get("/", controller, action, as: helper)
    end

    def root(constraints : Hash(String, Regex)? = nil, defaults : Hash(String, String)? = nil,
             as name_as : String | Symbol? = nil, &handler : HTTP::Server::Context, Params ->) : Nil
      helper = name_as ? normalize_name(name_as) : prefixed_name("root")
      get("/", constraints, defaults, as: helper, &handler)
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
    # `name_base:`/`singular_base:`/`path_name:` are internal hooks used by
    # nested `ResourceScope`; application code normally only passes `as:`.
    def resources(name : String, controller : Controller.class, only : Array(Symbol)? = nil, except : Array(Symbol)? = nil,
                  as name_as : String | Symbol? = nil, constraints : Hash(String, Regex)? = nil,
                  defaults : Hash(String, String)? = nil, shallow : Bool = false, path : String? = nil,
                  name_base : String? = nil, singular_base : String? = nil, path_name : String? = nil) : Nil
      base_resources(name, controller, only, except, constraints, defaults, name_as, shallow, path,
        name_base, singular_base, path_name)
    end

    def resources(name : String, controller : Controller.class, only : Array(Symbol)? = nil, except : Array(Symbol)? = nil,
                  as name_as : String | Symbol? = nil, constraints : Hash(String, Regex)? = nil,
                  defaults : Hash(String, String)? = nil, shallow : Bool = false, path : String? = nil,
                  name_base : String? = nil, singular_base : String? = nil, path_name : String? = nil,
                  &block : ResourceScope ->) : Nil
      # Member/collection routes register first so e.g. GET /base/search
      # wins over GET /base/:id (Rails order).
      base = normalized_base(path || name)
      key_name = path_name || name
      plural_key = name_base || prefixed_name(name_as ? name_as.to_s : Router.route_key(key_name))
      singular_key = singular_base || prefixed_name(name_as ? Router.singularize(name_as.to_s) : Router.singularize(Router.route_key(key_name)))
      yield ResourceScope.new(self, last_segment(key_name), base, controller, constraints, defaults,
        plural_key, singular_key, shallow)
      base_resources(name, controller, only, except, constraints, defaults, name_as, shallow, path,
        name_base, singular_base, path_name)
    end

    # Singular resource: `/profile` (show/create/update/destroy),
    # `/profile/new`, `/profile/edit`. No `:id`, no index.
    def resource(name : String, controller : Controller.class, only : Array(Symbol)? = nil, except : Array(Symbol)? = nil,
                 as name_as : String | Symbol? = nil, constraints : Hash(String, Regex)? = nil,
                 defaults : Hash(String, String)? = nil, path : String? = nil,
                 name_base : String? = nil, path_name : String? = nil) : Nil
      base_resource(name, controller, only, except, constraints, defaults, name_as, path, name_base, path_name)
    end

    def resource(name : String, controller : Controller.class, only : Array(Symbol)? = nil, except : Array(Symbol)? = nil,
                 as name_as : String | Symbol? = nil, constraints : Hash(String, Regex)? = nil,
                 defaults : Hash(String, String)? = nil, path : String? = nil,
                 name_base : String? = nil, path_name : String? = nil, &block : ResourceScope ->) : Nil
      base = normalized_base(path || name)
      key_name = path_name || name
      singular_key = name_base || prefixed_name(name_as ? name_as.to_s : Router.singularize(Router.route_key(key_name)))
      yield ResourceScope.new(self, last_segment(key_name), base, controller, constraints, defaults,
        singular_key, singular_key, false)
      base_resource(name, controller, only, except, constraints, defaults, name_as, path, name_base, path_name)
    end

    private def base_resources(name : String, controller : Controller.class, only : Array(Symbol)?, except : Array(Symbol)?,
                               constraints : Hash(String, Regex)?, defaults : Hash(String, String)?,
                               name_as : String | Symbol?, shallow : Bool, path : String?,
                               name_base : String?, singular_base : String?, path_name : String?) : String
      actions = [:index, :new, :show, :create, :update, :destroy, :edit]
      actions = actions & only if only
      actions = actions - except if except
      base = normalized_base(path || name)
      key_name = path_name || name
      plural_key = name_base || prefixed_name(name_as ? name_as.to_s : Router.route_key(key_name))
      singular_key = singular_base || prefixed_name(name_as ? Router.singularize(name_as.to_s) : Router.singularize(Router.route_key(key_name)))
      segment = last_segment(key_name)

      # Shallow member routes live outside the nested parent path. Keep the
      # namespace prefix (`/admin/comments/:id`) but drop `/posts/:post_id`.
      member_base = if shallow
                      "#{current_prefix}/#{segment}/:id"
                    else
                      "#{base}/:id"
                    end
      member_name = shallow ? prefixed_name(Router.singularize(Router.route_key(key_name))) : singular_key
      if actions.includes?(:index)
        add_controller_route("GET", base, controller, :index, constraints, defaults, plural_key)
      end
      if actions.includes?(:new)
        add_controller_route("GET", "#{base}/new", controller, :new, constraints, defaults, action_name("new", singular_key))
      end
      if actions.includes?(:show)
        add_controller_route("GET", member_base, controller, :show, constraints, defaults, member_name)
      end
      if actions.includes?(:create)
        add_controller_route("POST", base, controller, :create, constraints, defaults, plural_key)
      end
      if actions.includes?(:update)
        add_controller_route("PUT", member_base, controller, :update, constraints, defaults, member_name)
        add_controller_route("PATCH", member_base, controller, :update, constraints, defaults, member_name)
      end
      if actions.includes?(:destroy)
        add_controller_route("DELETE", member_base, controller, :destroy, constraints, defaults, member_name)
      end
      if actions.includes?(:edit)
        add_controller_route("GET", "#{member_base}/edit", controller, :edit, constraints, defaults, action_name("edit", member_name))
      end
      base
    end

    private def base_resource(name : String, controller : Controller.class, only : Array(Symbol)?, except : Array(Symbol)?,
                              constraints : Hash(String, Regex)?, defaults : Hash(String, String)?,
                              name_as : String | Symbol?, path : String?, name_base : String?, path_name : String?) : String
      actions = [:new, :show, :create, :update, :destroy, :edit]
      actions = actions & only if only
      actions = actions - except if except
      base = normalized_base(path || name)
      key_name = path_name || name
      singular_key = name_base || prefixed_name(name_as ? name_as.to_s : Router.singularize(Router.route_key(key_name)))
      if actions.includes?(:show)
        add_controller_route("GET", base, controller, :show, constraints, defaults, singular_key)
      end
      if actions.includes?(:new)
        add_controller_route("GET", "#{base}/new", controller, :new, constraints, defaults, action_name("new", singular_key))
      end
      if actions.includes?(:create)
        add_controller_route("POST", base, controller, :create, constraints, defaults, singular_key)
      end
      if actions.includes?(:update)
        add_controller_route("PUT", base, controller, :update, constraints, defaults, singular_key)
        add_controller_route("PATCH", base, controller, :update, constraints, defaults, singular_key)
      end
      if actions.includes?(:destroy)
        add_controller_route("DELETE", base, controller, :destroy, constraints, defaults, singular_key)
      end
      if actions.includes?(:edit)
        add_controller_route("GET", "#{base}/edit", controller, :edit, constraints, defaults, action_name("edit", singular_key))
      end
      base
    end

    # Prefix all routes inside the block (like Rails `namespace`/`scope`).
    # `mod:` records the Crystal module holding the controllers
    # (documentation for readers; pass fully-qualified classes explicitly).
    # Route helper names are prefixed (`admin_posts_path`) and a namespace
    # root becomes `admin_root_path`.
    #
    #   r.namespace(:admin, mod: "Admin") do |a|
    #     a.resources "posts", Admin::PostsController   # /admin/posts
    #   end
    def namespace(prefix : String | Symbol, mod : String? = nil, as name_as : String | Symbol? = nil,
                  path : String? = nil, constraints : Hash(String, Regex)? = nil,
                  defaults : Hash(String, String)? = nil, &block : self ->) : Nil
      raw_prefix = prefix.to_s
      name_prefix = name_as ? name_as.to_s : Router.underscore(raw_prefix.split('/').reject(&.empty?).join("_"))
      @prefix_stack << normalize_prefix(path || raw_prefix)
      @module_stack << mod if mod
      @name_prefix_stack << name_prefix unless name_prefix.empty?
      @constraints_stack << constraints if constraints
      @defaults_stack << defaults if defaults
      yield self
    ensure
      @prefix_stack.pop
      @module_stack.pop if mod
      @name_prefix_stack.pop unless name_prefix.try(&.empty?)
      @constraints_stack.pop if constraints
      @defaults_stack.pop if defaults
    end

    # Rails `scope`: path prefix only by default; `as:` adds a route-name
    # prefix. `module:` is metadata (Crystal resolves constants at compile
    # time, so pass fully-qualified controller classes).
    #
    #   r.scope(path: "admin", module: "Admin", as: :admin) { |s| ... }
    def scope(prefix : String | Symbol, *, module mod : String? = nil, as name_as : String | Symbol? = nil,
              constraints : Hash(String, Regex)? = nil, defaults : Hash(String, String)? = nil,
              &block : self ->) : Nil
      scope_impl(prefix.to_s, mod, name_as, constraints, defaults, &block)
    end

    def scope(*, path : String | Symbol? = nil, module mod : String? = nil, as name_as : String | Symbol? = nil,
              constraints : Hash(String, Regex)? = nil, defaults : Hash(String, String)? = nil,
              &block : self ->) : Nil
      p = path.try(&.to_s) || ""
      scope_impl(p, mod, name_as, constraints, defaults, &block)
    end

    private def scope_impl(path : String, mod : String?, name_as : String | Symbol?,
                           constraints : Hash(String, Regex)?, defaults : Hash(String, String)?,
                           &block : self ->) : Nil
      @prefix_stack << normalize_prefix(path) unless path.empty?
      @module_stack << mod if mod
      name_prefix = name_as.try(&.to_s)
      @name_prefix_stack << name_prefix if name_prefix && !name_prefix.empty?
      @constraints_stack << constraints if constraints
      @defaults_stack << defaults if defaults
      yield self
    ensure
      @prefix_stack.pop unless path.empty?
      @module_stack.pop if mod
      @name_prefix_stack.pop if name_prefix && !name_prefix.empty?
      @constraints_stack.pop if constraints
      @defaults_stack.pop if defaults
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

    # Keyword form: `r.constraints(id: /[0-9]+/) { |c| ... }`.
    def constraints(**mapping : Regex, &block : self ->) : Nil
      hash = {} of String => Regex
      mapping.each { |key, value| hash[key.to_s] = value }
      constraints(hash, &block)
    end

    # Block-scoped route defaults: `r.defaults({"format" => "json"})`.
    def defaults(mapping : Hash(String, String), &block : self ->) : Nil
      @defaults_stack << mapping
      yield self
    ensure
      @defaults_stack.pop
    end

    def defaults(**mapping, &block : self ->) : Nil
      hash = {} of String => String
      mapping.each { |key, value| hash[key.to_s] = value.to_s }
      defaults(hash, &block)
    end

    # Rails `concern`:
    #   r.concern(:commentable) do |s|
    #     s.member { |m| m.post :comment }
    #   end
    #   r.resources "posts", PostsController do |s|
    #     s.concerns :commentable
    #   end
    def concern(name : String | Symbol, &block : ResourceScope ->) : Nil
      @concerns[name.to_s] = block
    end

    def apply_concern(name : String | Symbol, scope : ResourceScope) : Nil
      concern = @concerns[name.to_s]? || raise RouteHelpers::UnknownRoute.new("Unknown route concern '#{name}'")
      concern.call(scope)
    end

    # Custom path generator. The block receives the named params hash; the
    # generated helper name goes through `path_for`/`url_for` like any
    # other route.
    #
    #   r.direct(:home) { |_params| "/" }
    #   r.direct(:browse, required: ["category"]) { |p| "/c/#{p["category"]}" }
    def direct(name : String | Symbol, path : String) : Nil
      helper = qualify_name(name.to_s)
      builder = Proc(Hash(String, String), String).new do |_params|
        path
      end
      @direct_routes[helper] = NamedRoute.new(helper, path, [] of String, nil, nil,
        {} of String => String, builder)
    end

    def direct(name : String | Symbol, required : Array(String) = [] of String,
               &block : Hash(String, String) -> String) : Nil
      helper = qualify_name(name.to_s)
      @direct_routes[helper] = NamedRoute.new(helper, "", [] of String, nil, nil,
        {} of String => String, block, required)
    end

    # Rails `resolve`: map a model/type name to a route key for
    # `polymorphic_path`.
    #
    #   r.resolve("Article", as: :post)     # Article -> post_path
    def resolve(type : String | Symbol, as route_name : String | Symbol) : Nil
      @resolved[type.to_s] = route_name.to_s
    end

    def resolve(type : String | Symbol, &block : -> String | Symbol) : Nil
      @resolved[type.to_s] = block.call.to_s
    end

    def resolved_route_key(type : String | Symbol) : String?
      @resolved[type.to_s]?
    end

    # Mount another router at a path prefix. Routes (and their helper
    # names, prefixed with `as:`) are copied into this router; the mounted
    # router remains usable on its own.
    #
    #   blog = Saci::Router.new.draw { |r| r.resources "posts", PostsController }
    #   app.mount blog, at: "/blog", as: :blog
    #   app.path_for("blog_posts") # => "/blog/posts"
    def mount(router : Router, at path : String, as name_as : String | Symbol? = nil) : Nil
      prefix = normalize_prefix(path)
      name_prefix = name_as ? name_as.to_s : (last_segment(path).presence || "")
      router.routes.each do |route|
        new_pattern = (prefix + route.pattern).gsub(/\/+/, "/")
        new_pattern = "/" if new_pattern.empty?
        regex, names = self.class.compile(new_pattern)
        mounted_router = router
        handler = Handler.new do |ctx, params|
          # Controllers inside the mounted router should see its own helper
          # names (`posts_path`), not the parent's `blog_posts`.
          Saci::Routes.current_router = mounted_router
          route.handler.call(ctx, params)
          nil
        end
        @routes << Route.new(route.http_method, new_pattern, regex, names, handler, route.defaults,
          route.name ? prefix_name(name_prefix, route.name.not_nil!) : nil,
          route.controller, route.action)
      end
      router.named_routes.each do |name, named|
        helper = prefix_name(name_prefix, name)
        @named_routes[helper] = NamedRoute.new(helper, (prefix + named.pattern).gsub(/\/+/, "/"),
          named.http_methods, named.controller, named.action, named.defaults, named.direct)
      end
      router.direct_routes.each do |name, named|
        helper = prefix_name(name_prefix, name)
        @named_routes[helper] = NamedRoute.new(helper, named.pattern, named.http_methods, named.controller,
          named.action, named.defaults, named.direct, named.direct_required)
      end
      router.ws_routes.each do |regex, names, pattern, handler|
        new_pattern = (prefix + pattern).gsub(/\/+/, "/")
        new_regex, new_names = self.class.compile(new_pattern)
        @ws_routes << {new_regex, new_names, new_pattern, handler}
      end
      @mounted_routers << {prefix, router}
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
      websocket(path) do |socket, ctx, params|
        Cable.handle(socket, params, registry, srv, ctx)
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

    # Routes grouped by HTTP method, each with the literal prefix its
    # pattern starts with (a cheap `starts_with?` filter before the regex).
    # Rebuilt whenever the route count changes (routes are only appended).
    private record IndexedRoute, route : Route, prefix : String

    @route_index : Hash(String, Array(IndexedRoute))? = nil
    @route_index_size = -1

    private def route_index : Hash(String, Array(IndexedRoute))
      if (index = @route_index) && @route_index_size == @routes.size
        return index
      end
      index = {} of String => Array(IndexedRoute)
      @routes.each do |route|
        (index[route.http_method] ||= [] of IndexedRoute) << IndexedRoute.new(route, Router.literal_prefix(route))
      end
      @route_index = index
      @route_index_size = @routes.size
      index
    end

    # The literal text a route's pattern starts with, but only when its
    # regex provably begins with exactly that text (otherwise "", i.e. no
    # pre-filter).
    def self.literal_prefix(route : Route) : String
      pattern = route.pattern
      cut = pattern.each_char_with_index { |c, i| break i if c == ':' || c == '*' || c == '(' } || pattern.size
      prefix = pattern[0, cut]
      route.regex.source.starts_with?("^" + Regex.escape(prefix)) ? prefix : ""
    end

    def find(method : String, path : String) : {Route, Hash(String, String)}?
      verb = method.upcase
      candidates = route_index[verb]?
      return nil if candidates.nil?
      candidates.each do |entry|
        next unless path.starts_with?(entry.prefix)
        route = entry.route
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

    def named_route?(route_name : String | Symbol) : Bool
      key = route_name.to_s
      @named_routes.has_key?(key) || @direct_routes.has_key?(key)
    end

    def helper_names : Array(String)
      (@named_routes.keys + @direct_routes.keys).uniq.sort
    end

    def url_helpers : RouteHelpers::UrlHelpers
      RouteHelpers::UrlHelpers.new(self)
    end

    # Runtime named-route builder. Positional arguments fill required path
    # params in declaration order; named params fill by name. Extra params
    # become a query string (arrays repeat keys):
    #
    # ```
    # router.path_for("post", 12)                  # /posts/12
    # router.path_for(:post, id: 12, page: 2)      # /posts/12?page=2
    # router.path_for(:post, 12, tags: ["a", "b"]) # /posts/12?tags[]=a&tags[]=b
    # ```
    #
    # `*_path`/`*_url` methods with compile-time names come from
    # `Saci::Routes.define` (see `routes_macro.cr`).
    def path_for(route_name : String | Symbol, *args, **params) : String
      key = route_name.to_s
      if direct = @direct_routes[key]?
        builder = direct.direct || raise RouteHelpers::UnknownRoute.new("Route '#{key}' has no path generator")
        path_params = {} of String => String
        required = direct.direct_required
        if args.size > required.size
          raise ArgumentError.new("Too many positional params for '#{key}' (expected #{required.size}, got #{args.size})")
        end
        required.each_with_index do |param, index|
          path_params[param] = RouteHelpers.param_string(args[index]) if index < args.size
        end
        params.each { |k, v| path_params[k.to_s] = RouteHelpers.param_string(v) unless v.nil? }
        required.each do |param|
          unless path_params.has_key?(param)
            raise RouteHelpers::MissingRouteParam.new("Missing route parameter '#{param}' for '#{key}'")
          end
        end
        result = builder.call(path_params)
        return apply_script_name(result)
      end

      route = @named_routes[key]? || raise RouteHelpers::UnknownRoute.new(
        "No route named '#{key}'. Known helpers: #{helper_names.join(", ")}")
      required = route.required_param_names
      if args.size > required.size
        raise ArgumentError.new("Too many positional params for '#{key}' (expected #{required.size}, got #{args.size})")
      end
      path_params = {} of String => String
      route.defaults.each { |k, v| path_params[k] = v }
      required.each_with_index do |param, index|
        path_params[param] = RouteHelpers.param_string(args[index]) if index < args.size
      end
      params.each do |k, v|
        path_params[k.to_s] = RouteHelpers.param_string(v) unless v.nil?
      end
      required.each do |param|
        unless path_params.has_key?(param)
          raise RouteHelpers::MissingRouteParam.new(
            "Missing route parameter '#{param}' for '#{key}' (#{route.pattern}). " \
            "Pass it positionally (#{key}(id)) or by name (#{key}(#{param}: ...)).")
        end
      end
      apply_script_name(RouteHelpers.build_path(route.pattern, required, path_params, params))
    end

    # Hash-based form used by polymorphic helpers (Crystal cannot construct
    # a dynamic NamedTuple for `**`). Path params are positional-ordered by
    # the pattern; `extra` becomes the query string.
    def path_for_params(route_name : String | Symbol, path_params : Hash(String, String),
                        extra : Hash(String, String) = {} of String => String) : String
      key = route_name.to_s
      if direct = @direct_routes[key]?
        builder = direct.direct || raise RouteHelpers::UnknownRoute.new("Route '#{key}' has no path generator")
        direct.direct_required.each do |param|
          unless path_params.has_key?(param)
            raise RouteHelpers::MissingRouteParam.new("Missing route parameter '#{param}' for '#{key}'")
          end
        end
        return apply_script_name(builder.call(path_params))
      end
      route = @named_routes[key]? || raise RouteHelpers::UnknownRoute.new(
        "No route named '#{key}'. Known helpers: #{helper_names.join(", ")}")
      values = route.defaults.dup
      path_params.each { |k, v| values[k] = v }
      required = route.required_param_names
      required.each do |param|
        unless values.has_key?(param)
          raise RouteHelpers::MissingRouteParam.new("Missing route parameter '#{param}' for '#{key}' (#{route.pattern})")
        end
      end
      apply_script_name(RouteHelpers.build_path(route.pattern, required, values, extra))
    end

    # Path (relative) from a controller/action pair using the route table.
    # This is a static lookup, not a Ruby-style `send`.
    #
    # ```
    # router.url_for(controller: PostsController, action: :show, id: 12)
    # # => "/posts/12"
    # ```
    def url_for(route_name : String | Symbol, *args, **params) : String
      if route_name.is_a?(String) && (route_name.starts_with?("/") || route_name.starts_with?("http://") || route_name.starts_with?("https://"))
        return append_query(route_name, params)
      end
      path_for(route_name, *args, **params)
    end

    def url_for(*, controller : Controller.class | String, action : Symbol, id = nil, **params) : String
      route = route_for(controller, action)
      unless route
        raise RouteHelpers::UnknownRoute.new("No route for #{controller}##{action}")
      end
      path_params = {} of String => String
      route.defaults.each { |k, v| path_params[k] = v }
      params.each do |k, v|
        path_params[k.to_s] = RouteHelpers.param_string(v) unless v.nil?
      end
      path_params["id"] = RouteHelpers.param_string(id) unless id.nil?
      required = RouteHelpers.required_param_names(route.pattern)
      required.each do |param|
        unless path_params.has_key?(param)
          raise RouteHelpers::MissingRouteParam.new(
            "Missing route parameter '#{param}' for #{controller}##{action} (#{route.pattern})")
        end
      end
      apply_script_name(RouteHelpers.build_path(route.pattern, required, path_params, params))
    end

    def full_url_for(route_name : String | Symbol, *args, **params) : String
      path = if route_name.is_a?(String) && (route_name.starts_with?("/") || route_name.starts_with?("http://") || route_name.starts_with?("https://"))
               append_query(route_name, params)
             else
               url_for(route_name, *args, **params)
             end
      RouteHelpers.full_url(path, options: @default_url_options)
    end

    def full_url_for(*, controller : Controller.class | String, action : Symbol, id = nil, **params) : String
      RouteHelpers.full_url(url_for(**params, controller: controller, action: action, id: id), options: @default_url_options)
    end

    def polymorphic_path(record, action : Symbol? = nil, **params) : String
      RouteHelpers.polymorphic_path(record, self, action, **params)
    end

    def polymorphic_path(records : Array, action : Symbol? = nil, **params) : String
      RouteHelpers.polymorphic_path(records, self, action, **params)
    end

    def polymorphic_url(record, action : Symbol? = nil, **params) : String
      RouteHelpers.polymorphic_url(record, **params, router: self, action: action)
    end

    def polymorphic_url(records : Array, action : Symbol? = nil, **params) : String
      RouteHelpers.polymorphic_url(records, **params, router: self, action: action)
    end

    def edit_polymorphic_path(record, **params) : String
      RouteHelpers.edit_polymorphic_path(record, self, **params)
    end

    def edit_polymorphic_path(records : Array, **params) : String
      RouteHelpers.edit_polymorphic_path(records, self, **params)
    end

    def route_for(controller : Controller.class | String, action : Symbol) : Route?
      candidates = @routes.select do |route|
        next false unless route.action == action
        if controller.is_a?(String)
          route.controller.try(&.name) == controller
        else
          route.controller == controller
        end
      end
      return nil if candidates.empty?
      # Prefer GET for read actions and PATCH for update (same path either
      # way, but a deterministic choice makes introspection stable).
      preferred = action == :update ? "PATCH" : "GET"
      candidates.find { |route| route.http_method == preferred } || candidates.first
    end

    # Web-framework style route recognition (`path` + `method:`).
    def recognize_path(path : String, method : String = "GET") : RecognizedRoute?
      if found = find(method, path)
        route, params = found
        return RecognizedRoute.new(route.name, route.http_method, route.pattern, route.controller, route.action, params)
      end
      nil
    end

    private def append_query(path : String, params) : String
      query = String.build do |io|
        RouteHelpers.append_extra_query(io, params, [] of String)
      end
      query.empty? ? path : "#{path}?#{query}"
    end

    private def apply_script_name(path : String) : String
      script_name = @default_url_options["script_name"]?
      return path unless script_name && !script_name.empty?
      script_name = RouteHelpers.normalize_script_name(script_name)
      return path if script_name.empty? || path.starts_with?(script_name)
      "#{script_name}#{path}"
    end

    # Shared, never mutated: the request log reads it only when logging.
    EMPTY_LOGGED_PARAMS = {} of String => String

    def call(context : HTTP::Server::Context) : Nil
      Saci::Routes.current_router = self
      request = context.request
      path = request.path || "/"
      started = Time.instant
      request_id = request.headers["X-Request-Id"]? || Saci.request_id
      context.response.headers["X-Request-Id"] = request_id
      log = Saci.log_requests
      logged_params = EMPTY_LOGGED_PARAMS
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
        logged_params = params.to_h if log
        method = override_method(request, params) || request.method
        # Reuse the first lookup unless `_method` changed the verb.
        found = path_match[0].http_method == method.upcase ? path_match : find(method, path)
        if found
          route, _ = found
          begin
            route.handler.call(context, params)
          rescue ex : Exception
            handle_handler_error(context, request, path, ex)
          end
        else
          render_not_found(context, method, path)
        end
      elsif fb = @fallback
        params = Params.build(request, {} of String => String)
        logged_params = params.to_h if log
        begin
          fb.call(context, params)
        rescue ex : Exception
          handle_handler_error(context, request, path, ex)
        end
      else
        render_not_found(context, request.method, path)
      end
      log_request(context, request, path, started, logged_params, request_id)
    end

    # Unmatched route (no `fallback`). Browsers (`Accept: text/html`) get
    # the app's `public/404.html` (or a built-in page); everyone else keeps
    # the JSON body. `r.fallback Controller, :action` takes over entirely.
    private def render_not_found(context : HTTP::Server::Context, method : String, path : String) : Nil
      response = context.response
      response.status_code = 404
      if Middleware.accepts_html?(context.request)
        response.content_type = "text/html; charset=utf-8"
        response.print(Exceptions.html_for(404, context.request))
      else
        response.content_type = "application/json"
        response.print({error: "Not Found: #{method} #{path}"}.to_json)
      end
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
      when RoutingError
        # Rails renders `ActionController::RoutingError` (and the common
        # `not_found!` helper built on it) as 404, not 500.
        context.response.status_code = 404
        context.response.content_type = "application/json"
        context.response.print({error: "Not Found"}.to_json)
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

    # Human/CLI-oriented table. Helper names are appended when registered so
    # `saci routes --expanded` can do plain string matching on this output.
    def routes_table : Array(String)
      @routes.map do |route|
        line = "#{route.http_method.ljust(6)} #{route.pattern}"
        line = "#{line.ljust(40)} #{route.name}" if route.name
        line
      end
    end

    # `{verb, path, "Controller#action"}` for every route, websocket route
    # and the fallback, as `saci routes --boot` prints them.
    def route_rows : Array(Tuple(String, String, String))
      rows = @routes.map do |route|
        target = if controller = route.controller
                   "#{controller.name}##{route.action}"
                 else
                   "(block)"
                 end
        {route.http_method, route.pattern, target}
      end
      @ws_routes.each { |(_, _, pattern, _)| rows << {"WS", pattern, "(socket)"} }
      rows << {"*", "*", "(fallback)"} if @fallback
      rows
    end

    # Structured, one-line-per-route view for CLI consumers.
    def routes_table_expanded : Array(String)
      @routes.map do |route|
        controller = route.controller.try(&.name) || "(block)"
        action = route.action.try(&.to_s) || "-"
        helper = route.name || "-"
        "#{route.http_method.ljust(6)} #{route.pattern.ljust(34)} #{helper.ljust(24)} #{controller}##{action}"
      end
    end

    def inspect(io : IO) : Nil
      io << "#<Saci::Router routes=" << @routes.size
      io << " helpers=" << helper_names.size
      io << " mounted=" << @mounted_routers.size
      io << ">\n"
      io << routes_table_expanded.join("\n")
    end

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

    private def merge_defaults(own : Hash(String, String)?) : Hash(String, String)
      return own.dup if @defaults_stack.empty? && own
      merged = {} of String => String
      @defaults_stack.each { |mapping| mapping.each { |k, v| merged[k] = v } }
      own.try(&.each { |k, v| merged[k] = v })
      merged
    end

    private def normalize_name(name : String | Symbol?) : String?
      name.try { |value| qualify_name(value.to_s) }
    end

    # Applies the namespace/scope name prefix unless the caller already
    # supplied a fully-qualified name (resources compute theirs with the
    # prefix included).
    private def qualify_name(name : String) : String
      prefix = @name_prefix_stack.join("_")
      return name if prefix.empty? || name == prefix || name.starts_with?("#{prefix}_")
      "#{prefix}_#{name}"
    end

    # `new_admin_post`, `edit_admin_post` (action prefix first, Rails order).
    private def action_name(action : String, base : String) : String
      "#{action}_#{base}"
    end

    private def prefixed_name(name : String) : String
      prefix = @name_prefix_stack.join("_")
      prefix.empty? ? name : "#{prefix}_#{name}"
    end

    private def prefix_name(prefix : String, name : String) : String
      prefix.empty? ? name : "#{prefix}_#{name}"
    end

    private def normalized_base(name : String) : String
      name.starts_with?("/") ? name : "/" + name
    end

    private def last_segment(name : String) : String
      name.split('/').reject(&.empty?).last? || name
    end

    private def register_named(name : String?, pattern : String, http_method : String,
                               controller : (Controller.class | Nil), action : Symbol?,
                               defaults : Hash(String, String)) : Nil
      return unless name
      key = name
      if existing = @named_routes[key]?
        # Same name/path for multiple verbs (index/create, show/update/destroy)
        # shares one helper entry.
        unless existing.http_methods.includes?(http_method.upcase)
          existing.http_methods << http_method.upcase
        end
      else
        @named_routes[key] = NamedRoute.new(key, pattern, [http_method.upcase], controller, action, defaults)
      end
    end

    def self.underscore(word : String) : String
      RouteHelpers.underscore(word)
    end

    def self.pluralize(word : String) : String
      RouteHelpers.pluralize(word)
    end

    # `resources` name key. Accepts a path-ish string; only the last segment
    # matters. `posts` -> `posts`, `categories` stays plural.
    def self.route_key(name : String) : String
      last = name.split('/').reject(&.empty?).last? || name
      last = last.split(':').last if last.includes?(':')
      last = RouteHelpers.underscore(last)
      singular = RouteHelpers.singularize(last)
      RouteHelpers.pluralize(singular) == last ? last : RouteHelpers.pluralize(last)
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
      RouteHelpers.singularize(word.split("/").last)
    end

    def self.compile(pattern : String, constraints : Hash(String, Regex)? = nil) : {Regex, Array(String)}
      names = [] of String
      parts = pattern.split("/").map do |seg|
        compile_segment(seg, names, constraints)
      end
      {Regex.new("^" + parts.join("/") + "$"), names}
    end

    private def self.compile_segment(seg : String, names : Array(String), constraints : Hash(String, Regex)?) : String
      # Generalized: static prefix/suffix literals may appear anywhere
      # around/between params in one segment. Split on ':' keeping
      # literals (e.g. "~:username" -> "~" + param, ":a.png" -> param +
      # ".png", ":a_:b.png" -> param + "_" + param + ".png").
      return Regex.escape(seg) unless seg.includes?(':') || seg.includes?('*')
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

  # Multidb test helper (defined here so `saci`-requiring apps get it
  # without touching `record/` in this task): truncates every table on
  # every connected database (primary + named). Call in `before_each`
  # for multidb apps; single-DB apps keep using `clean_database!`.
  module Record
    def self.clean_all! : Nil
      configuration_names.each do |name|
        connected_to(name) { clean_database! }
      end
    end
  end
end
