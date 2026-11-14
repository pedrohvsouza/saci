module Saci
  module Mailer
    # A before/after callback entry. `action_name` filtering happens at run
    # time because class-method mailers infer the action from the call stack
    # (or receive it from a parameterized proxy).
    struct Callback
      getter name : String
      getter proc : Proc(Context, Nil)
      getter only : Array(String)
      getter except : Array(String)

      def initialize(@name : String, @proc : Proc(Context, Nil),
                     @only : Array(String) = [] of String,
                     @except : Array(String) = [] of String)
      end

      def applies?(action : String?) : Bool
        name = action || ""
        (only.empty? || only.includes?(name)) && !except.includes?(name)
      end
    end

    # Around callbacks receive the next step as a Proc (typically the action
    # plus remaining around callbacks).
    struct AroundCallback
      getter name : String
      getter proc : Proc(Context, Proc(Mail), Mail)
      getter only : Array(String)
      getter except : Array(String)

      def initialize(@name : String, @proc : Proc(Context, Proc(Mail), Mail),
                     @only : Array(String) = [] of String,
                     @except : Array(String) = [] of String)
      end

      def applies?(action : String?) : Bool
        name = action || ""
        (only.empty? || only.includes?(name)) && !except.includes?(name)
      end
    end

    struct RescueHandler
      getter name : String
      getter matcher : Proc(Exception, Bool)
      getter handler : Proc(Exception, Mail?)

      def initialize(@name : String, @matcher : Proc(Exception, Bool), @handler : Proc(Exception, Mail?))
      end
    end

    class Base
      # Saci mailers are class methods (`def self.welcome`), so callbacks wrap
      # the `mail` build rather than a Rails-style instance dispatch. That
      # covers normal actions (whose body is the `mail` call) and keeps the
      # existing class-method API; a raise before `mail` is reached is outside
      # the callback chain.
      #
      # -- callback registries (overridden by the macros below) ----------------
      def self.__saci_before_callbacks : Array(Callback)
        [] of Callback
      end

      def self.__saci_after_callbacks : Array(Callback)
        [] of Callback
      end

      def self.__saci_around_callbacks : Array(AroundCallback)
        [] of AroundCallback
      end

      def self.__saci_rescue_handlers : Array(RescueHandler)
        [] of RescueHandler
      end

      # Registers a callback run before the mail is constructed. Callback
      # methods are class methods; they can mutate the draft through
      # `headers[...]` / `attachments[...]` and read `params`.
      #
      # ```
      # class UserMailer < Saci::Mailer::Base
      #   before_action :set_tenant, only: :welcome
      #
      #   def self.set_tenant
      #     headers["X-Tenant"] = params["tenant"].as_s
      #   end
      # end
      # ```
      macro before_action(*names, only = nil, except = nil)
        {% first = !@type.constants.map(&.stringify).includes?("SACI_BEFORE_ACTION_HOOK") %}
        {% if first %}
          SACI_BEFORE_ACTION_HOOK = true
        {% end %}
        {% only_list = [] of String %}
        {% except_list = [] of String %}
        {% if only.is_a?(ArrayLiteral) %}
          {% for item in only %}
            {% only_list << item.id.stringify %}
          {% end %}
        {% elsif only.is_a?(SymbolLiteral) %}
          {% only_list << only.id.stringify %}
        {% elsif only.is_a?(StringLiteral) %}
          {% only_list << only.string %}
        {% end %}
        {% if except.is_a?(ArrayLiteral) %}
          {% for item in except %}
            {% except_list << item.id.stringify %}
          {% end %}
        {% elsif except.is_a?(SymbolLiteral) %}
          {% except_list << except.id.stringify %}
        {% elsif except.is_a?(StringLiteral) %}
          {% except_list << except.string %}
        {% end %}

        def self.__saci_before_callbacks : Array(Saci::Mailer::Callback)
          {% if first %}
            super + [
          {% else %}
            previous_def + [
          {% end %}
            {% for name in names %}
              Saci::Mailer::Callback.new(
                "{{name.id}}",
                ->(ctx : Saci::Mailer::Context) { self.{{name.id}} },
                ({{only_list}} of String),
                ({{except_list}} of String)
              ),
            {% end %}
          ]
        end
      end

      # Registers a callback run after the mail is constructed. The resulting
      # mail is available as `current_mail` while the callback runs.
      macro after_action(*names, only = nil, except = nil)
        {% first = !@type.constants.map(&.stringify).includes?("SACI_AFTER_ACTION_HOOK") %}
        {% if first %}
          SACI_AFTER_ACTION_HOOK = true
        {% end %}
        {% only_list = [] of String %}
        {% except_list = [] of String %}
        {% if only.is_a?(ArrayLiteral) %}
          {% for item in only %}
            {% only_list << item.id.stringify %}
          {% end %}
        {% elsif only.is_a?(SymbolLiteral) %}
          {% only_list << only.id.stringify %}
        {% elsif only.is_a?(StringLiteral) %}
          {% only_list << only.string %}
        {% end %}
        {% if except.is_a?(ArrayLiteral) %}
          {% for item in except %}
            {% except_list << item.id.stringify %}
          {% end %}
        {% elsif except.is_a?(SymbolLiteral) %}
          {% except_list << except.id.stringify %}
        {% elsif except.is_a?(StringLiteral) %}
          {% except_list << except.string %}
        {% end %}

        def self.__saci_after_callbacks : Array(Saci::Mailer::Callback)
          {% if first %}
            super + [
          {% else %}
            previous_def + [
          {% end %}
            {% for name in names %}
              Saci::Mailer::Callback.new(
                "{{name.id}}",
                ->(ctx : Saci::Mailer::Context) { self.{{name.id}} },
                ({{only_list}} of String),
                ({{except_list}} of String)
              ),
            {% end %}
          ]
        end
      end

      # Registers an around callback. The callback method must accept a block
      # returning `Saci::Mailer::Mail` and return that mail (possibly modified):
      #
      # ```
      # around_action :timed, only: :welcome
      #
      # def self.timed(&block : -> Saci::Mailer::Mail) : Saci::Mailer::Mail
      #   start = Time.instant
      #   mail = yield
      #   headers["X-Duration"] = (Time.instant - start).total_milliseconds.to_s
      #   mail
      # end
      # ```
      macro around_action(*names, only = nil, except = nil)
        {% first = !@type.constants.map(&.stringify).includes?("SACI_AROUND_ACTION_HOOK") %}
        {% if first %}
          SACI_AROUND_ACTION_HOOK = true
        {% end %}
        {% only_list = [] of String %}
        {% except_list = [] of String %}
        {% if only.is_a?(ArrayLiteral) %}
          {% for item in only %}
            {% only_list << item.id.stringify %}
          {% end %}
        {% elsif only.is_a?(SymbolLiteral) %}
          {% only_list << only.id.stringify %}
        {% elsif only.is_a?(StringLiteral) %}
          {% only_list << only.string %}
        {% end %}
        {% if except.is_a?(ArrayLiteral) %}
          {% for item in except %}
            {% except_list << item.id.stringify %}
          {% end %}
        {% elsif except.is_a?(SymbolLiteral) %}
          {% except_list << except.id.stringify %}
        {% elsif except.is_a?(StringLiteral) %}
          {% except_list << except.string %}
        {% end %}

        def self.__saci_around_callbacks : Array(Saci::Mailer::AroundCallback)
          {% if first %}
            super + [
          {% else %}
            previous_def + [
          {% end %}
            {% for name in names %}
              Saci::Mailer::AroundCallback.new(
                "{{name.id}}",
                ->(ctx : Saci::Mailer::Context, nxt : Proc(Saci::Mailer::Mail)) {
                  self.{{name.id}} { nxt.call }
                },
                ({{only_list}} of String),
                ({{except_list}} of String)
              ),
            {% end %}
          ]
        end
      end

      # Handles an exception raised while running an action. The handler
      # receives the exception and must return a fallback `Mail` (or nil to
      # let the exception propagate). Handlers are matched last-registered
      # first, like Rails.
      macro rescue_from(error, **opts)
        {% first = !@type.constants.map(&.stringify).includes?("SACI_RESCUE_FROM_HOOK") %}
        {% if first %}
          SACI_RESCUE_FROM_HOOK = true
        {% end %}
        {% handler = opts[:with] %}
        {% if handler.is_a?(NilLiteral) %}
          {% raise "rescue_from requires with: :handler" %}
        {% end %}
        def self.__saci_rescue_handlers : Array(Saci::Mailer::RescueHandler)
          {% if first %}
            super + [
          {% else %}
            previous_def + [
          {% end %}
            Saci::Mailer::RescueHandler.new(
              "{{handler.id}}",
              ->(ex : Exception) { ex.is_a?({{error}}) },
              ->(ex : Exception) : Saci::Mailer::Mail? { self.{{handler.id}}(ex.as({{error}})) }
            ),
          ]
        end
      end

      # Runs callbacks around the mail build. If `rescue_from` produced a
      # fallback mail it is returned as-is (after callbacks are not run for
      # rescued actions, matching Rails' process_action semantics closely
      # enough for mailers).
      def self.__saci_run_callbacks(ctx : Context, &build : -> Mail) : Mail
        begin
          __saci_before_callbacks.each do |callback|
            callback.proc.call(ctx) if callback.applies?(ctx.action)
          end

          chain : Proc(Mail) = build
          __saci_around_callbacks.reverse_each do |callback|
            if callback.applies?(ctx.action)
              previous = chain
              chain = -> { callback.proc.call(ctx, previous) }
            end
          end
          mail = chain.call
          ctx.mail = mail

          __saci_after_callbacks.each do |callback|
            callback.proc.call(ctx) if callback.applies?(ctx.action)
          end
          mail
        rescue ex
          __saci_rescue_handlers.reverse_each do |handler|
            next unless handler.matcher.call(ex)
            result = handler.handler.call(ex)
            if result
              ctx.mail = result
              return result
            end
            break
          end
          raise ex
        end
      end
    end
  end
end
