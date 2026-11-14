require "openssl/hmac"

module Saci
  module Record
    # Attribute encryption behind `encrypts` (Rails Active Record
    # Encryption). Values are stored as AES-256-GCM envelopes
    # (`base64(iv)--base64(ciphertext)--base64(tag)`).
    #
    # Keys come from, in order: `Encryption.primary_key=` /
    # `deterministic_key=`, then the credentials entries
    # `record_encryption.primary_key` / `record_encryption.deterministic_key`,
    # then `secret_key_base`. Each is stretched to a 32-byte AES key with
    # HMAC-SHA256. Prefer dedicated keys in credentials: with the
    # `secret_key_base` fallback, rotating that secret makes existing
    # ciphertexts unreadable unless the old one goes in `previous_keys`.
    module Encryption
      class Error < Exception
      end

      # The stored value is not a valid envelope for any configured key.
      class DecryptionError < Error
      end

      class_property primary_key : String? = nil
      class_property deterministic_key : String? = nil

      # Old key material (either kind) still accepted for decryption, for
      # key rotation. New writes always use the current keys, so saving a
      # record re-encrypts it. Deterministic queries only match values
      # written with the current deterministic key.
      class_property previous_keys : Array(String) = [] of String

      # When true, a stored value that is not an envelope is returned as
      # is, so a column can be switched to `encrypts` before its existing
      # rows are re-saved. Off by default: a tampered or foreign value
      # raises `DecryptionError`.
      class_property? support_unencrypted_data : Bool = false

      @@key_mutex = Mutex.new
      @@keys = {} of {String, String} => Bytes

      # Clears memoized keys (call after changing keys or credentials).
      def self.reset_keys! : Nil
        @@key_mutex.synchronize { @@keys.clear }
      end

      def self.encrypt(plaintext : String, deterministic : Bool = false) : String
        if deterministic
          key = deterministic_aes_key
          iv = OpenSSL::HMAC.digest(:sha256, key, plaintext)[0, MessageEncryptor::IV_LEN]
          MessageEncryptor.encrypt_and_sign(key, plaintext.to_slice, iv)
        else
          MessageEncryptor.encrypt_and_sign(primary_aes_key, plaintext.to_slice)
        end
      end

      def self.decrypt(envelope : String) : String
        unless envelope.count('-') >= 4 && envelope.split("--").size == 3
          return envelope if support_unencrypted_data?
          raise DecryptionError.new("value is not an encrypted envelope")
        end
        decryption_keys.each do |key|
          begin
            return String.new(MessageEncryptor.decrypt_and_verify(key, envelope))
          rescue MessageEncryptor::Error
          end
        end
        return envelope if support_unencrypted_data?
        raise DecryptionError.new("could not decrypt the value with the configured keys")
      end

      # Column value written to the database.
      def self.encode(value : Value, deterministic : Bool, downcase : Bool) : Value
        case value
        when Nil    then nil
        when String then encrypt(downcase ? value.downcase : value, deterministic)
        else
          raise ArgumentError.new("encrypts supports String columns (got #{value.class})")
        end
      end

      # Column value read back from the database.
      def self.decode(value : Value) : Value
        value.is_a?(String) ? decrypt(value) : value
      end

      def self.primary_aes_key : Bytes
        derive(primary_key || credential("primary_key"), "primary")
      end

      def self.deterministic_aes_key : Bytes
        derive(deterministic_key || credential("deterministic_key"), "deterministic")
      end

      private def self.decryption_keys : Array(Bytes)
        keys = [primary_aes_key, deterministic_aes_key]
        previous_keys.each do |material|
          keys << derive(material, "primary")
          keys << derive(material, "deterministic")
        end
        keys
      end

      private def self.credential(name : String) : String?
        value = Credentials.dig("record_encryption.#{name}")
        value.nil? || value.empty? ? nil : value
      rescue
        nil
      end

      # nil material falls back to `secret_key_base`, derived the same way
      # as explicit keys so an old secret works in `previous_keys`.
      private def self.derive(material : String?, purpose : String) : Bytes
        m = material || Secrets.secret_key_base
        cache_key = {m, purpose}
        if key = @@key_mutex.synchronize { @@keys[cache_key]? }
          return key
        end
        key = OpenSSL::HMAC.digest(:sha256, m, "saci-record-encryption-v1/#{purpose}")
        @@key_mutex.synchronize do
          @@keys.clear if @@keys.size >= 64
          @@keys[cache_key] = key
        end
        key
      end
    end
  end
end
