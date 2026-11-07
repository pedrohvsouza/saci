require "uri"
require "socket"

module Saci
  # URL/path building helpers shared by `Saci::Router`, controllers and views.
  #
  # Saci has **two** complementary URL-helper APIs:
  #
  # 1. **Runtime registry** (always available):
  #    register a name with `as:`/`name:` on any route declaration, then build
  #    paths with `router.path_for("post", 1)`, `router.url_for(...)`, or the
  #    current router through controller/view instance helpers.
  #
  # 2. **Compile-time helpers** (`Saci::Routes.define`, see
  #    `routes_macro.cr`): generates ordinary Crystal methods such as
  #    `posts_path`, `post_path(id)`, `edit_post_path(post)` for use without a
  #    router receiver. Crystal has no runtime `method_missing`, so this can
  #    only be done by a macro that sees the route declarations at compile
  #    time.
  #
  # Both APIs share the same name -> pattern registry on `Saci::Router`, so a
  # route declared once feeds both.
  module RouteHelpers
    class UnknownRoute < Saci::RoutingError
    end

    class MissingRouteParam < Saci::RoutingError
    end

    # Default host/protocol/etc. used by `full_url_for` / `*_url` helpers.
    # Mutate this hash (or `router.default_url_options`) at boot:
    #
    # ```
    # Saci::RouteHelpers.default_url_options["host"] = "example.com"
    # Saci::RouteHelpers.default_url_options["protocol"] = "https"
    # ```
    @@default_url_options = {} of String => String

    def self.default_url_options : Hash(String, String)
      @@default_url_options
    end

    def self.default_url_options=(options : Hash(String, String)) : Hash(String, String)
      @@default_url_options = options
    end

    def self.configure_default_url_options(**options) : Nil
      options.each { |key, value| @@default_url_options[key.to_s] = value.to_s }
    end

    # Small Rails `ActiveModel::Name` equivalent. Only the naming surface
    # used by routes/forms is implemented.
    struct ModelName
      getter name : String
      getter namespace : String?
      getter singular : String
      getter plural : String
      getter element : String
      getter collection : String
      getter human : String
      getter param_key : String
      getter route_key : String
      getter singular_route_key : String

      def initialize(@name : String)
        parts = @name.split("::")
        leaf = parts.last
        @namespace = parts.size > 1 ? parts[0...-1].map(&.underscore).join("/") : nil
        singular = RouteHelpers.underscore(leaf)
        plural = RouteHelpers.pluralize(singular)
        @singular = singular
        @plural = plural
        @element = singular
        @collection = plural
        @param_key = singular
        ns = @namespace
        @singular_route_key = ns ? "#{ns.gsub('/', '_')}_#{singular}" : singular
        @route_key = ns ? "#{ns.gsub('/', '_')}_#{plural}" : plural
        @human = leaf.gsub(/([a-z\d])([A-Z])/, "\\1 \\2")
      end

      def new_route_key : String
        "new_#{singular_route_key}"
      end

      def edit_route_key : String
        "edit_#{singular_route_key}"
      end

      # Conventional path used when no named route was registered.
      # `Admin::Post` -> `/admin/posts`; `BlogPost` -> `/blog_posts`.
      def conventional_path : String
        if ns = @namespace
          "/#{ns}/#{@plural}"
        else
          "/#{@plural}"
        end
      end

      def singular_conventional_path : String
        if ns = @namespace
          "/#{ns}/#{@singular}"
        else
          "/#{@singular}"
        end
      end
    end

    def self.model_name(record) : ModelName
      ModelName.new(record.class.name)
    end

    def self.model_name(record : T.class) : ModelName forall T
      ModelName.new(T.name)
    end

    def self.dom_class(record) : String
      model_name(record).singular_route_key
    end

    def self.dom_class(record : Nil) : String
      ""
    end

    # Rails `dom_id`: `post_12`, `new_post`, optionally prefixed:
    # `dom_id(post, "edit")` -> `edit_post_12`.
    def self.dom_id(record : Nil, prefix : String? = nil) : String
      ""
    end

    def self.dom_id(record, prefix : String? = nil) : String
      base = dom_class(record)
      persisted = if record.responds_to?(:id)
                    !record.id.nil?
                  elsif record.responds_to?(:persisted?)
                    record.persisted?
                  else
                    true
                  end
      core = persisted ? "#{base}_#{record.id}" : "new_#{base}"
      prefix ? "#{prefix}_#{core}" : core
    end

    # Replaces `:name` / `*name`, drops optional `(...)` groups whose params
    # were not supplied, then appends extra params as a query string.
    # `required` names are checked explicitly so missing ids raise a helpful
    # error instead of leaking a literal `:id` into the URL.
    def self.build_path(pattern : String, required : Array(String), path_params : Hash(String, String), extra) : String
      required.each do |name|
        unless path_params.has_key?(name)
          raise MissingRouteParam.new("Missing route parameter '#{name}' for #{pattern.inspect}")
        end
      end
      template = resolve_optional(pattern, path_params)
      consumed = param_names(template)
      path = String.build do |io|
        i = 0
        while i < template.size
          char = template[i]
          if char == ':' && i + 1 < template.size && (template[i + 1].ascii_letter? || template[i + 1] == '_')
            j = i + 1
            while j < template.size && (template[j].alphanumeric? || template[j] == '_')
              j += 1
            end
            name = template[i + 1...j]
            value = path_params[name]?
            unless value
              raise MissingRouteParam.new("Missing route parameter '#{name}' for #{pattern.inspect}")
            end
            io << URI.encode_path_segment(value)
            i = j
          elsif char == '*' && i + 1 < template.size
            j = i + 1
            while j < template.size && (template[j].alphanumeric? || template[j] == '_')
              j += 1
            end
            name = j > i + 1 ? template[i + 1...j] : "splat"
            value = path_params[name]?
            unless value
              raise MissingRouteParam.new("Missing wildcard route parameter '#{name}' for #{pattern.inspect}")
            end
            io << value.split('/').map { |segment| URI.encode_path_segment(segment) }.join("/")
            i = j
          else
            io << char
            i += 1
          end
        end
      end
      path = "/" if path.empty?
      query = String.build do |io|
        append_extra_query(io, extra, consumed)
      end
      query.empty? ? path : "#{path}?#{query}"
    end

    # Appends only params that were not consumed by the path template.
    # `extra` may be a Hash or a NamedTuple; values may be arrays/hashes.
    def self.append_extra_query(io : IO, extra, consumed : Array(String)) : Nil
      first = true
      extra.each do |key, value|
        key_string = key.to_s
        next if consumed.includes?(key_string)
        next if value.nil?
        buffer = IO::Memory.new
        append_query(buffer, key_string, value)
        next if buffer.empty?
        io << '&' unless first
        first = false
        io << buffer
      end
    end

    # Recursively resolves `(...)` groups. A group is kept when at least one
    # `:param` inside it was supplied; otherwise it is dropped. This matches
    # Rails' optional-segment behavior closely enough for `(.:format)` and
    # `/top(/:length(/page/:page))`.
    def self.resolve_optional(pattern : String, params : Hash(String, String)) : String
      open = pattern.index('(')
      return pattern unless open
      depth = 0
      close = nil
      (open...pattern.size).each do |i|
        case pattern[i]
        when '(' then depth += 1
        when ')'
          depth -= 1
          if depth == 0
            close = i
            break
          end
        end
      end
      return pattern unless close
      inner = pattern[(open + 1)...close]
      before = pattern[0...open]
      after = pattern[(close + 1)..]
      names = param_names(inner)
      keep = !names.empty? && names.any? { |name| params.has_key?(name) }
      chosen = keep ? "#{before}#{inner}#{after}" : "#{before}#{after}"
      resolve_optional(chosen, params)
    end

    def self.param_names(pattern : String) : Array(String)
      names = [] of String
      pattern.scan(/:([A-Za-z_][A-Za-z0-9_]*)|\*([A-Za-z_][A-Za-z0-9_]*)/) do |match|
        name = match[1]? || match[2]?
        names << name if name && !names.includes?(name)
      end
      names
    end

    # Param names outside optional groups (they must be supplied).
    def self.required_param_names(pattern : String) : Array(String)
      param_names(strip_optional(pattern))
    end

    def self.strip_optional(pattern : String) : String
      result = String.build do |io|
        depth = 0
        pattern.each_char do |char|
          case char
          when '('
            depth += 1
          when ')'
            depth -= 1 if depth > 0
          else
            io << char if depth == 0
          end
        end
      end
      result
    end

    def self.query_string(params : Hash(String, String)) : String
      return "" if params.empty?
      String.build do |io|
        first = true
        params.each do |key, value|
          next if value.empty?
          io << '&' unless first
          first = false
          io << URI.encode_www_form(key) << '=' << URI.encode_www_form(value)
        end
      end
    end

    # Query strings accept arrays (repeated keys) and nested hashes
    # (`tags[]=a&tags[]=b`, `filter[name]=x`). Nil values are omitted.
    def self.append_query(io : IO, key : String, value) : Nil
      case value
      when Nil
        return
      when Array
        first = true
        value.each do |item|
          io << '&' unless first
          first = false
          append_query(io, "#{key}[]", item)
        end
      when Hash
        first = true
        value.each do |child_key, child_value|
          io << '&' unless first
          first = false
          append_query(io, "#{key}[#{child_key}]", child_value)
        end
      else
        io << URI.encode_www_form(key) << '=' << URI.encode_www_form(param_string(value))
      end
    end

    def self.query_string_from(io : IO, params) : Nil
      return if params.nil?
      first = true
      params.each do |key, value|
        next if value.nil?
        buffer = IO::Memory.new
        append_query(buffer, key.to_s, value)
        next if buffer.empty?
        io << '&' unless first
        first = false
        io << buffer
      end
    end

    # Converts positional route values to strings. Ids, slugs, and model
    # objects work: `post_path(post)` uses `post.to_param` when defined,
    # otherwise `post.id`, otherwise `to_s`.
    def self.param_string(value : Nil) : String
      raise MissingRouteParam.new("Nil route parameter")
    end

    def self.param_string(value : String) : String
      value
    end

    def self.param_string(value : Symbol) : String
      value.to_s
    end

    def self.param_string(value : Int | Float | Bool) : String
      value.to_s
    end

    def self.param_string(value) : String
      if value.responds_to?(:to_param)
        value.to_param.to_s
      elsif value.responds_to?(:id) && !value.id.nil?
        value.id.to_s
      else
        value.to_s
      end
    end

    def self.full_url(path : String, request : HTTP::Request? = nil, options : Hash(String, String)? = nil) : String
      return path if path.starts_with?("http://") || path.starts_with?("https://")
      merged = {} of String => String
      @@default_url_options.each { |key, value| merged[key] = value }
      options.try(&.each { |key, value| merged[key] = value })

      protocol = merged["protocol"]? || (request.try(&.ssl?) ? "https" : "http")
      host = merged["host"]?
      unless host
        host = request.try(&.hostname) || "localhost"
      end
      host = host.downcase
      if subdomain = merged["subdomain"]?
        unless subdomain.empty?
          domain = merged["domain"]? || (request.try(&.domain)) || host
          host = "#{subdomain}.#{domain}"
        end
      end

      default_port = protocol == "https" ? 443 : 80
      port = merged["port"]?.try(&.to_i?) || (host.includes?(':') ? nil : (request.try(&.port)))
      if port && port != default_port && !host.includes?(':')
        host = "#{host}:#{port}"
      end

      script_name = merged["script_name"]? || request.try(&.script_name) || ""
      script_name = RouteHelpers.normalize_script_name(script_name)
      path = "/" if path.empty?
      path = "#{script_name}#{path}" unless script_name.empty? || path.starts_with?(script_name)
      "#{protocol}://#{host}#{path}"
    end

    def self.normalize_script_name(value : String) : String
      return "" if value.empty? || value == "/"
      value = value.starts_with?("/") ? value : "/#{value}"
      value.ends_with?("/") ? value[0...-1] : value
    end

    # `polymorphic_path(post)` -> `post_path(post)` when named routes exist,
    # otherwise `/posts/12` (Rails conventions). New records use
    # `new_post_path` / `/posts/new`. `action: :edit` uses `edit_post_path`.
    def self.polymorphic_path(record, router : Router? = nil, action : Symbol? = nil, **params) : String
      model = model_name(record)
      persisted = if record.responds_to?(:persisted?)
                    record.persisted?
                  elsif record.responds_to?(:id)
                    !record.id.nil?
                  else
                    true
                  end
      key = if persisted
              case action
              when :edit then model.edit_route_key
              else            model.singular_route_key
              end
            else
              case action
              when :edit then model.edit_route_key
              else            model.new_route_key
              end
            end
      # Rails `resolve("Article") { :post }` overrides the model-name key.
      if router
        class_name = record.class.name
        resolved = router.resolved_route_key(class_name) || router.resolved_route_key(class_name.split("::").last)
        if resolved
          key = if persisted
                  action == :edit ? "edit_#{resolved}" : resolved
                else
                  action == :edit ? "edit_#{resolved}" : "new_#{resolved}"
                end
        end
      end
      path_params = {} of String => String
      if persisted && record.responds_to?(:id)
        path_params["id"] = param_string(record.id)
      end
      params.each { |k, v| path_params[k.to_s] = param_string(v) unless v.nil? }

      if router && router.named_route?(key)
        return router.path_for_params(key, path_params, path_params)
      end

      fallback = if persisted
                   case action
                   when :edit then "#{model.conventional_path}/#{path_params["id"]}/edit"
                   else            "#{model.conventional_path}/#{path_params["id"]}"
                   end
                 else
                   case action
                   when :edit then "#{model.conventional_path}/new/edit"
                   else            "#{model.conventional_path}/new"
                   end
                 end
      extra = path_params.reject { |k, _| k == "id" }
      query = query_string(extra)
      query.empty? ? fallback : "#{fallback}?#{query}"
    end

    # Nested polymorphic path: `[post, comment]` -> `post_comments_path`
    # (`post_comment_path` for a persisted comment). Intermediate records
    # become `post_id` path params.
    def self.polymorphic_path(records : Array, router : Router? = nil, action : Symbol? = nil, **params) : String
      raise MissingRouteParam.new("polymorphic_path cannot be called with an empty array") if records.empty?
      namespace = [] of String
      items = records
      if records.first.is_a?(Symbol)
        namespace << records.first.to_s
        items = records[1..]
        raise MissingRouteParam.new("polymorphic_path needs at least one record") if items.empty?
      end

      models = items.map { |item| model_name(item) }
      last = models.last
      persisted = if items.last.responds_to?(:persisted?)
                    items.last.persisted?
                  elsif items.last.responds_to?(:id)
                    !items.last.id.nil?
                  else
                    true
                  end
      prefix = namespace.join("_")
      segments = [] of String
      models[0...-1].each_with_index do |model, index|
        segments << model.singular
      end
      if namespace.empty?
        key_parts = models[0...-1].map(&.singular) + [persisted ? last.singular : last.plural]
        singular_parts = models.map(&.singular)
      else
        key_parts = namespace + models[0...-1].map(&.singular) + [persisted ? last.singular : last.plural]
        singular_parts = namespace + models.map(&.singular)
      end
      key = if persisted
              case action
              when :edit then "edit_#{singular_parts.join("_")}"
              else            singular_parts.join("_")
              end
            else
              case action
              when :edit then "edit_#{singular_parts.join("_")}"
              else            "new_#{singular_parts.join("_")}"
              end
            end

      path_params = {} of String => String
      models[0...-1].each_with_index do |model, index|
        item = items[index]
        path_params["#{model.singular}_id"] = param_string(item.id)
      end
      if persisted
        path_params["id"] = param_string(items.last.id)
      end
      params.each { |k, v| path_params[k.to_s] = param_string(v) unless v.nil? }

      if router && router.named_route?(key)
        return router.path_for_params(key, path_params, path_params)
      end

      # Convention fallback (no named route registered).
      base = String.build do |io|
        io << "/"
        first = true
        unless namespace.empty?
          io << namespace.join("/")
          first = false
        end
        models[0...-1].each do |model|
          io << "/" unless first
          first = false
          io << model.plural << "/:" << model.singular << "_id"
        end
        io << "/" unless first
        io << last.plural
        unless persisted
          io << "/new"
        end
      end
      path = String.build do |io|
        template = persisted && action == :edit ? "#{base}/:id/edit" : (persisted ? "#{base}/:id" : base)
        i = 0
        while i < template.size
          if template[i] == ':' && i + 1 < template.size
            j = i + 1
            while j < template.size && (template[j].alphanumeric? || template[j] == '_')
              j += 1
            end
            name = template[(i + 1)...j]
            io << URI.encode_path_segment(path_params[name]? || raise MissingRouteParam.new("Missing route parameter '#{name}'"))
            i = j
          else
            io << template[i]
            i += 1
          end
        end
      end
      extra = path_params.reject { |k, _| k == "id" || k.ends_with?("_id") }
      query = query_string(extra)
      query.empty? ? path : "#{path}?#{query}"
    end

    def self.polymorphic_url(record, request : HTTP::Request? = nil, router : Router? = nil, action : Symbol? = nil, **params) : String
      full_url(polymorphic_path(record, router, action, **params), request, router.try(&.default_url_options))
    end

    def self.polymorphic_url(records : Array, request : HTTP::Request? = nil, router : Router? = nil, action : Symbol? = nil, **params) : String
      full_url(polymorphic_path(records, router, action, **params), request, router.try(&.default_url_options))
    end

    def self.edit_polymorphic_path(record, router : Router? = nil, **params) : String
      polymorphic_path(record, router, :edit, **params)
    end

    def self.edit_polymorphic_path(records : Array, router : Router? = nil, **params) : String
      polymorphic_path(records, router, :edit, **params)
    end

    def self.underscore(word : String) : String
      word.gsub("::", "/")
        .gsub(/([A-Z\d]+)([A-Z][a-z])/, "\\1_\\2")
        .gsub(/([a-z\d])([A-Z])/, "\\1_\\2")
        .gsub('-', '_')
        .gsub('/', '_')
        .downcase
    end

    IRREGULAR_PLURALS = {
      "person" => "people",
      "man"    => "men",
      "woman"  => "women",
      "child"  => "children",
      "mouse"  => "mice",
      "goose"  => "geese",
      "ox"     => "oxen",
      "datum"  => "data",
      "medium" => "media",
    }

    def self.pluralize(word : String) : String
      if irregular = IRREGULAR_PLURALS[word]?
        return irregular
      end
      if word.ends_with?("y") && word.size > 1 && !"aeiou".includes?(word[-2])
        "#{word[0...-1]}ies"
      elsif word.ends_with?("s") || word.ends_with?("x") || word.ends_with?("z") ||
            word.ends_with?("ch") || word.ends_with?("sh")
        "#{word}es"
      else
        "#{word}s"
      end
    end

    def self.singularize(word : String) : String
      case word
      when "people"   then "person"
      when "men"      then "man"
      when "women"    then "woman"
      when "children" then "child"
      when "mice"     then "mouse"
      when "geese"    then "goose"
      when "data"     then "datum"
      else
        if word.ends_with?("ies") && word.size > 3
          "#{word[0...-3]}y"
        elsif word.ends_with?("ches") || word.ends_with?("shes") || word.ends_with?("xes") || word.ends_with?("zes")
          word[0...-2]
        elsif word.ends_with?("ses") && word.size > 3
          word[0...-2]
        elsif word.ends_with?("us") || word.ends_with?("ss") || word.ends_with?("news")
          word
        elsif word.ends_with?("s") && word.size > 1
          word[0...-1]
        else
          word
        end
      end
    end

    # Router-bound convenience wrapper returned by `Router#url_helpers`.
    # (`method_missing` does not exist in Crystal, hence `path_for("post")`
    # instead of dynamic `post_path`; use `Saci::Routes.define` for static
    # generated helpers.)
    class UrlHelpers
      getter router : Router

      def initialize(@router : Router)
      end

      def path_for(route_name : String | Symbol, *args, **params) : String
        @router.path_for(route_name, *args, **params)
      end

      def url_for(route_name : String | Symbol, *args, **params) : String
        @router.url_for(route_name, *args, **params)
      end

      def url_for(*, controller : Controller.class | String, action : Symbol, id = nil, **params) : String
        @router.url_for(**params, controller: controller, action: action, id: id)
      end

      def full_url_for(route_name : String | Symbol, *args, **params) : String
        @router.full_url_for(route_name, *args, **params)
      end

      def full_url_for(*, controller : Controller.class | String, action : Symbol, id = nil, **params) : String
        @router.full_url_for(**params, controller: controller, action: action, id: id)
      end

      def polymorphic_path(record, action : Symbol? = nil, **params) : String
        RouteHelpers.polymorphic_path(record, @router, action, **params)
      end

      def polymorphic_path(records : Array, action : Symbol? = nil, **params) : String
        RouteHelpers.polymorphic_path(records, @router, action, **params)
      end

      def polymorphic_url(record, action : Symbol? = nil, **params) : String
        RouteHelpers.polymorphic_url(record, **params, router: @router, action: action)
      end

      def polymorphic_url(records : Array, action : Symbol? = nil, **params) : String
        RouteHelpers.polymorphic_url(records, **params, router: @router, action: action)
      end

      def edit_polymorphic_path(record, **params) : String
        RouteHelpers.edit_polymorphic_path(record, @router, **params)
      end

      def edit_polymorphic_path(records : Array, **params) : String
        RouteHelpers.edit_polymorphic_path(records, @router, **params)
      end

      def named_routes : Hash(String, Router::NamedRoute)
        @router.named_routes
      end

      def [](name : String | Symbol) : Router::NamedRoute?
        @router.named_routes[name.to_s]?
      end

      def keys : Array(String)
        @router.helper_names
      end

      def has_key?(name : String | Symbol) : Bool
        @router.named_route?(name)
      end

      def size : Int32
        @router.helper_names.size
      end
    end
  end

  # `Saci::Routes` is both the macro namespace and a tiny global accessor
  # for the most recently drawn router. Controllers/views use it only when
  # no explicit router is supplied; request dispatch resets it to the router
  # handling the request.
  module Routes
    @@current_router : Router?

    def self.current_router : Router?
      @@current_router
    end

    def self.current_router=(router : Router?) : Router?
      @@current_router = router
    end

    def self.current_router! : Router
      @@current_router || raise RouteHelpers::UnknownRoute.new(
        "No current router. Draw a router with `Saci::Router.new.draw { ... }` " \
        "or use `Saci::Routes.define` (whose router is activated automatically) " \
        "before calling controller/view URL helpers."
      )
    end

    # Registry lookup is delegated to the current router.
    def self.path_for(route_name : String | Symbol, *args, **params) : String
      current_router!.path_for(route_name, *args, **params)
    end

    def self.url_for(route_name : String | Symbol, *args, **params) : String
      current_router!.url_for(route_name, *args, **params)
    end

    def self.url_for(*, controller : Controller.class | String, action : Symbol, id = nil, **params) : String
      current_router!.url_for(**params, controller: controller, action: action, id: id)
    end

    def self.full_url_for(route_name : String | Symbol, *args, **params) : String
      current_router!.full_url_for(route_name, *args, **params)
    end

    def self.full_url_for(*, controller : Controller.class | String, action : Symbol, id = nil, **params) : String
      current_router!.full_url_for(**params, controller: controller, action: action, id: id)
    end

    def self.polymorphic_path(record, action : Symbol? = nil, **params) : String
      RouteHelpers.polymorphic_path(record, current_router, action, **params)
    end

    def self.polymorphic_path(records : Array, action : Symbol? = nil, **params) : String
      RouteHelpers.polymorphic_path(records, current_router, action, **params)
    end

    def self.polymorphic_url(record, action : Symbol? = nil, **params) : String
      RouteHelpers.polymorphic_url(record, **params, router: current_router, action: action)
    end

    def self.polymorphic_url(records : Array, action : Symbol? = nil, **params) : String
      RouteHelpers.polymorphic_url(records, **params, router: current_router, action: action)
    end

    def self.edit_polymorphic_path(record, **params) : String
      RouteHelpers.edit_polymorphic_path(record, current_router, **params)
    end

    def self.edit_polymorphic_path(records : Array, **params) : String
      RouteHelpers.edit_polymorphic_path(records, current_router, **params)
    end

    def self.dom_id(record, prefix : String? = nil) : String
      RouteHelpers.dom_id(record, prefix)
    end

    def self.dom_class(record) : String
      RouteHelpers.dom_class(record)
    end

    def self.model_name(record) : RouteHelpers::ModelName
      RouteHelpers.model_name(record)
    end

    def self.url_helpers : RouteHelpers::UrlHelpers
      current_router!.url_helpers
    end

    def self.default_url_options : Hash(String, String)
      RouteHelpers.default_url_options
    end

    def self.default_url_options=(options : Hash(String, String)) : Hash(String, String)
      RouteHelpers.default_url_options = options
    end
  end

  # Controller instance helpers (`path_for`, `url_for`, `polymorphic_path`,
  # `dom_id`, ...). They use the current router, which `Router#draw` and
  # request dispatch keep in sync; for explicit control call
  # `Saci::Routes.current_router = router`.
  class Controller
    def routes : Router
      Saci::Routes.current_router!
    end

    def default_url_options : Hash(String, String)
      RouteHelpers.default_url_options
    end

    # Router defaults merged with the controller's `default_url_options`
    # (subclasses may override it, Rails-style).
    def url_options : Hash(String, String)
      merged = routes.default_url_options.dup
      default_url_options.each { |k, v| merged[k] = v }
      merged
    end

    def path_for(route_name : String | Symbol, *args, **params) : String
      routes.path_for(route_name, *args, **params)
    end

    def url_for(route_name : String | Symbol, *args, **params) : String
      routes.url_for(route_name, *args, **params)
    end

    def url_for(*, controller : Controller.class | String, action : Symbol, id = nil, **params) : String
      routes.url_for(**params, controller: controller, action: action, id: id)
    end

    def full_url_for(route_name : String | Symbol, *args, **params) : String
      path = routes.url_for(route_name, *args, **params)
      RouteHelpers.full_url(path, request, url_options)
    end

    def full_url_for(*, controller : Controller.class | String, action : Symbol, id = nil, **params) : String
      path = routes.url_for(**params, controller: controller, action: action, id: id)
      RouteHelpers.full_url(path, request, url_options)
    end

    def polymorphic_path(record, action : Symbol? = nil, **params) : String
      RouteHelpers.polymorphic_path(record, routes, action, **params)
    end

    def polymorphic_path(records : Array, action : Symbol? = nil, **params) : String
      RouteHelpers.polymorphic_path(records, routes, action, **params)
    end

    def polymorphic_url(record, action : Symbol? = nil, **params) : String
      RouteHelpers.polymorphic_url(record, request, routes, action, **params)
    end

    def polymorphic_url(records : Array, action : Symbol? = nil, **params) : String
      RouteHelpers.polymorphic_url(records, request, routes, action, **params)
    end

    def edit_polymorphic_path(record, **params) : String
      RouteHelpers.edit_polymorphic_path(record, routes, **params)
    end

    def edit_polymorphic_path(records : Array, **params) : String
      RouteHelpers.edit_polymorphic_path(records, routes, **params)
    end

    def dom_id(record, prefix : String? = nil) : String
      RouteHelpers.dom_id(record, prefix)
    end

    def dom_class(record) : String
      RouteHelpers.dom_class(record)
    end

    def model_name(record) : RouteHelpers::ModelName
      RouteHelpers.model_name(record)
    end
  end

  # Module-level view helpers. ECR templates rendered by `render_template`
  # run in the controller instance, so the instance methods above are the
  # primary surface; these are for code shared outside a controller.
  module Views
    def self.path_for(route_name : String | Symbol, *args, **params) : String
      Saci::Routes.path_for(route_name, *args, **params)
    end

    def self.url_for(route_name : String | Symbol, *args, **params) : String
      Saci::Routes.url_for(route_name, *args, **params)
    end

    def self.full_url_for(route_name : String | Symbol, *args, **params) : String
      Saci::Routes.full_url_for(route_name, *args, **params)
    end

    def self.polymorphic_path(record, action : Symbol? = nil, **params) : String
      Saci::Routes.polymorphic_path(record, action, **params)
    end

    def self.polymorphic_path(records : Array, action : Symbol? = nil, **params) : String
      Saci::Routes.polymorphic_path(records, action, **params)
    end

    def self.dom_id(record, prefix : String? = nil) : String
      RouteHelpers.dom_id(record, prefix)
    end

    def self.dom_class(record) : String
      RouteHelpers.dom_class(record)
    end

    def self.model_name(record) : RouteHelpers::ModelName
      RouteHelpers.model_name(record)
    end
  end
end

# `request.script_name` is the only request helper that lives here; the
# host/domain/port/ssl helpers are defined in `http_request_ext.cr` (loaded by
# `controller.cr`) and must not be duplicated: a later redefinition with a
# different signature would hide the `tld_length:` overload.
class HTTP::Request
  def script_name : String
    Saci::RouteHelpers.normalize_script_name(headers["X-Script-Name"]? || "")
  end
end
