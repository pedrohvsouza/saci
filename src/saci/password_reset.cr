require "json"
require "openssl/hmac"
require "crypto/subtle"

require "./secrets"

module Saci
  module Record
    # Helpers behind `generates_token_for` (Rails 7.1-style stateless
    # tokens). The signed payload carries the record class/id, the purpose,
    # an optional expiry, a random nonce and a *fingerprint* of the block
    # value — never the value itself. Changing the block value (e.g. the
    # password salt/digest) makes every previously issued token fail.
    module TokenFor
      VERSION = 1

      # A generator registered by a `generates_token_for` declaration. The
      # procs are typed against `Record::Base` (framework-spellable) and
      # cast to the owning class internally; the matcher makes parent-class
      # declarations work for subclasses.
      struct Generator
        getter owner : String
        getter purpose : String
        getter expires_in : Time::Span?
        getter value : Proc(Record::Base, String)
        getter matcher : Proc(Record::Base, Bool)

        def initialize(@owner : String, @purpose : String, @expires_in : Time::Span?,
                       @value : Proc(Record::Base, String), @matcher : Proc(Record::Base, Bool))
        end
      end

      @@generators = [] of Generator
      @@mutex = Mutex.new

      def self.register(owner : String, purpose : String, expires_in : Time::Span?,
                        value : Proc(Record::Base, String),
                        matcher : Proc(Record::Base, Bool)) : Nil
        @@mutex.synchronize do
          @@generators << Generator.new(owner, purpose, expires_in, value, matcher)
        end
      end

      # Most recently registered matching generator wins, so a subclass can
      # override a purpose declared on its parent.
      def self.lookup(record : Record::Base, purpose : String) : Generator?
        @@mutex.synchronize do
          @@generators.reverse_each do |generator|
            if generator.purpose == purpose && generator.matcher.call(record)
              return generator
            end
          end
        end
        nil
      end

      # Opaque, purpose/class-separated fingerprint of the block value.
      def self.fingerprint(class_name : String, purpose : String, value : String) : String
        OpenSSL::HMAC.hexdigest(
          :sha256,
          Secrets.secret_key_base,
          "saci-token-for-v#{VERSION}/#{class_name}/#{purpose}/#{value}"
        )
      end

      def self.secure_compare(expected : String, actual : String?) : Bool
        return false if actual.nil? || actual.bytesize != expected.bytesize
        Crypto::Subtle.constant_time_compare(expected, actual)
      end
    end
  end

  class Record::Base
    # -- stateless, purpose-scoped tokens (Rails `generates_token_for`) ----

    # Generates a signed, purpose-scoped token for this record. The record
    # must be persisted (its primary key is embedded in the payload).
    #
    # ```
    # user.generate_token_for(:password_reset)
    # ```
    #
    # Token payload (JSON, then `Saci::Secrets.sign`):
    # `v`, `cls`, `id`, `pur`, `exp` (optional), `fp`, `nonce`.
    # The HMAC covers the whole payload, so class, purpose and expiry are
    # tamper-proof. The fingerprint is an HMAC of the `generates_token_for`
    # block value, so the raw value never appears in the token.
    def generate_token_for(purpose : String | Symbol) : String
      pur = purpose.to_s
      pk = self.class.__saci_primary_key
      id_val = __saci_get_attr(pk)
      if id_val.nil?
        raise RecordNotSaved.new("Cannot generate a token for an unpersisted #{self.class} (primary key is nil)")
      end

      generator = Record::TokenFor.lookup(self, pur)
      if generator.nil?
        raise ArgumentError.new("No token generator for purpose #{pur.inspect} on #{self.class}")
      end

      value = generator.value.call(self)
      expires_in = generator.expires_in
      fingerprint = Record::TokenFor.fingerprint(self.class.name, pur, value)

      io = IO::Memory.new
      JSON.build(io) do |json|
        json.object do
          json.field "v", Record::TokenFor::VERSION
          json.field "cls", self.class.name
          json.field "id", id_val.to_s
          json.field "pur", pur
          json.field "fp", fingerprint
          json.field("exp", (Time.utc + expires_in).to_unix) if expires_in
          # Nonce makes tokens non-deterministic; it is covered by the MAC.
          json.field "nonce", Saci::Record.secure_token(12)
        end
      end
      Secrets.sign(io.to_s)
    end

    # Finds the record a token was generated for, or nil. Verifies the
    # signature, class, purpose, expiry, row existence and block-value
    # fingerprint. `now:` is injectable for tests; production callers use
    # the default.
    def self.find_by_token_for(purpose : String | Symbol, token : String, now : Time = Time.utc) : self?
      pur = purpose.to_s
      raw = Secrets.verify_signed(token)
      return nil if raw.nil?
      obj = JSON.parse(raw)
      return nil unless obj.as_h?
      return nil unless obj["v"]?.try(&.as_i?) == TokenFor::VERSION
      return nil unless obj["cls"]?.try(&.as_s?) == self.name
      return nil unless obj["pur"]?.try(&.as_s?) == pur

      if exp_raw = obj["exp"]?
        exp = case raw_exp = exp_raw.raw
              when Int   then raw_exp.to_i64
              when Float then raw_exp.to_i64
              else            nil
              end
        return nil if exp.nil? || now.to_unix > exp
      end

      id_str = obj["id"]?.try(&.as_s?)
      return nil if id_str.nil?
      id_val = __saci_pk_from_string(id_str)
      return nil if id_val.nil?

      record = find(id_val)
      fingerprint = obj["fp"]?.try(&.as_s?)
      return nil unless record.__saci_token_for_matches?(pur, fingerprint)
      record
    rescue RecordNotFound
      nil
    rescue
      nil
    end

    # Like `find_by_token_for`, but raises `RecordNotFound` instead of
    # returning nil (generic message; the reason is deliberately hidden so
    # callers can't distinguish expired from forged tokens).
    def self.find_by_token_for!(purpose : String | Symbol, token : String, now : Time = Time.utc) : self
      find_by_token_for(purpose, token, now) ||
        raise RecordNotFound.new("Couldn't find #{self.name} for token purpose #{purpose}")
    end

    def __saci_token_for_matches?(purpose : String, fingerprint : String?) : Bool
      generator = Record::TokenFor.lookup(self, purpose)
      return false if generator.nil?
      value = generator.value.call(self)
      expected = Record::TokenFor.fingerprint(self.class.name, purpose, value)
      Record::TokenFor.secure_compare(expected, fingerprint)
    end

    # Rails-style declaration:
    #
    # ```
    # class User < ApplicationRecord
    #   column password_digest : String
    #   has_secure_password
    #
    #   generates_token_for :password_reset, expires_in: 15.minutes do |user|
    #     user.password_salt
    #   end
    # end
    #
    # token = user.generate_token_for(:password_reset)
    # User.find_by_token_for(:password_reset, token) # => user or nil
    # ```
    #
    # The block value is hashed, never embedded. Rotate it (password salt,
    # digest, updated_at, a dedicated nonce column) to invalidate every
    # outstanding token. The purpose is embedded and MAC-protected, so a
    # token minted for `:login` never verifies for `:password_reset`.
    #
    # *purpose* must be a symbol literal (needed to identify the generator
    # at compile time). *expires_in* is an optional `Time::Span`; omit it
    # for non-expiring tokens. Generators declared on a parent class also
    # apply to subclasses.
    macro generates_token_for(purpose, expires_in = nil, &block)
      {% unless purpose.is_a?(SymbolLiteral) %}
        {% raise "generates_token_for purpose must be a symbol literal, e.g. :password_reset" %}
      {% end %}
      {% if block.args.size > 1 %}
        {% raise "generates_token_for block takes zero or one argument (the record)" %}
      {% end %}

      Saci::Record::TokenFor.register(
        owner: {{@type.name.stringify}},
        purpose: {{purpose.id.stringify}},
        expires_in: {{expires_in || nil}},
        value: ->(record : Saci::Record::Base) do
          %typed = record.as({{@type}})
          {% if block.args.size == 1 %}
            {{block.args[0]}} = %typed
          {% end %}
          ({{block.body}}).to_s
        end,
        matcher: ->(record : Saci::Record::Base) { record.is_a?({{@type}}) }
      )
    end

    # Convenience declaration for the common password-reset case. The
    # block value is the record's bcrypt salt, so tokens stop working as
    # soon as the password is changed:
    #
    # ```
    # class User < ApplicationRecord
    #   column password_digest : String
    #   has_secure_password
    #   generates_password_reset_token # expires in 15 minutes by default
    # end
    # ```
    macro generates_password_reset_token(expires_in = 15.minutes)
      generates_token_for :password_reset, expires_in: {{expires_in}} do |record|
        record.password_salt
      end
    end

    # -- has_secure_password reset integration ----------------------------
    #
    # Recommended controller flow (no generated app code required; the
    # `saci g authentication` generator can emit this shape):
    #
    # ```
    # class PasswordsController < ApplicationController
    #   allow_unauthenticated_access only: [:new, :create, :edit, :update]
    #
    #   def create
    #     if user = User.find_by(email: params["email"]?)
    #       token = user.generate_token_for(:password_reset)
    #       PasswordsMailer.reset(user, token).deliver_later
    #     end
    #     # Always the same response: don't reveal whether the email exists.
    #     redirect_to "/login", notice: "Check your email for reset instructions"
    #   end
    #
    #   def update
    #     user = User.find_by_token_for(:password_reset, params["token"]?)
    #     if user && user.reset_password(params["password"], params["password_confirmation"])
    #       redirect_to "/login", notice: "Password updated"
    #     else
    #       redirect_to "/passwords/new", alert: "Invalid or expired token"
    #     end
    #   end
    # end
    # ```
    #
    # The email link contains `/passwords/:token/edit`; the update action
    # posts the token plus the new password. Never log the token/URL.

    # Bcrypt salt half of `password_digest` (`$2a$11$<22 chars><digest>`).
    # Changes whenever the password changes, which makes it a good default
    # token block value. Returns nil when no digest is present.
    def password_salt : String?
      digest = __saci_get_attr("password_digest").as?(String)
      return nil if digest.nil? || digest.empty?
      # bcrypt format: $<scheme>$<cost>$<22-char salt><31-char hash>
      parts = digest.split('$')
      salt = parts[3]?
      return nil if salt.nil? || salt.size < 22
      salt[0, 22]
    end

    # Digest stored in the optional `reset_password_token` column by
    # `issue_password_reset_token!` (never the plaintext token). Declare
    # the column yourself:
    #
    # ```
    # column reset_password_token : String
    # column reset_password_token_expires_at : Time
    # ```
    def reset_password_token : String?
      value = __saci_get_attr("reset_password_token")
      value.is_a?(String) ? value : nil
    end

    def reset_password_token_expires_at : Time?
      value = __saci_get_attr("reset_password_token_expires_at")
      value.is_a?(Time) ? value : nil
    end

    # Stateful (Rails 7.0/Devise-style) reset token flow: stores an HMAC
    # digest plus expiry, returns the plaintext token once (put it in the
    # email link). Requires the two columns above.
    #
    # For new code prefer `generates_token_for :password_reset` — no
    # columns, no cleanup job, automatic invalidation.
    def issue_password_reset_token!(expires_in : Time::Span = 15.minutes) : String
      token = Saci::Record.secure_token
      digest = Record::TokenFor.fingerprint(self.class.name, "stored_password_reset", token)
      unless __saci_set_attr("reset_password_token", digest)
        raise ArgumentError.new("#{self.class} needs a reset_password_token column for stored reset tokens")
      end
      __saci_set_attr("reset_password_token_expires_at", Time.utc + expires_in)
      save!
      token
    end

    # True when a stateful reset token is present and unexpired. When
    # *token* is supplied it is also compared (constant time) against the
    # stored digest.
    def password_reset_token_valid?(token : String? = nil, now : Time = Time.utc) : Bool
      stored = reset_password_token
      expiry = reset_password_token_expires_at
      return false if stored.nil? || stored.empty? || expiry.nil?
      return false if now > expiry
      return true if token.nil?
      expected = Record::TokenFor.fingerprint(self.class.name, "stored_password_reset", token)
      Record::TokenFor.secure_compare(expected, stored)
    end

    # Finds by the stateful reset token (hashes the submitted token, then
    # checks expiry). Returns nil for unknown/expired tokens.
    def self.find_by_reset_password_token(token : String, now : Time = Time.utc) : self?
      return nil unless __saci_column_names.any? { |(name, _)| name == "reset_password_token" }
      digest = Record::TokenFor.fingerprint(self.name, "stored_password_reset", token)
      record = where("reset_password_token = ?", digest).first
      return nil if record.nil?
      record.password_reset_token_valid?(token, now: now) ? record : nil
    rescue
      nil
    end

    # Sets a new password (with optional confirmation), clears the stateful
    # reset token and saves. Returns false on validation failure (including
    # a confirmation mismatch), true when persisted. Requires
    # `has_secure_password`.
    #
    # ```
    # if user = User.find_by_token_for(:password_reset, params["token"]?)
    #   user.reset_password(params["password"], params["password_confirmation"])
    # end
    # ```
    def reset_password(new_password : String, confirmation : String? = nil) : Bool
      unless __saci_set_attr("password", new_password)
        raise ArgumentError.new("#{self.class} must use has_secure_password to reset passwords")
      end
      # Always reset the virtual confirmation: a stale value from an earlier
      # failed attempt must not fail this save.
      __saci_set_attr("password_confirmation", confirmation)
      __saci_set_attr("reset_password_token", nil)
      __saci_set_attr("reset_password_token_expires_at", nil)
      save
    end

    # Like `reset_password`, raising `RecordInvalid` on failure.
    def reset_password!(new_password : String, confirmation : String? = nil) : Bool
      unless reset_password(new_password, confirmation)
        raise RecordInvalid.new(errors)
      end
      true
    end
  end
end
