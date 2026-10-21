# Compile-time named route helpers (G4).
#
# Crystal has no runtime `method_missing`, so `posts_path` cannot be produced
# from a runtime `Router#draw` block. `Saci::Routes.define` reads the route
# declarations with macros and generates ordinary Crystal methods:
#
# ```
# Saci::Routes.define AppRoutes do |r|
#   r.root HomeController, :index
#   r.resources "posts", PostsController do |s|
#     s.member { |m| m.post :upvote }    # upvote_post_path
#     s.collection { |c| c.get :search } # search_posts_path
#     s.resources "comments", CommentsController
#   end
#   r.namespace :admin do |a|
#     a.resources "posts", Admin::PostsController
#   end
# end
#
# AppRoutes.posts_path                   # "/posts"
# AppRoutes.post_path(12)                # "/posts/12"
# AppRoutes.post_path(id: 12)            # "/posts/12"
# AppRoutes.post_comments_path(3)        # "/posts/3/comments"
# AppRoutes.new_post_comment_path(3)     # "/posts/3/comments/new"
# AppRoutes.edit_post_comment_path(3, 9) # "/posts/3/comments/9/edit"
# AppRoutes.admin_posts_path             # "/admin/posts"
# AppRoutes.upvote_post_path(4)          # "/posts/4/upvote"
# AppRoutes.search_posts_path            # "/posts/search"
# ```
#
# `AppRoutes.router` builds (and memoizes) the real `Saci::Router`; route
# dispatch is still the runtime router. `AppRoutes.draw(router)` adds the
# same routes to an existing router, and `AppRoutes.activate!` makes it the
# current router for controller/view helpers.
#
# Supported inside `define`:
# * `root`, all verb routes (`as:` required for a helper name),
# * `resources` (with `only:`, `except:`, `as:`, `path:`),
# * nested `resources` and singular `resource`,
# * `member`/`collection` (default Rails names + custom `as:`),
# * `shallow do ... end` / `resources ..., shallow: true` (member helpers
#   drop the parent prefix, matching the runtime routes),
# * `namespace` (name prefix) and `scope` with `as:`.
#
# `direct` names get a generated helper, but the custom path block is still
# evaluated by the runtime router. Not expanded by the macro (runtime
# `path_for` still works for them): `concern`/`concerns`, `resolve`, `mount`,
# and routes produced by arbitrary Ruby-style runtime code. Use
# `AppRoutes.path_for("name")` for those.
module Saci
  module Routes
    # Defines a module with compile-time `*_path` helpers plus a memoized
    # router. See the file comment for the supported DSL subset.
    macro define(name = nil, &block)
      {% module_name = name ? name.id : "Saci::Routes::Generated".id %}
      module {{module_name}}
        @@router : Saci::Router?

        def self.router : Saci::Router
          @@router ||= Saci::Router.new.draw do |r|
            {{block.body}}
          end
        end

        def self.draw(router : Saci::Router = Saci::Router.new) : Saci::Router
          router.draw do |r|
            {{block.body}}
          end
        end

        def self.activate! : Saci::Router
          r = router
          Saci::Routes.current_router = r
          r
        end

        def self.path_for(name : String | Symbol, *args, **params) : String
          router.path_for(name, *args, **params)
        end

        def self.url_for(name : String | Symbol, *args, **params) : String
          router.url_for(name, *args, **params)
        end

        def self.url_for(*, controller : Saci::Controller.class | String, action : Symbol, id = nil, **params) : String
          router.url_for(**params, controller: controller, action: action, id: id)
        end

        def self.full_url_for(name : String | Symbol, *args, **params) : String
          router.full_url_for(name, *args, **params)
        end

        def self.full_url_for(*, controller : Saci::Controller.class | String, action : Symbol, id = nil, **params) : String
          router.full_url_for(**params, controller: controller, action: action, id: id)
        end

        def self.polymorphic_path(record, action : Symbol? = nil, **params) : String
          router.polymorphic_path(record, action, **params)
        end

        def self.polymorphic_path(records : Array, action : Symbol? = nil, **params) : String
          router.polymorphic_path(records, action, **params)
        end

        def self.edit_polymorphic_path(record, **params) : String
          router.edit_polymorphic_path(record, **params)
        end

        def self.recognize_path(path : String, method : String = "GET") : Saci::Router::RecognizedRoute?
          router.recognize_path(path, method)
        end

        def self.helper_names : Array(String)
          router.helper_names
        end

        def self.routes_table : Array(String)
          router.routes_table
        end

        {% if block.body.class_name == "Expressions" %}
          {% tops = block.body.expressions %}
        {% else %}
          {% tops = [block.body] %}
        {% end %}
        {% for ex in tops %}
          Saci::Routes.__emit_route({{ex}}, "")
        {% end %}
      end
    end

    # Routes the macro does not understand are ignored here; the runtime
    # router still sees them through `block.body`.
    macro __emit_route(call, name_prefix = nil)
      {% prefix = name_prefix || "" %}
      {% name = call.name.id.stringify %}
      {% if name == "resources" %}
        Saci::Routes.__emit_resources({{call}}, {{prefix}}, nil, {{prefix}})
      {% elsif name == "resource" %}
        Saci::Routes.__emit_resource({{call}}, {{prefix}}, {{prefix}})
      {% elsif name == "namespace" %}
        Saci::Routes.__emit_namespace({{call}}, {{prefix}})
      {% elsif name == "scope" %}
        Saci::Routes.__emit_scope({{call}}, {{prefix}})
      {% elsif name == "root" %}
        {% helper = prefix.id.empty? ? "root" : "#{prefix.id}_root" %}
        Saci::Routes.__emit_helper({{helper}}, {{helper}})
      {% elsif name == "direct" %}
        {% direct_name = call.args[0].id %}
        {% helper = prefix.id.empty? ? direct_name : "#{prefix.id}_#{direct_name.id}" %}
        Saci::Routes.__emit_helper({{helper}}, {{helper}})
      {% elsif ["get", "post", "put", "patch", "delete"].includes?(name) %}
        {% as_name = nil %}
        {% if call.named_args %}
          {% for named in call.named_args %}
            {% if named.name == "as" %}
              {% as_name = named.value.id %}
            {% end %}
          {% end %}
        {% end %}
        {% if as_name %}
          {% helper = prefix.id.empty? ? as_name : "#{prefix.id}_#{as_name.id}" %}
          Saci::Routes.__emit_helper({{helper}}, {{helper}})
        {% end %}
      {% end %}
    end

    # Emits one `def self.<helper>(*args, **params)` delegating to the
    # router registry. `@type.has_method?` keeps repeated declarations from
    # redefining the same method.
    macro __emit_helper(helper, route_name = nil)
      {% route = route_name || helper %}
      {% route_literal = "#{route.id}" %}
      {% method_name = "#{helper.id}_path" %}
      def self.{{method_name.id}}(*args, **params) : String
        router.path_for({{route_literal}}, *args, **params)
      end
    end

    macro __emit_resources(call, singular_prefix = nil, shallow_prefix = nil, namespace_prefix = nil)
      {% outer = singular_prefix || "" %}
      {% raw_name = call.args[0].id %}
      {% key = raw_name.split("/").last.id %}
      {% name_as = nil %}
      {% only = nil %}
      {% except = nil %}
      {% if call.named_args %}
        {% for named in call.named_args %}
          {% if named.name == "as" %}
            {% name_as = named.value.id %}
          {% elsif named.name == "only" %}
            {% only = named.value.map(&.id.stringify) %}
          {% elsif named.name == "except" %}
            {% except = named.value.map(&.id.stringify) %}
          {% end %}
        {% end %}
      {% end %}
      {% shallow_flag = false %}
      {% if call.named_args %}
        {% for named in call.named_args %}
          {% if named.name == "shallow" %}{% shallow_flag = named.value %}{% end %}
        {% end %}
      {% end %}
      {% key = name_as || key %}
      {% plural = key.ends_with?("s") ? key : (key.ends_with?("y") ? key[0...-1] + "ies" : key + "s") %}
      {% singular = key.ends_with?("ies") ? key[0...-3] + "y" : (key.ends_with?("s") ? key[0...-1] : key) %}
      {% plural_full = outer.id.empty? ? plural : "#{outer.id}_#{plural.id}" %}
      {% singular_full = outer.id.empty? ? singular : "#{outer.id}_#{singular.id}" %}
      {% new_helper = "new_#{singular_full.id}" %}
      {% edit_helper = "edit_#{singular_full.id}" %}
      {% ns = namespace_prefix || "" %}
      {% is_shallow = shallow_flag || !shallow_prefix.nil? %}
      {% if is_shallow %}
        {% shallow_name = ns.id.empty? ? singular : "#{ns.id}_#{singular.id}" %}
        {% member_name = shallow_name %}
        {% edit_member = "edit_#{shallow_name.id}" %}
      {% else %}
        {% member_name = singular_full %}
        {% edit_member = edit_helper %}
      {% end %}

      {% index_enabled = true %}
      {% if only %}{% index_enabled = only.includes?("index") %}{% end %}
      {% if except %}{% index_enabled = index_enabled && !except.includes?("index") %}{% end %}
      {% if index_enabled %}
        Saci::Routes.__emit_helper({{plural_full}}, {{plural_full}})
      {% end %}

      {% new_enabled = true %}
      {% if only %}{% new_enabled = only.includes?("new") %}{% end %}
      {% if except %}{% new_enabled = new_enabled && !except.includes?("new") %}{% end %}
      {% if new_enabled %}
        Saci::Routes.__emit_helper({{new_helper}}, {{new_helper}})
      {% end %}

      {% show_enabled = true %}
      {% if only %}{% show_enabled = only.includes?("show") || only.includes?("update") || only.includes?("destroy") %}{% end %}
      {% if except %}{% show_enabled = show_enabled && (!except.includes?("show") || !except.includes?("update") || !except.includes?("destroy")) %}{% end %}
      {% if show_enabled %}
        Saci::Routes.__emit_helper({{member_name}}, {{member_name}})
      {% end %}

      {% edit_enabled = true %}
      {% if only %}{% edit_enabled = only.includes?("edit") %}{% end %}
      {% if except %}{% edit_enabled = edit_enabled && !except.includes?("edit") %}{% end %}
      {% if edit_enabled %}
        Saci::Routes.__emit_helper({{edit_member}}, {{edit_member}})
      {% end %}

      {% if call.block %}
        {% if call.block.body.class_name == "Expressions" %}
          {% subs = call.block.body.expressions %}
        {% else %}
          {% subs = [call.block.body] %}
        {% end %}
        {% for sub in subs %}
          {% sub_name = sub.name.id.stringify %}
          {% if sub_name == "member" %}
            {% if sub.block.body.class_name == "Expressions" %}
              {% members = sub.block.body.expressions %}
            {% else %}
              {% members = [sub.block.body] %}
            {% end %}
            {% for member in members %}
              {% member_as = nil %}
              {% if member.named_args %}
                {% for named in member.named_args %}
                  {% if named.name == "as" %}{% member_as = named.value.id %}{% end %}
                {% end %}
              {% end %}
              {% if member.args.size > 0 && member.args[0].class_name == "SymbolLiteral" %}
                {% helper = member_as || "#{member.args[0].id}_#{singular_full.id}" %}
                Saci::Routes.__emit_helper({{helper}}, {{helper}})
              {% end %}
            {% end %}
          {% elsif sub_name == "collection" %}
            {% if sub.block.body.class_name == "Expressions" %}
              {% collections = sub.block.body.expressions %}
            {% else %}
              {% collections = [sub.block.body] %}
            {% end %}
            {% for item in collections %}
              {% item_as = nil %}
              {% if item.named_args %}
                {% for named in item.named_args %}
                  {% if named.name == "as" %}{% item_as = named.value.id %}{% end %}
                {% end %}
              {% end %}
              {% if item.args.size > 0 && item.args[0].class_name == "SymbolLiteral" %}
                {% helper = item_as || "#{item.args[0].id}_#{plural_full.id}" %}
                Saci::Routes.__emit_helper({{helper}}, {{helper}})
              {% end %}
            {% end %}
          {% elsif sub_name == "resources" %}
            Saci::Routes.__emit_resources({{sub}}, {{singular_full}}, {{shallow_prefix}}, {{namespace_prefix}})
          {% elsif sub_name == "resource" %}
            Saci::Routes.__emit_resource({{sub}}, {{singular_full}}, {{namespace_prefix}})
          {% elsif sub_name == "shallow" %}
            {% if sub.block.body.class_name == "Expressions" %}
              {% shallow_subs = sub.block.body.expressions %}
            {% else %}
              {% shallow_subs = [sub.block.body] %}
            {% end %}
            {% for shallow_sub in shallow_subs %}
              {% if shallow_sub.name.id == "resources" %}
                Saci::Routes.__emit_resources({{shallow_sub}}, {{singular_full}}, {{namespace_prefix}}, {{namespace_prefix}})
              {% elsif shallow_sub.name.id == "resource" %}
                Saci::Routes.__emit_resource({{shallow_sub}}, {{singular_full}})
              {% end %}
            {% end %}
          {% end %}
        {% end %}
      {% end %}
    end

    # Singular `resource`. Helpers: `profile_path`, `new_profile_path`,
    # `edit_profile_path`; nested under posts -> `post_avatar_path`.
    macro __emit_resource(call, singular_prefix = nil, namespace_prefix = nil)
      {% outer = singular_prefix || "" %}
      {% raw_name = call.args[0].id %}
      {% key = raw_name.split("/").last.id %}
      {% name_as = nil %}
      {% only = nil %}
      {% except = nil %}
      {% if call.named_args %}
        {% for named in call.named_args %}
          {% if named.name == "as" %}
            {% name_as = named.value.id %}
          {% elsif named.name == "only" %}
            {% only = named.value.map(&.id.stringify) %}
          {% elsif named.name == "except" %}
            {% except = named.value.map(&.id.stringify) %}
          {% end %}
        {% end %}
      {% end %}
      {% key = name_as || key %}
      {% singular = key.ends_with?("ies") ? key[0...-3] + "y" : (key.ends_with?("s") ? key[0...-1] : key) %}
      {% singular_full = outer.id.empty? ? singular : "#{outer.id}_#{singular.id}" %}
      {% new_helper = "new_#{singular_full.id}" %}
      {% edit_helper = "edit_#{singular_full.id}" %}

      {% show_enabled = true %}
      {% if only %}{% show_enabled = only.includes?("show") || only.includes?("update") || only.includes?("destroy") || only.includes?("create") %}{% end %}
      {% if except %}{% show_enabled = show_enabled && !except.includes?("show") %}{% end %}
      {% if show_enabled %}
        Saci::Routes.__emit_helper({{singular_full}}, {{singular_full}})
      {% end %}

      {% new_enabled = true %}
      {% if only %}{% new_enabled = only.includes?("new") %}{% end %}
      {% if except %}{% new_enabled = new_enabled && !except.includes?("new") %}{% end %}
      {% if new_enabled %}
        Saci::Routes.__emit_helper({{new_helper}}, {{new_helper}})
      {% end %}

      {% edit_enabled = true %}
      {% if only %}{% edit_enabled = only.includes?("edit") %}{% end %}
      {% if except %}{% edit_enabled = edit_enabled && !except.includes?("edit") %}{% end %}
      {% if edit_enabled %}
        Saci::Routes.__emit_helper({{edit_helper}}, {{edit_helper}})
      {% end %}

      {% if call.block %}
        {% if call.block.body.class_name == "Expressions" %}
          {% subs = call.block.body.expressions %}
        {% else %}
          {% subs = [call.block.body] %}
        {% end %}
        {% for sub in subs %}
          {% if sub.name.id == "resources" %}
            Saci::Routes.__emit_resources({{sub}}, {{singular_full}}, nil, {{namespace_prefix}})
          {% elsif sub.name.id == "resource" %}
            Saci::Routes.__emit_resource({{sub}}, {{singular_full}}, {{namespace_prefix}})
          {% end %}
        {% end %}
      {% end %}
    end

    macro __emit_namespace(call, outer_prefix = nil)
      {% outer = outer_prefix || "" %}
      {% raw = call.args[0].id %}
      {% name_as = nil %}
      {% if call.named_args %}
        {% for named in call.named_args %}
          {% if named.name == "as" %}{% name_as = named.value.id %}{% end %}
        {% end %}
      {% end %}
      {% ns = name_as || raw.underscore %}
      {% prefix = outer.id.empty? ? ns : "#{outer.id}_#{ns.id}" %}
      {% if call.block %}
        {% if call.block.body.class_name == "Expressions" %}
          {% subs = call.block.body.expressions %}
        {% else %}
          {% subs = [call.block.body] %}
        {% end %}
        {% for sub in subs %}
          Saci::Routes.__emit_route({{sub}}, {{prefix}})
        {% end %}
      {% end %}
    end

    macro __emit_scope(call, outer_prefix = nil)
      {% outer = outer_prefix || "" %}
      {% name_as = nil %}
      {% if call.named_args %}
        {% for named in call.named_args %}
          {% if named.name == "as" %}{% name_as = named.value.id %}{% end %}
        {% end %}
      {% end %}
      {% prefix = name_as ? (outer.id.empty? ? name_as : "#{outer.id}_#{name_as.id}") : outer %}
      {% if call.block %}
        {% if call.block.body.class_name == "Expressions" %}
          {% subs = call.block.body.expressions %}
        {% else %}
          {% subs = [call.block.body] %}
        {% end %}
        {% for sub in subs %}
          Saci::Routes.__emit_route({{sub}}, {{prefix}})
        {% end %}
      {% end %}
    end
  end
end
