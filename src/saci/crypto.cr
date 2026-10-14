require "openssl"

module Saci
  # Minimal AES-256-GCM binding. The stdlib `OpenSSL::Cipher` binds accessor
  # symbols (`EVP_CIPHER_key_length`, …) that OpenSSL ≥ 3.2 removed, so it
  # cannot link on modern systems; this declares only the long-stable
  # Init/Update/Final + cipher symbols (present from 1.1 through 3.x) and
  # reuses stdlib `LibCrypto` for the rest. Revisit if stdlib fixes its own.
  lib LibSaciGcm
    fun aes_256_gcm = EVP_aes_256_gcm : LibCrypto::EVP_CIPHER
    fun encrypt_init = EVP_EncryptInit_ex(ctx : LibCrypto::EVP_CIPHER_CTX, cipher : LibCrypto::EVP_CIPHER, engine : Void*, key : UInt8*, iv : UInt8*) : Int32
    fun decrypt_init = EVP_DecryptInit_ex(ctx : LibCrypto::EVP_CIPHER_CTX, cipher : LibCrypto::EVP_CIPHER, engine : Void*, key : UInt8*, iv : UInt8*) : Int32
    fun encrypt_update = EVP_EncryptUpdate(ctx : LibCrypto::EVP_CIPHER_CTX, ciphertext : UInt8*, ciphertext_len : Int32*, plaintext : UInt8*, len : Int32) : Int32
    fun decrypt_update = EVP_DecryptUpdate(ctx : LibCrypto::EVP_CIPHER_CTX, plaintext : UInt8*, plaintext_len : Int32*, ciphertext : UInt8*, len : Int32) : Int32
    fun encrypt_final = EVP_EncryptFinal_ex(ctx : LibCrypto::EVP_CIPHER_CTX, ciphertext : UInt8*, ciphertext_len : Int32*) : Int32
    fun decrypt_final = EVP_DecryptFinal_ex(ctx : LibCrypto::EVP_CIPHER_CTX, plaintext : UInt8*, plaintext_len : Int32*) : Int32
  end

  # Authenticated encryption for credentials (random 96-bit IV per message,
  # 128-bit tag; envelope is `base64(iv) + base64(ciphertext) + base64(tag)`).
  module MessageEncryptor
    class Error < Exception
    end

    IV_LEN  = 12
    TAG_LEN = 16

    def self.encrypt_and_sign(key : Bytes, plaintext : Bytes) : String
      raise Error.new("AES-256-GCM needs a 32-byte key") unless key.size == 32
      iv = Bytes.new(IV_LEN)
      Random::Secure.random_bytes(iv)
      ctx = LibCrypto.evp_cipher_ctx_new
      begin
        raise Error.new("encrypt init failed") unless LibSaciGcm.encrypt_init(ctx, LibSaciGcm.aes_256_gcm, nil, key.to_unsafe, iv.to_unsafe) == 1
        buf = Bytes.new(plaintext.size + 16)
        buf_len = 0
        raise Error.new("encrypt update failed") unless LibSaciGcm.encrypt_update(ctx, buf.to_unsafe, pointerof(buf_len), plaintext.to_unsafe, plaintext.size) == 1
        fin = Bytes.new(16)
        fin_len = 0
        raise Error.new("encrypt final failed") unless LibSaciGcm.encrypt_final(ctx, fin.to_unsafe, pointerof(fin_len)) == 1
        tag = Bytes.new(TAG_LEN)
        raise Error.new("tag read failed") unless LibCrypto.evp_cipher_ctx_ctrl(ctx, 0x10, TAG_LEN, tag.to_unsafe.as(Void*)) == 1
        [iv, buf[0, buf_len] + fin[0, fin_len], tag].map { |part| Base64.strict_encode(part) }.join("--")
      ensure
        LibCrypto.evp_cipher_ctx_free(ctx)
      end
    end

    def self.decrypt_and_verify(key : Bytes, envelope : String) : Bytes
      raise Error.new("AES-256-GCM needs a 32-byte key") unless key.size == 32
      parts = envelope.split("--")
      raise Error.new("malformed envelope") unless parts.size == 3
      iv, ciphertext, tag = parts.map { |part| Base64.decode(part) }
      raise Error.new("bad iv length") unless iv.size == IV_LEN
      raise Error.new("bad tag length") unless tag.size == TAG_LEN
      ctx = LibCrypto.evp_cipher_ctx_new
      begin
        raise Error.new("decrypt init failed") unless LibSaciGcm.decrypt_init(ctx, LibSaciGcm.aes_256_gcm, nil, key.to_unsafe, iv.to_unsafe) == 1
        raise Error.new("tag rejected") unless LibCrypto.evp_cipher_ctx_ctrl(ctx, 0x11, tag.size, tag.to_unsafe.as(Void*)) == 1
        buf = Bytes.new(ciphertext.size + 16)
        buf_len = 0
        raise Error.new("decrypt update failed") unless LibSaciGcm.decrypt_update(ctx, buf.to_unsafe, pointerof(buf_len), ciphertext.to_unsafe, ciphertext.size) == 1
        fin = Bytes.new(16)
        fin_len = 0
        raise Error.new("authentication failed") unless LibSaciGcm.decrypt_final(ctx, fin.to_unsafe, pointerof(fin_len)) == 1
        buf[0, buf_len] + fin[0, fin_len]
      ensure
        LibCrypto.evp_cipher_ctx_free(ctx)
      end
    rescue ex : Error
      raise ex
    rescue
      raise Error.new("decryption failed")
    end
  end
end
