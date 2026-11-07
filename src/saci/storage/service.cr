module Saci
  module Storage
    class Error < Exception
    end

    # Raised when a key is malformed or the backing file is missing.
    class FileNotFound < Error
    end

    # Raised when a service is selected but not registered/configured.
    class NotConfigured < Error
    end

    # Raised when an upload exceeds `Storage.max_upload_size`.
    class UploadTooLarge < Error
    end

    # Raised when an upload's content type is on the unsafe inline list.
    class UnsafeContentType < Error
    end

    # Catch-all for malformed uploads (bad key, empty filename, ...).
    class InvalidUpload < Error
    end

    # A file stored by a `Service`, with the metadata needed to stream it
    # from a local disk (`FilesController`).
    struct StoredFile
      getter path : String
      getter filename : String
      getter content_type : String

      def initialize(@path : String, @filename : String, @content_type : String)
      end
    end

    # Common interface for every storage backend (ActiveStorage::Service
    # equivalent).
    #
    # Implementations are registered by name:
    #
    # ```
    # Saci::Storage.register_service("backup", Saci::Storage::DiskService.new("/mnt/backup", name: "backup"))
    # Saci::Storage.register_service("s3", Saci::Storage::S3Service.new(bucket: "my-bucket", ...))
    # ```
    #
    # `upload` takes an optional pre-generated `key:` so mirroring,
    # direct uploads and derivative variants can write the same key to more
    # than one backend. When omitted the service generates one.
    abstract class Service
      # Registry name (`"local"`, `"s3"`, ...). `Blob#service_name` stores it.
      abstract def name : String

      abstract def upload(data : Bytes | IO | String, filename : String, content_type : String = "application/octet-stream", public : Bool? = nil, key : String? = nil) : String

      abstract def download(key : String) : Bytes

      abstract def delete(key : String) : Nil

      abstract def exists?(key : String) : Bool

      # URL clients can fetch. Disk services return a signed `/files/...`
      # route; object stores may return a pre-signed upstream URL.
      abstract def url(key : String, base : String = "/files", expires_in : Time::Span = 5.minutes) : String

      # Local path + metadata for `FilesController`. Backends without local
      # files (S3) return nil and rely on `#url`.
      abstract def locate(key : String) : StoredFile?
    end
  end
end
