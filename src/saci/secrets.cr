require "base64"
require "openssl/hmac"

require "openssl/hmac"
require "crypto/subtle"

module Saci
  class CookieOverflow < Exception
  end

  # Application secret + signed values. The secret comes from
  # `SECRET_KEY_BASE`; without it, a random dev secret is generated once and
  # persisted to `tmp/.dev_secret` (never commit it — add `tmp/` to
  # `.gitignore`). In production there is no fallback: booting without a
  # secret raises instead of silently running with an insecure default.
  module Secrets
    class MissingSecretInProduction < Exception
    end

    @@secret : String? = nil
    @@mutex = Mutex.new

    def self.secret_key_base : String
      if env = ENV["SECRET_KEY_BASE"]?
        return env unless env.empty?
      end
      if from_creds = credentials_secret
        return from_creds
      end
      if Saci.env == "production"
        raise MissingSecretInProduction.new(
          "SECRET_KEY_BASE is not set (and no secret_key_base in credentials). " \
          "Refusing to boot in production with a generated dev secret. " \
          "Set SECRET_KEY_BASE (e.g. from `saci secret`) and restart.")
      end
      @@mutex.synchronize do
        @@secret ||= begin
          path = "tmp/.dev_secret"
          if File.exists?(path)
            File.read(path).strip
          else
            STDERR.puts "[saci] WARNING: SECRET_KEY_BASE is not set — using a generated dev secret at #{path}. Set SECRET_KEY_BASE in production."
            Dir.mkdir_p("tmp")
            token = generate_secret
            File.write(path, token)
            token
          end
        end
      end
    end

    # Reads `secret_key_base` from the encrypted credentials file, if the
    # file and master key are present. Never raises (returns nil).
    private def self.credentials_secret : String?
      value = Credentials.dig("secret_key_base")
      value.nil? || value.empty? ? nil : value
    rescue
      nil
    end

    # 128 hex chars of secure randomness (also backing `saci secret`).
    def self.generate_secret : String
      bytes = Bytes.new(64)
      Random::Secure.random_bytes(bytes)
      bytes.hexstring
    end

    # Clears the memoized secret (spec isolation).
    def self.reset_secret_key_base! : Nil
      @@mutex.synchronize { @@secret = nil }
    end

    # Derives a 32-byte AES key for `purpose` (e.g. `"cookie"`,
    # `"session"`) from the app secret via HMAC-SHA256. Purpose separation
    # means a value encrypted for one use never decrypts for another.
    # (HMAC, not `Digest`, because stdlib digests can't link on OpenSSL ≥ 3.2.)
    def self.encrypted_key(purpose : String) : Bytes
      OpenSSL::HMAC.digest(:sha256, secret_key_base, "saci-encrypted-v1/#{purpose}")
    end

    # `payload--hmac(payload)` with a URL-safe payload encoding.
    def self.sign(payload : String) : String
      encoded = Base64.urlsafe_encode(payload, false)
      "#{encoded}--#{OpenSSL::HMAC.hexdigest(:sha256, secret_key_base, encoded)}"
    end

    # Returns the payload, or nil when tampered/malformed.
    def self.verify_signed(signed : String) : String?
      # Signature is fixed-width (SHA256 hex); split from the right so `--`
      # inside the payload encoding can never confuse parsing.
      return nil if signed.bytesize < 67
      sig = signed[-64..]
      return nil unless signed[-66...-64] == "--"
      encoded = signed[0...-66]
      return nil if encoded.empty?
      expected = OpenSSL::HMAC.hexdigest(:sha256, secret_key_base, encoded)
      return nil unless Crypto::Subtle.constant_time_compare(expected, sig)
      String.new(Base64.decode(encoded))
    rescue
      nil
    end
  end
end
