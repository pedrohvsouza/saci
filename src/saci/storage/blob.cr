require "../record"
require "../job"

module Saci
  module Storage
    # Persisted metadata for one uploaded file (ActiveStorage::Blob).
    #
    # ```
    # class CreateActiveStorageTables < Saci::Record::Migration
    #   def change
    #     create_table :active_storage_blobs do |t|
    #       t.string :key, null: false
    #       t.string :filename, null: false
    #       t.string :content_type, null: false
    #       t.bigint :byte_size, null: false
    #       t.string :checksum, null: false
    #       t.string :service_name, null: false
    #       t.json :metadata
    #       t.datetime :created_at
    #     end
    #   end
    # end
    # ```
    #
    # The bytes live in the configured service; this row is the stable
    # handle. `has_one_attached` / `has_many_attached` create blobs via
    # `Blob.create_and_upload!` and store an `Attachment` join row.
    class Blob < Saci::Record::Base
      table "active_storage_blobs"

      column id : Int64, primary: true
      column key : String
      column filename : String
      column content_type : String
      column byte_size : Int64
      column checksum : String
      column service_name : String
      column metadata : JSON
      column created_at : Time

      # `metadata` is stored as JSON text but exposed as a parsed hash
      # (Rails-compatible). `metadata_json` remains the raw accessor.
      def metadata : Hash(String, JSON::Any)
        raw = @metadata
        return {} of String => JSON::Any if raw.nil? || raw.strip.empty?
        JSON.parse(raw).as_h? || {} of String => JSON::Any
      rescue JSON::ParseException
        {} of String => JSON::Any
      end

      def metadata=(value : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
        @metadata = value.to_json
        value
      end

      def metadata=(value : Hash(String, String)) : Hash(String, String)
        @metadata = value.to_json
        value
      end

      def service_name : String
        @service_name || "local"
      end

      # The backend that holds this blob's bytes.
      def service : Service
        Storage.service_named(service_name)
      end

      def service=(value : Service) : Service
        @service_name = value.name
        value
      end

      # Pre-signed/expiring URL (public keys stay unsigned with the disk
      # service; S3 returns a SigV4 pre-signed URL).
      def url(base : String = "/files", expires_in : Time::Span = 5.minutes) : String
        current_key = key || raise InvalidUpload.new("blob #{id} has no key")
        service.url(current_key, base: base, expires_in: expires_in)
      end

      def download : Bytes
        current_key = key || raise InvalidUpload.new("blob #{id} has no key")
        service.download(current_key)
      end

      # Block form streams (buffered) through an `IO`:
      # `blob.open { |io| ... }`; the no-block form returns `IO::Memory`.
      def open(&block : IO -> T) : T forall T
        yield IO::Memory.new(download)
      end

      def open : IO::Memory
        IO::Memory.new(download)
      end

      def attachments : Array(Attachment)
        current_id = id
        return [] of Attachment if current_id.nil?
        Attachment.where(blob_id: current_id).order(:id).to_a
      end

      def attachment : Attachment?
        attachments.first?
      end

      def attached? : Bool
        !attachment.nil?
      end

      def signed_id : String
        Storage.signed_global_id(self)
      end

      def self.find_signed(signed_id : String) : Blob?
        record = Storage.resolve_signed_global_id(signed_id)
        record.is_a?(Blob) ? record : nil
      end

      # Optional `mirror:` services this blob was written to. Stored in
      # `metadata["mirror_services"]` so purge can clean every copy.
      def mirror_names : Array(String)
        raw = metadata["mirror_services"]?
        return [] of String unless raw
        raw.as_a?.try(&.compact_map(&.as_s?)) || [] of String
      end

      # Deletes the attachment rows, every stored copy and this row.
      def purge : Nil
        current_id = id
        if current_id
          Attachment.where(blob_id: current_id).to_a.each do |attachment|
            attachment.destroy
          end
        end
        if current_key = key
          begin
            service.delete(current_key)
          rescue ex : FileNotFound | NotConfigured
          end
          mirror_names.each do |mirror_name|
            begin
              Storage.service_named(mirror_name).delete(current_key)
            rescue ex : FileNotFound | NotConfigured
            end
          end
        end
        destroy unless new_record?
        nil
      end

      def purge_later : Nil
        if current_id = id
          PurgeJob.perform_later({"blob_id" => current_id})
        else
          purge
        end
        nil
      end

      # Purges only when no other attachment references this blob (called
      # after an attachment is removed/replaced).
      def purge_if_unattached : Nil
        current_id = id
        return if current_id.nil?
        return if Attachment.exists?(blob_id: current_id)
        purge
      end

      # Lazy derivative (see `Saci::Storage::Variant`). Without a processor
      # configured this is a documented pass-through to the original blob.
      #
      # ```
      # blob.variant(resize_to_limit: [300, 300]).url
      # ```
      def variant(*, resize_to_limit : Array(Int32) | Tuple(Int32, Int32) | Nil = nil,
                  resize_to_fill : Array(Int32) | Tuple(Int32, Int32) | Nil = nil,
                  resize_to_fit : Array(Int32) | Tuple(Int32, Int32) | Nil = nil,
                  **extra) : Variant
        extras = {} of String => String
        extra.each { |name, value| extras[name.to_s] = value.to_s }
        Variant.new(self, Variant::Transformations.new(
          resize_to_limit: resize_to_limit,
          resize_to_fill: resize_to_fill,
          resize_to_fit: resize_to_fit,
          extra: extras
        ))
      end

      # Previews (PDF/video first pages) have no bundled backend, like
      # variants. True only when an application processor is installed and
      # the blob is a previewable container.
      def previewable? : Bool
        return false unless Storage.variant_processor
        ct = content_type || ""
        ct == "application/pdf" || ct.starts_with?("video/")
      end

      # Documented preview extension point. With a processor this is a
      # variant tagged `preview=true`; without one it is the original blob
      # (pass-through — install a previewer to generate real thumbnails).
      def preview : Variant
        variant(preview: true)
      end

      # Pure-Crystal metadata analysis (PNG/GIF/JPEG/WebP dimensions).
      def analyze : Blob
        current_key = key || raise InvalidUpload.new("blob #{id} has no key")
        data = service.download(current_key)
        merged = metadata
        Analysis.analyze(data, content_type).each do |name, value|
          merged[name] = JSON::Any.new(value.to_i64)
        end
        self.metadata = merged
        update_columns(metadata: @metadata) unless new_record?
        self
      end

      def analyze_later : Nil
        if current_id = id
          AnalyzeJob.perform_later({"blob_id" => current_id})
        else
          analyze
        end
        nil
      end

      # Uploads `data`, computes checksum/size and persists the row.
      #
      # ```
      # blob = Saci::Storage::Blob.create_and_upload!(
      #   File.open("avatar.png"), filename: "avatar.png",
      #   content_type: "image/png"
      # )
      # post.avatar.attach(blob)
      # ```
      #
      # `mirrors:` uploads the same key to additional registered services
      # (see `MirrorService`); the primary is always read.
      def self.create_and_upload!(data : Bytes | IO | String,
                                  *,
                                  filename : String,
                                  content_type : String? = nil,
                                  service_name : String | Symbol | Nil = nil,
                                  mirrors : Array(String) | Array(Symbol) | String | Symbol | Nil = nil,
                                  key : String? = nil,
                                  identify : Bool = true,
                                  metadata : Hash(String, JSON::Any)? = nil) : Blob
        bytes = Storage.read_upload(data)
        safe_name = Storage.sanitize_filename(filename)
        resolved_type = content_type || Storage.content_type_for(safe_name, bytes)
        Storage.validate_upload!(bytes, resolved_type)

        resolved_service = (service_name || Storage.service.name).to_s
        primary = Storage.service_named(resolved_service)
        mirror_list = normalize_service_names(mirrors)
        mirror_services = mirror_list.map { |name| Storage.service_named(name) }

        generated_key = key || Storage.generate_key
        raise InvalidUpload.new("invalid storage key: #{generated_key.inspect}") unless Storage.valid_key?(generated_key)

        uploaded_mirrors = [] of Service
        begin
          stored_key = primary.upload(bytes, filename: safe_name, content_type: resolved_type, key: generated_key)
          mirror_services.each do |mirror|
            mirror.upload(bytes, filename: safe_name, content_type: resolved_type, key: stored_key)
            uploaded_mirrors << mirror
          end
        rescue ex
          primary.delete(generated_key) rescue nil
          uploaded_mirrors.each { |mirror| mirror.delete(generated_key) rescue nil }
          raise ex
        end

        merged = metadata ? metadata.dup : {} of String => JSON::Any
        if identify
          Analysis.analyze(bytes, resolved_type).each do |name, value|
            merged[name] = JSON::Any.new(value.to_i64)
          end
        end
        unless mirror_list.empty?
          merged["mirror_services"] = JSON::Any.new(mirror_list.map { |name| JSON::Any.new(name) })
        end

        blob = new(
          key: stored_key,
          filename: safe_name,
          content_type: resolved_type,
          byte_size: bytes.size.to_i64,
          checksum: SHA256.hexdigest(bytes),
          service_name: resolved_service,
          created_at: Time.utc
        )
        blob.metadata = merged
        begin
          blob.save!
        rescue ex
          primary.delete(stored_key) rescue nil
          uploaded_mirrors.each { |mirror| mirror.delete(stored_key) rescue nil }
          raise ex
        end
        blob
      end

      private def self.normalize_service_names(names : Array(String) | Array(Symbol) | String | Symbol | Nil) : Array(String)
        case names
        when Array(String) then names
        when Array(Symbol) then names.map(&.to_s)
        when String        then [names]
        when Symbol        then [names.to_s]
        else                    [] of String
        end
      end
    end
  end
end
