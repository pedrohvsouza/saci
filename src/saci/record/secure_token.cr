require "base64"
require "random/secure"

module Saci
  module Record
    # Generates a URL-safe random token (24 random bytes → 32 base64url
    # chars, no padding), backing `has_secure_token`. Uses
    # `Random::Secure` (CSPRNG).
    def self.secure_token(bytes : Int = 24) : String
      raw = Bytes.new(bytes)
      Random::Secure.random_bytes(raw)
      Base64.urlsafe_encode(raw, false)
    end
  end

  class Record::Base
    # Rails-like `has_secure_token`. Requires a `String` column named after
    # the attribute (`token` by default):
    #
    # ```
    # class User < ApplicationRecord
    #   column api_token : String
    #   has_secure_token :api_token
    # end
    #
    # user = User.create!(email: "a@b.c") # api_token auto-generated
    # user.regenerate_api_token!          # new token, saved (bang)
    # ```
    #
    # The token is generated in a `before_validation on: :create` hook and
    # only when blank — explicit values are kept and updates never
    # overwrite. Uniqueness is validated at the model level; add a DB
    # unique index too (model validation alone races under concurrency):
    #
    # ```
    # add_index :users, :api_token, unique: true
    # ```
    macro has_secure_token(attr = :token)
      validates {{attr}}, uniqueness: true

      before_validation on: :create do
        %current = self.{{attr.id}}
        if %current.nil? || %current.strip.empty?
          self.{{attr.id}} = Saci::Record.secure_token
        end
      end

      # Regenerates the token and saves (raises `RecordInvalid` when the
      # record is invalid — like `save!`). Returns the new token.
      def regenerate_{{attr.id}}! : String
        %fresh = Saci::Record.secure_token
        self.{{attr.id}} = %fresh
        save!
        %fresh
      end
    end

    # Tamper-proof signed ID (password resets, magic login links, ...),
    # HMAC-signed with the app's `secret_key_base` via
    # `Saci::Secrets.sign`:
    #
    # ```
    # sid = user.signed_id(purpose: "login", expires_in: 15.minutes)
    # User.find_signed(sid, purpose: "login") # => user or nil
    # ```
    #
    # The payload carries the primary key, the model class name, the
    # purpose and an optional unix expiry. Purpose separation is enforced
    # by matching the embedded purpose (a token minted for one purpose
    # never verifies for another — the HMAC covers the whole payload).
    def signed_id(purpose : String? = nil, expires_in : Time::Span? = nil) : String
      pk = self.class.__saci_primary_key
      id_val = __saci_get_attr(pk)
      raise RecordNotSaved.new("Cannot sign id for unpersisted #{self.class} (primary key is nil)") if id_val.nil?
      io = IO::Memory.new
      ::JSON.build(io) do |json|
        json.object do
          json.field "id", id_val.to_s
          json.field "cls", self.class.name
          json.field("pur", purpose) if purpose
          json.field("exp", (Time.utc + expires_in).to_unix) if expires_in
        end
      end
      Secrets.sign(io.to_s)
    end

    # Verifies a `signed_id` token: bad signature, tampering, expiry,
    # wrong purpose, cross-model tokens and missing rows all return nil
    # (never raises).
    def self.find_signed(signed : String, purpose : String? = nil) : self?
      raw = Secrets.verify_signed(signed)
      return nil if raw.nil?
      obj = JSON.parse(raw)
      return nil unless obj["cls"]?.try(&.as_s?) == self.name
      return nil unless obj["pur"]?.try(&.as_s?) == purpose
      if exp_raw = obj["exp"]?.try(&.raw)
        exp = exp_raw.is_a?(Int) ? exp_raw.to_i64 : nil
        return nil if exp.nil? || Time.utc.to_unix > exp
      end
      id_str = obj["id"]?.try(&.as_s?)
      return nil if id_str.nil?
      id_val = __saci_pk_from_string(id_str)
      return nil if id_val.nil?
      find(id_val)
    rescue RecordNotFound
      nil
    rescue
      nil
    end

    # Decodes a stringified id from a signed payload back into the primary
    # key's column type (nil when unparseable).
    def self.__saci_pk_from_string(s : String) : Value
      col_type = __saci_column_names.find { |(n, _)| n == __saci_primary_key }.try(&.[1])
      case col_type
      when "Int32"   then s.to_i32?
      when "Float64" then s.to_f64?
      when "String"  then s
      when "Time"    then Record.parse_time(s)
      when "Bytes"   then nil
      else                s.to_i64?
      end
    end

    # Rails-like `authenticate_by`: finds by the non-password attributes
    # (single query) then verifies the password via `authenticate`.
    # Returns the record on success, nil otherwise — unknown login and
    # wrong password are indistinguishable (no user enumeration, matching
    # password-reset conventions):
    #
    # ```
    # User.authenticate_by(email: "a@b.c", password: "secret")
    # ```
    #
    # Timing: a miss still costs one bcrypt digest (dummy hash), so
    # unknown-login and wrong-password failures take ~the same time.
    # Raises `ArgumentError` when `password` is missing or when no
    # identifying attribute is given (refusing to match the first row),
    # and `UnknownAttributeError` for unknown finder attributes.
    def self.authenticate_by(**attrs : Object) : self?
      ad = Record.adapter_of(connection)
      cols_meta = __saci_column_names
      password_raw = nil
      password_seen = false
      conds = [] of String
      binds = [] of Value
      attrs.each do |key, value|
        if key.to_s == "password"
          password_seen = true
          password_raw = value
        else
          ks = key.to_s
          unless cols_meta.any? { |(n, _)| n == ks }
            raise UnknownAttributeError.new("unknown attribute '#{ks}' for #{self}")
          end
          if value.nil?
            conds << "#{Record.quote(ks, ad)} IS NULL"
          else
            conds << "#{Record.quote(ks, ad)} = ?"
            binds << Record.to_db(value, ad)
          end
        end
      end
      raise ArgumentError.new("authenticate_by requires a password (e.g. authenticate_by(email: \"x\", password: \"y\"))") unless password_seen
      raise ArgumentError.new("authenticate_by requires at least one identifying attribute besides password") if conds.empty?
      password = password_raw.to_s
      record = where(conds.join(" AND "), binds).first
      if record.nil?
        Record.bcrypt_digest("saci-authenticate-by-dummy:#{password}")
        return nil
      end
      record.authenticate(password)
    end
  end
end
