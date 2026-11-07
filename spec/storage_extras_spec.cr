require "spec"
require "file_utils"
require "json"
require "uri"
require "../src/saci"

STORAGE_EXTRAS_TMP    = "/tmp/opencode/saci-storage-extras"
STORAGE_EXTRAS_BACKUP = "/tmp/opencode/saci-storage-extras-backup"
STORAGE_EXTRAS_DB     = "/tmp/opencode/saci_storage_extras_test.db"

class CreateStorageExtras < Saci::Record::Migration
  def change
    create_table :storage_posts do |t|
      t.string :title
      t.timestamps
    end

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

class StoragePost < Saci::Record::Base
  table "storage_posts"

  column id : Int64, primary: true
  column title : String
  timestamps

  has_one_attached :avatar
  has_one_attached :mirrored, service: :local, mirror: :backup
  has_many_attached :documents
end

class FakeVariantProcessor < Saci::Storage::Variant::Processor
  def process(data : Bytes, transformations : Saci::Storage::Variant::Transformations, content_type : String) : Bytes
    ("processed:" + String.new(data)).to_slice
  end
end

def extras_png_bytes(width : Int32, height : Int32) : Bytes
  bytes = [] of UInt8
  [0x89_u8, 0x50_u8, 0x4e_u8, 0x47_u8, 0x0d_u8, 0x0a_u8, 0x1a_u8, 0x0a_u8].each { |b| bytes << b }
  [0x00_u8, 0x00_u8, 0x00_u8, 0x0d_u8].each { |b| bytes << b }
  "IHDR".each_byte { |b| bytes << b }
  [width.to_u32, height.to_u32].each do |value|
    4.times { |i| bytes << ((value >> ((3 - i) * 8)) & 0xff).to_u8 }
  end
  [8_u8, 2_u8, 0_u8, 0_u8, 0_u8].each { |b| bytes << b }
  Slice.new(bytes.to_unsafe, bytes.size)
end

def extras_gif_bytes(width : Int32, height : Int32) : Bytes
  bytes = [] of UInt8
  "GIF89a".each_byte { |b| bytes << b }
  [width, height].each do |value|
    2.times { |i| bytes << ((value >> (i * 8)) & 0xff).to_u8 }
  end
  Slice.new(bytes.to_unsafe, bytes.size)
end

def extras_jpeg_bytes(width : Int32, height : Int32) : Bytes
  bytes = [] of UInt8
  [0xff_u8, 0xd8_u8, 0xff_u8, 0xc0_u8, 0x00_u8, 0x11_u8, 0x08_u8].each { |b| bytes << b }
  [height, width].each do |value|
    2.times { |i| bytes << ((value >> ((1 - i) * 8)) & 0xff).to_u8 }
  end
  [0x03_u8, 0x01_u8, 0x11_u8, 0x00_u8, 0x02_u8, 0x11_u8, 0x00_u8, 0x03_u8, 0x11_u8, 0x00_u8, 0xff_u8, 0xd9_u8].each { |b| bytes << b }
  Slice.new(bytes.to_unsafe, bytes.size)
end

def extras_webp_bytes(width : Int32, height : Int32) : Bytes
  bytes = [] of UInt8
  "RIFF".each_byte { |b| bytes << b }
  [22_u8, 0_u8, 0_u8, 0_u8].each { |b| bytes << b }
  "WEBPVP8X".each_byte { |b| bytes << b }
  [10_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8].each { |b| bytes << b }
  [width - 1, height - 1].each do |value|
    3.times { |i| bytes << ((value >> (i * 8)) & 0xff).to_u8 }
  end
  Slice.new(bytes.to_unsafe, bytes.size)
end

def extras_multipart(filename : String, content_type : String, body : String, boundary : String = "SACIBOUND") : Tuple(HTTP::Headers, String)
  payload = String.build do |io|
    io << "--" << boundary << "\r\n"
    io << %(Content-Disposition: form-data; name="file"; filename="#{filename}") << "\r\n"
    io << "Content-Type: " << content_type << "\r\n\r\n"
    io << body << "\r\n"
    io << "--" << boundary << "--\r\n"
  end
  {HTTP::Headers{"Content-Type" => "multipart/form-data; boundary=#{boundary}"}, payload}
end

describe "Saci::Storage blob/attachment extras" do
  before_all do
    File.delete(STORAGE_EXTRAS_DB) if File.exists?(STORAGE_EXTRAS_DB)
    Saci::Record::Base.connection = DB.open("sqlite3://#{STORAGE_EXTRAS_DB}")
    Saci::Record::Migrator.migrate(
      Saci::Record::Base.connection.as(DB::Database),
      [CreateStorageExtras] of Saci::Record::Migration.class
    )
  end

  after_all do
    Saci::Storage.reset_signing_keys!
    Saci::Storage.reset_services!
    Saci::Storage.variant_processor = nil
    Saci::Storage.max_upload_size = 100_i64 * 1024_i64 * 1024_i64
    Saci::Storage.block_unsafe_content_types = true
    Saci::Record::Base.connection.as(DB::Database).close
  end

  before_each do
    Saci::Record.clean_database!
    FileUtils.rm_rf(STORAGE_EXTRAS_TMP)
    FileUtils.rm_rf(STORAGE_EXTRAS_BACKUP)
    Dir.mkdir_p(STORAGE_EXTRAS_TMP)
    Dir.mkdir_p(STORAGE_EXTRAS_BACKUP)
    Saci::Storage.reset_services!
    Saci::Storage.reset_signing_keys!
    Saci::Storage.signing_keys = ["storage-extras-spec-secret"]
    Saci::Storage.service = Saci::Storage::DiskService.new(STORAGE_EXTRAS_TMP)
    Saci::Storage.register_service("backup", Saci::Storage::DiskService.new(STORAGE_EXTRAS_BACKUP, name: "backup"))
    Saci::Storage.variant_processor = nil
    Saci::Storage.max_upload_size = 100_i64 * 1024_i64 * 1024_i64
    Saci::Storage.block_unsafe_content_types = true
  end

  describe "Blob lifecycle" do
    it "uploads, analyzes, signs and purges a blob" do
      bytes = extras_png_bytes(4, 3)
      low_key = Saci::Storage.upload("module-data", filename: "m.txt", content_type: "text/plain")
      Saci::Storage.exists?(low_key).should be_true
      String.new(Saci::Storage.download(low_key)).should eq("module-data")
      Saci::Storage.delete(low_key)
      Saci::Storage.exists?(low_key).should be_false

      blob = Saci::Storage::Blob.create_and_upload!(bytes, filename: "Pic One.PNG")

      blob.id.should_not be_nil
      blob.key.should_not be_nil
      Saci::Storage.valid_key?(blob.key.not_nil!).should be_true
      blob.filename.should eq("Pic One.PNG")
      blob.content_type.should eq("image/png")
      blob.byte_size.should eq(bytes.size.to_i64)
      blob.checksum.not_nil!.size.should eq(64)
      blob.service_name.should eq("local")
      blob.metadata["width"].as_i64.should eq(4)
      blob.metadata["height"].as_i64.should eq(3)

      String.new(blob.download).should eq(String.new(bytes))
      blob.open { |io| io.getb_to_end.size.should eq(bytes.size) }

      Saci::Storage::Blob.find(blob.id.not_nil!).key.should eq(blob.key)
      Saci::Storage::Blob.find_signed(blob.signed_id).not_nil!.id.should eq(blob.id)
      Saci::Storage.resolve_signed_global_id(blob.signed_id).not_nil!.read_attribute("id").should eq(blob.id)

      path = File.join(STORAGE_EXTRAS_TMP, blob.key.not_nil!)
      File.exists?(path).should be_true

      blob.purge
      Saci::Storage::Blob.find_by(id: blob.id.not_nil!).should be_nil
      File.exists?(path).should be_false
    end

    it "sanitizes filenames, rejects unsafe types and enforces size limits" do
      blob = Saci::Storage::Blob.create_and_upload!("data", filename: "../../etc/passwd")
      blob.filename.should eq("passwd")

      expect_raises(Saci::Storage::UnsafeContentType) do
        Saci::Storage::Blob.create_and_upload!("<html>", filename: "x.html", content_type: "text/html")
      end

      Saci::Storage.max_upload_size = 4_i64
      begin
        expect_raises(Saci::Storage::UploadTooLarge) do
          Saci::Storage::Blob.create_and_upload!("12345", filename: "x.txt", content_type: "text/plain")
        end
      ensure
        Saci::Storage.max_upload_size = 100_i64 * 1024_i64 * 1024_i64
      end
    end

    it "analyzes later through the job adapter" do
      blob = Saci::Storage::Blob.create_and_upload!(extras_png_bytes(7, 5), filename: "later.png", identify: false)
      blob.metadata["width"]?.should be_nil
      Saci::Job.with_adapter(:inline) { blob.analyze_later }
      Saci::Storage::Blob.find(blob.id.not_nil!).metadata["width"].as_i64.should eq(7)
    end
  end

  describe "has_one_attached" do
    it "attaches, replaces, resolves and purges a single file" do
      post = StoragePost.create!(title: "hello")
      post.avatar.attached?.should be_false
      post.avatar_attached?.should be_false

      first = post.avatar.attach("first-data", filename: "one.txt", content_type: "text/plain")
      post.avatar.attached?.should be_true
      post.avatar_attached?.should be_true
      post.avatar.filename.should eq("one.txt")
      post.avatar.content_type.should eq("text/plain")
      post.avatar.byte_size.should eq(10_i64)
      post.avatar.checksum.should_not be_nil
      String.new(post.avatar.download.not_nil!).should eq("first-data")
      post.avatar.open { |io| String.new(io.getb_to_end).should eq("first-data") }
      post.avatar.url.not_nil!.should contain("/files/")
      post.avatar.url.not_nil!.should contain("sig=")
      post.avatar.signed_id.should_not be_nil
      post.avatar.attachment.not_nil!.record.not_nil!.read_attribute("id").should eq(post.id)
      post.avatar_attachment.not_nil!.name.should eq("avatar")
      post.avatar_blob.not_nil!.id.should eq(first.blob.not_nil!.id)

      first_blob = first.blob.not_nil!
      second = post.avatar.attach("second-data", filename: "two.txt", content_type: "text/plain")
      second_blob = second.blob.not_nil!
      Saci::Storage::Blob.count.should eq(1)
      Saci::Storage::Blob.find_by(id: first_blob.id.not_nil!).should be_nil
      Saci::Storage::Attachment.count.should eq(1)
      post.avatar.filename.should eq("two.txt")

      standalone = Saci::Storage::Blob.create_and_upload!("assigned", filename: "a.txt", content_type: "text/plain")
      post.avatar = standalone
      post.avatar.blob.not_nil!.id.should eq(standalone.id)
      Saci::Storage::Blob.find_by(id: second_blob.id.not_nil!).should be_nil

      post.avatar.purge
      post.avatar.attached?.should be_false
      Saci::Storage::Blob.count.should eq(0)
      Saci::Storage::Attachment.count.should eq(0)
    end

    it "purges later and attaches uploaded files" do
      post = StoragePost.create!(title: "later")
      post.avatar.attach("x", filename: "x.txt", content_type: "text/plain")
      Saci::Job.with_adapter(:inline) { post.avatar.purge_later }
      Saci::Storage::Blob.count.should eq(0)

      uploaded = Saci::Params::UploadedFile.new("avatar", "up.txt", "uploaded-bytes", "text/plain")
      post.avatar = uploaded
      post.avatar.filename.should eq("up.txt")
      String.new(post.avatar.download.not_nil!).should eq("uploaded-bytes")
    end
  end

  describe "has_many_attached" do
    it "attaches several blobs, lists them and purges" do
      post = StoragePost.create!(title: "many")
      post.documents.attached?.should be_false
      post.documents.attach("alpha", filename: "a.txt", content_type: "text/plain")
      post.documents.attach("beta", filename: "b.txt", content_type: "text/plain")
      post.documents.size.should eq(2)
      post.documents.attached?.should be_true
      post.documents_attachments.size.should eq(2)
      post.documents_blobs.size.should eq(2)
      post.documents.filename.should eq("a.txt")
      post.documents.url.not_nil!.should contain("/files/")
      post.documents.first.not_nil!.name.should eq("documents")

      first = Saci::Storage::Blob.create_and_upload!("one", filename: "1.txt", content_type: "text/plain")
      second = Saci::Storage::Blob.create_and_upload!("two", filename: "2.txt", content_type: "text/plain")
      post.documents = [first, second]
      post.documents.size.should eq(4)

      post.documents.purge
      Saci::Storage::Blob.count.should eq(0)
      Saci::Storage::Attachment.count.should eq(0)
    end
  end

  describe "mirroring" do
    it "writes to primary and mirror, reads primary and deletes both" do
      primary = Saci::Storage::DiskService.new(STORAGE_EXTRAS_TMP, name: "primary")
      backup = Saci::Storage::DiskService.new(STORAGE_EXTRAS_BACKUP, name: "backup")
      mirror = Saci::Storage::MirrorService.new(primary, backup)

      key = mirror.upload("mirrored-data", filename: "m.txt", content_type: "text/plain")
      primary.exists?(key).should be_true
      backup.exists?(key).should be_true
      String.new(mirror.download(key)).should eq("mirrored-data")

      mirror.delete(key)
      primary.exists?(key).should be_false
      backup.exists?(key).should be_false
    end

    it "honors the mirror: macro option and purges every copy" do
      post = StoragePost.create!(title: "mirror")
      post.mirrored.attach("mirrored-blob", filename: "m.txt", content_type: "text/plain")
      blob = post.mirrored.blob.not_nil!
      blob.mirror_names.should eq(["backup"])
      key = blob.key.not_nil!
      File.exists?(File.join(STORAGE_EXTRAS_TMP, key)).should be_true
      File.exists?(File.join(STORAGE_EXTRAS_BACKUP, key)).should be_true

      post.mirrored.purge
      File.exists?(File.join(STORAGE_EXTRAS_TMP, key)).should be_false
      File.exists?(File.join(STORAGE_EXTRAS_BACKUP, key)).should be_false
      Saci::Storage::Blob.count.should eq(0)
    end
  end

  describe "signed URLs and direct uploads" do
    it "round-trips signed message tokens and rejects tampering" do
      token = Saci::Storage.sign_message("purpose", "payload")
      Saci::Storage.verify_message("purpose", token).should eq("payload")
      Saci::Storage.verify_message("other", token).should be_nil
      Saci::Storage.verify_message("purpose", "#{token}x").should be_nil

      expired = Saci::Storage.sign_message("purpose", "payload", expires_in: -10.seconds)
      Saci::Storage.verify_message("purpose", expired).should be_nil
    end

    it "serves blob URLs through the signed FilesController route" do
      blob = Saci::Storage::Blob.create_and_upload!("served-bytes", filename: "s.txt", content_type: "text/plain")
      url = blob.url
      parts = url.split("?", 2)[1].split("&")
      expires = parts[0].split("=")[1].to_i64
      sig = parts[1].split("=")[1]
      Saci::Storage.verified_url?(blob.key.not_nil!, expires, sig).should be_true

      router = Saci::Router.new.draw do |r|
        r.get "/files/*key", Saci::Storage::FilesController, :show
      end
      Saci::TestSession.serve(router) do |app|
        response = app.get(url)
        response.status_code.should eq(200)
        response.body.should eq("served-bytes")

        named = Saci::Storage::Blob.create_and_upload!(
          "named-bytes", filename: "n.txt", content_type: "text/plain", service_name: "backup"
        )
        named_url = named.url
        named_url.should contain("service=backup")
        named_response = app.get(named_url)
        named_response.status_code.should eq(200)
        named_response.body.should eq("named-bytes")
        app.get(named_url.sub("service=backup", "service=local")).status_code.should eq(404)
      end
    end

    it "signs direct uploads and stores them through the endpoint" do
      url = Saci::Storage.direct_upload_url(filename: "up.txt", content_type: "text/plain", byte_size: 11_i64)
      token = URI.decode_www_form(url.split("token=", 2)[1])
      verified = Saci::Storage.verify_direct_upload(token)
      verified.should_not be_nil
      verified.not_nil!.filename.should eq("up.txt")
      verified.not_nil!.content_type.should eq("text/plain")
      verified.not_nil!.accepts?(11_i64, "text/plain").should be_true
      verified.not_nil!.accepts?(12_i64, "text/plain").should be_false

      headers, body = extras_multipart("up.txt", "text/plain", "direct-data")
      router = Saci::Router.new.draw do |r|
        r.post "/direct_uploads", Saci::Storage::DirectUploadsController, :create
      end
      Saci::TestSession.serve(router) do |app|
        response = app.post(url, headers, body)
        response.status_code.should eq(201)
        json = JSON.parse(response.body)
        json["signed_id"].as_s.should_not be_empty
        blob = Saci::Storage::Blob.find_signed(json["signed_id"].as_s).not_nil!
        String.new(blob.download).should eq("direct-data")
        blob.filename.should eq("up.txt")

        _, short_body = extras_multipart("up.txt", "text/plain", "short")
        app.post(url, headers, short_body).status_code.should eq(422)
        app.post(url, headers, body).status_code.should eq(422)
        app.post("/direct_uploads?token=bogus", headers, body).status_code.should eq(422)
      end
    end

    it "exposes the controller helper" do
      controller = Saci::Storage::DirectUploadsController.new(
        HTTP::Server::Context.new(HTTP::Request.new("GET", "/"), HTTP::Server::Response.new(IO::Memory.new)),
        Saci::Params.new,
        :create
      )
      controller.direct_upload_url(filename: "a.txt", content_type: "text/plain", byte_size: 2_i64).should contain("/direct_uploads?token=")
    end
  end

  describe "metadata analysis" do
    it "reads dimensions from PNG/GIF/JPEG/WebP headers" do
      Saci::Storage::Analysis.image_dimensions(extras_png_bytes(3, 2)).should eq({3, 2})
      Saci::Storage::Analysis.image_dimensions(extras_gif_bytes(11, 7)).should eq({11, 7})
      Saci::Storage::Analysis.image_dimensions(extras_jpeg_bytes(9, 4)).should eq({9, 4})
      Saci::Storage::Analysis.image_dimensions(extras_webp_bytes(13, 6)).should eq({13, 6})
      Saci::Storage::Analysis.image_dimensions("not an image".to_slice).should be_nil
      Saci::Storage::Analysis.analyze(Bytes.empty, "video/mp4")["duration"]?.should eq(0)
      Saci::Storage::SHA256.hexdigest("abc").should eq("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    end
  end

  describe "variants" do
    it "passes through without a processor and processes with one" do
      blob = Saci::Storage::Blob.create_and_upload!(extras_png_bytes(10, 10), filename: "pic.png")

      variant = blob.variant(resize_to_limit: [5, 5])
      variant.processed?.should be_false
      variant.url.should eq(blob.url)
      variant.download.should eq(blob.download)
      variant.filename.should eq("pic_limit-5x5.png")
      blob.previewable?.should be_false
      blob.preview.url.should eq(blob.url)

      Saci::Storage.variant_processor = FakeVariantProcessor.new
      begin
        variant.processed?.should be_true
        String.new(variant.download).should start_with("processed:")
        derived = variant.processed
        derived.id.should_not be_nil
        derived.metadata["variant_of"]?.should_not be_nil
        derived.download.size.should be > blob.download.size
      ensure
        Saci::Storage.variant_processor = nil
      end
    end
  end

  describe "S3Service skeleton" do
    it "builds SigV4 pre-signed URLs and reports missing configuration" do
      service = Saci::Storage::S3Service.new(
        bucket: "my-bucket",
        region: "eu-central-1",
        access_key_id: "AKIAIOSFODNN7EXAMPLE",
        secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
      )
      url = service.presigned_url("ab/cd/file.bin", expires_in: 5.minutes)
      uri = URI.parse(url)
      uri.host.should eq("s3.eu-central-1.amazonaws.com")
      uri.path.should eq("/my-bucket/ab/cd/file.bin")
      query = URI::Params.parse(uri.query.not_nil!)
      query["X-Amz-Algorithm"].should eq("AWS4-HMAC-SHA256")
      query["X-Amz-SignedHeaders"].should eq("host")
      query["X-Amz-Signature"].size.should eq(64)
      service.locate("ab/cd/file.bin").should be_nil

      unconfigured = Saci::Storage::S3Service.new(bucket: nil, access_key_id: nil, secret_access_key: nil)
      expect_raises(Saci::Storage::NotConfigured) { unconfigured.presigned_url("ab/cd/file.bin") }
      expect_raises(Saci::Storage::NotConfigured) { unconfigured.download("ab/cd/file.bin") }
    end
  end

  describe "Action Text attachments" do
    it "round-trips attachment tags through sanitize, extraction and rendering" do
      blob = Saci::Storage::Blob.create_and_upload!("chart-bytes", filename: "chart.png", content_type: "image/png")
      html = Saci::RichText.attachment_tag(blob, caption: "<strong>Chart</strong>")
      html.should contain("<action-text-attachment")
      html.should contain(%(sgid="#{blob.signed_id}"))
      html.should contain(%(content-type="image/png"))
      html.should contain(%(filename="chart.png"))
      html.should contain("<strong>Chart</strong>")

      sanitized = Saci::RichText.sanitize(html)
      sanitized.should contain("<action-text-attachment")
      sanitized.should contain(%(sgid="#{blob.signed_id}"))
      sanitized.should contain("</action-text-attachment>")
      sanitized.should_not contain("<script>")

      evil = %(<action-text-attachment sgid="forged" onclick="alert(1)" content-type="text/html" filename="a.txt" style="x">cap</action-text-attachment>)
      cleaned = Saci::RichText.sanitize(evil)
      cleaned.should_not contain("onclick")
      cleaned.should_not contain("style=")
      cleaned.should contain(%(content-type="text/html"))

      parsed = Saci::RichText.attachments(html)
      parsed.size.should eq(1)
      parsed[0].sgid.should eq(blob.signed_id)
      parsed[0].filename.should eq("chart.png")
      parsed[0].caption?.should be_true
      parsed[0].blob.not_nil!.id.should eq(blob.id)
      parsed[0].to_plain_text.should eq("Chart")
      Saci::RichText.find_signed(blob.signed_id).not_nil!.read_attribute("id").should eq(blob.id)

      plain = Saci::RichText.plain_text("<p>Before</p>#{html}<p>After</p>")
      plain.should eq("Before After")
      plain.should_not contain("Chart")

      content = Saci::RichText::Content.new("<p>Hi</p>#{html}")
      content.attachments.size.should eq(1)
      content.attachables.map(&.class.name).should contain("Saci::Storage::Blob")

      rendered = content.render_attachments { |attachment| "<span>#{attachment.filename}</span>" }
      rendered.should contain("<p>Hi</p>")
      rendered.should contain("<span>chart.png</span>")
      rendered.should_not contain("<action-text-attachment")

      default_rendered = Saci::Views.render_attachments(html)
      default_rendered.should contain("<a href=")
      default_rendered.should contain("chart.png")

      blob.to_rich_text_attachment.filename.should eq("chart.png")
      blob.to_plain_text.should eq("chart.png")
    end

    it "drops invalid signed ids instead of raising" do
      html = %(<action-text-attachment sgid="not-a-token" content-type="text/plain" filename="x.txt">cap</action-text-attachment>)
      attachment = Saci::RichText.attachments(html).first
      attachment.attachable.should be_nil
      attachment.blob.should be_nil
      Saci::RichText.render_attachments(html).should_not contain("<a href=")
    end
  end
end
