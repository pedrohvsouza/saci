require "random/secure"

# Per-request data that has no place in the framework's own classes. Crystal
# unifies instance variables across reopenings, so this adds a private slot to
# the stdlib response without changing its public API.
class HTTP::Server::Response
  @saci_csp_nonce : String? = nil

  def saci_csp_nonce : String?
    @saci_csp_nonce
  end

  def saci_csp_nonce=(value : String?) : Nil
    @saci_csp_nonce = value
  end
end

module Saci
  module SecureHeaders
    CSP_HEADER                = "Content-Security-Policy"
    CSP_NONCE_PLACEHOLDER     = "'nonce'"
    CSP_NONCE_PLACEHOLDER_ALT = "{{nonce}}"

    # Returns the response's nonce, generating one lazily. Same nonce for
    # every helper in a request; a new response gets a new nonce.
    def self.nonce_for(response : HTTP::Server::Response) : String
      if nonce = response.saci_csp_nonce
        nonce
      else
        nonce = Random::Secure.urlsafe_base64(16)
        response.saci_csp_nonce = nonce
        nonce
      end
    end

    # Rails `content_security_policy_nonce` equivalent.
    def self.content_security_policy_nonce(response : HTTP::Server::Response) : String
      nonce_for(response)
    end

    def self.nonce?(response : HTTP::Server::Response) : Bool
      !response.saci_csp_nonce.nil?
    end

    # Replaces `'nonce'` / `{{nonce}}` placeholders with a single-quoted
    # nonce source. Policies without a placeholder are returned untouched
    # (static `csp`/`skip_csp` behavior is preserved) and no nonce is
    # generated.
    def self.interpolate_csp_nonce(policy : String, response : HTTP::Server::Response) : String
      return policy unless policy.includes?(CSP_NONCE_PLACEHOLDER) || policy.includes?(CSP_NONCE_PLACEHOLDER_ALT)
      nonce = nonce_for(response)
      policy
        .gsub(CSP_NONCE_PLACEHOLDER, "'nonce-#{nonce}'")
        .gsub(CSP_NONCE_PLACEHOLDER_ALT, nonce)
    end

    # Sets a CSP header, interpolating a nonce if the policy asks for one.
    def self.set_csp_header(response : HTTP::Server::Response, policy : String) : Nil
      response.headers[CSP_HEADER] = interpolate_csp_nonce(policy, response)
    end

    # Builds a semicolon-separated directive string and sets it with nonce
    # interpolation (per-response directive overrides).
    def self.set_csp_directives(response : HTTP::Server::Response, directives : Hash(String, String)) : Nil
      policy = directives.map { |directive, sources| "#{directive} #{sources}" }.join("; ")
      set_csp_header(response, policy)
    end

    # `<meta name="csp-nonce" content="...">` for view layouts (Rails
    # `csp_meta_tag`). Uses the same nonce as the CSP header.
    def self.csp_meta_tag(response : HTTP::Server::Response, name : String = "csp-nonce") : String
      %(<meta name="#{name}" content="#{nonce_for(response)}">)
    end
  end

  class Controller
    # Nonce for this request (generated on first use and cached on the
    # response). Also available in views, where it is typically used with
    # `csp_meta_tag`.
    def content_security_policy_nonce : String
      SecureHeaders.nonce_for(response)
    end

    def csp_nonce : String
      content_security_policy_nonce
    end

    # Sets a per-request CSP, interpolating `'nonce'` if present:
    #
    # ```
    # before_action :set_csp
    #
    # private def set_csp
    #   content_security_policy("default-src 'self'; script-src 'self' 'nonce'")
    # end
    # ```
    def content_security_policy(policy : String) : Nil
      SecureHeaders.set_csp_header(response, policy)
    end

    # Directive-hash form of `content_security_policy` (insertion order):
    #
    # ```
    # content_security_policy({
    #   "default-src" => "'self'",
    #   "script-src"  => "'self' 'nonce'",
    # })
    # ```
    def content_security_policy(directives : Hash(String, String)) : Nil
      SecureHeaders.set_csp_directives(response, directives)
    end

    def csp_meta_tag(name : String = "csp-nonce") : String
      SecureHeaders.csp_meta_tag(response, name)
    end

    # Per-response Permissions-Policy override. Features not listed keep the
    # globally configured allowlist.
    def permissions_policy(policy : Hash(String, Array(String))) : Nil
      SecureHeaders.apply_permissions_policy(response, policy)
    end
  end
end
