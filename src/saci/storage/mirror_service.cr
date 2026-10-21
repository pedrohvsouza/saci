module Saci
  module Storage
    # Writes each upload to a primary service and one or more mirrors;
    # reads always go to the primary.
    #
    # ```
    # primary = Saci::Storage::DiskService.new("/srv/files", name: "local")
    # backup = Saci::Storage::DiskService.new("/mnt/backup", name: "backup")
    # mirror = Saci::Storage::MirrorService.new(primary, backup)
    # Saci::Storage.register_service("local", mirror) # reads primary, writes both
    # ```
    #
    # Mirror failures propagate (the primary copy is removed best-effort
    # before re-raising) so callers never believe an upload is mirrored
    # when it is not. Deletes run on every service.
    class MirrorService < Service
      getter primary : Service
      getter mirrors : Array(Service)
      getter name : String

      def initialize(@primary : Service, mirrors : Array(Service) | Service, @name : String = "mirror")
        @mirrors = mirrors.as?(Array(Service)) || [mirrors.as(Service)]
        raise ArgumentError.new("MirrorService needs at least one mirror") if @mirrors.empty?
      end

      def upload(data : Bytes | IO | String, filename : String, content_type : String = "application/octet-stream", public : Bool? = nil, key : String? = nil) : String
        # Buffer once so the same bytes can be replayed to every service.
        bytes = Storage.read_upload(data)
        key = @primary.upload(bytes, filename: filename, content_type: content_type, public: public, key: key)
        begin
          @mirrors.each do |mirror|
            mirror.upload(bytes, filename: filename, content_type: content_type, public: public, key: key)
          end
        rescue ex
          @primary.delete(key) rescue nil
          raise ex
        end
        key
      end

      def download(key : String) : Bytes
        @primary.download(key)
      end

      def delete(key : String) : Nil
        first_error = nil
        ([@primary] + @mirrors).each do |service|
          begin
            service.delete(key)
          rescue ex
            first_error ||= ex
          end
        end
        raise first_error if first_error
      end

      def exists?(key : String) : Bool
        @primary.exists?(key)
      end

      def url(key : String, base : String = "/files", expires_in : Time::Span = 5.minutes) : String
        @primary.url(key, base: base, expires_in: expires_in)
      end

      def locate(key : String) : StoredFile?
        @primary.locate(key)
      end
    end

    # Convenience: write to `primary_name` and every name in `mirror_names`.
    #
    # The returned service is not registered globally; call
    # `Storage.register_service` if you want `Blob#service` to resolve it.
    def self.mirror_service(primary_name : String, mirror_names : Array(String) | String) : MirrorService
      names = mirror_names.is_a?(Array(String)) ? mirror_names : [mirror_names]
      MirrorService.new(service_named(primary_name), names.map { |name| service_named(name) })
    end
  end
end
