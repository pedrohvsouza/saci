module Saci
  module Storage
    # Lazy image transformation handle returned by `Blob#variant`.
    #
    # Without a processor the variant is a pass-through: `#url` and
    # `#download` return the original blob unchanged. Install one of the
    # bundled processors (see `Saci::Storage::Processors`) or your own:
    #
    # ```
    # Saci::Storage.variant_processor = Saci::Storage::Processors::Vips.new
    # post.avatar.variant(resize_to_limit: [300, 300]).url
    #
    # class MyProcessor < Saci::Storage::Variant::Processor
    #   def process(data : Bytes, transformations : Saci::Storage::Variant::Transformations,
    #               content_type : String) : Bytes
    #     # call a binding or a service
    #   end
    # end
    # ```
    #
    # The first request for a variant processes the original and stores
    # the result as a blob under a key derived from the original's key
    # and the transformations. Later requests, from any process, find that
    # blob and reuse it. `Blob#purge` deletes the variants with the
    # original.
    class Variant
      # `format:` values and the content types they produce.
      FORMATS = {
        "png"  => "image/png",
        "jpeg" => "image/jpeg",
        "jpg"  => "image/jpeg",
        "gif"  => "image/gif",
        "webp" => "image/webp",
        "avif" => "image/avif",
      }

      # File extensions for variant filenames.
      EXTENSIONS = {
        "image/png"  => ".png",
        "image/jpeg" => ".jpg",
        "image/gif"  => ".gif",
        "image/webp" => ".webp",
        "image/avif" => ".avif",
      }

      # Content type of a variant of a `content_type` original: the
      # `format:` option's type, PNG for a preview of a non-image, or the
      # original's type.
      def self.output_content_type(content_type : String, transformations : Transformations) : String
        if format = transformations.extra["format"]?
          FORMATS[format.downcase]? || raise ArgumentError.new("unsupported variant format #{format.inspect} (supported: #{FORMATS.keys.join(", ")})")
        elsif transformations.preview? && !content_type.starts_with?("image/")
          "image/png"
        else
          content_type
        end
      end

      class Transformations
        getter resize_to_limit : Tuple(Int32, Int32)?
        getter resize_to_fill : Tuple(Int32, Int32)?
        getter resize_to_fit : Tuple(Int32, Int32)?
        getter extra : Hash(String, String)

        def initialize(*, resize_to_limit : Array(Int32) | Tuple(Int32, Int32) | Nil = nil,
                       resize_to_fill : Array(Int32) | Tuple(Int32, Int32) | Nil = nil,
                       resize_to_fit : Array(Int32) | Tuple(Int32, Int32) | Nil = nil,
                       extra : Hash(String, String) = {} of String => String)
          @resize_to_limit = normalize(resize_to_limit)
          @resize_to_fill = normalize(resize_to_fill)
          @resize_to_fit = normalize(resize_to_fit)
          @extra = extra
        end

        def empty? : Bool
          @resize_to_limit.nil? && @resize_to_fill.nil? && @resize_to_fit.nil? && @extra.empty?
        end

        # True for `Blob#preview` (a first page or frame as an image).
        def preview? : Bool
          @extra["preview"]? == "true"
        end

        # True when anything besides `preview` is requested.
        def image_changes? : Bool
          !(@resize_to_limit.nil? && @resize_to_fill.nil? && @resize_to_fit.nil?) || @extra.keys.any? { |name| name != "preview" }
        end

        def to_h : Hash(String, String)
          result = @extra.dup
          if limit = @resize_to_limit
            result["resize_to_limit"] = "#{limit[0]}x#{limit[1]}"
          end
          if fill = @resize_to_fill
            result["resize_to_fill"] = "#{fill[0]}x#{fill[1]}"
          end
          if fit = @resize_to_fit
            result["resize_to_fit"] = "#{fit[0]}x#{fit[1]}"
          end
          result
        end

        def cache_key : String
          parts = [] of String
          if limit = @resize_to_limit
            parts << "limit-#{limit[0]}x#{limit[1]}"
          end
          if fill = @resize_to_fill
            parts << "fill-#{fill[0]}x#{fill[1]}"
          end
          if fit = @resize_to_fit
            parts << "fit-#{fit[0]}x#{fit[1]}"
          end
          @extra.keys.sort.each { |k| parts << "#{k}-#{@extra[k]}" }
          parts.empty? ? "original" : parts.join("_")
        end

        private def normalize(value : Array(Int32) | Tuple(Int32, Int32) | Nil) : Tuple(Int32, Int32)?
          case value
          when Array(Int32)
            return nil unless value.size == 2
            {value[0], value[1]}
          when Tuple(Int32, Int32)
            value
          else
            nil
          end
        end
      end

      # Pluggable transformation backend. `process` returns encoded image
      # bytes of `output_content_type`: the input's format unless the
      # transformations ask for another (`format:`, or PNG for a preview).
      abstract class Processor
        abstract def process(data : Bytes, transformations : Transformations, content_type : String) : Bytes

        # Content type of what `process` returns.
        def output_content_type(content_type : String, transformations : Transformations) : String
          Variant.output_content_type(content_type, transformations)
        end

        # Whether `Blob#variant` can transform a blob of this type.
        def variable?(content_type : String) : Bool
          content_type.starts_with?("image/")
        end

        # Whether `Blob#preview` can render a blob of this type.
        def previewable?(content_type : String) : Bool
          content_type == "application/pdf" || content_type.starts_with?("video/")
        end
      end

      getter blob : Blob
      getter transformations : Transformations

      @processed_blob : Blob? = nil

      def initialize(@blob : Blob, @transformations : Transformations)
      end

      # True when an application processor is installed.
      def processed? : Bool
        !Storage.variant_processor.nil?
      end

      # The derivative blob. Without a processor this is the original blob
      # (documented pass-through). With one, it is the stored variant: found
      # by its key, or processed and uploaded beside the original on first
      # use. Memoized.
      def processed : Blob
        return @blob unless processor = Storage.variant_processor
        @processed_blob ||= find_or_process(processor)
      end

      # Storage key of the variant (nil when the original has none). Keeps
      # the original's visibility (`public/` prefix).
      def key : String?
        @blob.key.try { |original| Storage.variant_key(original, @transformations.cache_key) }
      end

      private def find_or_process(processor : Processor) : Blob
        variant_key = key
        if variant_key && (existing = Blob.find_by(key: variant_key))
          return existing
        end
        source_type = @blob.content_type || "application/octet-stream"
        bytes = processor.process(@blob.download, @transformations, source_type)
        Blob.create_and_upload!(
          bytes,
          filename: filename,
          content_type: processor.output_content_type(source_type, @transformations),
          service_name: @blob.service_name,
          key: variant_key,
          public: @blob.key.try { |blob_key| Storage.public_key?(blob_key) } || false,
          metadata: {
            "variant_of"      => JSON::Any.new(@blob.id || 0_i64),
            "transformations" => JSON::Any.new(@transformations.to_h.to_json),
          }
        )
      end

      def download : Bytes
        processed.download
      end

      def url(base : String = "/files", expires_in : Time::Span = 5.minutes) : String
        processed.url(base: base, expires_in: expires_in)
      end

      def filename : String
        original = @blob.filename || "variant"
        ext = File.extname(original)
        stem = ext.empty? ? original : original[0, original.size - ext.size]
        if (type = content_type) && type != @blob.content_type
          ext = EXTENSIONS[type]? || ext
        end
        "#{stem}_#{@transformations.cache_key}#{ext}"
      end

      # The variant's content type: the original's without a processor
      # (pass-through), else what the processor produces.
      def content_type : String?
        source = @blob.content_type
        return source unless (processor = Storage.variant_processor) && source
        processor.output_content_type(source, @transformations)
      end

      def byte_size : Int64?
        processed.byte_size
      end
    end
  end
end
