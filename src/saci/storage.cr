require "base64"
require "json"
require "openssl/hmac"
require "uri"

require "./storage/service"
require "./storage/sha256"
require "./storage/analysis"
require "./storage/variant"
require "./storage/mirror_service"
require "./storage/s3_service"

module Saci
  # ActiveStorage-style uploads with a pluggable service backend.
  #
  # The default is a local `DiskService` rooted at `storage/`. Models can
  # store the returned key in a plain string column and serve files with
  # `send_file` or the signed `FilesController` route below; the richer
  # `Blob` / `has_one_attached` API lives in `Saci::Storage::Blob` and
  # `Saci::Storage::Attached`.
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
  #
  # # named services (S3, mirrors, additional disks):
  # Saci::Storage.register_service("s3", Saci::Storage::S3Service.new(bucket: "b", ...))
  # Saci::Storage.service_named("s3").upload(data, filename: "a.bin")
  # ```
  module Storage
    # Key format: hex sharded over two levels (`ab/cd/<rest>`).
    # Public files live under a `public/` key prefix
    # (`public/ab/cd/<rest>`) and are served without a signature.
    KEY_RE        = /\A(public\/)?[0-9a-f\/]+\z/
    PUBLIC_PREFIX = "public/"

    # Content types that browsers may execute when served inline. Uploads
    # through `Blob`/direct uploads reject these by default; plain
    # `Storage.upload` remains a low-level escape hatch.
    UNSAFE_CONTENT_TYPES = %w(
      text/html application/xhtml+xml image/svg+xml
      application/javascript text/javascript application/x-javascript
      application/xml text/xml
    )

    def self.valid_key?(key : String) : Bool
      !key.empty? && KEY_RE.matches?(key) && !key.includes?("..")
    end

    def self.public_key?(key : String) : Bool
      key == "public" || key.starts_with?(PUBLIC_PREFIX)
    end

    @@service : Service? = nil
    @@services = {} of String => Service
    @@service_mutex = Mutex.new

    # The default service used by `Storage.upload`, `Blob` lookups with a
    # blank service name, and `FilesController`.
    def self.service : Service
      @@service_mutex.synchronize { ensure_default_service_locked }
    end

    def self.service=(service : Service) : Nil
      @@service_mutex.synchronize do
        @@services[service.name] = service
        @@service = service
      end
    end

    # Registers a backend by name without making it the default.
    def self.register_service(name : String, service : Service) : Nil
      @@service_mutex.synchronize { @@services[name] = service }
    end

    def self.service_named(name : String) : Service
      @@service_mutex.synchronize do
        ensure_default_service_locked
        @@services[name]? || raise NotConfigured.new(
          "storage service #{name.inspect} is not registered " \
          "(known: #{@@services.keys.sort.join(", ")})"
        )
      end
    end

    def self.services : Hash(String, Service)
      @@service_mutex.synchronize { @@services.dup }
    end

    # Uploads through the active service and returns the storage key.
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

    # Drops registered services (spec isolation). The next `service` call
    # lazily creates a fresh default disk service.
    def self.reset_services! : Nil
      @@service_mutex.synchronize do
        @@service = nil
        @@services.clear
      end
    end

    private def self.ensure_default_service_locked : Service
      @@service ||= begin
        disk = DiskService.new("storage")
        @@services[disk.name] = disk
        disk
      end
    end

    @@max_upload_size : Int64 = 100_i64 * 1024_i64 * 1024_i64
    @@block_unsafe_content_types : Bool = true

    # Global ceiling for `Blob`/direct uploads (default 100 MiB).
    def self.max_upload_size : Int64
      @@max_upload_size
    end

    def self.max_upload_size=(bytes : Int64) : Nil
      raise ArgumentError.new("max_upload_size must be positive") if bytes <= 0
      @@max_upload_size = bytes
    end

    def self.block_unsafe_content_types? : Bool
      @@block_unsafe_content_types
    end

    # Set false only when every upload is served with
    # `Content-Disposition: attachment` by an upstream proxy.
    def self.block_unsafe_content_types=(value : Bool) : Nil
      @@block_unsafe_content_types = value
    end

    @@variant_processor : Variant::Processor? = nil

    # Pluggable transformation backend used by `Blob#variant`. Without one
    # variants are pass-throughs to the original blob (documented).
    def self.variant_processor : Variant::Processor?
      @@variant_processor
    end

    def self.variant_processor=(processor : Variant::Processor?) : Nil
      @@variant_processor = processor
    end

    def self.dangerous_content_type?(content_type : String?) : Bool
      return false if content_type.nil?
      base = content_type.downcase.split(';', 2)[0].strip
      UNSAFE_CONTENT_TYPES.includes?(base)
    end

    # Buffers any supported upload input exactly once.
    def self.read_upload(data : Bytes | IO | String) : Bytes
      case data
      when Bytes  then data
      when String then data.to_slice
      when IO     then data.getb_to_end
      else             raise InvalidUpload.new("unsupported upload input: #{data.class}")
      end
    end

    # Enforces size/type policy before anything touches a service.
    def self.validate_upload!(bytes : Bytes, content_type : String?) : Nil
      if bytes.size.to_i64 > @@max_upload_size
        raise UploadTooLarge.new("upload is #{bytes.size} bytes; limit is #{@@max_upload_size}")
      end
      if @@block_unsafe_content_types && dangerous_content_type?(content_type)
        raise UnsafeContentType.new("refusing to store executable/inline content type #{content_type.inspect}")
      end
    end

    def self.generate_key(public : Bool = false) : String
      hex = Random::Secure.hex(16)
      shard = "#{hex[0, 2]}/#{hex[2, 2]}/#{hex[4..]}"
      public ? "#{PUBLIC_PREFIX}#{shard}" : shard
    end

    # Strips path components and control characters so metadata can never
    # inject a traversal or a CRLF into a response header.
    def self.sanitize_filename(filename : String) : String
      name = filename.gsub('\\', '/').split('/').last? || ""
      name = name.gsub(/[\x00-\x1f\x7f]/, "").strip
      name = "file" if name.empty? || name == "." || name == ".."
      if name.size > 200
        ext = File.extname(name)
        ext = "" if ext.size > 20
        name = name[0, 200 - ext.size] + ext
      end
      name
    end

    # Sniffs common signatures, then falls back to the file extension.
    def self.content_type_for(filename : String, bytes : Bytes = Bytes.empty) : String
      return "image/png" if png?(bytes)
      return "image/jpeg" if jpeg?(bytes)
      return "image/gif" if gif?(bytes)
      return "image/webp" if webp?(bytes)
      return "application/pdf" if bytes.size >= 5 && String.new(bytes[0, 5]) == "%PDF-"
      return "video/mp4" if bytes.size >= 12 && String.new(bytes[8, 4]) == "ftyp"
      return "audio/mpeg" if bytes.size >= 3 && String.new(bytes[0, 3]) == "ID3"
      return "audio/ogg" if bytes.size >= 4 && String.new(bytes[0, 4]) == "OggS"
      case File.extname(filename).downcase
      when ".png"          then "image/png"
      when ".jpg", ".jpeg" then "image/jpeg"
      when ".gif"          then "image/gif"
      when ".webp"         then "image/webp"
      when ".txt", ".md"   then "text/plain"
      when ".csv"          then "text/csv"
      when ".json"         then "application/json"
      when ".pdf"          then "application/pdf"
      when ".zip"          then "application/zip"
      when ".mp3"          then "audio/mpeg"
      when ".mp4"          then "video/mp4"
      when ".webm"         then "video/webm"
      else                      "application/octet-stream"
      end
    end

    private def self.png?(bytes : Bytes) : Bool
      return false if bytes.size < 8
      signature = [0x89_u8, 0x50_u8, 0x4e_u8, 0x47_u8, 0x0d_u8, 0x0a_u8, 0x1a_u8, 0x0a_u8]
      (0...8).all? { |i| bytes[i] == signature[i] }
    end

    private def self.jpeg?(bytes : Bytes) : Bool
      bytes.size >= 3 && bytes[0] == 0xff_u8 && bytes[1] == 0xd8_u8 && bytes[2] == 0xff_u8
    end

    private def self.gif?(bytes : Bytes) : Bool
      bytes.size >= 6 && (String.new(bytes[0, 6]) == "GIF87a" || String.new(bytes[0, 6]) == "GIF89a")
    end

    private def self.webp?(bytes : Bytes) : Bool
      bytes.size >= 12 && String.new(bytes[0, 4]) == "RIFF" && String.new(bytes[8, 4]) == "WEBP"
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

    def self.verification_keys : Array(String)
      @@signing_mutex.synchronize { @@signing_keys.try(&.dup) || [Secrets.secret_key_base] }
    end

    def self.signed_url(key : String, base : String = "/files", expires_in : Time::Span = 5.minutes, service_name : String? = nil) : String
      expires = Time.utc.to_unix + expires_in.total_seconds.to_i64
      payload = service_name ? "#{key}:#{expires}:#{service_name}" : "#{key}:#{expires}"
      sig = OpenSSL::HMAC.hexdigest(:sha256, verification_keys.first, payload)
      url = "#{base}/#{key}?expires=#{expires}&sig=#{sig}"
      url += "&service=#{URI.encode_www_form(service_name)}" if service_name
      url
    end

    def self.verified_url?(key : String, expires : Int64, sig : String, service_name : String? = nil) : Bool
      return false if Time.utc.to_unix > expires
      payload = service_name ? "#{key}:#{expires}:#{service_name}" : "#{key}:#{expires}"
      verification_keys.any? do |secret|
        expected = OpenSSL::HMAC.hexdigest(:sha256, secret, payload)
        Crypto::Subtle.constant_time_compare(expected, sig)
      end
    end

    # Stable unsigned URL for a public key (`public/...`). No expiry/sig.
    # `service_name` scopes the route to a named disk service.
    def self.public_url(key : String, base : String = "/files", service_name : String? = nil) : String
      url = "#{base}/#{key}"
      service_name ? "#{url}?service=#{URI.encode_www_form(service_name)}" : url
    end

    # URL for a key on a registered service (default: active service).
    def self.url(key : String, service_name : String? = nil, base : String = "/files", expires_in : Time::Span = 5.minutes) : String
      service_name ? service_named(service_name).url(key, base: base, expires_in: expires_in) : service.url(key, base: base, expires_in: expires_in)
    end

    # Generic signed token: `base64url(purpose + "\n" + data).expires.sig`.
    # `expires_in: nil` creates a non-expiring token (signed ids).
    def self.sign_message(purpose : String, data : String, expires_in : Time::Span? = 30.days) : String
      expires = expires_in ? Time.utc.to_unix + expires_in.total_seconds.to_i64 : 0_i64
      encoded = Base64.urlsafe_encode("#{purpose}\n#{data}", false)
      sig = OpenSSL::HMAC.hexdigest(:sha256, signing_keys.first, "#{encoded}.#{expires}")
      "#{encoded}.#{expires}.#{sig}"
    end

    # Returns the embedded data, or nil when the token is malformed,
    # expired, or signed with an unknown key.
    def self.verify_message(purpose : String, token : String) : String?
      parts = token.split('.')
      return nil unless parts.size == 3
      encoded, raw_expires, sig = parts
      expires = raw_expires.to_i64?
      return nil unless expires
      return nil if expires != 0 && Time.utc.to_unix > expires

      verified = verification_keys.any? do |key|
        expected = OpenSSL::HMAC.hexdigest(:sha256, key, "#{encoded}.#{expires}")
        Crypto::Subtle.constant_time_compare(expected, sig)
      end
      return nil unless verified

      payload = String.new(Base64.decode(encoded))
      prefix = "#{purpose}\n"
      return nil unless payload.starts_with?(prefix)
      payload[prefix.size..]
    rescue
      nil
    end

    # Signed global id (`sgid`) for any persisted record. Used by Action
    # Text attachments and direct-upload forms; never expose raw ids when
    # the id alone would let a user probe other records.
    def self.signed_global_id(record : Saci::Record::Base) : String
      pk = record.__saci_get_attr(record.class.__saci_primary_key)
      raise InvalidUpload.new("cannot sign an unsaved #{record.class}") if pk.nil?
      sign_message("sgid", "#{record.class.name}\u0001#{pk}", expires_in: nil)
    end

    # Resolves a signed global id to its record, or nil when the token is
    # invalid/expired or the row has been deleted.
    def self.resolve_signed_global_id(token : String) : Saci::Record::Base?
      data = verify_message("sgid", token)
      return nil unless data
      type, separator, id = data.partition('\u0001')
      return nil if separator.empty? || type.empty? || id.empty?
      value = id.to_i64? || id
      Saci::Record.resolve_polymorphic(type, value)
    rescue Saci::Record::RecordNotFound
      nil
    end

    class DiskService < Service
      getter root : String
      getter public_mode : Bool
      getter name : String

      # Per-service default for public files; each `upload` can override
      # with `public: true/false` (nil inherits the service default).
      def initialize(@root : String = "storage", public public_mode : Bool = false, @name : String = "local")
        @public_mode = public_mode
      end

      def public_mode? : Bool
        @public_mode
      end

      def upload(data : Bytes | IO | String, filename : String, content_type : String = "application/octet-stream", public : Bool? = nil, key : String? = nil) : String
        is_public = public.nil? ? @public_mode : public
        key ||= Storage.generate_key(is_public)
        assert_key!(key)
        path = file_path(key)
        Dir.mkdir_p(File.dirname(path))
        case data
        when IO     then File.open(path, "wb") { |file| IO.copy(data, file) }
        when Bytes  then File.write(path, data)
        when String then File.write(path, data)
        end
        safe_name = Storage.sanitize_filename(filename)
        meta = {"filename" => safe_name, "content_type" => content_type, "size" => File.size(path).to_s}
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
        return nil unless Storage.valid_key?(key)
        path = file_path(key)
        return nil unless File.exists?(path)
        filename = File.basename(key)
        content_type = "application/octet-stream"
        if File.exists?("#{path}.meta")
          begin
            meta = JSON.parse(File.read("#{path}.meta")).as_h
            filename = meta["filename"]?.try(&.as_s?) || filename
            content_type = meta["content_type"]?.try(&.as_s?) || content_type
          rescue JSON::ParseException
            # Corrupt sidecar: fall back to key-derived metadata.
          end
        end
        StoredFile.new(path, filename, content_type)
      end

      def delete(key : String) : Nil
        assert_key!(key)
        path = file_path(key)
        File.delete(path) if File.exists?(path)
        File.delete("#{path}.meta") if File.exists?("#{path}.meta")
      end

      def exists?(key : String) : Bool
        return false unless Storage.valid_key?(key)
        File.exists?(file_path(key))
      end

      # Stable unsigned URL for a public key under this service. Named
      # services add `?service=` so `FilesController` can resolve them.
      def public_url(key : String, base : String = "/files") : String
        Storage.public_url(key, base: base, service_name: route_service_name)
      end

      def url(key : String, base : String = "/files", expires_in : Time::Span = 5.minutes) : String
        if Storage.public_key?(key)
          public_url(key, base: base)
        else
          Storage.signed_url(key, base: base, expires_in: expires_in, service_name: route_service_name)
        end
      end

      # The default `"local"` service needs no query parameter (keeps
      # existing URLs short/backwards-compatible).
      private def route_service_name : String?
        @name == "local" ? nil : @name
      end

      private def file_path(key : String) : String
        File.join(@root, key)
      end

      private def assert_key!(key : String) : Nil
        raise FileNotFound.new("invalid key: #{key.inspect}") unless Storage.valid_key?(key)
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
        service_name = params["service"]?
        service = begin
          service_name ? Storage.service_named(service_name) : Storage.service
        rescue Storage::NotConfigured
          head :not_found
          return
        end
        unless Storage.public_key?(key)
          expires = params["expires"]?.try(&.to_i64?)
          sig = params["sig"]?
          unless expires && sig && Storage.verified_url?(key, expires, sig, service_name)
            head :not_found
            return
          end
        end
        if stored = service.locate(key)
          disposition = Storage.dangerous_content_type?(stored.content_type) ? "attachment" : "inline"
          send_file(stored.path, filename: stored.filename, content_type: stored.content_type, disposition: disposition)
        else
          head :not_found
        end
      end
    end
  end
end

require "./storage/blob"
require "./storage/attachment"
require "./storage/attachments"
require "./storage/direct_upload"
