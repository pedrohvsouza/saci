require "spec"
require "file_utils"
require "../src/saci"

STORAGE_TMP = "/tmp/opencode/saci-storage"

def with_storage(& : Saci::Storage::DiskService ->) : Nil
  FileUtils.rm_rf(STORAGE_TMP)
  Dir.mkdir_p(STORAGE_TMP)
  service = Saci::Storage::DiskService.new(STORAGE_TMP)
  begin
    yield service
  ensure
    FileUtils.rm_rf(STORAGE_TMP)
  end
end

describe Saci::Storage::DiskService do
  it "round-trips uploads with metadata" do
    with_storage do |service|
      key = service.upload("hello", filename: "hi.txt", content_type: "text/plain")
      key.should match(/\A[0-9a-f\/]+\z/)
      service.exists?(key).should be_true
      String.new(service.download(key)).should eq("hello")
      stored = service.locate(key).not_nil!
      stored.filename.should eq("hi.txt")
      stored.content_type.should eq("text/plain")
      service.delete(key)
      service.exists?(key).should be_false
    end
  end

  it "rejects traversal keys and missing files" do
    with_storage do |service|
      expect_raises(Saci::Storage::FileNotFound) { service.download("../x") }
      expect_raises(Saci::Storage::FileNotFound) { service.download("ab/cd/nope") }
    end
  end
end

describe "storage routes" do
  it "serves signed urls and rejects tampered or expired ones" do
    ENV["SECRET_KEY_BASE"] = "storage-spec-secret"
    begin
      with_storage do |service|
        Saci::Storage.service = service
        begin
          key = service.upload("binary-data", filename: "data.bin", content_type: "application/octet-stream")
          router = Saci::Router.new.draw do |r|
            r.get "/files/*key", Saci::Storage::FilesController, :show
          end
          Saci::TestSession.serve(router) do |app|
            url = Saci::Storage.signed_url(key, base: "/files")
            ok = app.get(url)
            ok.status_code.should eq(200)
            ok.body.should eq("binary-data")
            ok.headers["Content-Disposition"].should contain("data.bin")

            bad = app.get("#{url}x")
            bad.status_code.should eq(404)

            expired = Saci::Storage.signed_url(key, base: "/files", expires_in: -10.seconds)
            app.get(expired).status_code.should eq(404)
          end
        ensure
          Saci::Storage.service = Saci::Storage::DiskService.new("storage")
        end
      end
    ensure
      ENV.delete("SECRET_KEY_BASE")
    end
  end
end
