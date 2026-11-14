require "spec"
require "file_utils"
require "compress/zlib"
require "digest/crc32"
require "../src/saci"

SV_TMP = File.join(Dir.tempdir, "saci-storage-variants-#{Process.pid}")
SV_DB  = File.join(Dir.tempdir, "saci_storage_variants_#{Process.pid}.db")

class CreateStorageVariantsTables < Saci::Record::Migration
  def change
    create_table :active_storage_blobs do |t|
      t.string :key, null: false
      t.string :filename, null: false
      t.string :content_type, null: false
      t.bigint :byte_size, null: false
      t.string :checksum, null: false
      t.string :service_name, null: false
      t.json :metadata
      t.datetime :created_at
    end

    create_table :active_storage_attachments do |t|
      t.string :record_type, null: false
      t.bigint :record_id, null: false
      t.string :name, null: false
      t.bigint :blob_id, null: false
      t.datetime :created_at
    end
  end
end

# Counts calls and tags the output so specs can tell it from the original.
class CountingVariantProcessor < Saci::Storage::Variant::Processor
  getter calls = 0

  def process(data : Bytes, transformations : Saci::Storage::Variant::Transformations, content_type : String) : Bytes
    @calls += 1
    sv_png(2, 2)
  end
end

# Runs a command that outlives any reasonable timeout.
class SlowVariantProcessor < Saci::Storage::Processors::Command
  def image_command(input : String, input_type : String, output : String,
                    output_type : String, transformations : Saci::Storage::Variant::Transformations) : Array(String)
    ["sleep", "30"]
  end
end

# A real, decodable RGB PNG filled with one color.
def sv_png(width : Int32, height : Int32, rgb : Tuple(UInt8, UInt8, UInt8) = {200_u8, 30_u8, 30_u8}) : Bytes
  raw = IO::Memory.new
  height.times do
    raw.write_byte(0_u8)
    width.times { raw.write_byte(rgb[0]); raw.write_byte(rgb[1]); raw.write_byte(rgb[2]) }
  end
  deflated = IO::Memory.new
  Compress::Zlib::Writer.open(deflated) { |zlib| zlib.write(raw.to_slice) }

  io = IO::Memory.new
  io.write(Bytes[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
  chunk = ->(type : String, data : Bytes) do
    io.write_bytes(data.size.to_u32, IO::ByteFormat::BigEndian)
    body = IO::Memory.new
    body << type
    body.write(data)
    io.write(body.to_slice)
    io.write_bytes(Digest::CRC32.checksum(body.to_slice), IO::ByteFormat::BigEndian)
  end
  header = IO::Memory.new
  header.write_bytes(width.to_u32, IO::ByteFormat::BigEndian)
  header.write_bytes(height.to_u32, IO::ByteFormat::BigEndian)
  header.write(Bytes[8, 2, 0, 0, 0])
  chunk.call("IHDR", header.to_slice)
  chunk.call("IDAT", deflated.to_slice)
  chunk.call("IEND", Bytes.empty)
  io.to_slice
end

# A one-page PDF with a correct cross-reference table.
def sv_pdf : Bytes
  objects = [
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /Contents 4 0 R >>",
    "<< /Length 35 >>\nstream\n0 0 1 rg 10 10 100 50 re f\nendstream",
  ]
  io = IO::Memory.new
  io << "%PDF-1.4\n"
  offsets = [] of Int32
  objects.each_with_index do |body, index|
    offsets << io.pos.to_i32
    io << (index + 1) << " 0 obj\n" << body << "\nendobj\n"
  end
  xref = io.pos
  io << "xref\n0 " << (objects.size + 1) << "\n0000000000 65535 f \n"
  offsets.each { |offset| io << offset.to_s.rjust(10, '0') << " 00000 n \n" }
  io << "trailer\n<< /Size " << (objects.size + 1) << " /Root 1 0 R >>\nstartxref\n" << xref << "\n%%EOF\n"
  io.to_slice
end

def sv_transformations(*, resize_to_limit : Tuple(Int32, Int32)? = nil, resize_to_fill : Tuple(Int32, Int32)? = nil,
                       resize_to_fit : Tuple(Int32, Int32)? = nil, **options) : Saci::Storage::Variant::Transformations
  extras = {} of String => String
  options.each { |name, value| extras[name.to_s] = value.to_s }
  Saci::Storage::Variant::Transformations.new(resize_to_limit: resize_to_limit, resize_to_fill: resize_to_fill,
    resize_to_fit: resize_to_fit, extra: extras)
end

def sv_dims(bytes : Bytes) : Tuple(Int32, Int32)?
  Saci::Storage::Analysis.image_dimensions(bytes)
end

describe "Saci::Storage variants and processors" do
  before_all do
    File.delete(SV_DB) if File.exists?(SV_DB)
    Saci::Record::Base.connection = DB.open("sqlite3://#{SV_DB}")
    Saci::Record::Migrator.migrate(
      Saci::Record::Base.connection.as(DB::Database),
      [CreateStorageVariantsTables] of Saci::Record::Migration.class
    )
  end

  after_all do
    Saci::Storage.variant_processor = nil
    Saci::Storage.reset_services!
    Saci::Storage.reset_signing_keys!
    Saci::Record::Base.connection.as(DB::Database).close
    File.delete(SV_DB) if File.exists?(SV_DB)
    FileUtils.rm_rf(SV_TMP)
  end

  before_each do
    Saci::Record.clean_database!
    FileUtils.rm_rf(SV_TMP)
    Dir.mkdir_p(SV_TMP)
    Saci::Storage.reset_services!
    Saci::Storage.signing_keys = ["storage-variants-spec-secret"]
    Saci::Storage.service = Saci::Storage::DiskService.new(SV_TMP)
    Saci::Storage.variant_processor = nil
  end

  describe "stored variants" do
    it "processes once and reuses the stored blob from new handles" do
      processor = CountingVariantProcessor.new
      Saci::Storage.variant_processor = processor
      blob = Saci::Storage::Blob.create_and_upload!(sv_png(10, 10), filename: "pic.png")

      first = blob.variant(resize_to_limit: [5, 5]).processed
      again = blob.variant(resize_to_limit: [5, 5]).processed
      reloaded = Saci::Storage::Blob.find(blob.id.not_nil!).variant(resize_to_limit: [5, 5]).processed

      processor.calls.should eq(1)
      again.id.should eq(first.id)
      reloaded.id.should eq(first.id)
      first.key.should eq(blob.variant(resize_to_limit: [5, 5]).key)
      first.metadata["variant_of"].as_i64.should eq(blob.id)
      first.metadata["width"].as_i64.should eq(2)

      blob.variant(resize_to_limit: [6, 6]).processed.id.should_not eq(first.id)
      processor.calls.should eq(2)
    end

    it "derives the same key whatever the option order" do
      blob = Saci::Storage::Blob.create_and_upload!(sv_png(4, 4), filename: "pic.png")
      a = blob.variant(format: "webp", quality: 80)
      b = blob.variant(quality: 80, format: "webp")
      a.key.should eq(b.key)
      a.filename.should eq(b.filename)
      a.key.should_not eq(blob.key)
      Saci::Storage.valid_key?(a.key.not_nil!).should be_true
    end

    it "keeps the original's visibility" do
      Saci::Storage.variant_processor = CountingVariantProcessor.new
      shown = Saci::Storage::Blob.create_and_upload!(sv_png(4, 4), filename: "a.png", public: true)
      hidden = Saci::Storage::Blob.create_and_upload!(sv_png(4, 4), filename: "b.png")
      Saci::Storage.public_key?(shown.variant(resize_to_fit: [2, 2]).processed.key.not_nil!).should be_true
      Saci::Storage.public_key?(hidden.variant(resize_to_fit: [2, 2]).processed.key.not_nil!).should be_false
    end

    it "names and types a variant by its output format" do
      blob = Saci::Storage::Blob.create_and_upload!(sv_png(4, 4), filename: "photo.png")
      blob.variant(format: "webp").content_type.should eq("image/png") # pass-through without a processor

      Saci::Storage.variant_processor = CountingVariantProcessor.new
      webp = blob.variant(format: "webp", resize_to_limit: [2, 2])
      webp.content_type.should eq("image/webp")
      webp.filename.should eq("photo_limit-2x2_format-webp.webp")
      webp.processed.content_type.should eq("image/webp")
      expect_raises(ArgumentError, /unsupported variant format/) { blob.variant(format: "bmp").content_type }
    end

    it "types previews of documents as PNG" do
      Saci::Storage.variant_processor = CountingVariantProcessor.new
      pdf = Saci::Storage::Blob.create_and_upload!(sv_pdf, filename: "report.pdf")
      preview = pdf.preview(resize_to_limit: [50, 50])
      preview.content_type.should eq("image/png")
      preview.filename.should eq("report_limit-50x50_preview-true.png")
      preview.processed.content_type.should eq("image/png")
    end

    it "purges variants with the original" do
      Saci::Storage.variant_processor = CountingVariantProcessor.new
      blob = Saci::Storage::Blob.create_and_upload!(sv_png(8, 8), filename: "pic.png")
      other = Saci::Storage::Blob.create_and_upload!(sv_png(8, 8), filename: "other.png")
      small = blob.variant(resize_to_limit: [4, 4]).processed
      tiny = blob.variant(resize_to_limit: [2, 2]).processed
      kept = other.variant(resize_to_limit: [4, 4]).processed
      odd = Saci::Storage::Blob.create_and_upload!(sv_png(2, 2), filename: "odd.png")
      junk = Saci::Storage::Blob.create_and_upload!(sv_png(2, 2), filename: "junk.png")
      Saci::Record::Base.connection.exec("UPDATE active_storage_blobs SET metadata = '' WHERE id = ?", odd.id)
      Saci::Record::Base.connection.exec("UPDATE active_storage_blobs SET metadata = 'not json' WHERE id = ?", junk.id)

      Saci::Storage::Blob.variants_of(blob.id.not_nil!).map(&.id.not_nil!).sort!.should eq([small.id, tiny.id].map(&.not_nil!).sort!)
      blob.purge

      Saci::Storage::Blob.find_by(id: small.id).should be_nil
      Saci::Storage::Blob.find_by(id: tiny.id).should be_nil
      Saci::Storage.exists?(small.key.not_nil!).should be_false
      Saci::Storage::Blob.find_by(id: kept.id).should_not be_nil
    end

    it "asks the processor what it can transform and preview" do
      png = Saci::Storage::Blob.create_and_upload!(sv_png(2, 2), filename: "a.png")
      pdf = Saci::Storage::Blob.create_and_upload!(sv_pdf, filename: "a.pdf")
      png.variable?.should be_false
      pdf.previewable?.should be_false

      Saci::Storage.variant_processor = Saci::Storage::Processors::ImageMagick.new(pdftoppm: "saci-missing-pdftoppm")
      png.variable?.should be_true
      pdf.variable?.should be_false
      pdf.previewable?.should be_false
      Saci::Storage.variant_processor = Saci::Storage::Processors::ImageMagick.new(pdftoppm: "sh")
      pdf.previewable?.should be_true
    end
  end

  describe Saci::Storage::Processors::Vips do
    it "builds vipsthumbnail commands" do
      vips = Saci::Storage::Processors::Vips.new
      vips.image_command("/t/in", "image/png", "/t/out.png", "image/png", sv_transformations(resize_to_limit: {300, 200}))
        .should eq(["vipsthumbnail", "/t/in", "--size", "300x200>", "-o", "/t/out.png"])
      vips.image_command("/t/in", "image/png", "/t/out.png", "image/png", sv_transformations(resize_to_fit: {30, 20}))
        .should eq(["vipsthumbnail", "/t/in", "--size", "30x20", "-o", "/t/out.png"])
      vips.image_command("/t/in", "image/jpeg", "/t/out.webp", "image/webp", sv_transformations(resize_to_fill: {64, 64}, quality: 80, strip: true))
        .should eq(["vipsthumbnail", "/t/in", "--size", "64x64", "--smartcrop", "centre", "-o", "/t/out.webp[Q=80,strip]"])
      vips.image_command("/t/in", "image/png", "/t/out.jpeg", "image/jpeg", sv_transformations(format: "jpeg"))
        .should eq(["vipsthumbnail", "/t/in", "--size", "100000000x100000000>", "-o", "/t/out.jpeg"])
    end
  end

  describe Saci::Storage::Processors::ImageMagick do
    it "builds commands with explicit coders" do
      magick = Saci::Storage::Processors::ImageMagick.new(binary: "magick")
      magick.image_command("/t/in", "image/png", "/t/out.png", "image/png", sv_transformations(resize_to_limit: {300, 200}))
        .should eq(["magick", "PNG:/t/in[0]", "-auto-orient", "-resize", "300x200>", "PNG:/t/out.png"])
      magick.image_command("/t/in", "image/gif", "/t/out.webp", "image/webp", sv_transformations(resize_to_fill: {64, 32}, strip: true, quality: 70))
        .should eq(["magick", "GIF:/t/in[0]", "-auto-orient", "-resize", "64x32^", "-gravity", "center",
                    "-extent", "64x32", "+repage", "-strip", "-quality", "70", "WEBP:/t/out.webp"])
      magick.image_command("/t/in", "image/jpeg", "/t/out.avif", "image/avif", sv_transformations(resize_to_fit: {10, 10}))
        .should eq(["magick", "JPEG:/t/in[0]", "-auto-orient", "-resize", "10x10", "AVIF:/t/out.avif"])
    end
  end

  describe Saci::Storage::Processors::Command do
    processor = Saci::Storage::Processors::ImageMagick.new(binary: "saci-missing-magick", max_pixels: 1_000_i64)

    it "rejects bad transformations before running anything" do
      png = sv_png(10, 10)
      expect_raises(ArgumentError, /one of resize_to_limit/) do
        processor.process(png, sv_transformations(resize_to_limit: {5, 5}, resize_to_fill: {5, 5}), "image/png")
      end
      expect_raises(ArgumentError, /unsupported variant option "rotate"/) do
        processor.process(png, sv_transformations(rotate: 90), "image/png")
      end
      expect_raises(ArgumentError, /quality must be 1..100/) do
        processor.process(png, sv_transformations(quality: 0), "image/png")
      end
      expect_raises(ArgumentError, /must be positive/) do
        processor.process(png, sv_transformations(resize_to_fit: {0, 5}), "image/png")
      end
    end

    it "sniffs the input instead of trusting the content type" do
      expect_raises(Saci::Storage::Processors::UnsupportedType, /use preview/) do
        processor.process("<svg xmlns='http://www.w3.org/2000/svg'/>".to_slice, sv_transformations(resize_to_fit: {5, 5}), "image/png")
      end
      expect_raises(Saci::Storage::Processors::UnsupportedType, /cannot preview/) do
        processor.process("plain text".to_slice, sv_transformations(preview: true), "application/pdf")
      end
    end

    it "refuses images over max_pixels and reports missing tools" do
      expect_raises(Saci::Storage::Processors::UnsupportedType, /40x40; the limit is 1000 pixels/) do
        processor.process(sv_png(40, 40), sv_transformations(resize_to_fit: {5, 5}), "image/png")
      end
      expect_raises(Saci::Storage::Processors::CommandError, /saci-missing-magick is not installed/) do
        processor.process(sv_png(10, 10), sv_transformations(resize_to_fit: {5, 5}), "image/png")
      end
    end

    it "kills a command that runs past the timeout" do
      slow = SlowVariantProcessor.new(timeout: 200.milliseconds)
      started = Time.instant
      expect_raises(Saci::Storage::Processors::CommandError, /timed out/) do
        slow.process(sv_png(4, 4), sv_transformations(resize_to_fit: {2, 2}), "image/png")
      end
      (Time.instant - started).should be < 5.seconds
    end
  end

  describe "with the real tools" do
    {% for name, binary in {"Vips" => "vipsthumbnail", "ImageMagick" => "convert"} %}
      if Process.find_executable({{binary}}) || ({{name}} == "ImageMagick" && Process.find_executable("magick"))
        it "resizes, crops and converts with {{name.id}}" do
          processor = Saci::Storage::Processors::{{name.id}}.new
          png = sv_png(40, 20)
          limited = processor.process(png, sv_transformations(resize_to_limit: {10, 10}), "image/png")
          sv_dims(limited).should eq({10, 5})
          processor.process(png, sv_transformations(resize_to_limit: {100, 100}), "image/png").try { |b| sv_dims(b) }.should eq({40, 20})
          processor.process(png, sv_transformations(resize_to_fit: {80, 80}), "image/png").try { |b| sv_dims(b) }.should eq({80, 40})
          filled = processor.process(png, sv_transformations(resize_to_fill: {8, 8}, format: "jpeg", quality: 70), "image/png")
          Saci::Storage.content_type_for("", filled).should eq("image/jpeg")
          sv_dims(filled).should eq({8, 8})
          webp = processor.process(png, sv_transformations(format: "webp", strip: true), "image/png")
          Saci::Storage.content_type_for("", webp).should eq("image/webp")

          Saci::Storage.variant_processor = processor
          blob = Saci::Storage::Blob.create_and_upload!(png, filename: "wide.png")
          variant = blob.variant(resize_to_limit: [10, 10]).processed
          variant.metadata["width"].as_i64.should eq(10)
          sv_dims(variant.download).should eq({10, 5})
        end
      else
        pending "resizes, crops and converts with {{name.id}} ({{binary.id}} is not installed)"
      end
    {% end %}

    if Process.find_executable("pdftoppm")
      it "renders the first page of a PDF" do
        processor = Saci::Storage::Processors::ImageMagick.new
        preview = processor.process(sv_pdf, sv_transformations(preview: true), "application/pdf")
        Saci::Storage.content_type_for("", preview).should eq("image/png")
        dims = sv_dims(preview).not_nil!
        (dims[0] > dims[1]).should be_true

        Saci::Storage.variant_processor = processor
        blob = Saci::Storage::Blob.create_and_upload!(sv_pdf, filename: "doc.pdf")
        blob.previewable?.should be_true
        stored = blob.preview.processed
        stored.content_type.should eq("image/png")
        stored.filename.should eq("doc_preview-true.png")
      end
    else
      pending "renders the first page of a PDF (pdftoppm is not installed)"
    end

    if Process.find_executable("ffmpeg")
      it "renders the first frame of a video" do
        video = File.join(SV_TMP, "clip.mp4")
        Dir.mkdir_p(SV_TMP)
        Process.run("ffmpeg", ["-nostdin", "-loglevel", "error", "-f", "lavfi", "-i", "color=c=blue:s=64x48:d=0.2",
                               "-pix_fmt", "yuv420p", "-y", video]).success?.should be_true
        processor = Saci::Storage::Processors::Vips.new
        frame = processor.process(File.read(video).to_slice, sv_transformations(preview: true), "video/mp4")
        Saci::Storage.content_type_for("", frame).should eq("image/png")
        sv_dims(frame).should eq({64, 48})
      end
    else
      pending "renders the first frame of a video (ffmpeg is not installed)"
    end
  end
end
