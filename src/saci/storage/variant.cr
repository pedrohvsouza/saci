module Saci
  module Storage
    # Lazy image transformation handle returned by `Blob#variant`.
    #
    # Saci does not bundle libvips/minimagick. Without a processor the
    # variant is a pass-through: `#url`/`#download` return the original
    # blob unchanged. Register a processor to get real transformations:
    #
    # ```
    # class MyProcessor < Saci::Storage::Variant::Processor
    #   def process(data : Bytes, transformations : Saci::Storage::Variant::Transformations,
    #               content_type : String) : Bytes
    #     # shell out to `vips`/`magick`, or call a binding
    #   end
    # end
    #
    # Saci::Storage.variant_processor = MyProcessor.new
    # post.avatar.variant(resize_to_limit: [300, 300]).url
    # ```
    class Variant
      # Normalised transformation options.
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
          @extra.each { |k, v| parts << "#{k}-#{v}" }
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

      # Pluggable transformation backend. Must return encoded image bytes
      # in the same format as the input (JPEG/PNG/WebP/...).
      abstract class Processor
        abstract def process(data : Bytes, transformations : Transformations, content_type : String) : Bytes
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
      # (documented pass-through). With a processor the result is uploaded
      # as a new blob beside the original and memoized.
      def processed : Blob
        return @blob unless processor = Storage.variant_processor
        @processed_blob ||= begin
          bytes = processor.process(@blob.download, @transformations, @blob.content_type || "application/octet-stream")
          Blob.create_and_upload!(
            bytes,
            filename: filename,
            content_type: @blob.content_type,
            service_name: @blob.service_name,
            identify: false,
            metadata: {
              "variant_of"      => JSON::Any.new(@blob.id || 0_i64),
              "transformations" => JSON::Any.new(@transformations.to_h.to_json),
            }
          )
        end
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
        "#{stem}_#{@transformations.cache_key}#{ext.empty? ? "" : ext}"
      end

      def content_type : String?
        @blob.content_type
      end

      def byte_size : Int64?
        processed.byte_size
      end
    end
  end
end
