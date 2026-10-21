module Saci
  # Enhanced CSRF/form-token helpers. `controller.cr` keeps its historical
  # zero-argument `form_authenticity_token` (raw global token); these
  # overloads add Rails' `form_options:` API and masked/per-form tokens
  # without changing the single-token flow.
  #
  # ```
  # form_authenticity_token # raw global (legacy)
  # form_authenticity_token(form_options: {"action" => "posts#create"})
  # per_form_authenticity_token("posts#create")
  # masked_authenticity_token        # masked global
  # request_forgery_protection_token # "authenticity_token"
  # ```
  class Controller
    # Masked token scoped to `form_options["action"]` when present, else a
    # masked global token. Masked tokens are accepted by
    # `CSRF.verified?`/`verified_for?`.
    def form_authenticity_token(*, form_options : Hash(String, String)) : String
      action = form_options["action"]? || form_options["action_name"]?
      __saci_form_token_for(action)
    end

    def form_authenticity_token(*, form_options : NamedTuple) : String
      action = form_options[:action]?.try(&.to_s)
      __saci_form_token_for(action)
    end

    def form_authenticity_token(form_options : Hash(String, String)) : String
      action = form_options["action"]? || form_options["action_name"]?
      __saci_form_token_for(action)
    end

    # Per-form token bound to `action` (e.g. `"posts#create"`). The same
    # global cookie token is embedded, so no server-side storage is needed.
    def per_form_authenticity_token(action : String | Symbol) : String
      CSRF.per_form_token(form_authenticity_token, action.to_s)
    end

    # Masked global token (unmasks server-side to the cookie token).
    def masked_authenticity_token : String
      CSRF.masked_token(form_authenticity_token)
    end

    # The form parameter name (Rails' class-level
    # `request_forgery_protection_token`), for `<input name="...">`.
    def request_forgery_protection_token : String
      CSRF::PARAM_NAME
    end

    # Shared by the `form_options` overloads. Calling the zero-argument
    # method here is unambiguous; routing one overload through another
    # caused infinite recursion (Crystal treats `form_options:` as a named
    # argument for positional parameters too).
    private def __saci_form_token_for(action : String?) : String
      CSRF.form_token(form_authenticity_token, action)
    end
  end
end
