require "../params"
require "./attachment"

module Saci
  module Storage
    # Proxies returned by `has_one_attached` / `has_many_attached`.
    # They are lightweight views over `Attachment` rows, created on every
    # call (like Rails' attached proxies).
    module Attached
      abstract class Base
        getter record : Saci::Record::Base
        getter name : String
        getter service_name : String?
        getter mirror_names : Array(String)

        def initialize(@record : Saci::Record::Base, @name : String,
                       service_name : String | Symbol | Nil = nil,
                       mirror_names : Array(String) | Array(Symbol) | String | Symbol | Nil = nil)
          @service_name = service_name.try(&.to_s)
          @mirror_names = case mirror_names
                          when Array(String) then mirror_names
                          when Array(Symbol) then mirror_names.map(&.to_s)
                          when String        then [mirror_names]
                          when Symbol        then [mirror_names.to_s]
                          else                    [] of String
                          end
        end

        protected def effective_service_name : String
          @service_name || Saci::Storage.service.name
        end
      end

      # `post.avatar` for `has_one_attached :avatar`.
      class One < Base
        @attachment : Attachment? = nil
        @loaded : Bool = false

        # Current join row, or nil when nothing is attached.
        def attachment : Attachment?
          return @attachment if @loaded
          @loaded = true
          @attachment = Attachment.find_for(@record, @name)
        end

        def attached? : Bool
          !attachment.nil?
        end

        def blob : Blob?
          attachment.try(&.blob)
        end

        # Attaches an existing blob, replacing any previous attachment
        # (the old blob is purged when no other attachment uses it).
        def attach(blob : Blob) : Attachment
          replace_with(blob)
        end

        def attach(attachment : Attachment) : Attachment
          replace_with(attachment.blob || raise InvalidUpload.new("attachment #{attachment.id} has no blob"))
        end

        # `post.avatar.attach(file.bytes, filename: file.filename, content_type: file.content_type)`
        def attach(data : Bytes | IO | String, *, filename : String, content_type : String? = nil) : Attachment
          blob = Blob.create_and_upload!(
            data,
            filename: filename,
            content_type: content_type,
            service_name: effective_service_name,
            mirrors: @mirror_names
          )
          replace_with(blob)
        end

        def attach(file : Saci::Params::UploadedFile) : Attachment
          blob = Blob.create_and_upload!(
            file.bytes,
            filename: file.filename,
            content_type: file.content_type,
            service_name: effective_service_name,
            mirrors: @mirror_names
          )
          replace_with(blob)
        end

        # Attaches a blob referenced by a signed direct-upload id.
        def attach_signed(signed_id : String) : Attachment
          blob = Blob.find_signed(signed_id) || raise InvalidUpload.new("invalid or expired blob signed id")
          attach(blob)
        end

        def purge : Nil
          attachment.try(&.purge)
          @attachment = nil
          @loaded = true
          nil
        end

        def purge_later : Nil
          attachment.try(&.purge_later)
          @attachment = nil
          @loaded = true
          nil
        end

        def url(base : String = "/files", expires_in : Time::Span = 5.minutes) : String?
          blob.try(&.url(base: base, expires_in: expires_in))
        end

        def download : Bytes?
          blob.try(&.download)
        end

        def open(&block : IO -> T) : T forall T
          current = blob || raise FileNotFound.new("#{@record.class}##{@name} has no attached file")
          current.open { |io| yield io }
        end

        def filename : String?
          blob.try(&.filename)
        end

        def content_type : String?
          blob.try(&.content_type)
        end

        def byte_size : Int64?
          blob.try(&.byte_size)
        end

        def checksum : String?
          blob.try(&.checksum)
        end

        def metadata : Hash(String, JSON::Any)?
          blob.try(&.metadata)
        end

        def signed_id : String?
          blob.try(&.signed_id)
        end

        def variant(*, resize_to_limit : Array(Int32) | Tuple(Int32, Int32) | Nil = nil,
                    resize_to_fill : Array(Int32) | Tuple(Int32, Int32) | Nil = nil,
                    resize_to_fit : Array(Int32) | Tuple(Int32, Int32) | Nil = nil,
                    **extra) : Variant?
          current = blob
          return nil unless current
          current.variant(
            **extra,
            resize_to_limit: resize_to_limit,
            resize_to_fill: resize_to_fill,
            resize_to_fit: resize_to_fit
          )
        end

        private def replace_with(blob : Blob) : Attachment
          previous = attachment
          created = begin
            Attachment.attach(@record, @name, blob)
          rescue ex
            blob.purge_if_unattached rescue nil
            raise ex
          end
          @attachment = created
          @loaded = true
          previous.try(&.purge) if previous && previous.id != created.id
          created
        end
      end

      # `post.documents` for `has_many_attached :documents`.
      class Many < Base
        @attachments : Array(Attachment)? = nil

        def attachments : Array(Attachment)
          @attachments ||= Attachment.all_for(@record, @name)
        end

        def blobs : Array(Blob)
          attachments.compact_map(&.blob)
        end

        def attached? : Bool
          !attachments.empty?
        end

        def empty? : Bool
          attachments.empty?
        end

        def size : Int32
          attachments.size
        end

        def each(&block : Attachment ->) : Nil
          attachments.each { |attachment| yield attachment }
        end

        def first : Attachment?
          attachments.first?
        end

        def last : Attachment?
          attachments.last?
        end

        def attach(blob : Blob) : Attachment
          created = begin
            Attachment.attach(@record, @name, blob)
          rescue ex
            blob.purge_if_unattached rescue nil
            raise ex
          end
          attachments << created
          created
        end

        def attach(blobs : Array(Blob)) : Array(Attachment)
          blobs.map { |blob| attach(blob) }
        end

        def attach(data : Bytes | IO | String, *, filename : String, content_type : String? = nil) : Attachment
          blob = Blob.create_and_upload!(
            data,
            filename: filename,
            content_type: content_type,
            service_name: effective_service_name,
            mirrors: @mirror_names
          )
          attach(blob)
        end

        def attach(file : Saci::Params::UploadedFile) : Attachment
          blob = Blob.create_and_upload!(
            file.bytes,
            filename: file.filename,
            content_type: file.content_type,
            service_name: effective_service_name,
            mirrors: @mirror_names
          )
          attach(blob)
        end

        def attach_signed(signed_id : String) : Attachment
          blob = Blob.find_signed(signed_id) || raise InvalidUpload.new("invalid or expired blob signed id")
          attach(blob)
        end

        def purge : Nil
          attachments.each(&.purge)
          @attachments = [] of Attachment
          nil
        end

        def purge_later : Nil
          attachments.each(&.purge_later)
          @attachments = [] of Attachment
          nil
        end

        def url(base : String = "/files", expires_in : Time::Span = 5.minutes) : String?
          blobs.first?.try(&.url(base: base, expires_in: expires_in))
        end

        def download : Bytes?
          blobs.first?.try(&.download)
        end

        def filename : String?
          blobs.first?.try(&.filename)
        end

        def content_type : String?
          blobs.first?.try(&.content_type)
        end

        def byte_size : Int64?
          blobs.first?.try(&.byte_size)
        end

        def checksum : String?
          blobs.first?.try(&.checksum)
        end

        def metadata : Hash(String, JSON::Any)?
          blobs.first?.try(&.metadata)
        end

        def variant(*, resize_to_limit : Array(Int32) | Tuple(Int32, Int32) | Nil = nil,
                    resize_to_fill : Array(Int32) | Tuple(Int32, Int32) | Nil = nil,
                    resize_to_fit : Array(Int32) | Tuple(Int32, Int32) | Nil = nil,
                    **extra) : Variant?
          current = blobs.first?
          return nil unless current
          current.variant(
            **extra,
            resize_to_limit: resize_to_limit,
            resize_to_fill: resize_to_fill,
            resize_to_fit: resize_to_fit
          )
        end
      end
    end
  end

  class Record::Base
    # Declares a single attached file backed by `Storage::Attachment` /
    # `Storage::Blob` rows:
    #
    # ```
    # class User < Saci::Record::Base
    #   column id : Int64, primary: true
    #   has_one_attached :avatar
    # end
    #
    # user.avatar.attach(io, filename: "me.png")
    # user.avatar.attached? # => true
    # user.avatar.url       # signed /files/... URL
    # user.avatar.purge_later
    # ```
    #
    # `service:` selects a registered service; `mirror:` writes the same
    # key to additional registered services (reads stay on the primary).
    macro has_one_attached(name, service = nil, mirror = nil)
      def {{name.id}} : Saci::Storage::Attached::One
        Saci::Storage::Attached::One.new(
          self,
          {{name.id.stringify}},
          service_name: {% if service %}{{ service }}{% else %}nil{% end %},
          mirror_names: {% if mirror %}{% if mirror.is_a?(ArrayLiteral) %}{{ mirror }}{% else %}[{{ mirror }}]{% end %}{% else %}[] of String{% end %}
        )
      end

      def {{name.id}}=(value : Saci::Storage::Blob) : Saci::Storage::Blob
        {{name.id}}.attach(value)
        value
      end

      def {{name.id}}=(value : Saci::Storage::Attachment) : Saci::Storage::Attachment
        {{name.id}}.attach(value)
        value
      end

      def {{name.id}}=(value : Saci::Params::UploadedFile) : Saci::Params::UploadedFile
        {{name.id}}.attach(value)
        value
      end

      # Rails-compatible convenience readers.
      def {{name.id}}_attachment : Saci::Storage::Attachment?
        {{name.id}}.attachment
      end

      def {{name.id}}_blob : Saci::Storage::Blob?
        {{name.id}}.blob
      end

      def {{name.id}}_attached? : Bool
        {{name.id}}.attached?
      end
    end

    # Declares multiple attached files:
    #
    # ```
    # class Message < Saci::Record::Base
    #   column id : Int64, primary: true
    #   has_many_attached :documents
    # end
    #
    # message.documents.attach(io, filename: "a.pdf", content_type: "application/pdf")
    # message.documents.attachments # => [Storage::Attachment]
    # ```
    macro has_many_attached(name, service = nil, mirror = nil)
      def {{name.id}} : Saci::Storage::Attached::Many
        Saci::Storage::Attached::Many.new(
          self,
          {{name.id.stringify}},
          service_name: {% if service %}{{ service }}{% else %}nil{% end %},
          mirror_names: {% if mirror %}{% if mirror.is_a?(ArrayLiteral) %}{{ mirror }}{% else %}[{{ mirror }}]{% end %}{% else %}[] of String{% end %}
        )
      end

      def {{name.id}}=(values : Array(Saci::Storage::Blob)) : Array(Saci::Storage::Blob)
        {{name.id}}.attach(values)
        values
      end

      def {{name.id}}_attachments : Array(Saci::Storage::Attachment)
        {{name.id}}.attachments
      end

      def {{name.id}}_blobs : Array(Saci::Storage::Blob)
        {{name.id}}.blobs
      end

      def {{name.id}}_attached? : Bool
        {{name.id}}.attached?
      end
    end
  end
end

require "./jobs"
