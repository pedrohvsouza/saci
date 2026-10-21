require "./controller"
require "./policy"

module Saci
  # Controller integration for `Saci::Policy` (G306). Included into the
  # framework `Controller` by requiring this file; existing controllers get
  # `authorize!`, `can?` and `policy_scope` without changing their base class.
  module AuthorizationControllerHelpers
    # Raises `Saci::Authorization::NotAuthorizedError` unless the resource's
    # registered policy allows the action. Pass `policy:` to skip registry
    # lookup (useful for policies that are not registered with `resource`).
    def authorize!(
      action : Symbol | String,
      resource : Symbol | String | Saci::Record::Base | Saci::Record::Base.class | Nil = nil,
      policy : Saci::Policy? = nil,
    ) : Bool
      selected = policy || Saci::Authorization.policy_for(resource)
      selected.authorize!(action, resource)
    end

    def can?(
      action : Symbol | String,
      resource : Symbol | String | Saci::Record::Base | Saci::Record::Base.class | Nil = nil,
      policy : Saci::Policy? = nil,
    ) : Bool
      selected = policy || Saci::Authorization.policy_for(resource)
      selected.can?(action, resource)
    end

    # Applies the policy's `resolve` scope to a query.
    #
    # ```
    # posts = policy_scope(Post.all)
    # ```
    def policy_scope(query : Saci::Record::Query(T)) : Saci::Record::Query(T) forall T
      policy = Saci::Authorization.policy_for_name({{ T.stringify }})
      policy.resolve(query).as(Saci::Record::Query(T))
    end

    # Applies the policy's `resolve` scope to a model's full relation.
    #
    # ```
    # posts = policy_scope(Post)
    # ```
    def policy_scope(model : T.class) : Saci::Record::Query(T) forall T
      policy = Saci::Authorization.policy_for_name({{ T.stringify }})
      policy.resolve(model.all).as(Saci::Record::Query(T))
    end
  end

  class Controller
    include AuthorizationControllerHelpers
  end
end
