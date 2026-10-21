module Saci
  # Rails `Permissions-Policy` serialization/merging.
  #
  # ```
  # Saci::PermissionsPolicy.serialize({"camera"      => [] of String,
  #                                    "geolocation" => ["self"]})
  # # => "camera=(), geolocation=(self)"
  # ```
  #
  # Allowlists follow the structured-header syntax: `self`, `*` and origins
  # are emitted as-is (origins quoted), an empty array denies the feature.
  module PermissionsPolicy
    def self.serialize(policy : Hash(String, Array(String))) : String
      policy.map { |feature, allowlist| "#{feature}=#{serialize_allowlist(allowlist)}" }.join(", ")
    end

    def self.serialize_allowlist(allowlist : Array(String)) : String
      return "()" if allowlist.empty?
      values = allowlist.map do |value|
        case value
        when "self", "*" then value
        else                  %("#{value}")
        end
      end
      "(#{values.join(" ")})"
    end

    # Per-response overrides win feature-by-feature over the global policy.
    def self.merge(base : Hash(String, Array(String)), override : Hash(String, Array(String))) : Hash(String, Array(String))
      merged = {} of String => Array(String)
      base.each { |feature, allowlist| merged[feature] = allowlist.dup }
      override.each { |feature, allowlist| merged[feature] = allowlist.dup }
      merged
    end
  end

  module SecureHeaders
    @@permissions_policy = {} of String => Array(String)

    # Global policy, e.g. in a boot initializer:
    #
    # ```
    # Saci::SecureHeaders.permissions_policy(
    #   camera: [] of String,
    #   geolocation: ["self"],
    #   payment: [] of String)
    # ```
    #
    # An empty policy (the default) emits no `Permissions-Policy` header.
    def self.permissions_policy(policy : Hash(String, Array(String))) : Nil
      @@mutex.synchronize { @@permissions_policy = policy.dup }
    end

    def self.permissions_policy(**features : Array(String)) : Nil
      policy = {} of String => Array(String)
      features.each { |feature, allowlist| policy[feature.to_s] = allowlist }
      self.permissions_policy(policy)
    end

    def self.permissions_policy=(policy : Hash(String, Array(String))) : Nil
      self.permissions_policy(policy)
    end

    def self.permissions_policy : Hash(String, Array(String))
      @@mutex.synchronize do
        copy = {} of String => Array(String)
        @@permissions_policy.each { |feature, allowlist| copy[feature] = allowlist.dup }
        copy
      end
    end

    # Applies the global policy merged with `override` (per-response). The
    # header is set unless one already exists and no override was supplied,
    # so actions that set the header directly keep the final word.
    def self.apply_permissions_policy(response : HTTP::Server::Response, override : Hash(String, Array(String))? = nil) : Nil
      return if override.nil? && response.headers.has_key?("Permissions-Policy")
      policy = permissions_policy
      policy = PermissionsPolicy.merge(policy, override.not_nil!) if override
      if policy.empty?
        response.headers.delete("Permissions-Policy") if override
        return
      end
      response.headers["Permissions-Policy"] = PermissionsPolicy.serialize(policy)
    end
  end
end
