require "spec"
require "file_utils"
require "../src/saci"
require "../src/saci/cli/util"
require "../src/saci/cli/assets_command"

private def assets_tmp(label : String) : String
  dir = File.join("/tmp/opencode", "saci-assets-#{label}-#{Random::Secure.hex(4)}")
  Dir.mkdir_p(dir)
  dir
end

private def with_app_env(value : String, &) : Nil
  previous = ENV["APP_ENV"]?
  ENV["APP_ENV"] = value
  begin
    yield
  ensure
    previous ? (ENV["APP_ENV"] = previous) : ENV.delete("APP_ENV")
  end
end

private def assets_router : Saci::Router
  Saci::Router.new.draw do |r|
    r.get("/hello") { |ctx, _params| ctx.response.print("hello") }
  end
end

DIGEST_64 = "a" * 64

describe "Saci::Middleware::Static cache headers" do
  it "defaults to no-cache in development and test, max-age elsewhere" do
    settings = Saci::Middleware::Static::Settings.new
    with_app_env("development") { settings.cache_control.should eq("no-cache") }
    with_app_env("test") { settings.cache_control.should eq("no-cache") }
    with_app_env("production") { settings.cache_control.should eq("public, max-age=3600") }
    settings.cache_control = "public, max-age=5"
    with_app_env("development") { settings.cache_control.should eq("public, max-age=5") }
    settings.cache_control = nil
    with_app_env("production") { settings.cache_control.should be_nil }
  end

  it "serves fingerprinted files as immutable in every environment" do
    root = assets_tmp("static")
    Dir.mkdir_p(File.join(root, "assets"))
    File.write(File.join(root, "assets", "app-#{DIGEST_64}.css"), "a{}")
    File.write(File.join(root, "assets", "app.css"), "a{}")
    config = Saci::Configuration.new
    config.public_file_server.root = root
    begin
      with_app_env("development") do
        Saci::TestSession.serve(assets_router, config: config) do |app|
          app.get("/assets/app-#{DIGEST_64}.css").headers["Cache-Control"].should eq("public, max-age=31536000, immutable")
          app.get("/assets/app.css").headers["Cache-Control"].should eq("no-cache")
        end
      end
      with_app_env("production") do
        Saci::TestSession.serve(assets_router, config: config) do |app|
          app.get("/assets/app.css").headers["Cache-Control"].should eq("public, max-age=3600")
        end
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "recognizes digested file names" do
    Saci::Middleware::Static.digested?("app-#{DIGEST_64}.css").should be_true
    Saci::Middleware::Static.digested?("images/logo-#{DIGEST_64}.png").should be_true
    Saci::Middleware::Static.digested?("app.css").should be_false
    Saci::Middleware::Static.digested?("app-1234.css").should be_false
  end
end

describe Saci::Middleware::DevAssets do
  it "serves src/assets under /assets with no-cache in development" do
    source = assets_tmp("dev-source")
    public_root = assets_tmp("dev-public")
    File.write(File.join(source, "application.css"), "body{}")
    Dir.mkdir_p(File.join(source, "images"))
    File.write(File.join(source, "images", "logo.svg"), "<svg/>")
    File.write(File.join(source, ".secret"), "x")
    Dir.mkdir_p(File.join(public_root, "assets"))
    File.write(File.join(public_root, "assets", "legacy.css"), "legacy{}")
    config = Saci::Configuration.new
    config.assets.source = source
    config.public_file_server.root = public_root
    begin
      with_app_env("development") do
        Saci::TestSession.serve(assets_router, config: config) do |app|
          css = app.get("/assets/application.css")
          css.status_code.should eq(200)
          css.body.should eq("body{}")
          css.headers["Content-Type"].should contain("text/css")
          css.headers["Cache-Control"].should eq("no-cache")
          app.get("/assets/application.css", HTTP::Headers{"If-None-Match" => css.headers["ETag"]}).status_code.should eq(304)
          app.get("/assets/images/logo.svg").body.should eq("<svg/>")
          app.get("/assets/.secret").status_code.should eq(404)
          app.get("/assets/../#{File.basename(public_root)}").status_code.should eq(404)
          # Misses fall through to public/ and then the router.
          app.get("/assets/legacy.css").body.should eq("legacy{}")
          app.get("/hello").body.should eq("hello")
        end
      end
    ensure
      FileUtils.rm_rf(source)
      FileUtils.rm_rf(public_root)
    end
  end

  it "stays off in production unless enabled" do
    source = assets_tmp("dev-prod")
    File.write(File.join(source, "application.css"), "body{}")
    config = Saci::Configuration.new
    config.assets.source = source
    config.public_file_server.root = File.join(source, "missing-public")
    begin
      with_app_env("production") do
        config.assets.active?.should be_false
        config.assets.enabled = true
        config.assets.active?.should be_true
      end
    ensure
      FileUtils.rm_rf(source)
    end
  end
end

describe "Saci::Assets.precompile / clobber" do
  it "writes digested and plain copies plus a manifest, then removes only its output" do
    root = assets_tmp("precompile")
    source = File.join(root, "src", "assets")
    output = File.join(root, "public", "assets")
    Dir.mkdir_p(File.join(source, "images"))
    File.write(File.join(source, "application.css"), "body{}")
    File.write(File.join(source, "images", "logo.svg"), "<svg/>")
    Dir.mkdir_p(output)
    File.write(File.join(output, "stale-#{DIGEST_64}.css"), "old")
    File.write(File.join(output, "hand-written.txt"), "keep me")
    File.write(File.join(output, ".manifest.json"), %({"stale.css":"stale-#{DIGEST_64}.css"}))
    begin
      manifest = Saci::Assets.precompile(source, output)
      manifest.keys.sort.should eq(["application.css", "images/logo.svg"])
      digested = manifest["application.css"]
      digested.should match(/\Aapplication-[0-9a-f]{64}\.css\z/)
      File.read(File.join(output, digested)).should eq("body{}")
      File.read(File.join(output, "application.css")).should eq("body{}")
      File.exists?(File.join(output, "images", "logo.svg")).should be_true
      File.exists?(File.join(output, "stale-#{DIGEST_64}.css")).should be_false
      Saci::Assets.asset_path("application.css").should eq("/assets/#{digested}")

      Saci::Assets.clobber(output, source).should eq(5)
      File.read(File.join(output, "hand-written.txt")).should eq("keep me")
      Dir.children(output).should eq(["hand-written.txt"])
      Saci::Assets.asset_path("application.css").should eq("/assets/application.css")
    ensure
      Saci::Assets.manifest_path = nil
      FileUtils.rm_rf(root)
    end
  end

  it "refuses overlapping or missing directories" do
    root = assets_tmp("precompile-bad")
    begin
      expect_raises(ArgumentError, /does not exist/) { Saci::Assets.precompile(File.join(root, "nope"), File.join(root, "out")) }
      expect_raises(ArgumentError, /separate directories/) { Saci::Assets.precompile(root, root) }
      expect_raises(ArgumentError, /separate directories/) { Saci::Assets.precompile(root, File.join(root, "out")) }
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "is driven by saci assets:precompile and assets:clobber" do
    root = assets_tmp("precompile-cli")
    Dir.mkdir_p(File.join(root, "src", "assets"))
    File.write(File.join(root, "src", "assets", "app.js"), "go()")
    begin
      Dir.cd(root) do
        Saci::CLI::AssetsCommand.run([] of String, "precompile").should eq(0)
        Dir.glob("public/assets/app-*.js").size.should eq(1)
        File.exists?("public/assets/.manifest.json").should be_true
        Saci::CLI::AssetsCommand.run([] of String, "clobber").should eq(0)
        Dir.exists?("public/assets").should be_false
        expect_raises(Saci::CLI::Error, /does not exist/) do
          Saci::CLI::AssetsCommand.run(["--source", "missing"], "precompile")
        end
      end
    ensure
      Saci::Assets.manifest_path = nil
      FileUtils.rm_rf(root)
    end
  end
end
