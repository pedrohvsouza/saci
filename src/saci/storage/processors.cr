require "file_utils"

module Saci
  module Storage
    # Bundled `Variant::Processor`s. They run the image tools as child
    # processes, so Saci links no image library and an app installs only
    # the tool it picks:
    #
    # ```
    # Saci::Storage.variant_processor = Saci::Storage::Processors::Vips.new        # libvips-tools
    # Saci::Storage.variant_processor = Saci::Storage::Processors::ImageMagick.new # imagemagick
    # Saci::Storage.variant_processor = Saci::Storage::Processors.detect           # whichever is installed
    #
    # post.avatar.variant(resize_to_limit: [300, 300]).url
    # post.avatar.variant(resize_to_fill: [64, 64], format: "webp", quality: 80).url
    # post.document.preview(resize_to_limit: [400, 400]).url # PDF (pdftoppm) / video (ffmpeg)
    # ```
    #
    # Transformations: `resize_to_limit` (shrink to fit, never enlarge),
    # `resize_to_fit` (fit, enlarging if needed), `resize_to_fill` (cover
    # and crop to the exact size), plus the options `format:`
    # (png/jpeg/gif/webp/avif), `quality:` (1-100) and `strip: true`
    # (drop metadata). Other options raise `ArgumentError`. Images are
    # auto-oriented, and animated GIFs keep their first frame.
    #
    # Inputs are limited to PNG, JPEG, GIF and WebP, detected from the
    # bytes (not the stored content type), and passed to the tool with an
    # explicit format, so a crafted upload cannot reach ImageMagick's
    # script-like coders or ffmpeg's playlist demuxers. Images above
    # `max_pixels` are refused before decoding, and every command is
    # killed after `timeout`.
    module Processors
      class Error < Exception
      end

      # The input is not a format this processor handles.
      class UnsupportedType < Error
      end

      # A tool is not installed, exited with an error or timed out.
      class CommandError < Error
      end

      IMAGE_TYPES = {"image/png" => "png", "image/jpeg" => "jpeg", "image/gif" => "gif", "image/webp" => "webp"}

      # `Vips` when `vipsthumbnail` is on the PATH, else `ImageMagick` when
      # `magick` or `convert` is, else nil (variants stay pass-throughs).
      def self.detect : Variant::Processor?
        if Process.find_executable("vipsthumbnail")
          Vips.new
        elsif Process.find_executable("magick") || Process.find_executable("convert")
          ImageMagick.new
        end
      end

      # Image type from the leading bytes, or nil for anything else.
      def self.sniff_image(bytes : Bytes) : String?
        type = Storage.content_type_for("", bytes)
        IMAGE_TYPES.has_key?(type) ? type : nil
      end

      # Container for previews: `"pdf"`, the ffmpeg demuxer (`"mov"` for
      # MP4/QuickTime, `"matroska"` for WebM/MKV) or nil.
      def self.sniff_container(bytes : Bytes) : String?
        return "pdf" if bytes.size >= 5 && String.new(bytes[0, 5]) == "%PDF-"
        return "mov" if bytes.size >= 12 && String.new(bytes[4, 4]) == "ftyp"
        return "matroska" if bytes.size >= 4 && bytes[0] == 0x1a_u8 && bytes[1] == 0x45_u8 && bytes[2] == 0xdf_u8 && bytes[3] == 0xa3_u8
        nil
      end

      # Shared plumbing: temp files, input checks, previews and running
      # commands. Subclasses build the image command.
      abstract class Command < Variant::Processor
        OPTIONS = {"format", "quality", "strip", "preview"}

        property timeout : Time::Span
        property max_pixels : Int64
        property pdftoppm : String
        property ffmpeg : String

        def initialize(*, @timeout : Time::Span = 30.seconds, @max_pixels : Int64 = 50_000_000_i64,
                       @pdftoppm : String = "pdftoppm", @ffmpeg : String = "ffmpeg")
        end

        # Argument vector (command first) that turns `input` (an image of
        # `input_type`) into `output` (an image of `output_type`).
        abstract def image_command(input : String, input_type : String, output : String,
                                   output_type : String, transformations : Variant::Transformations) : Array(String)

        def variable?(content_type : String) : Bool
          IMAGE_TYPES.has_key?(content_type)
        end

        def previewable?(content_type : String) : Bool
          case content_type
          when "application/pdf"
            !Process.find_executable(@pdftoppm).nil?
          when "video/mp4", "video/quicktime", "video/webm", "video/x-matroska"
            !Process.find_executable(@ffmpeg).nil?
          else
            false
          end
        end

        def process(data : Bytes, transformations : Variant::Transformations, content_type : String) : Bytes
          validate!(transformations)
          Dir.mkdir_p(Dir.tempdir)
          dir = File.join(Dir.tempdir, "saci-variant-#{Random::Secure.hex(8)}")
          Dir.mkdir(dir, 0o700)
          begin
            input_type = Processors.sniff_image(data)
            input = File.join(dir, "input")
            File.write(input, data)
            if input_type.nil?
              raise UnsupportedType.new("cannot make a variant of #{content_type}; use preview") unless transformations.preview?
              input = render_preview(input, data, dir)
              input_type = "image/png"
            else
              check_pixels!(data)
            end
            output_type = output_content_type(input_type, transformations)
            return File.read(input).to_slice if transformations.preview? && output_type == input_type && !transformations.image_changes?
            output = File.join(dir, "output.#{IMAGE_TYPES[output_type]? || output_type.split('/').last}")
            run(image_command(input, input_type, output, output_type, transformations))
            raise CommandError.new("#{image_command_name} wrote no output") unless File.exists?(output)
            File.read(output).to_slice
          ensure
            FileUtils.rm_rf(dir)
          end
        end

        # First executable name, for messages.
        def image_command_name : String
          "image tool"
        end

        private def validate!(transformations : Variant::Transformations) : Nil
          resizes = [transformations.resize_to_limit, transformations.resize_to_fit, transformations.resize_to_fill].compact
          raise ArgumentError.new("use one of resize_to_limit, resize_to_fit or resize_to_fill per variant") if resizes.size > 1
          resizes.each do |(width, height)|
            raise ArgumentError.new("variant sizes must be positive, got #{width}x#{height}") unless width > 0 && height > 0
          end
          transformations.extra.each_key do |name|
            raise ArgumentError.new("unsupported variant option #{name.inspect} (supported: format, quality, strip)") unless OPTIONS.includes?(name)
          end
          if quality = transformations.extra["quality"]?
            value = quality.to_i?
            raise ArgumentError.new("variant quality must be 1..100, got #{quality.inspect}") unless value && 1 <= value <= 100
          end
        end

        private def check_pixels!(data : Bytes) : Nil
          return unless dims = Analysis.image_dimensions(data)
          pixels = dims[0].to_i64 * dims[1].to_i64
          raise UnsupportedType.new("image is #{dims[0]}x#{dims[1]}; the limit is #{@max_pixels} pixels") if pixels > @max_pixels
        end

        private def render_preview(input : String, data : Bytes, dir : String) : String
          case container = Processors.sniff_container(data)
          when "pdf"
            base = File.join(dir, "preview")
            run([@pdftoppm, "-f", "1", "-l", "1", "-singlefile", "-png", "-r", "150", "-scale-to", "2048", input, base])
            "#{base}.png"
          when "mov", "matroska"
            output = File.join(dir, "preview.png")
            run([@ffmpeg, "-nostdin", "-hide_banner", "-loglevel", "error", "-f", container.to_s, "-i", input,
                 "-frames:v", "1", "-an", "-y", output])
            output
          else
            raise UnsupportedType.new("cannot preview this file (only PDF, MP4/QuickTime and WebM/MKV)")
          end
        end

        protected def run(argv : Array(String)) : Nil
          command = argv.first
          raise CommandError.new("#{command} is not installed") unless Process.find_executable(command)
          error = IO::Memory.new
          process = Process.new(command, argv[1..], input: Process::Redirect::Close,
            output: Process::Redirect::Close, error: error)
          done = Channel(Process::Status).new(1)
          spawn { done.send(process.wait) }
          select
          when status = done.receive
            unless status.success?
              raise CommandError.new("#{File.basename(command)} failed (#{status}): #{error.to_s.strip[0, 500]}")
            end
          when timeout(@timeout)
            process.terminate(graceful: false) rescue nil
            done.receive
            raise CommandError.new("#{File.basename(command)} timed out after #{@timeout.total_seconds}s")
          end
        end
      end

      # libvips through `vipsthumbnail` (package `libvips-tools`). Fast
      # and memory-light; the recommended processor.
      class Vips < Command
        property vipsthumbnail : String

        def initialize(*, @vipsthumbnail : String = "vipsthumbnail", timeout : Time::Span = 30.seconds,
                       max_pixels : Int64 = 50_000_000_i64, pdftoppm : String = "pdftoppm", ffmpeg : String = "ffmpeg")
          super(timeout: timeout, max_pixels: max_pixels, pdftoppm: pdftoppm, ffmpeg: ffmpeg)
        end

        def image_command_name : String
          @vipsthumbnail
        end

        def image_command(input : String, input_type : String, output : String,
                          output_type : String, transformations : Variant::Transformations) : Array(String)
          argv = [@vipsthumbnail, input]
          if size = transformations.resize_to_limit
            argv.push("--size", "#{size[0]}x#{size[1]}>")
          elsif size = transformations.resize_to_fit
            argv.push("--size", "#{size[0]}x#{size[1]}")
          elsif size = transformations.resize_to_fill
            argv.push("--size", "#{size[0]}x#{size[1]}", "--smartcrop", "centre")
          else
            # vipsthumbnail always resizes; a box no image reaches with
            # "shrink only" keeps the size and still auto-orients.
            argv.push("--size", "100000000x100000000>")
          end
          options = [] of String
          if quality = transformations.extra["quality"]?
            options << "Q=#{quality.to_i}"
          end
          options << "strip" if transformations.extra["strip"]? == "true"
          argv.push("-o", options.empty? ? output : "#{output}[#{options.join(",")}]")
          argv
        end
      end

      # ImageMagick through `magick` (7) or `convert` (6). Inputs are named
      # with an explicit coder (`PNG:file[0]`), so the input's own format
      # sniffing and delegates are never used.
      class ImageMagick < Command
        @binary : String?

        def initialize(*, binary : String? = nil, timeout : Time::Span = 30.seconds,
                       max_pixels : Int64 = 50_000_000_i64, pdftoppm : String = "pdftoppm", ffmpeg : String = "ffmpeg")
          @binary = binary
          super(timeout: timeout, max_pixels: max_pixels, pdftoppm: pdftoppm, ffmpeg: ffmpeg)
        end

        # `magick` when installed, else `convert`.
        def binary : String
          @binary ||= Process.find_executable("magick") ? "magick" : "convert"
        end

        def image_command_name : String
          binary
        end

        def image_command(input : String, input_type : String, output : String,
                          output_type : String, transformations : Variant::Transformations) : Array(String)
          argv = [binary, "#{coder(input_type)}:#{input}[0]", "-auto-orient"]
          if size = transformations.resize_to_limit
            argv.push("-resize", "#{size[0]}x#{size[1]}>")
          elsif size = transformations.resize_to_fit
            argv.push("-resize", "#{size[0]}x#{size[1]}")
          elsif size = transformations.resize_to_fill
            geometry = "#{size[0]}x#{size[1]}"
            argv.push("-resize", "#{geometry}^", "-gravity", "center", "-extent", geometry, "+repage")
          end
          argv << "-strip" if transformations.extra["strip"]? == "true"
          if quality = transformations.extra["quality"]?
            argv.push("-quality", quality.to_i.to_s)
          end
          argv << "#{coder(output_type)}:#{output}"
          argv
        end

        private def coder(content_type : String) : String
          (IMAGE_TYPES[content_type]? || Variant::FORMATS.key_for?(content_type) || "png").upcase
        end
      end
    end
  end
end
