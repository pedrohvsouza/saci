require "base64"
require "random/secure"
require "openssl/hmac"
require "crypto/subtle"
require "uri"

require "./secrets"

module Saci
  # RFC 6238 time-based one-time passwords (TOTP) and RFC 4226 HOTP
  # counters — the server side of authenticator apps (Google Authenticator,
  # 1Password, Authy, ...).
  #
  # ```
  # secret = Saci::TOTP.random_secret                   # base32, 160-bit
  # Saci::TOTP.code(secret)                             # => "492039"
  # Saci::TOTP.verify(secret, params["code"], drift: 1) # => true/false
  #
  # Saci::TOTP.provisioning_uri(secret, issuer: "Acme", account: "a@b.c")
  # # => "otpauth://totp/Acme:a%40b.c?secret=...&issuer=Acme&..."
  # ```
  #
  # The provisioning URI is the standard `otpauth://` format every
  # authenticator app understands. Rendering it as a QR image is
  # intentionally out of scope (no image/QR shard is bundled): pass the URI
  # to any QR library or to a QR-as-a-service endpoint. Never log the
  # secret or the URI — both contain the shared key.
  #
  # Only HMAC-SHA1 is generated (the interoperable default required by the
  # `otpauth://` ecosystem). SHA256/SHA512 can be added later without
  # changing the API; `provisioning_uri` accepts `algorithm:` but currently
  # only emits `SHA1`.
  module TOTP
    ALPHABET            = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
    BACKUP_ALPHABET     = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    BACKUP_CODE_VERSION = "saci-totp-backup-v1"

    # Generates a new base32 secret (default 20 bytes = 160 bits, the
    # RFC 4226 recommendation). Store it as text; never log it.
    def self.random_secret(bytes : Int32 = 20) : String
      raise ArgumentError.new("secret length must be positive") if bytes <= 0
      raw = Bytes.new(bytes)
      Random::Secure.random_bytes(raw)
      base32_encode(raw)
    end

    # RFC 4648 base32 (no padding by default; decoding accepts padding and
    # common grouping spaces/dashes).
    def self.base32_encode(data : Bytes) : String
      String.build do |io|
        buffer = 0_u64
        bits = 0
        data.each do |byte|
          buffer = (buffer << 8) | byte
          bits += 8
          while bits >= 5
            bits -= 5
            io << ALPHABET[(buffer >> bits) & 0x1f]
          end
        end
        io << ALPHABET[(buffer << (5 - bits)) & 0x1f] if bits > 0
      end
    end

    def self.base32_decode(secret : String) : Bytes
      clean = secret.upcase.delete(" \t\r\n-").rstrip('=')
      raise ArgumentError.new("empty TOTP secret") if clean.empty?
      bytes = [] of UInt8
      buffer = 0_u64
      bits = 0
      clean.each_char do |char|
        index = ALPHABET.index(char)
        raise ArgumentError.new("invalid base32 character '#{char}'") if index.nil?
        buffer = (buffer << 5) | index.to_u64
        bits += 5
        if bits >= 8
          bits -= 8
          bytes << ((buffer >> bits) & 0xff).to_u8
        end
      end
      Bytes.new(bytes.size) { |i| bytes[i] }
    end

    # RFC 6238 code for *time* (default: now), zero-padded to *digits*.
    # *period* is in seconds. Compute manually for test vectors, e.g.
    # `TOTP.code(secret, time: Time.unix(59), digits: 8)`.
    def self.code(secret : String, time : Time = Time.utc, digits : Int32 = 6, period : Int32 = 30) : String
      validate_params(digits, period)
      counter = time.to_unix // period
      raise ArgumentError.new("time is before the Unix epoch") if counter < 0
      hotp(base32_decode(secret), counter.to_u64, digits)
    end

    # RFC 4226 HOTP for an explicit counter.
    def self.hotp(key : Bytes, counter : UInt64, digits : Int32 = 6) : String
      validate_params(digits, 30)
      counter_bytes = Bytes.new(8)
      8.times do |i|
        counter_bytes[7 - i] = ((counter >> (8 * i)) & 0xff).to_u8
      end
      digest = OpenSSL::HMAC.digest(:sha1, key, counter_bytes)
      offset = (digest[19] & 0x0f).to_i
      binary = ((digest[offset].to_u64 & 0x7f) << 24) |
               (digest[offset + 1].to_u64 << 16) |
               (digest[offset + 2].to_u64 << 8) |
               digest[offset + 3].to_u64
      modulo = 10_i64 ** digits
      (binary % modulo).to_s.rjust(digits, '0')
    end

    # Verifies *code* against the secret for the current time. *drift* is
    # the number of adjacent periods accepted in each direction (1 allows
    # 30s of clock skew on either side). Every candidate is compared in
    # constant time and the loop never short-circuits, so a wrong code
    # costs the same as a right one.
    def self.verify(secret : String, code : String, time : Time = Time.utc,
                    drift : Int32 = 1, digits : Int32 = 6, period : Int32 = 30) : Bool
      validate_params(digits, period)
      raise ArgumentError.new("drift must be >= 0") if drift < 0
      normalized = normalize_code(code)
      return false unless normalized.size == digits && normalized.each_char.all?(&.ascii_number?)
      key = base32_decode(secret)
      counter = time.to_unix // period
      valid = false
      (-drift..drift).each do |offset|
        candidate_counter = counter + offset
        next if candidate_counter < 0
        candidate = hotp(key, candidate_counter.to_u64, digits)
        valid = Crypto::Subtle.constant_time_compare(candidate, normalized) || valid
      end
      valid
    end

    # Builds the standard `otpauth://totp/...` provisioning URI. The
    # issuer/account label is percent-encoded, as are query values.
    # `algorithm` is accepted for forward compatibility but only SHA1 is
    # emitted (the interoperable default).
    def self.provisioning_uri(secret : String, issuer : String? = nil, account : String = "",
                              digits : Int32 = 6, period : Int32 = 30,
                              algorithm : String = "SHA1") : String
      validate_params(digits, period)
      raise ArgumentError.new("account must not be empty") if account.empty?
      if issuer && issuer.empty?
        raise ArgumentError.new("issuer must not be empty")
      end
      unless algorithm.upcase == "SHA1"
        raise ArgumentError.new("only SHA1 provisioning is supported")
      end

      label = if issuer
                "#{encode(issuer)}:#{encode(account)}"
              else
                encode(account)
              end
      params = [] of String
      params << "secret=#{encode(secret)}"
      params << "issuer=#{encode(issuer)}" if issuer
      params << "algorithm=SHA1"
      params << "digits=#{digits}"
      params << "period=#{period}"
      "otpauth://totp/#{label}?#{params.join("&")}"
    end

    # Human-friendly one-time backup codes. Ambiguous characters
    # (0/O, 1/I) are omitted. Store only `backup_code_digest(code)`, never
    # the plaintext codes.
    def self.generate_backup_codes(count : Int32 = 10, length : Int32 = 10) : Array(String)
      raise ArgumentError.new("count must be positive") if count <= 0
      raise ArgumentError.new("length must be positive") if length <= 0
      Array.new(count) do
        String.build do |io|
          length.times { io << BACKUP_ALPHABET[Random::Secure.rand(BACKUP_ALPHABET.size)] }
        end
      end
    end

    # Keyed digest for storing a backup code (HMAC-SHA256 with the app
    # secret, purpose-separated). Codes are normalized (case/grouping
    # insensitive) before hashing.
    def self.backup_code_digest(code : String) : String
      normalized = normalize_backup_code(code)
      OpenSSL::HMAC.hexdigest(:sha256, Saci::Secrets.secret_key_base, "#{BACKUP_CODE_VERSION}/#{normalized}")
    end

    # Constant-time check of a submitted backup code against a stored
    # digest.
    def self.verify_backup_code_digest(code : String, digest : String) : Bool
      expected = backup_code_digest(code)
      Crypto::Subtle.constant_time_compare(expected, digest)
    rescue
      false
    end

    # Constant-time check against a plaintext list (useful for tests and
    # small one-off recovery sets). Does not consume the code; callers
    # should remove the matched entry themselves.
    def self.verify_backup_code(code : String, codes : Enumerable(String)) : Bool
      normalized = normalize_backup_code(code)
      valid = false
      codes.each do |candidate|
        valid = Crypto::Subtle.constant_time_compare(normalized, normalize_backup_code(candidate)) || valid
      end
      valid
    end

    # Uppercases and strips spaces/dashes from backup codes.
    def self.normalize_backup_code(code : String) : String
      code.upcase.delete(" \t\r\n-")
    end

    private def self.normalize_code(code : String) : String
      code.delete(" \t\r\n-")
    end

    private def self.validate_params(digits : Int32, period : Int32) : Nil
      unless 6 <= digits <= 10
        raise ArgumentError.new("TOTP digits must be between 6 and 10")
      end
      raise ArgumentError.new("TOTP period must be positive") if period <= 0
    end

    # `URI.encode_path_segment` percent-encodes spaces as %20 (rather than
    # the `+` used by form encoding), which authenticator apps prefer in
    # otpauth URIs.
    private def self.encode(value : String) : String
      URI.encode_path_segment(value)
    end
  end
end
