require "spec"
require "http/client"
require "file_utils"
require "../src/saci"

# Live S3 harness. Needs an S3-compatible server that checks signatures
# and an existing bucket; `live/s3.sh` starts one in Docker. Run:
# `live/s3.sh` or `S3_ENDPOINT=... S3_BUCKET=... S3_ACCESS_KEY_ID=...
# S3_SECRET_ACCESS_KEY=... crystal spec live/s3_live_spec.cr`.
S3_LIVE_ENDPOINT = ENV["S3_ENDPOINT"]? || abort("S3_ENDPOINT is not set (e.g. http://127.0.0.1:59000). See live/README.md.")
S3_LIVE_BUCKET   = ENV.fetch("S3_BUCKET", "saci-test")
S3_LIVE_KEY_ID   = ENV.fetch("S3_ACCESS_KEY_ID", "saciaccess")
S3_LIVE_SECRET   = ENV.fetch("S3_SECRET_ACCESS_KEY", "saci-secret-key-123")
S3_LIVE_REGION   = ENV.fetch("S3_REGION", "us-east-1")
S3_LIVE_DB       = File.join(Dir.tempdir, "saci_s3_live_#{Process.pid}.db")

class S3LiveTables < Saci::Record::Migration
  def change
    create_table :s3_live_users do |t|
      t.string :name
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

class S3LiveUser < Saci::Record::Base
  table "s3_live_users"
  column id : Int64, primary: true
  column name : String

  has_one_attached :avatar
end

def s3_live_service(secret : String = S3_LIVE_SECRET, bucket : String = S3_LIVE_BUCKET) : Saci::Storage::S3Service
  Saci::Storage::S3Service.new(bucket: bucket, region: S3_LIVE_REGION, access_key_id: S3_LIVE_KEY_ID,
    secret_access_key: secret, endpoint: S3_LIVE_ENDPOINT, name: "s3")
end

def s3_live_key(suffix : String = "") : String
  "live/#{Random::Secure.hex(6)}#{suffix}"
end

def s3_live_get(url : String) : HTTP::Client::Response
  HTTP::Client.get(url)
end

describe "S3Service live" do
  service = s3_live_service

  it "uploads, checks, downloads and deletes an object" do
    data = Bytes.new(256) { |i| i.to_u8 }
    key = service.upload(data, filename: "bytes.bin", content_type: "application/octet-stream", key: s3_live_key)
    service.exists?(key).should be_true
    service.download(key).should eq(data)
    service.delete(key)
    service.exists?(key).should be_false
  end

  it "generates its own key and round-trips strings, IO and empty bodies" do
    key = service.upload("hello s3", filename: "a.txt", content_type: "text/plain")
    Saci::Storage.valid_key?(key).should be_true
    String.new(service.download(key)).should eq("hello s3")
    service.delete(key)

    io_key = service.upload(IO::Memory.new("from io"), filename: "b.txt", key: s3_live_key)
    String.new(service.download(io_key)).should eq("from io")
    service.delete(io_key)

    empty_key = service.upload(Bytes.empty, filename: "empty.txt", key: s3_live_key)
    service.exists?(empty_key).should be_true
    service.download(empty_key).should eq(Bytes.empty)
    service.delete(empty_key)
  end

  it "handles a multi-megabyte object" do
    data = Random.new(42).random_bytes(6 * 1024 * 1024)
    key = service.upload(data, filename: "big.bin", key: s3_live_key)
    service.download(key).should eq(data)
    service.delete(key)
  end

  it "signs keys with characters that need encoding" do
    ["live/space name.txt", "live/plus+equals=.txt", "live/tilde~(paren)!.txt", "live/ação/naïve 日本.txt",
     "live/semi;colon,comma&amp@at$.txt"].each do |key|
      service.upload("x:#{key}", filename: "k.txt", content_type: "text/plain", key: key).should eq(key)
      service.exists?(key).should be_true
      String.new(service.download(key)).should eq("x:#{key}")
      response = s3_live_get(service.url(key))
      response.status_code.should eq(200)
      response.body.should eq("x:#{key}")
      service.delete(key)
      service.exists?(key).should be_false
    end
  end

  it "reports missing objects" do
    key = s3_live_key("-missing")
    service.exists?(key).should be_false
    expect_raises(Saci::Storage::FileNotFound) { service.download(key) }
    service.delete(key) # idempotent
  end

  it "serves pre-signed URLs with the stored content type and rejects tampering" do
    key = service.upload("<p>hi</p>", filename: "page.html", content_type: "text/plain", key: s3_live_key)
    url = service.url(key, expires_in: 2.minutes)
    response = s3_live_get(url)
    response.status_code.should eq(200)
    response.body.should eq("<p>hi</p>")
    response.headers["Content-Type"].should start_with("text/plain")

    s3_live_get(url.sub(/X-Amz-Signature=[0-9a-f]{4}/, "X-Amz-Signature=0000")).status_code.should eq(403)
    s3_live_get(url.sub("X-Amz-Expires=120", "X-Amz-Expires=600")).status_code.should eq(403)
    service.delete(key)
  end

  it "fails loudly with a wrong secret or bucket" do
    expect_raises(Saci::Storage::Error, /S3 upload failed \(403\)/) do
      s3_live_service(secret: "wrong-secret").upload("x", filename: "x.txt", key: s3_live_key)
    end
    expect_raises(Saci::Storage::Error, /S3 upload failed \(404\)/) do
      s3_live_service(bucket: "saci-no-such-bucket-#{Random::Secure.hex(4)}").upload("x", filename: "x.txt", key: s3_live_key)
    end
  end

  describe "with blobs and attachments" do
    before_all do
      File.delete(S3_LIVE_DB) if File.exists?(S3_LIVE_DB)
      Saci::Record::Base.connection = DB.open("sqlite3://#{S3_LIVE_DB}")
      Saci::Record::Migrator.migrate(Saci::Record::Base.connection.as(DB::Database), [S3LiveTables] of Saci::Record::Migration.class)
      Saci::Storage.service = service
    end

    after_all do
      Saci::Storage.reset_services!
      Saci::Record::Base.connection.as(DB::Database).close
      File.delete(S3_LIVE_DB) if File.exists?(S3_LIVE_DB)
    end

    it "attaches, serves and purges through S3" do
      user = S3LiveUser.create!(name: "ana")
      user.avatar.attach(IO::Memory.new("avatar-bytes"), filename: "me.txt", content_type: "text/plain")
      blob = user.avatar.blob.not_nil!
      blob.service_name.should eq("s3")
      service.exists?(blob.key.not_nil!).should be_true

      String.new(blob.download).should eq("avatar-bytes")
      response = s3_live_get(user.avatar.url.not_nil!)
      response.status_code.should eq(200)
      response.body.should eq("avatar-bytes")

      user.avatar.purge
      service.exists?(blob.key.not_nil!).should be_false
    end
  end
end
