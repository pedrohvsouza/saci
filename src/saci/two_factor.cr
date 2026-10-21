require "./totp"

module Saci
  class Record::Base
    # No 2FA configured unless the model uses `has_two_factor`.
    def two_factor_enabled? : Bool
      false
    end

    # Opt-in TOTP/2FA helpers. The macro deliberately does **not** add
    # columns (Saci has no migration-from-model path): declare them in your
    # model/migration first:
    #
    # ```
    # class User < ApplicationRecord
    #   column otp_secret : String
    #   column two_factor_enabled : Bool, default: false
    #
    #   has_two_factor issuer: "Acme"
    # end
    #
    # secret = user.enable_two_factor!            # base32, store safely
    # user.two_factor_provisioning_uri("a@b.c")   # otpauth:// URI (QR input)
    # user.verify_two_factor_code(params["code"]) # => true/false
    # ```
    #
    # Column names are configurable (`secret_column:`, `enabled_column:`).
    # Secrets are never logged by this macro.
    macro has_two_factor(secret_column = :otp_secret, enabled_column = :two_factor_enabled,
                         issuer = nil, digits = 6, period = 30, drift = 1)
      def two_factor_enabled? : Bool
        %secret = self.{{secret_column.id}}
        %enabled = self.{{enabled_column.id}}
        !%secret.nil? && !%secret.to_s.empty? && %enabled == true
      end

      def two_factor_secret : String?
        %value = self.{{secret_column.id}}
        %value.nil? ? nil : %value.to_s
      end

      # Creates and persists a fresh base32 secret (does not enable 2FA
      # yet — confirm one code first, then call `enable_two_factor!`).
      def generate_two_factor_secret! : String
        %secret = Saci::TOTP.random_secret
        self.{{secret_column.id}} = %secret
        save!
        %secret
      end

      # Generates a secret when missing, marks 2FA enabled and saves.
      # Returns the secret (needed for the provisioning URI/QR).
      def enable_two_factor! : String
        %secret = self.{{secret_column.id}}
        if %secret.nil? || %secret.to_s.empty?
          %secret = Saci::TOTP.random_secret
          self.{{secret_column.id}} = %secret
        end
        self.{{enabled_column.id}} = true
        save!
        %secret.to_s
      end

      # Disables 2FA and destroys the shared secret.
      def disable_two_factor! : Bool
        self.{{enabled_column.id}} = false
        self.{{secret_column.id}} = nil
        save
      end

      # `otpauth://totp/...` URI — feed it to any QR renderer. `issuer`
      # defaults to the macro argument (nil means the URI carries no issuer).
      def two_factor_provisioning_uri(account : String, issuer : String? = {{issuer}}) : String
        %secret = self.{{secret_column.id}}
        if %secret.nil? || %secret.to_s.empty?
          raise ArgumentError.new("#{self.class} has no 2FA secret (call generate_two_factor_secret! first)")
        end
        Saci::TOTP.provisioning_uri(
          %secret.to_s,
          issuer: issuer,
          account: account,
          digits: {{digits}},
          period: {{period}}
        )
      end

      # Verifies a submitted TOTP code against the stored secret. Returns
      # false when 2FA/secret is not configured.
      def verify_two_factor_code(code : String, drift : Int32 = {{drift}}) : Bool
        %secret = self.{{secret_column.id}}
        return false if %secret.nil? || %secret.to_s.empty?
        Saci::TOTP.verify(
          %secret.to_s,
          code,
          drift: drift,
          digits: {{digits}},
          period: {{period}}
        )
      end
    end
  end
end
