require "openssl/hmac"

module Saci
  # ActiveStorage-style uploads (disk service). Models store the returned key
  # in a plain string column; serve files with `send_file` or the signed
  # `FilesController` route below.
  #
  # ```
  # key = Saci::Storage.upload(File.read("pic.png"), filename: "pic.png", content_type: "image/png")
  # # ... store key on your record ...
  # Saci::Storage.download(key) # => Bytes
  #
  # # routes:
  # r.get "/files/*key", Saci::Storage::FilesController, :show
  # Saci::Storage.signed_url(key) # => "/files/ab/cd/…?expires=…&sig=…"
  # Saci::Storage.rotate_signing_key!("new-secret") # old URLs verify till expiry
  # pub = Saci::Storage.upload(data, filename: "a.png", public: true)
  # Saci::Storage.public_url(pub) # => "/files/public/ab/cd/…" (unsigned)
  # ```
  module Storage
    class FileNotFound < Exception
    end

    # Key format: hex sharded over two levels (`ab/cd/<rest>`).
    # Public files live under a `public/` key prefix
    # (`public/ab/cd/<rest>`) and are served without a signature.
    KEY_RE = /\A(public\/)?[0-9a-f\/]+\z/
    PUBLIC_PREFIX = "public/"

    def self.valid_key?(key : String) : Bool
      !key.empty? && KEY_RE.matches?(key) && !key.includes?("..")
    end

    # True for keys under the public prefix (`public/...`).
    def self.public_key?(key : String) : Bool
      key == "public" || key.starts_with?(PUBLIC_PREFIX)
    end

    @@service : DiskService? = nil
    @@service_mutex = Mutex.new

    def self.service : DiskService
      @@service_mutex.synchronize { @@service ||= DiskService.new("storage") }
    end

    def self.service=(service : DiskService) : Nil
      @@service_mutex.synchronize { @@service = service }
    end

    def self.upload(data : Bytes | IO | String, filename : String, content_type : String = "application/octet-stream", public : Bool? = nil) : String
      service.upload(data, filename: filename, content_type: content_type, public: public)
    end

    def self.download(key : String) : Bytes
      service.download(key)
    end

    def self.delete(key : String) : Nil
      service.delete(key)
    end

    def self.exists?(key : String) : Bool
      service.exists?(key)
    end

    # Signing keys for expiring URLs. `keys.first` signs new URLs;
    # every entry verifies old ones, so rotation never invalidates
    # in-flight URLs before their natural `expires` (grace = natural
    # expiry, no separate window to configure). Defaults to
    # `[Secrets.secret_key_base]` when unset.
    @@signing_keys : Array(String)? = nil
    @@signing_mutex = Mutex.new

    def self.signing_keys : Array(String)
      @@signing_mutex.synchronize { @@signing_keys.try(&.dup) || [Secrets.secret_key_base] }
    end

    def self.signing_keys=(keys : Array(String)) : Nil
      raise ArgumentError.new("signing_keys needs at least one key") if keys.empty?
      @@signing_mutex.synchronize { @@signing_keys = keys.dup }
    end

    # Rotate to `new_secret`: new URLs sign with it, URLs signed with any
    # previous primary still verify until their natural expiry.
    # Unknown keys never verify.
    def self.rotate_signing_key!(new_secret : String) : Nil
      @@signing_mutex.synchronize do
        current = @@signing_keys.try(&.dup) || [Secrets.secret_key_base]
        @@signing_keys = [new_secret] + current
      end
    end

    # Drop any rotation overrides (spec isolation).
    def self.reset_signing_keys! : Nil
      @@signing_mutex.synchronize { @@signing_keys = nil }
    end

    private def self.verification_keys : Array(String)
      @@signing_mutex.synchronize { @@signing_keys.try(&.dup) || [Secrets.secret_key_base] }
    end

    def self.signed_url(key : String, base : String = "/files", expires_in : Time::Span = 5.minutes) : String
      expires = Time.utc.to_unix + expires_in.total_seconds.to_i64
      sig = OpenSSL::HMAC.hexdigest(:sha256, verification_keys.first, "#{key}:#{expires}")
      "#{base}/#{key}?expires=#{expires}&sig=#{sig}"
    end

    def self.verified_url?(key : String, expires : Int64, sig : String) : Bool
      return false if Time.utc.to_unix > expires
      verification_keys.any? do |secret|
        expected = OpenSSL::HMAC.hexdigest(:sha256, secret, "#{key}:#{expires}")
        Crypto::Subtle.constant_time_compare(expected, sig)
      end
    end

    # Stable unsigned URL for a public key (`public/...`). No expiry/sig.
    def self.public_url(key : String, base : String = "/files") : String
      "#{base}/#{key}"
    end

    struct StoredFile
      getter path : String
      getter filename : String
      getter content_type : String

      def initialize(@path : String, @filename : String, @content_type : String)
      end
    end

    class DiskService
      getter root : String
      getter public_mode : Bool

      # Per-service default for public files; each `upload` can override
      # with `public: true/false` (nil inherits the service default).
      def initialize(@root : String = "storage", public public_mode : Bool = false)
        @public_mode = public_mode
      end

      def public_mode? : Bool
        @public_mode
      end

      def upload(data : Bytes | IO | String, filename : String, content_type : String = "application/octet-stream", public : Bool? = nil) : String
        is_public = public.nil? ? @public_mode : public
        hex = Random::Secure.hex(16)
        shard = "#{hex[0, 2]}/#{hex[2, 2]}/#{hex[4..]}"
        key = is_public ? "#{PUBLIC_PREFIX}#{shard}" : shard
        path = file_path(key)
        Dir.mkdir_p(File.dirname(path))
        case data
        when IO     then File.open(path, "wb") { |f| IO.copy(data, f) }
        when Bytes  then File.write(path, data)
        when String then File.write(path, data)
        end
        meta = {"filename" => filename, "content_type" => content_type, "size" => File.size(path).to_s}
        File.write("#{path}.meta", meta.to_json)
        key
      end

      def download(key : String) : Bytes
        assert_key!(key)
        path = file_path(key)
        raise FileNotFound.new("no such file: #{key}") unless File.exists?(path)
        File.open(path, "rb", &.getb_to_end)
      end

      def locate(key : String) : StoredFile?
        assert_key!(key)
        path = file_path(key)
        return nil unless File.exists?(path)
        filename = File.basename(key)
        content_type = "application/octet-stream"
        if File.exists?("#{path}.meta")
          meta = JSON.parse(File.read("#{path}.meta")).as_h
          filename = meta["filename"]?.try(&.as_s?) || filename
          content_type = meta["content_type"]?.try(&.as_s?) || content_type
        end
        StoredFile.new(path, filename, content_type)
      end

      def delete(key : String) : Nil
        assert_key!(key)
        File.delete(file_path(key)) if File.exists?(file_path(key))
        File.delete("#{file_path(key)}.meta") if File.exists?("#{file_path(key)}.meta")
      end

      def exists?(key : String) : Bool
        return false unless valid_key?(key)
        File.exists?(file_path(key))
      end

      # Stable unsigned URL for a public key under this service.
      def public_url(key : String, base : String = "/files") : String
        Storage.public_url(key, base: base)
      end

      private def file_path(key : String) : String
        File.join(@root, key)
      end

      private def assert_key!(key : String) : Nil
        raise FileNotFound.new("invalid key: #{key.inspect}") unless Storage.valid_key?(key)
      end

      private def valid_key?(key : String) : Bool
        Storage.valid_key?(key)
      end
    end

    # Mount in your router to serve uploads (see `Storage.signed_url`).
    # Private keys need an expiring signature; public keys (`public/...`,
    # see `DiskService#public_mode`) are served unsigned. No directory
    # listing is ever served — unknown/missing keys are 404.
    #
    # ```
    # r.get "/files/*key", Saci::Storage::FilesController, :show
    # ```
    class FilesController < Controller
      def show
        key = params["key"]?
        unless key && Storage.valid_key?(key)
          head :not_found
          return
        end
        unless Storage.public_key?(key)
          expires = params["expires"]?.try(&.to_i64?)
          sig = params["sig"]?
          unless expires && sig && Storage.verified_url?(key, expires, sig)
            head :not_found
            return
          end
        end
        if stored = Storage.service.locate(key)
          send_file(stored.path, filename: stored.filename, content_type: stored.content_type, disposition: "inline")
        else
          head :not_found
        end
      end
    end
  end
end
