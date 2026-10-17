module Saci
  # Rails-like base controller (ActionController::Base equivalent).
  #
  # ```
  # class ApplicationController < Saci::Controller
  # end
  #
  # class UsersController < ApplicationController
  #   before_action :require_token, only: [:show]
  #
  #   def show
  #     render json: {id: params["id"]? || "?"}
  #   end
  #
  #   private def require_token
  #     render(json: {error: "unauthorized"}, status: :unauthorized) unless params.has_key?("token")
  #   end
  # end
  # ```
  #
  # How it works in Crystal (statically compiled, no Ruby-style `send`):
  # * `before_action` generates a per-class filter-chain fragment. Fragments
  #   chain with `previous_def` (same-type chaining, which Crystal supports)
  #   onto a per-class chain base injected by the `inherited` hook.
  #   `run_before_filters` calls `super` (parent filters first, Rails order)
  #   then its own class's chain method *statically*, so private filter
  #   methods and filter inheritance both work.
  # * `after_action` mirrors it, except `run_after_filters` runs the class's
  #   own chain *before* `super` (Rails runs afters child-first).
  # * `rescue_from` generates a per-class rescue chain the same way;
  #   `run_rescue` tries the class's own handlers before `super`.
  # * Action dispatch (`call_action`) is generated per controller subclass by
  #   the `inherited` hook using `{% verbatim %}` (deferred expansion, the
  #   same technique `JSON::Serializable` uses). At instantiation time the
  #   full method list is known, so a `case` over action names calling each
  #   action *statically* is generated, walking up the superclass chain
  #   (inherited actions work, most-derived override wins).
  #
  # Constraints (compared to Rails):
  # * Any public zero-argument instance method is dispatchable as an action
  #   (same as Rails). Keep helpers private or give them parameters.
  #   (`respond_to`/`request_format` are excluded explicitly.)
  # * Avoid public zero-argument `&block` methods in controllers: they cannot
  #   be called without a block, which breaks dispatcher codegen.
  # * Avoid public zero-argument `def self.x` methods; they may confuse the
  #   dispatcher. Regular `def self.x` helpers *with* parameters are fine.
  class Controller
    alias FilterTarget = Symbol | Array(Symbol) | Nil

    # Raised when `respond_to` has no handler for the request format
    # (rendered as 406 by the router; `rescue_from` can catch it, like
    # Lobsters' `UnknownFormat` handler rendering a 404 page).
    class UnknownFormat < Exception
    end

    # Content-negotiation collector for `respond_to`:
    #   respond_to do |f|
    #     f.html { render_template :show }
    #     f.json { render json: @story }
    #     f.rss { render xml: rss_feed(...) }
    #   end
    class Responder
      def initialize
        @handlers = {} of Symbol => Proc(Nil)
      end

      def html(&block : ->) : Nil
        @handlers[:html] = block
      end

      def json(&block : ->) : Nil
        @handlers[:json] = block
      end

      def rss(&block : ->) : Nil
        @handlers[:rss] = block
      end

      def xml(&block : ->) : Nil
        @handlers[:xml] = block
      end

      def text(&block : ->) : Nil
        @handlers[:text] = block
      end

      # Fallback when no specific handler matches the request format.
      def any(&block : ->) : Nil
        @handlers[:any] = block
      end

      def run(format : Symbol) : Bool
        if h = @handlers[format]?
          h.call
          true
        elsif h = @handlers[:any]?
          h.call
          true
        else
          false
        end
      end
    end

    # `skip_before_action` / `skip_after_action` registry:
    # `"after:LoginController:clear_session_cookie"` -> [{only, except}].
    SKIP_FILTERS = {} of String => Array(Tuple(Array(Symbol), Array(Symbol)))

    getter context : HTTP::Server::Context
    getter params : Params
    getter action_name : Symbol

    @performed : Bool = false

    def initialize(@context : HTTP::Server::Context, @params : Params, @action_name : Symbol)
    end

    # -- request / response helpers -------------------------------------

    def request : HTTP::Request
      context.request
    end

    def response : HTTP::Server::Response
      context.response
    end

    def performed? : Bool
      @performed
    end

    # -- filters ----------------------------------------------------------

    def self.filter_applies?(only : FilterTarget, except : FilterTarget, action : Symbol) : Bool
      if o = only
        list = o.is_a?(Symbol) ? [o.as(Symbol)] : o.as(Array(Symbol))
        return false unless list.includes?(action)
      end
      if e = except
        list = e.is_a?(Symbol) ? [e.as(Symbol)] : e.as(Array(Symbol))
        return false if list.includes?(action)
      end
      true
    end

    # Records a `skip_before_action` / `skip_after_action` entry. Runs at
    # class-definition time; checked per request by `__saci_own_skip?`.
    def self.register_skip(kind : Symbol, klass : String, name : Symbol, only : FilterTarget, except : FilterTarget) : Nil
      only_list = case only
                  when Symbol        then [only.as(Symbol)]
                  when Array(Symbol) then only.as(Array(Symbol)).dup
                  else                    [] of Symbol
                  end
      except_list = case except
                    when Symbol        then [except.as(Symbol)]
                    when Array(Symbol) then except.as(Array(Symbol)).dup
                    else                    [] of Symbol
                    end
      key = "#{kind}:#{klass}:#{name}"
      (SKIP_FILTERS[key] ||= [] of Tuple(Array(Symbol), Array(Symbol))) << {only_list, except_list}
    end

    def self.skip_match?(klass : String, kind : Symbol, name : Symbol, action : Symbol) : Bool
      entries = SKIP_FILTERS["#{kind}:#{klass}:#{name}"]?
      return false unless entries
      entries.any? do |(only, except)|
        filter_applies?(only.empty? ? nil : only, except.empty? ? nil : except, action)
      end
    end

    # Registers a before filter. Chained onto the class's own filter chain
    # via `previous_def` (same-type chaining). The filter method itself may
    # be private, like in Rails. A filter that renders or redirects halts
    # the remaining filters of the same controller too (Rails semantics).
    macro before_action(name, only = nil, except = nil)
      def __saci_chain_for_{{@type.name.stringify.gsub(/::/, "_").id}}(action_name : Symbol) : Nil
        previous_def
        return if performed?
        if Saci::Controller.filter_applies?({{only}}, {{except}}, action_name) && !__saci_own_skip?(:before, {{name}}, action_name)
          {{name.id}}
        end
      end
    end

    # Runs after the action (and after any `rescue_from` handler), even when
    # a before filter halted the chain — Rails `after_action` equivalent.
    # Parent filters run *after* child filters (Rails reverse order).
    # Symbol form (`after_action :touch`) or block form, both honoring
    # `only:`/`except:`:
    #
    # ```
    # after_action :clear_session_cookie
    # after_action only: [:create, :update] do
    #   @story.touch
    # end
    # ```
    macro after_action(name = nil, only = nil, except = nil, &block)
      def __saci_after_for_{{@type.name.stringify.gsub(/::/, "_").id}}(action_name : Symbol) : Nil
        previous_def
        {% if name %}
          if Saci::Controller.filter_applies?({{only}}, {{except}}, action_name) && !__saci_own_skip?(:after, {{name}}, action_name)
            {{name.id}}
          end
        {% elsif block %}
          if Saci::Controller.filter_applies?({{only}}, {{except}}, action_name)
            {{block.body}}
          end
        {% end %}
      end
    end

    # Suppresses an inherited filter for this controller (Rails
    # `skip_before_action` / `skip_after_action`, with `only:`/`except:`).
    macro skip_before_action(name, only = nil, except = nil)
      Saci::Controller.register_skip(:before, {{@type.name.stringify}}, {{name}}, {{only}}, {{except}})
    end

    macro skip_after_action(name, only = nil, except = nil)
      Saci::Controller.register_skip(:after, {{@type.name.stringify}}, {{name}}, {{only}}, {{except}})
    end

    # Catches exceptions raised by filters/actions in this controller (and
    # subclasses — child handlers run first). The block runs in controller
    # context, so `render`/`redirect_to` work; claiming the exception skips
    # the router's default error page:
    #
    # ```
    # rescue_from Saci::Record::RecordNotFound do
    #   render json: {error: "not found"}, status: :not_found
    # end
    # rescue_from ArgumentError do |ex|
    #   render plain: "bad: #{ex.message}", status: :bad_request
    # end
    # ```
    macro rescue_from(*excs, &block)
      def __saci_rescue_for_{{@type.name.stringify.gsub(/::/, "_").id}}(__saci_exc : Exception) : Bool
        {% if block %}
          {% if block.args.size > 0 %}
            {% for e in excs %}
              if __saci_exc.is_a?({{e}})
                {{block.args[0].id}} = __saci_exc.as({{e}})
                {{block.body}}
                return true
              end
            {% end %}
          {% else %}
            {% for e in excs %}
              if __saci_exc.is_a?({{e}})
                {{block.body}}
                return true
              end
            {% end %}
          {% end %}
        {% end %}
        previous_def
      end
    end

    # Rails `protect_from_forgery` (double-submit-cookie CSRF defense,
    # `with: :exception` strategy — the Rails default).
    # Safe methods (GET/HEAD/OPTIONS/TRACE) ensure the cookie exists and
    # pass; state-changing requests must echo the token back via the
    # `authenticity_token` param or `X-CSRF-Token` header, else
    # `InvalidAuthenticityToken` is raised (rendered as 422).
    #
    # ```
    # class ApplicationController < Saci::Controller
    #   protect_from_forgery
    # end
    # ```
    macro protect_from_forgery(only = nil, except = nil)
      before_action :verify_authenticity_token, only: {{only}}, except: {{except}}
    end

    macro inherited
      def __saci_chain_for_{{@type.name.stringify.gsub(/::/, "_").id}}(action_name : Symbol) : Nil
      end

      def __saci_after_for_{{@type.name.stringify.gsub(/::/, "_").id}}(action_name : Symbol) : Nil
      end

      def __saci_rescue_for_{{@type.name.stringify.gsub(/::/, "_").id}}(__saci_exc : Exception) : Bool
        false
      end

      def run_before_filters(action_name : Symbol) : Bool
        super
        return false if performed?
        __saci_chain_for_{{@type.name.stringify.gsub(/::/, "_").id}}(action_name)
        !performed?
      end

      def run_after_filters(action_name : Symbol) : Nil
        __saci_after_for_{{@type.name.stringify.gsub(/::/, "_").id}}(action_name)
        super
      end

      # Virtual skip check: the most-derived override wins (so a child's
      # `skip_after_action` suppresses a parent-declared filter), then walks
      # up via `super`.
      def __saci_own_skip?(kind : Symbol, name : Symbol, action_name : Symbol) : Bool
        super || Saci::Controller.skip_match?({{@type.name.stringify}}, kind, name, action_name)
      end

      # Child handlers first, then `super` (parent handlers).
      def run_rescue(__saci_exc : Exception) : Bool
        __saci_rescue_for_{{@type.name.stringify.gsub(/::/, "_").id}}(__saci_exc) || super
      end

      def call_action(name : Symbol) : Nil
        {% verbatim do %}
          {% begin %}
            case name
            {% t = @type %}
            {% emitted = [] of String %}
            {% for i in 0..10 %}
              {% if t && t.name != "Saci::Controller" %}
                {% for m in t.methods %}
                  {% if m.args.empty? && m.visibility == :public && !emitted.includes?(m.name.stringify) && ![:initialize, :call_action, :run_before_filters, :run_after_filters, :run_rescue, :__saci_own_skip?, :respond_to, :request_format, :performed?, :context, :params, :action_name, :request, :response, :filter_applies?, :register_skip, :skip_match?, :status_code_for, :verify_authenticity_token, :form_authenticity_token, :content, :stale?, :fresh_when].includes?(m.name.symbolize) %}
            when {{m.name.symbolize}}
              {{m.name.id}}
              nil
                    {% emitted << m.name.stringify %}
                  {% end %}
                {% end %}
                {% t = t.superclass %}
              {% end %}
            {% end %}
            else
              raise Saci::ActionNotFound.new("Unknown action #{self.class}##{name}")
            end
          {% end %}
        {% end %}
      end
    end

    # Base implementations (used when a controller defines no filters or
    # when dispatch reaches Saci::Controller itself).
    def run_before_filters(_action : Symbol) : Bool
      true
    end

    def run_after_filters(_action : Symbol) : Nil
    end

    def run_rescue(_exc : Exception) : Bool
      false
    end

    def __saci_own_skip?(_kind : Symbol, _name : Symbol, _action : Symbol) : Bool
      false
    end

    def call_action(name : Symbol) : Nil
      raise Saci::ActionNotFound.new("Unknown action #{self.class}##{name}")
    end

    # Content negotiation (Rails `respond_to` equivalent). The request format
    # comes from `params["format"]` (`.json` URLs, `?format=rss`) or the
    # `Accept` header; raises `UnknownFormat` (router renders 406) when no
    # handler matches and no `any` fallback was given.
    def respond_to(& : Responder ->) : Nil
      responder = Responder.new
      yield responder
      format = request_format
      unless responder.run(format)
        raise UnknownFormat.new("No response for format #{format}")
      end
    end

    # `:html`, `:json`, `:rss`, `:xml`, `:text`, or `:unknown`.
    def request_format : Symbol
      if f = params["format"]?
        case f.downcase
        when "json"         then return :json
        when "rss"          then return :rss
        when "xml"          then return :xml
        when "html", "htm"  then return :html
        when "text", "txt"  then return :text
        else                     return :unknown
        end
      end
      accept = request.headers["Accept"]? || ""
      if accept.includes?("application/rss+xml")
        :rss
      elsif accept.includes?("application/json")
        :json
      elsif accept.includes?("application/xml") || accept.includes?("text/xml")
        :xml
      elsif accept.includes?("text/html")
        :html
      elsif accept.includes?("text/plain")
        :text
      elsif accept.empty? || accept.includes?("*/*")
        :html
      else
        :unknown
      end
    end

    # -- rendering ---------------------------------------------------------

    # Rails-style keyword API:
    #   render json: {...}, status: :created
    #   render html: "<h1>hi</h1>"
    #   render text: "ok"
    #   render plain: "ok"
    #   render xml: "<rss/>"          # `application/xml`
    # `content_type:` overrides the default for the chosen body type.
    def render(*, json : Object? = nil, html : String? = nil, text : String? = nil, plain : String? = nil, xml : String? = nil, status : Int32 | Symbol = 200, content_type : String? = nil) : Nil
      code = normalize_status(status)
      if !json.nil?
        respond(plain: json.to_json, content_type: content_type || "application/json; charset=utf-8", status: code)
      elsif h = html
        respond(plain: h, content_type: content_type || "text/html; charset=utf-8", status: code)
      elsif x = xml
        respond(plain: x, content_type: content_type || "application/xml; charset=utf-8", status: code)
      elsif t = text
        respond(plain: t, content_type: content_type || "text/plain; charset=utf-8", status: code)
      elsif p = plain
        respond(plain: p, content_type: content_type || "text/plain; charset=utf-8", status: code)
      else
        respond(plain: "", status: code)
      end
    end

    def redirect_to(location : String, status : Int32 | Symbol = 302) : Nil
      response.status_code = normalize_status(status)
      response.headers["Location"] = location
      response.content_type = "text/plain"
      response.print("Redirecting to #{location}")
      @performed = true
    end

    def head(status : Int32 | Symbol) : Nil
      response.status_code = normalize_status(status)
      @performed = true
    end

    # -- security helpers ------------------------------------------------------

    def cookies : CookieJar
      @cookies ||= CookieJar.new(request, response)
    end

    def session : Session
      @session ||= Session.new(cookies)
    end

    def flash : Flash
      @flash ||= Flash.new(session)
    end

    # Clears the session (session-fixation defense) — call on login.
    def reset_session : Nil
      session.clear
      @flash.try(&.clear)
    end

    def session_used? : Bool
      !@session.nil?
    end

    def flash_used? : Bool
      !@flash.nil?
    end

    def persist_session! : Nil
      flash.commit! if flash_used?
      session.commit! if session_used?
    end

    # The CSRF token for this client (sets the cookie when absent). Embed
    # it in forms as `authenticity_token` or send it as `X-CSRF-Token`.
    def form_authenticity_token : String
      if existing = CSRF.cookie_token(request)
        existing
      else
        token = CSRF.generate_token
        CSRF.set_cookie(response, token)
        token
      end
    end

    # HTML-escapes `text` for safe interpolation into `render html:`.
    def h(text : Object) : String
      HTML.escape(text.to_s)
    end

    private def verify_authenticity_token : Nil
      if CSRF.safe_method?(request.method)
        form_authenticity_token
        return
      end
      unless CSRF.verified?(request, params)
        raise InvalidAuthenticityToken.new
      end
    end

    # Localization shortcut using the current request locale
    # (`Saci::I18n.locale` — set it in a `before_action`, e.g. from
    # `params["locale"]` via `Saci::I18n.parse_locale`).
    def t(key : String | Symbol, locale : I18n::Locale? = nil, count : Int32 | Int64 | Float64 | Nil = nil, default : String? = nil, **values) : String
      I18n.t(key, **values, locale: locale, count: count, default: default)
    end

    private def respond(*, plain : String, content_type : String = "text/plain", status : Int32 = 200) : Nil
      response.status_code = status
      response.content_type = content_type
      response.print(plain)
      @performed = true
    end

    private def normalize_status(status : Int32 | Symbol) : Int32
      case status
      when Int32  then status.as(Int32)
      when Symbol then self.class.status_code_for(status.as(Symbol))
      else             200
      end
    end

    def self.status_code_for(sym : Symbol) : Int32
      case sym
      when :ok                    then 200
      when :created               then 201
      when :accepted              then 202
      when :no_content            then 204
      when :moved_permanently     then 301
      when :found                 then 302
      when :see_other             then 303
      when :not_modified          then 304
      when :bad_request           then 400
      when :unauthorized          then 401
      when :forbidden             then 403
      when :not_found             then 404
      when :method_not_allowed    then 405
      when :conflict              then 409
      when :gone                  then 410
      when :unprocessable_entity  then 422
      when :unprocessable_content then 422
      when :too_many_requests     then 429
      when :internal_server_error then 500
      when :service_unavailable   then 503
      else                             200
      end
    end
  end
end
