require "json"
require "./record"

module Saci
  # Fiber-local authorization context (current user + role names).
  module Authorization
    # Raised by `Policy#authorize!` (and `Controller#authorize!`).
    class NotAuthorizedError < Exception
      getter action : String
      getter resource : String?

      def initialize(@action : String, @resource : String? = nil)
        super("Not authorized to #{@action} #{@resource || "resource"}")
      end
    end

    # No policy was registered for a resource class.
    class PolicyNotFoundError < Exception
    end

    class Context
      property user : Saci::Record::Base?
      property roles : Set(String)

      def initialize(@user : Saci::Record::Base? = nil, @roles : Set(String) = Set(String).new)
      end
    end

    alias PolicyFactory = Proc(Saci::Record::Base?, Set(String), Saci::Policy)

    @@contexts = {} of UInt64 => Context
    @@context_mutex = Mutex.new
    @@factories = {} of String => PolicyFactory
    @@factories_mutex = Mutex.new

    def self.context : Context
      key = Fiber.current.object_id
      @@context_mutex.synchronize { @@contexts[key] ||= Context.new }
    end

    def self.current_user : Saci::Record::Base?
      context.user
    end

    def self.current_user=(user : Saci::Record::Base?) : Nil
      context.user = user
    end

    def self.current_roles : Set(String)
      context.roles.dup
    end

    # Accepts symbols or strings; stored as strings so policy declarations
    # (`role :admin`) and runtime roles (`["admin"]`) compare consistently.
    def self.current_roles=(roles) : Nil
      context.roles = role_set(roles)
    end

    def self.role_set(roles) : Set(String)
      roles.map(&.to_s).to_set
    end

    # Scoped context; restores the previous values even when the block
    # raises. Omitted values inherit the current context (use
    # `clear_context!` for a clean slate).
    def self.with_context(
      *,
      user : Saci::Record::Base? = current_user,
      roles = nil,
      &block : -> T
    ) : T forall T
      ctx = context
      previous_user = ctx.user
      previous_roles = ctx.roles
      ctx.user = user
      ctx.roles = role_set(roles) if roles
      begin
        yield
      ensure
        ctx.user = previous_user
        ctx.roles = previous_roles
      end
    end

    def self.with_roles(roles, &block : -> T) : T forall T
      with_context(roles: roles) { yield }
    end

    def self.with_user(user : Saci::Record::Base?, &block : -> T) : T forall T
      with_context(user: user) { yield }
    end

    def self.clear_context! : Nil
      key = Fiber.current.object_id
      @@context_mutex.synchronize { @@contexts.delete(key) }
    end

    # -- policy registry --------------------------------------------------

    # Registers a policy factory for a model class. The `resource` macro on
    # a policy expands to this call, so most applications never call it
    # directly.
    def self.register(
      klass : Saci::Record::Base.class,
      &factory : Saci::Record::Base?, Set(String) -> Saci::Policy
    ) : Nil
      @@factories_mutex.synchronize { @@factories[klass.name] = factory }
    end

    def self.registered?(klass : Saci::Record::Base.class) : Bool
      @@factories_mutex.synchronize { @@factories.has_key?(klass.name) }
    end

    def self.policy_for(
      resource : Saci::Record::Base,
      user : Saci::Record::Base? = current_user,
      roles : Set(String) = current_roles,
    ) : Saci::Policy
      policy_for_name(resource.class.name, user, roles)
    end

    def self.policy_for(
      resource : Saci::Record::Base.class,
      user : Saci::Record::Base? = current_user,
      roles : Set(String) = current_roles,
    ) : Saci::Policy
      policy_for_name(resource.name, user, roles)
    end

    def self.policy_for(
      resource : String,
      user : Saci::Record::Base? = current_user,
      roles : Set(String) = current_roles,
    ) : Saci::Policy
      policy_for_name(resource, user, roles)
    end

    def self.policy_for_name(
      name : String,
      user : Saci::Record::Base? = current_user,
      roles : Set(String) = current_roles,
    ) : Saci::Policy
      factory = @@factories_mutex.synchronize { @@factories[name]? }
      unless factory
        raise PolicyNotFoundError.new(
          "No authorization policy registered for #{name}. " \
          "Add `resource #{name}` to the policy class or call Saci::Authorization.register(#{name}) { ... }."
        )
      end
      factory.call(user, roles)
    end
  end

  # Base policy class. Associate it with a model through `resource Post`;
  # scopes override `resolve(scope)`. Policies are non-generic so the same
  # class name can be used as the base for every resource (Crystal has no
  # "generic and non-generic class with the same name").
  class Policy
    class Rule
      getter action : String
      getter resource : String

      def initialize(@action : String, @resource : String)
      end

      def matches?(action : String, resource : String) : Bool
        action_ok = @action == "*" || @action == "manage" || @action == action
        resource_ok = @resource == "*" || (resource != "*" && @resource == resource)
        action_ok && resource_ok
      end
    end

    class Role
      getter name : String
      getter rules : Array(Rule)

      def initialize(@name : String, @rules : Array(Rule) = [] of Rule)
      end
    end

    getter user : Saci::Record::Base?
    getter roles : Set(String)
    getter resource : Saci::Record::Base?

    def initialize(
      *,
      user : Saci::Record::Base? = Saci::Authorization.current_user,
      roles = nil,
      resource : Saci::Record::Base? = nil,
    )
      @user = user
      @roles = roles ? Saci::Authorization.role_set(roles) : Saci::Authorization.current_roles
      @resource = resource
    end

    def role?(name : String | Symbol) : Bool
      @roles.includes?(name.to_s)
    end

    # `resource` may be a model instance, a model class, a class-name
    # string, `:all`, or nil (meaning "this policy's resource").
    def can?(
      action : Symbol | String,
      resource : Symbol | String | Saci::Record::Base | Saci::Record::Base.class | Nil = nil,
    ) : Bool
      requested_action = action.to_s
      requested_resource = normalize_resource(resource)

      allowed = self.class.__saci_policy_allowed
      return true if allowed.includes?(requested_action) || allowed.includes?("manage")

      self.class.__saci_policy_roles.each do |role|
        next unless @roles.includes?(role.name)
        role.rules.each do |rule|
          return true if rule.matches?(requested_action, requested_resource)
        end
      end
      false
    end

    def authorize!(
      action : Symbol | String,
      resource : Symbol | String | Saci::Record::Base | Saci::Record::Base.class | Nil = nil,
    ) : Bool
      return true if can?(action, resource)
      raise Authorization::NotAuthorizedError.new(action.to_s, normalize_resource(resource))
    end

    # Row-level scope. Override via the `scope do ... end` macro; the base
    # implementation is intentionally a no-op.
    def resolve(scope : Saci::Record::Query(T)) : Saci::Record::Query(T) forall T
      scope
    end

    def resource_name : String
      self.class.__saci_policy_resource || "*"
    end

    private def normalize_resource(
      resource : Symbol | String | Saci::Record::Base | Saci::Record::Base.class | Nil,
    ) : String
      case resource
      when Nil
        resource_name
      when Symbol
        resource.to_s == "all" ? "*" : resource.to_s
      when String
        resource == "all" ? "*" : resource
      when Saci::Record::Base
        resource.class.name
      else
        resource.name
      end
    end

    # -- compile-time DSL ------------------------------------------------

    macro allow(*actions)
      def self.__saci_policy_allowed : Array(String)
        previous_def + [
          {% for action in actions %}
            {{action.id.stringify}},
          {% end %}
        ]
      end
    end

    macro role(name, &block)
      {% rules = [] of Nil %}
      {% body = block.body %}
      {% expressions = body.is_a?(Expressions) ? body.expressions : [body] %}
      {% for expression in expressions %}
        {% if expression.is_a?(Call) && expression.name == "can" %}
          {% if expression.args.size != 2 %}
            {% raise "role can expects `can :action, :resource` (got #{expression.args.size} arguments)" %}
          {% end %}
          {% action_arg = expression.args[0] %}
          {% if action_arg.is_a?(SymbolLiteral) %}
            {% action_name = action_arg.id.stringify %}
          {% elsif action_arg.is_a?(StringLiteral) %}
            {% action_name = action_arg %}
          {% else %}
            {% raise "role can action must be a symbol or string" %}
          {% end %}
          {% resource_arg = expression.args[1] %}
          {% if resource_arg.is_a?(SymbolLiteral) %}
            {% resource_name = resource_arg.id.stringify == "all" ? "*" : resource_arg.id.stringify %}
          {% elsif resource_arg.is_a?(StringLiteral) %}
            {% resource_name = resource_arg == "all" ? "*" : resource_arg %}
          {% else %}
            {% resource_name = resource_arg.stringify %}
          {% end %}
          {% rules << {action_name, resource_name} %}
        {% else %}
          {% raise "role block only supports `can :action, :resource` calls" %}
        {% end %}
      {% end %}

      def self.__saci_policy_roles : Array(Saci::Policy::Role)
        previous_def + [
          Saci::Policy::Role.new({{name.id.stringify}}, [
            {% for rule in rules %}
              Saci::Policy::Rule.new({{rule[0]}}, {{rule[1]}}),
            {% end %}
          ]),
        ]
      end
    end

    # Replaces `resolve(scope)`. The block receives `scope`; `user` and
    # `roles` are available as policy readers.
    macro scope(&block)
      def resolve(scope)
        {{block.body}}
      end
    end

    # Associates (and registers) a policy with a model class. Expands to a
    # factory registration executed when the class body loads.
    macro resource(klass)
      def self.__saci_policy_resource : String?
        {{klass}}.name
      end

      Saci::Authorization.register({{klass}}) do |user, roles|
        {{@type}}.new(user: user, roles: roles)
      end
    end

    # Per-class stubs so the DSL macros can chain with `previous_def`
    # within the subclass (`previous_def` does not reach an inherited
    # definition directly); `super` bridges to the parent class.
    macro inherited
      def self.__saci_policy_allowed : Array(String)
        super
      end

      def self.__saci_policy_roles : Array(Saci::Policy::Role)
        super
      end
    end

    # Class-level defaults, extended by `previous_def` in the macros above.
    def self.__saci_policy_allowed : Array(String)
      [] of String
    end

    def self.__saci_policy_roles : Array(Role)
      [] of Role
    end

    def self.__saci_policy_resource : String?
      nil
    end
  end
end
