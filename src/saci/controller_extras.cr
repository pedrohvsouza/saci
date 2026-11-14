require "base64"
require "json"
require "uri"

module Saci
  # Open-redirect protection switch (Rails
  # `config.action_controller.raise_on_open_redirects`). Enabled by default;
  # `allow_other_host: true` on a single redirect remains the preferred
  # escape hatch. Disable globally only for legacy applications:
  #
  # ```
  # Saci.raise_on_open_redirects = false
  # Saci::Controller.raise_on_open_redirects = false # same switch
  # ```
  class_property raise_on_open_redirects : Bool = true
end

module Saci
  class Controller
    # Module-level switch exposed on the controller for Rails parity.
    def self.raise_on_open_redirects : Bool
      Saci.raise_on_open_redirects
    end

    def self.raise_on_open_redirects=(value : Bool) : Bool
      Saci.raise_on_open_redirects = value
    end

    # Overridable defaults for `full_url_for` (Rails `default_url_options`).
    # Return `{"protocol" => ..., "host" => ...}`; the default reflects the
    # current request.
    def default_url_options : Hash(String, String)
      {"protocol" => request.protocol, "host" => request.host_with_port}
    end

    # Absolute URL for a relative path (Rails `url_for`-lite; named routes
    # live in the router/URL-helpers layer). Absolute URLs pass through.
    #
    # ```
    # full_url_for("/posts") # => "https://example.com/posts"
    # ```
    def full_url_for(path : String) : String
      return path if path.matches?(/\A[a-zA-Z][a-zA-Z0-9+\-.]*:\/\//)
      return "#{request.protocol}:#{path}" if path.starts_with?("//")
      options = default_url_options
      protocol = options["protocol"]? || request.protocol
      host = options["host"]? || request.host_with_port
      target = path.starts_with?('/') ? path : "/#{path}"
      "#{protocol}://#{host}#{target}"
    end

    # Rails `render` keyword surface. The macro resolves literal
    # `template:`, `action:` and `partial:` options at compile time (Crystal
    # cannot evaluate a runtime template name); everything else forwards to
    # `__saci_render`.
    #
    # ```
    # render json: @post, status: :created, location: post_path(@post)
    # render body: "raw", content_type: "text/csv"
    # render file: "public/export.csv"
    # render template: "shared/error", layout: false, status: 422
    # render action: :show
    # render partial: "comments/comment", comment: comment
    # render partial: "shared/row", locals: {label: "Hi"}
    # ```
    macro render(**options)
      {% if options[:template] || options[:action] %}
        {% tmpl = options[:template] || options[:action] %}
        {% is_action = options[:action] ? true : false %}
        {% layout = options[:layout].nil? ? "application" : options[:layout] %}
        {% status = options[:status].nil? ? 200 : options[:status] %}
        {% content_type = options[:content_type] %}
        {% if tmpl.is_a?(SymbolLiteral) || tmpl.is_a?(StringLiteral) %}
          {% if tmpl.is_a?(StringLiteral) && is_action && !tmpl.id.stringify.includes?("/") %}
            {% ctrl_path = @type.name.stringify.split("::").map { |p| p.gsub(/Controller$/, "").underscore }.join("/") %}
            render_template "{{ctrl_path}}/{{tmpl}}", layout: {{layout}}, status: {{status}}
          {% else %}
            render_template {{tmpl}}, layout: {{layout}}, status: {{status}}
          {% end %}
        {% else %}
          __saci_render(template: {{options[:template]}}, action: {{options[:action]}}, status: {{status}}, content_type: {{content_type}})
        {% end %}
      {% elsif options[:partial] %}
        {% status = options[:status].nil? ? 200 : options[:status] %}
        {% content_type = options[:content_type] %}
        render html: render_partial({{options[:partial]}}{% for k, v in options %}{% unless [:partial, :status, :content_type, :layout, :locals].includes?(k) %}, {{k}}: {{v}}{% end %}{% end %}{% if options[:locals] && options[:locals].is_a?(NamedTupleLiteral) %}{% for k, v in options[:locals] %}, {{k}}: {{v}}{% end %}{% end %}), status: {{status}}{% if content_type %}, content_type: {{content_type}}{% end %}
      {% else %}
        __saci_render({{options.double_splat}})
      {% end %}
    end

    # Renders to a String without touching the response (`render_to_string`).
    # Literal template/action/partial options are resolved at compile time;
    # json/plain/html/body/file are handled by
    # `__saci_render_to_string`.
    #
    # ```
    # html = render_to_string(partial: "comments/comment", comment: @comment)
    # payload = render_to_string(json: {ok: true})
    # ```
    macro render_to_string(**options)
      {% if options[:template] || options[:action] %}
        {% tmpl = options[:template] || options[:action] %}
        {% is_action = options[:action] ? true : false %}
        {% layout = options[:layout].nil? ? false : options[:layout] %}
        {% if tmpl.is_a?(SymbolLiteral) || tmpl.is_a?(StringLiteral) %}
          {% views_root = system("pwd").strip + "/src/views" %}
          {% ctrl_path = @type.name.stringify.split("::").map { |p| p.gsub(/Controller$/, "").underscore }.join("/") %}
          {% if tmpl.is_a?(SymbolLiteral) %}
            {% template = ctrl_path + "/" + tmpl.id.stringify %}
          {% elsif is_action && !tmpl.id.stringify.includes?("/") %}
            {% template = ctrl_path + "/" + tmpl.id.stringify %}
          {% else %}
            {% template = tmpl.id.stringify %}
          {% end %}
          {% if layout.is_a?(StringLiteral) %}
            @__content = __saci_buffered do |__saci_rts_view_io|
              ECR.embed("{{views_root + "/" + template + ".ecr"}}", "__saci_rts_view_io")
            end
            __saci_buffered do |__saci_rts_layout_io|
              ECR.embed("{{views_root + "/layouts/" + layout.id.stringify + ".ecr"}}", "__saci_rts_layout_io")
            end
          {% else %}
            __saci_buffered do |__saci_rts_view_io|
              ECR.embed("{{views_root + "/" + template + ".ecr"}}", "__saci_rts_view_io")
            end
          {% end %}
        {% else %}
          __saci_render_to_string(template: {{options[:template]}}, action: {{options[:action]}})
        {% end %}
      {% elsif options[:partial] %}
        render_partial({{options[:partial]}}{% for k, v in options %}{% unless [:partial, :status, :content_type, :layout, :locals].includes?(k) %}, {{k}}: {{v}}{% end %}{% end %}{% if options[:locals] && options[:locals].is_a?(NamedTupleLiteral) %}{% for k, v in options[:locals] %}, {{k}}: {{v}}{% end %}{% end %})
      {% else %}
        __saci_render_to_string({{options.double_splat}})
      {% end %}
    end

    # Turbo Stream compatibility overload (turbo.cr historically defined a
    # `render` method; the `render` macro now owns the name, so forward its
    # options here).
    def __saci_render(*, turbo_stream : String | Array(String), status : Int32 | Symbol = 200, content_type : String? = nil) : Nil
      body = turbo_stream.is_a?(Array) ? turbo_stream.join : turbo_stream
      __saci_render(html: body, status: status, content_type: content_type || "text/vnd.turbo-stream.html")
    end

    # Method half of `render_to_string` (see the macro above).
    def __saci_render_to_string(*, json : Object? = nil, html : String? = nil, text : String? = nil, plain : String? = nil, xml : String? = nil, body : String? = nil, file : String? = nil, template : String | Symbol | Nil = nil, action : String | Symbol | Nil = nil, partial : String | Symbol | Nil = nil, status : Int32 | Symbol = 200, content_type : String? = nil, location : String? = nil) : String
      if !json.nil?
        json.to_json
      elsif h = html
        h
      elsif x = xml
        x
      elsif t = text
        t
      elsif p = plain
        p
      elsif b = body
        b
      elsif f = file
        File.read(self.class.render_file_path(f))
      elsif t = template
        raise RenderError.new("render_to_string(template:) needs a compile-time literal (got #{t.inspect}); use `render_template` or a literal path")
      elsif a = action
        raise RenderError.new("render_to_string(action:) needs a compile-time literal (got #{a.inspect}); use `render_template` or a literal path")
      elsif p = partial
        raise RenderError.new("render_to_string(partial:) needs a compile-time literal (got #{p.inspect}); use `render_partial`")
      else
        ""
      end
    end

    # Root that `render file:` may read from (defaults to the process
    # working directory, i.e. the app root). Absolute paths outside this
    # root are rejected with `UnsafeFilePath`.
    class_property render_file_root : String = Dir.current

    def self.render_file_path(path : String) : String
      raise UnsafeFilePath.new("file path contains a NUL byte") if path.includes?('\0')
      root = File.expand_path(render_file_root)
      resolved = File.expand_path(path.starts_with?('/') ? path : File.join(root, path))
      prefix = root.ends_with?('/') ? root : root + "/"
      unless resolved == root || resolved.starts_with?(prefix)
        raise UnsafeFilePath.new("render file: path escapes render_file_root: #{path.inspect}")
      end
      unless File.file?(resolved)
        raise MissingFile.new("render file: not found: #{path.inspect}")
      end
      # Resolve symlinks too: a link inside the root must not point outside.
      real_root = File.realpath(root)
      real_path = File.realpath(resolved)
      real_prefix = real_root.ends_with?('/') ? real_root : real_root + "/"
      unless real_path == real_root || real_path.starts_with?(real_prefix)
        raise UnsafeFilePath.new("render file: path resolves outside render_file_root: #{path.inspect}")
      end
      real_path
    rescue ex : UnsafeFilePath | MissingFile
      raise ex
    rescue ex
      raise UnsafeFilePath.new("render file: invalid path #{path.inspect}: #{ex.message}")
    end

    def self.content_type_for_file(path : String) : String
      case File.extname(path).downcase
      when ".html", ".htm" then "text/html; charset=utf-8"
      when ".txt"          then "text/plain; charset=utf-8"
      when ".csv"          then "text/csv; charset=utf-8"
      when ".json"         then "application/json; charset=utf-8"
      when ".xml"          then "application/xml; charset=utf-8"
      when ".css"          then "text/css; charset=utf-8"
      when ".js"           then "text/javascript; charset=utf-8"
      when ".svg"          then "image/svg+xml"
      when ".png"          then "image/png"
      when ".jpg", ".jpeg" then "image/jpeg"
      when ".gif"          then "image/gif"
      when ".webp"         then "image/webp"
      when ".pdf"          then "application/pdf"
      else                      "application/octet-stream"
      end
    end

    # Constant-time-ish comparison for HTTP auth credentials. Length is
    # leaked (unavoidable for strings), contents are not short-circuited.
    def self.secure_compare(a : String, b : String) : Bool
      return false unless a.bytesize == b.bytesize
      diff = 0_u8
      a.to_slice.each_with_index do |byte, i|
        diff |= byte ^ b.to_slice[i]
      end
      diff == 0
    end

    # Parses `Authorization: Basic ...` and yields user/password. Returns
    # false when the header is missing or malformed; never responds.
    def authenticate_with_http_basic(&block : String, String -> Bool) : Bool
      header = request.headers["Authorization"]?
      return false unless header
      scheme, encoded = header.split(' ', 2)
      return false unless scheme.downcase == "basic" && !encoded.empty?
      decoded = begin
        Base64.decode_string(encoded)
      rescue
        return false
      end
      if idx = decoded.index(':')
        user = decoded[0...idx]
        password = decoded[(idx + 1)..]?
        return false unless password
        block.call(user, password)
      else
        false
      end
    end

    # Like `authenticate_with_http_basic`, but sends 401 +
    # `WWW-Authenticate: Basic` when authentication fails.
    def authenticate_or_request_with_http_basic(realm : String = "Application", message : String? = nil, &block : String, String -> Bool) : Bool
      return true if authenticate_with_http_basic(&block)
      request_http_basic_authentication(realm, message)
      false
    end

    def request_http_basic_authentication(realm : String = "Application", message : String? = nil) : Nil
      response.headers["WWW-Authenticate"] = %(Basic realm="#{realm}")
      respond(plain: message || "HTTP Basic: Access denied.\n", content_type: "text/plain; charset=utf-8", status: 401)
    end

    # Parses `Authorization: Token token="...", other="..."` (Rails token
    # scheme) or `Authorization: Bearer ...` and yields the token plus any
    # extra token parameters. Never responds.
    def authenticate_with_http_token(&block : String, Hash(String, String) -> Bool) : Bool
      header = request.headers["Authorization"]?
      return false unless header
      scheme, rest = header.split(' ', 2)
      return false unless rest
      token : String? = nil
      options = {} of String => String
      case scheme.downcase
      when "bearer"
        token = rest.strip
      when "token"
        rest.split(',').each do |part|
          key, value = part.strip.split('=', 2)
          next unless value
          k = key.strip.downcase
          v = value.strip.strip('"')
          if k == "token"
            token = v
          else
            options[k] = v
          end
        end
      else
        return false
      end
      t = token
      return false if t.nil? || t.empty?
      block.call(t, options)
    end

    # Like `authenticate_with_http_token`, but sends 401 +
    # `WWW-Authenticate: Token` when authentication fails.
    def authenticate_or_request_with_http_token(realm : String = "Application", &block : String, Hash(String, String) -> Bool) : Bool
      return true if authenticate_with_http_token(&block)
      request_http_token_authentication(realm)
      false
    end

    def request_http_token_authentication(realm : String = "Application") : Nil
      response.headers["WWW-Authenticate"] = %(Token realm="#{realm}")
      respond(plain: "HTTP Token: Access denied.\n", content_type: "text/plain; charset=utf-8", status: 401)
    end

    # `http_basic_authenticate_with name: "admin", password: "secret"`
    # installs a before filter (Rails G60 convenience macro).
    #
    # `name:` / `password:` are evaluated on every request and may be
    # `String?`; a nil or empty expected value denies everyone (fails
    # closed), so a missing secret never opens the door:
    #
    # ```
    # http_basic_authenticate_with name: ENV["ADMIN_USER"]?, password: ENV["ADMIN_PASSWORD"]?
    # ```
    #
    # `credentials: "moderation"` reads `moderation.name` (or
    # `moderation.user`) and `moderation.password` from the encrypted
    # credentials, also failing closed when any of them (or the master key)
    # is missing:
    #
    # ```
    # http_basic_authenticate_with credentials: "moderation", only: [:index]
    # ```
    macro http_basic_authenticate_with(**options)
      {% unless options[:credentials] || (options[:name] && options[:password]) %}
        {% raise "http_basic_authenticate_with requires name: and password: (or credentials:)" %}
      {% end %}
      {% realm = options[:realm].nil? ? "Application" : options[:realm] %}
      {% suffix = options[:only] ? "_" + options[:only].stringify.gsub(/[^a-zA-Z0-9_]/, "_") : "" %}
      {% filter_name = "__saci_http_basic_authenticate" + suffix %}
      private def {{filter_name.id}} : Nil
        {% if options[:credentials] %}
          __saci_expected = Saci::Controller.http_basic_credentials({{options[:credentials]}})
        {% else %}
          __saci_expected = { ({{options[:name]}}).as(String?), ({{options[:password]}}).as(String?) }
        {% end %}
        authenticate_or_request_with_http_basic({{realm}}) do |__saci_user, __saci_password|
          Saci::Controller.http_basic_match?(__saci_user, __saci_password, __saci_expected[0], __saci_expected[1])
        end
      end
      before_action :{{filter_name.id}}, only: {{options[:only]}}, except: {{options[:except]}}
    end

    # Constant-time check of a Basic login against expected values. Nil or
    # empty expectations never match.
    def self.http_basic_match?(user : String, password : String, expected_name : String?, expected_password : String?) : Bool
      return false if expected_name.nil? || expected_name.empty?
      return false if expected_password.nil? || expected_password.empty?
      name_ok = secure_compare(user, expected_name)
      password_ok = secure_compare(password, expected_password)
      name_ok && password_ok
    end

    # `{name, password}` from the credentials entry *key* (`name:` or
    # `user:` plus `password:`); nils when the entry, a value or the
    # master key is missing.
    def self.http_basic_credentials(key : String | Symbol) : Tuple(String?, String?)
      prefix = key.to_s
      name = Saci::Credentials.dig("#{prefix}.name") || Saci::Credentials.dig("#{prefix}.user")
      {name, Saci::Credentials.dig("#{prefix}.password")}
    rescue
      {nil, nil}
    end

    # Blocks requests from unsupported browsers with a 406. Supports the
    # Rails preset, per-browser minimum versions, an explicit allowlist of
    # UA substrings, or a blocklist:
    #
    # ```
    # allow_browser versions: :modern, only: [:index]
    # allow_browser versions: {chrome: 120, firefox: 121, safari: 16.4}
    # allow_browser allow: ["MyApp"], only: [:api]
    # allow_browser block: ["BadBot"]
    # allow_browser ..., name: :api_clients    # unique filter name
    # ```
    macro allow_browser(**options)
      {% browser_name = options[:name] %}
      {% suffix = browser_name ? "_" + browser_name.id.stringify.gsub(/[^a-zA-Z0-9_]/, "_") : (options[:only] ? "_" + options[:only].stringify.gsub(/[^a-zA-Z0-9_]/, "_") : "") %}
      {% filter_name = "__saci_allow_browser" + suffix %}
      private def {{filter_name.id}} : Nil
        __saci_ua = request.headers["User-Agent"]? || ""
        __saci_blocked = if __saci_ua.empty?
                           true
                         else
                         {% if options[:allow] %}
                           !({{options[:allow]}}).any? { |__saci_part| __saci_ua.includes?(__saci_part) }
                         {% elsif options[:block] %}
                           ({{options[:block]}}).any? { |__saci_part| __saci_ua.includes?(__saci_part) }
                         {% elsif options[:versions] && options[:versions].is_a?(SymbolLiteral) && options[:versions].id.stringify == "modern" %}
                           !Saci::Controller.modern_browser?(__saci_ua)
                         {% elsif options[:versions] %}
                           !Saci::Controller.supported_browser?(__saci_ua, {{options[:versions]}})
                         {% else %}
                           !Saci::Controller.modern_browser?(__saci_ua)
                         {% end %}
                         end
        if __saci_blocked
          respond(plain: "Not Acceptable", content_type: "text/plain; charset=utf-8", status: 406)
        end
      end
      before_action :{{filter_name.id}}, only: {{options[:only]}}, except: {{options[:except]}}
    end

    # Conservative "modern" preset (Rails 8-ish): current-ish evergreen
    # browser versions. Unknown/bot UAs are blocked, matching Rails'
    # `versions: :modern` intent.
    def self.modern_browser?(ua : String) : Bool
      return false if ua.empty?
      return false if ua.matches?(/MSIE|Trident/)
      return true if (v = browser_version(ua, "edge")) && v >= 120.0
      return true if (v = browser_version(ua, "chrome")) && v >= 120.0
      return true if (v = browser_version(ua, "firefox")) && v >= 121.0
      return true if (v = browser_version(ua, "safari")) && v >= 16.4
      return true if (v = browser_version(ua, "opera")) && v >= 106.0
      false
    end

    def self.supported_browser?(ua : String, versions) : Bool
      versions.each do |key, minimum|
        name = key.to_s.downcase
        if name == "ie" || name == "internet_explorer"
          matched = ua.matches?(/MSIE|Trident/)
          if minimum.is_a?(Bool)
            return matched == minimum
          else
            next unless matched
            return (browser_version(ua, "ie") || 0.0) >= minimum.to_f
          end
        end
        if v = browser_version(ua, name)
          if minimum.is_a?(Bool)
            return minimum
          else
            return v >= minimum.to_f
          end
        end
      end
      false
    end

    def self.browser_version(ua : String, browser : String) : Float64?
      pattern = case browser.downcase
                when "edge", "edg"        then /Edg(?:e|A|iOS)?\/([\d]+(?:\.[\d]+)?)/
                when "chrome", "chromium" then /(?:Chrome|Chromium)\/([\d]+(?:\.[\d]+)?)/
                when "firefox"            then /Firefox\/([\d]+(?:\.[\d]+)?)/
                when "safari"             then ua.includes?("Chrome") || ua.includes?("Chromium") ? nil : /Version\/([\d]+(?:\.[\d]+)?).*Safari\//
                when "opera", "opr"       then /(?:OPR|Opera)\/([\d]+(?:\.[\d]+)?)/
                when "ie"                 then /(?:MSIE |rv:)([\d]+(?:\.[\d]+)?)/
                else                           nil
                end
      return nil unless pattern
      if m = ua.match(pattern)
        m[1].to_f?
      end
    end

    # `rate_limit to: 10, within: 1.minute` installs a before filter backed
    # by `Saci::Throttle` (same store as the global Rack::Attack-style
    # rules). Buckets are keyed by controller + action + discriminator +
    # window, so limits are per action and per client:
    #
    # ```
    # rate_limit to: 5, within: 1.minute, only: [:create],
    #   by: ->(req : HTTP::Request) { req.headers["X-Api-Key"]? || "anon" }
    # rate_limit to: 100, within: 1.hour, only: [:index],
    #   with: -> { head :too_many_requests }
    # ```
    #
    # The default discriminator is `Saci::Throttle.client_ip(context)`.
    # Default response is `429` with `Retry-After`. Use `name:` to declare
    # several limits in one controller and `skip_rate_limit :name` to
    # suppress an inherited one.
    macro rate_limit(**options)
      {% unless options[:to] %}
        {% raise "rate_limit requires to:" %}
      {% end %}
      {% limit = options[:to] %}
      {% within = options[:within].nil? ? 1.minute : options[:within] %}
      {% lim_name = options[:name] %}
      {% suffix = lim_name ? "_" + lim_name.id.stringify.gsub(/[^a-zA-Z0-9_]/, "_") : "" %}
      {% filter_name = "__saci_rate_limit" + suffix %}
      private def {{filter_name.id}} : Nil
        __saci_rate_limit_key = {% if options[:by] %}
                                  ({{options[:by]}}).call(request)
                                {% else %}
                                  Saci::Throttle.client_ip(context)
                                {% end %}
        if __saci_retry_after = Saci::Controller.check_rate_limit(
             {{@type.name.stringify}},
             action_name,
             {{lim_name ? lim_name.id.stringify : "default"}},
             {{limit}},
             {{within}},
             __saci_rate_limit_key
           )
          response.headers["Retry-After"] = __saci_retry_after.to_s
          {% if options[:with] %}
            {% if options[:with].is_a?(SymbolLiteral) %}
              {{options[:with].id}}
            {% else %}
              ({{options[:with]}}).call
            {% end %}
          {% else %}
            head :too_many_requests
          {% end %}
          @performed = true unless performed?
        end
      end
      before_action :{{filter_name.id}}, only: {{options[:only]}}, except: {{options[:except]}}
    end

    macro skip_rate_limit(name = nil)
      {% suffix = name ? "_" + name.id.stringify.gsub(/[^a-zA-Z0-9_]/, "_") : "" %}
      Saci::Controller.register_skip(:before, {{@type.name.stringify}}, {{("__saci_rate_limit" + suffix).id.symbolize}}, nil, nil)
    end

    def self.check_rate_limit(controller : String, action : Symbol, name : String, limit : Int32, period : Time::Span, key : String?) : Int32?
      return nil if key.nil? || key.empty?
      period_secs = period.total_seconds.to_i64
      period_secs = 1_i64 if period_secs < 1
      now = Time.utc.to_unix
      window = now // period_secs
      bucket = "controller:#{controller}:#{action}:#{name}:#{key}:#{window}"
      ttl = ((window + 1) * period_secs - now).to_i
      ttl = 1 if ttl < 1
      count = begin
        Saci::Throttle.store.increment(bucket, window, period_secs, ttl)
      rescue ex : Exception
        STDERR.puts("warning: saci controller rate_limit store unreachable (#{ex.message}); allowing request (fail-open)")
        return nil
      end
      return nil unless count > limit
      retry_after = (window + 1) * period_secs - now
      retry_after > 0 ? retry_after.to_i : 0
    end

    struct WrapParameters
      getter format : Array(Symbol)
      getter included_keys : Array(String)
      getter excluded_keys : Array(String)
      getter name : String?

      def initialize(format : Symbol | Array(Symbol), include_keys : Array(Symbol)?, exclude_keys : Array(Symbol)?, name : String | Symbol?)
        @format = case format
                  when Symbol        then [format]
                  when Array(Symbol) then format
                  else                    [:json]
                  end
        @included_keys = include_keys.try(&.map(&.to_s)) || [] of String
        @excluded_keys = exclude_keys.try(&.map(&.to_s)) || [] of String
        @name = name.try(&.to_s)
      end

      def json_format? : Bool
        @format.includes?(:json)
      end
    end

    WRAP_JSON_EXCLUDES = ["controller", "action", "format", "_method", "authenticity_token"]

    @@wrap_parameters = {} of String => WrapParameters
    @@wrap_parents = {} of String => String
    @@rescue_responses = {} of String => Int32

    def self.register_wrap_parameters(klass : String, format : Symbol | Array(Symbol), include_keys : Array(Symbol)?, exclude_keys : Array(Symbol)?, name : String | Symbol?) : Nil
      @@wrap_parameters[klass] = WrapParameters.new(format, include_keys, exclude_keys, name)
    end

    # Wraps JSON request bodies under a root key derived from the controller
    # name (`UsersController` -> `user`), Rails `wrap_parameters`:
    #
    # ```
    # wrap_parameters format: :json
    # wrap_parameters format: :json, include: [:name, :email], exclude: [:role]
    # wrap_parameters format: :json, name: :account
    # ```
    macro wrap_parameters(**options)
      Saci::Controller.register_wrap_parameters(
        {{@type.name.stringify}},
        {{options[:format] || :json}},
        {{options[:include]}},
        {{options[:exclude]}},
        {{options[:name]}}
      )
    end

    def self.inherit_wrap_parameters(child : String, parent : String) : Nil
      @@wrap_parents[child] = parent
    end

    def self.wrap_options_for(klass : String) : WrapParameters?
      current : String? = klass
      guard = 0
      while current && guard < 100
        if opts = @@wrap_parameters[current]?
          return opts
        end
        current = @@wrap_parents[current]?
        guard += 1
      end
      nil
    end

    # `UsersController` -> `user`, `Admin::PostsController` -> `post`.
    def self.infer_wrap_name(klass : String) : String
      base = klass.split("::").last
      base = base.sub(/Controller$/, "")
      singularize(underscore(base))
    end

    def self.underscore(value : String) : String
      value
        .gsub(/([A-Z]+)([A-Z][a-z])/) { |_full, match| "#{match[1]}_#{match[2]}" }
        .gsub(/([a-z\d])([A-Z])/) { |_full, match| "#{match[1]}_#{match[2]}" }
        .gsub('-', '_')
        .downcase
    end

    def self.singularize(word : String) : String
      case word
      when "people"   then "person"
      when "children" then "child"
      when "men"      then "man"
      when "women"    then "woman"
      when "mice"     then "mouse"
      else
        if word.ends_with?("ies") && word.size > 3
          word[0...-3] + "y"
        elsif word.ends_with?("ses") || word.ends_with?("xes") || word.ends_with?("zes") || word.ends_with?("ches") || word.ends_with?("shes")
          word[0...-2]
        elsif word.ends_with?("s") && !word.ends_with?("ss")
          word[0...-1]
        else
          word
        end
      end
    end

    # Called from `initialize` before filters run.
    private def __saci_apply_params_wrapper : Nil
      opts = Saci::Controller.wrap_options_for(self.class.name)
      return unless opts
      return unless opts.json_format?
      content_type = request.headers["Content-Type"]? || ""
      is_json = content_type.includes?("application/json") || params["format"]? == "json"
      return unless is_json
      root = opts.name || Saci::Controller.infer_wrap_name(self.class.name)
      params.wrap!(root, opts.included_keys, opts.excluded_keys)
    end

    # Registers the HTTP status used for an exception class name. This is a
    # registry/helper: the built-in router renders `ParameterMissing`/
    # `RoutingError`/`UnknownFormat` itself; custom middleware or a future
    # exceptions app can consult `rescue_response_status`.
    def self.register_rescue_response(name : String, status : Int32 | Symbol) : Nil
      @@rescue_responses[name] = status.is_a?(Int32) ? status : status_code_for(status.as(Symbol))
    end

    def self.rescue_response_status_for(name : String) : Int32?
      @@rescue_responses[name]?
    end

    def self.rescue_response_status(exc : Exception) : Int32?
      @@rescue_responses[exc.class.name]?
    end

    # ```
    # rescue_responses({"MyError" => :not_found, "OtherError" => :bad_request})
    # rescue_responses my_error: :not_found
    # ```
    macro rescue_responses(mapping)
      {% if mapping.is_a?(HashLiteral) %}
        {% for key, status in mapping %}
          Saci::Controller.register_rescue_response({{key}}, {{status}})
        {% end %}
      {% else %}
        {% raise "rescue_responses expects a hash literal ({Name => status})" %}
      {% end %}
    end

    macro rescue_responses(**mapping)
      {% for exc, status in mapping %}
        Saci::Controller.register_rescue_response({{exc.stringify}}, {{status}})
      {% end %}
    end
  end
end

# Seed the common Rails mappings (exact names; subclasses can register their
# own with `rescue_responses`).
Saci::Controller.register_rescue_response("Saci::ParameterMissing", 400)
Saci::Controller.register_rescue_response("Saci::Controller::UnsafeRedirectError", 500)
Saci::Controller.register_rescue_response("Saci::Controller::UnknownFormat", 406)
Saci::Controller.register_rescue_response("Saci::RoutingError", 404)
