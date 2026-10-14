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
  # * Avoid public zero-argument `&block` methods in controllers: they cannot
  #   be called without a block, which breaks dispatcher codegen.
  # * Avoid public zero-argument `def self.x` methods; they may confuse the
  #   dispatcher. Regular `def self.x` helpers *with* parameters are fine.
  class Controller
    alias FilterTarget = Symbol | Array(Symbol) | Nil

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

    # Registers a before filter. Chained onto the class's own filter chain
    # via `previous_def` (same-type chaining). The filter method itself may
    # be private, like in Rails.
    macro before_action(name, only = nil, except = nil)
      def __saci_chain_for_{{@type.name.stringify.gsub(/::/, "_").id}}(action_name : Symbol) : Nil
        previous_def
        if Saci::Controller.filter_applies?({{only}}, {{except}}, action_name)
          {{name.id}}
        end
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

      def run_before_filters(action_name : Symbol) : Bool
        super
        return false if performed?
        __saci_chain_for_{{@type.name.stringify.gsub(/::/, "_").id}}(action_name)
        !performed?
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
                  {% if m.args.empty? && m.visibility == :public && !emitted.includes?(m.name.stringify) && ![:initialize, :call_action, :run_before_filters, :performed?, :context, :params, :action_name, :request, :response, :filter_applies?, :status_code_for, :verify_authenticity_token, :form_authenticity_token, :content, :stale?, :fresh_when].includes?(m.name.symbolize) %}
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

    def call_action(name : Symbol) : Nil
      raise Saci::ActionNotFound.new("Unknown action #{self.class}##{name}")
    end

    # -- rendering ---------------------------------------------------------

    # Rails-style keyword API:
    #   render json: {...}, status: :created
    #   render html: "<h1>hi</h1>"
    #   render text: "ok"
    #   render plain: "ok"
    def render(*, json : Object? = nil, html : String? = nil, text : String? = nil, plain : String? = nil, status : Int32 | Symbol = 200) : Nil
      code = normalize_status(status)
      if !json.nil?
        respond(plain: json.to_json, content_type: "application/json; charset=utf-8", status: code)
      elsif h = html
        respond(plain: h, content_type: "text/html; charset=utf-8", status: code)
      elsif t = text
        respond(plain: t, content_type: "text/plain; charset=utf-8", status: code)
      elsif p = plain
        respond(plain: p, content_type: "text/plain; charset=utf-8", status: code)
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
      when :unprocessable_entity  then 422
      when :internal_server_error then 500
      else                             200
      end
    end
  end
end
