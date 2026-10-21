require "base64"
require "digest/sha256"
require "openssl"

# Reopen the stdlib crypto bindings for the EVP public-key signing API
# (Crystal 1.22 does not expose OpenSSL::PKey). Only the symbols needed by
# DKIM are declared.
lib LibCrypto
  fun bio_new_mem_buf = BIO_new_mem_buf(buf : Void*, len : Int32) : Bio*
  fun pem_read_bio_private_key = PEM_read_bio_PrivateKey(bio : Bio*, pkey : Void*, cb : Void*, u : Void*) : Void*
  fun evp_pkey_free = EVP_PKEY_free(pkey : Void*) : Void
  fun evp_digest_sign_init = EVP_DigestSignInit(ctx : EVP_MD_CTX, pctx : Void*, type : EVP_MD, e : Void*, pkey : Void*) : Int32
  fun evp_digest_sign_update = EVP_DigestSignUpdate(ctx : EVP_MD_CTX, data : UInt8*, count : LibC::SizeT) : Int32
  fun evp_digest_sign_final = EVP_DigestSignFinal(ctx : EVP_MD_CTX, sigret : UInt8*, siglen : LibC::SizeT*) : Int32
end

module Saci
  module Mailer
    # DKIM configuration. `private_key` is PEM content (use
    # `DkimSettings.from_file` for a path). Only the common
    # `rsa-sha256` / `relaxed/relaxed` combination is implemented.
    #
    # ```
    # Saci::Mailer.dkim_settings = Saci::Mailer::DkimSettings.from_file(
    #   domain: "example.com", selector: "mail",
    #   path: "config/dkim/example.com.pem")
    # ```
    struct DkimSettings
      property domain : String
      property selector : String
      property private_key : String
      property headers : Array(String)
      property canonicalization : String

      def initialize(@domain : String, @selector : String, @private_key : String,
                     @headers : Array(String) = ["from", "to", "subject", "date", "message-id", "mime-version", "content-type"],
                     @canonicalization : String = "relaxed/relaxed")
        raise ArgumentError.new("DKIM domain is required") if @domain.strip.empty?
        raise ArgumentError.new("DKIM selector is required") if @selector.strip.empty?
        raise ArgumentError.new("DKIM private key is required") if @private_key.strip.empty?
        unless @canonicalization == "relaxed/relaxed"
          raise ArgumentError.new("only relaxed/relaxed DKIM canonicalization is supported")
        end
      end

      def self.from_file(*, domain : String, selector : String, path : String,
                         headers : Array(String) = ["from", "to", "subject", "date", "message-id", "mime-version", "content-type"]) : DkimSettings
        new(domain, selector, File.read(path), headers)
      end
    end

    module Dkim
      def self.sign(mime : String, settings : DkimSettings) : String
        separator = mime.index("\r\n\r\n")
        raise ArgumentError.new("cannot DKIM-sign malformed MIME (no header/body separator)") unless separator
        header_block = mime[0...separator]
        body = mime[(separator + 4)..]

        headers = parse_headers(header_block)
        body_hash = Base64.strict_encode(Digest::SHA256.digest(canonical_body(body)))

        signed_names = settings.headers.map(&.downcase).select { |name| headers.any? { |h| h[0].downcase == name } }
        raise ArgumentError.new("cannot DKIM-sign mail without a From header") unless signed_names.includes?("from")

        dkim_value = "v=1; a=rsa-sha256; c=#{settings.canonicalization}; " \
                     "d=#{settings.domain}; s=#{settings.selector}; t=#{Time.utc.to_unix}; " \
                     "h=#{signed_names.join(":")}; bh=#{body_hash}; b="

        signing_headers = String.build do |io|
          signed_names.each do |name|
            raw = headers.find { |h| h[0].downcase == name }.not_nil![1]
            io << canonical_header(raw) << "\r\n"
          end
          io << canonical_header("DKIM-Signature: #{dkim_value}") << "\r\n"
        end

        signature = rsa_sha256(signing_headers, settings.private_key)
        final_value = dkim_value.sub(/b=$/, "b=#{signature}")
        "DKIM-Signature: #{final_value}\r\n" + mime
      end

      # Relaxed header canonicalization: lowercase name, unfold, collapse
      # whitespace, trim value.
      def self.canonical_header(raw : String) : String
        colon = raw.index(':') || raise ArgumentError.new("malformed header")
        name = raw[0...colon].strip.downcase
        value = raw[(colon + 1)..].gsub(/\r\n[ \t]+/, " ").gsub(/[ \t]+/, " ").strip
        "#{name}:#{value}"
      end

      # Relaxed body canonicalization (RFC 6376 §3.4.4).
      def self.canonical_body(body : String) : String
        lines = body.split("\r\n")
        while lines.last? == ""
          lines.pop
        end
        return "\r\n" if lines.empty?
        canonical = lines.map { |line| line.gsub(/[ \t]+/, " ").rstrip }.join("\r\n")
        canonical + "\r\n"
      end

      private def self.parse_headers(block : String) : Array({String, String})
        result = [] of {String, String}
        current : Array(String)? = nil
        block.split("\r\n").each do |line|
          if line.starts_with?(" ") || line.starts_with?("\t")
            current.try(&.<<(line))
          else
            if raw = current
              result << split_header(raw.join("\r\n"))
            end
            current = [line]
          end
        end
        if raw = current
          result << split_header(raw.join("\r\n"))
        end
        result
      end

      private def self.split_header(raw : String) : {String, String}
        colon = raw.index(':') || raise ArgumentError.new("malformed header")
        {raw[0...colon].strip, raw}
      end

      private def self.rsa_sha256(data : String, private_key_pem : String) : String
        bio = LibCrypto.bio_new_mem_buf(private_key_pem.to_unsafe, private_key_pem.bytesize)
        raise ArgumentError.new("could not allocate DKIM key buffer") if bio.null?
        pkey = LibCrypto.pem_read_bio_private_key(bio, nil, nil, nil)
        raise ArgumentError.new("could not parse DKIM RSA private key") if pkey.null?

        ctx = LibCrypto.evp_md_ctx_new
        raise ArgumentError.new("could not allocate DKIM signing context") if ctx.null?
        begin
          if LibCrypto.evp_digest_sign_init(ctx, nil, LibCrypto.evp_sha256, nil, pkey) != 1
            raise ArgumentError.new("DKIM RSA signing initialization failed")
          end
          bytes = data.to_slice
          if LibCrypto.evp_digest_sign_update(ctx, bytes, bytes.size) != 1
            raise ArgumentError.new("DKIM RSA signing failed")
          end
          length = LibC::SizeT.new(0)
          LibCrypto.evp_digest_sign_final(ctx, nil, pointerof(length))
          signature = Bytes.new(length.to_i)
          if LibCrypto.evp_digest_sign_final(ctx, signature, pointerof(length)) != 1
            raise ArgumentError.new("DKIM RSA signing failed")
          end
          Base64.strict_encode(signature[0, length.to_i])
        ensure
          LibCrypto.evp_md_ctx_free(ctx)
          LibCrypto.evp_pkey_free(pkey)
          LibCrypto.BIO_free(bio)
        end
      end
    end

    # Reopen the stdlib crypto bindings for the EVP public-key signing API
    # (Crystal 1.22 does not expose OpenSSL::PKey). Only the symbols needed by
    # DKIM are declared.
    @@dkim_settings : DkimSettings? = nil
    @@dkim_mutex = Mutex.new

    def self.dkim_settings : DkimSettings?
      @@dkim_mutex.synchronize { @@dkim_settings }
    end

    def self.dkim_settings=(settings : DkimSettings?) : Nil
      @@dkim_mutex.synchronize { @@dkim_settings = settings }
    end

    def self.dkim_enabled? : Bool
      !dkim_settings.nil?
    end
  end
end
