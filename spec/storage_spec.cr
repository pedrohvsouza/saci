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

describe "storage signing-key rotation" do
  it "keeps old urls valid until expiry, signs new with the new key, rejects unknown" do
    ENV["SECRET_KEY_BASE"] = "rotation-spec-secret"
    begin
      with_storage do |service|
        Saci::Storage.service = service
        begin
          Saci::Storage.reset_signing_keys!
          key = service.upload("rot", filename: "r.bin", content_type: "application/octet-stream")
          old_url = Saci::Storage.signed_url(key, base: "/files")
          old_parts = old_url.split("?", 2)[1].split("&")
          old_expires = old_parts[0].split("=")[1].to_i64
          old_sig = old_parts[1].split("=")[1]

          Saci::Storage.rotate_signing_key!("brand-new-secret")
          Saci::Storage.signing_keys.first.should eq("brand-new-secret")

          # Old signatures verify through the grace window (natural expiry).
          Saci::Storage.verified_url?(key, old_expires, old_sig).should be_true

          # New signings use the new key, not the old one.
          new_url = Saci::Storage.signed_url(key, base: "/files")
          new_parts = new_url.split("?", 2)[1].split("&")
          new_expires = new_parts[0].split("=")[1].to_i64
          new_sig = new_parts[1].split("=")[1]
          old_keyed = OpenSSL::HMAC.hexdigest(:sha256, "rotation-spec-secret", "#{key}:#{new_expires}")
          new_sig.should_not eq(old_keyed)
          new_sig.should eq(OpenSSL::HMAC.hexdigest(:sha256, "brand-new-secret", "#{key}:#{new_expires}"))
          Saci::Storage.verified_url?(key, new_expires, new_sig).should be_true

          # Unknown keys never verify.
          forged = OpenSSL::HMAC.hexdigest(:sha256, "attacker-secret", "#{key}:#{new_expires}")
          Saci::Storage.verified_url?(key, new_expires, forged).should be_false

          router = Saci::Router.new.draw do |r|
            r.get "/files/*key", Saci::Storage::FilesController, :show
          end
          Saci::TestSession.serve(router) do |app|
            app.get(old_url).status_code.should eq(200)
            app.get(new_url).status_code.should eq(200)
            app.get("/files/#{key}?expires=#{new_expires}&sig=#{forged}").status_code.should eq(404)
          end
        ensure
          Saci::Storage.reset_signing_keys!
          Saci::Storage.service = Saci::Storage::DiskService.new("storage")
        end
      end
    ensure
      ENV.delete("SECRET_KEY_BASE")
    end
  end

  it "supports an explicit signing_keys list and rejects an empty one" do
    Saci::Storage.signing_keys = ["primary-k", "old-k"]
    begin
      Saci::Storage.signing_keys.should eq(["primary-k", "old-k"])
      expires = Time.utc.to_unix + 300
      old_sig = OpenSSL::HMAC.hexdigest(:sha256, "old-k", "k:#{expires}")
      Saci::Storage.verified_url?("k", expires, old_sig).should be_true
      url = Saci::Storage.signed_url("k", base: "/files", expires_in: 5.minutes)
      url_expires = url.split("?", 2)[1].split("&")[0].split("=")[1].to_i64
      url.split("sig=")[1].should eq(OpenSSL::HMAC.hexdigest(:sha256, "primary-k", "k:#{url_expires}"))
      expect_raises(ArgumentError) { Saci::Storage.signing_keys = [] of String }
    ensure
      Saci::Storage.reset_signing_keys!
    end
  end

  it "still rejects expired urls after rotation" do
    ENV["SECRET_KEY_BASE"] = "rotation-expiry-secret"
    begin
      with_storage do |service|
        Saci::Storage.service = service
        begin
          Saci::Storage.reset_signing_keys!
          key = service.upload("rot-exp", filename: "r.bin")
          expired = Saci::Storage.signed_url(key, base: "/files", expires_in: -10.seconds)
          parts = expired.split("?", 2)[1].split("&")
          Saci::Storage.verified_url?(key, parts[0].split("=")[1].to_i64, parts[1].split("=")[1]).should be_false
          Saci::Storage.rotate_signing_key!("next-secret")
          Saci::Storage.verified_url?(key, parts[0].split("=")[1].to_i64, parts[1].split("=")[1]).should be_false
          router = Saci::Router.new.draw do |r|
            r.get "/files/*key", Saci::Storage::FilesController, :show
          end
          Saci::TestSession.serve(router) do |app|
            app.get(expired).status_code.should eq(404)
          end
        ensure
          Saci::Storage.reset_signing_keys!
          Saci::Storage.service = Saci::Storage::DiskService.new("storage")
        end
      end
    ensure
      ENV.delete("SECRET_KEY_BASE")
    end
  end
end

describe "storage public-file mode" do
  it "serves public uploads unsigned, rejects traversal, keeps private signed" do
    ENV["SECRET_KEY_BASE"] = "public-spec-secret"
    dir = "/tmp/opencode/saci-storage-public"
    begin
      FileUtils.rm_rf(dir)
      Dir.mkdir_p(dir)
      pub = Saci::Storage::DiskService.new(dir, public: true)
      priv = Saci::Storage::DiskService.new(dir)
      pub.public_mode?.should be_true
      priv.public_mode?.should be_false
      Saci::Storage.service = pub
      begin
        Saci::Storage.reset_signing_keys!
        key = pub.upload("pub-data", filename: "p.txt", content_type: "text/plain")
        key.starts_with?("public/").should be_true
        Saci::Storage.valid_key?(key).should be_true
        Saci::Storage.public_key?(key).should be_true
        url = pub.public_url(key, base: "/files")
        url.should eq("/files/#{key}")
        url.includes?("sig").should be_false
        url.includes?("expires").should be_false
        Saci::Storage.public_url(key, base: "/files").should eq(url)

        pkey = priv.upload("sec-data", filename: "s.bin", content_type: "application/octet-stream")
        Saci::Storage.public_key?(pkey).should be_false

        router = Saci::Router.new.draw do |r|
          r.get "/files/*key", Saci::Storage::FilesController, :show
        end
        Saci::TestSession.serve(router) do |app|
          ok = app.get(url)
          ok.status_code.should eq(200)
          ok.body.should eq("pub-data")

          app.get("/files/#{pkey}").status_code.should eq(404)
          signed = Saci::Storage.signed_url(pkey, base: "/files")
          priv_ok = app.get(signed)
          priv_ok.status_code.should eq(200)
          priv_ok.body.should eq("sec-data")

          # Traversal + missing + listing-shaped paths stay 404.
          Saci::Storage.valid_key?("public/../secret").should be_false
          app.get("/files/public/../secret").status_code.should eq(404)
          app.get("/files/public/ab/cd/missing").status_code.should eq(404)
          app.get("/files/public/").status_code.should eq(404)
        end
        expect_raises(Saci::Storage::FileNotFound) { pub.download("public/../secret") }
      ensure
        Saci::Storage.reset_signing_keys!
        Saci::Storage.service = Saci::Storage::DiskService.new("storage")
        FileUtils.rm_rf(dir)
      end
    ensure
      ENV.delete("SECRET_KEY_BASE")
    end
  end

  it "pins per-upload public override over the service default" do
    dir = "/tmp/opencode/saci-storage-mixed"
    begin
      FileUtils.rm_rf(dir)
      Dir.mkdir_p(dir)
      priv_default = Saci::Storage::DiskService.new(dir)
      pub_default = Saci::Storage::DiskService.new(dir, public: true)

      forced_public = priv_default.upload("a", filename: "a.txt", public: true)
      forced_public.starts_with?("public/").should be_true
      forced_private = pub_default.upload("b", filename: "b.txt", public: false)
      forced_private.starts_with?("public/").should be_false
      inherited_public = pub_default.upload("c", filename: "c.txt")
      inherited_public.starts_with?("public/").should be_true
      inherited_private = priv_default.upload("d", filename: "d.txt")
      inherited_private.starts_with?("public/").should be_false

      # Mixed services sharing a root: public serves unsigned, private needs sig.
      ENV["SECRET_KEY_BASE"] = "mixed-spec-secret"
      begin
        Saci::Storage.service = pub_default
        begin
          Saci::Storage.reset_signing_keys!
          router = Saci::Router.new.draw do |r|
            r.get "/files/*key", Saci::Storage::FilesController, :show
          end
          Saci::TestSession.serve(router) do |app|
            app.get(Saci::Storage.public_url(forced_public, base: "/files")).status_code.should eq(200)
            app.get("/files/#{forced_private}").status_code.should eq(404)
            app.get(Saci::Storage.signed_url(forced_private, base: "/files")).status_code.should eq(200)
          end
        ensure
          Saci::Storage.reset_signing_keys!
          Saci::Storage.service = Saci::Storage::DiskService.new("storage")
        end
      ensure
        ENV.delete("SECRET_KEY_BASE")
      end
    ensure
      FileUtils.rm_rf(dir)
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
