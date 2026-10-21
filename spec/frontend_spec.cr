require "spec"
require "file_utils"
require "json"
require "../src/saci"
require "../src/saci/importmap"
require "../src/saci/turbo_drive"
require "../src/saci/stimulus"
require "../src/saci/pwa"
require "../src/saci/frontend"
require "../src/saci/cli/importmap_command"

def frontend_tmp_dir(name : String, & : String ->) : Nil
  dir = File.join("/tmp/opencode", "saci-frontend-#{name}-#{Random.rand(1_000_000)}")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

def with_frontend_assets_root(dir : String, & : ->) : Nil
  previous_root = Saci::Assets.root
  previous_manifest = Saci::Assets.manifest_path
  Saci::Assets.configure(root: dir)
  begin
    yield
  ensure
    Saci::Assets.configure(root: previous_root, manifest_path: previous_manifest)
    Saci::Importmap.reset!
  end
end

describe "Saci::Importmap" do
  it "builds pins and standard imports JSON" do
    Saci::Importmap.reset!
    manifest = Saci::Importmap.draw do |map|
      map.pin "application", to: "app/javascript/application.js", preload: true
      map.pin "turbo", to: "vendor/javascript/turbo.js"
      map.pin "remote", to: "https://cdn.example.com/turbo.js"
    end

    manifest.pins.map(&.name).should eq(["application", "turbo", "remote"])
    imports = JSON.parse(manifest.to_json)["imports"]
    imports["application"].as_s.should eq("/assets/application.js")
    imports["turbo"].as_s.should eq("/assets/turbo.js")
    imports["remote"].as_s.should eq("https://cdn.example.com/turbo.js")
    manifest.preloads.map(&.name).should eq(["application"])
  end

  it "pins every .js file recursively with a name prefix" do
    frontend_tmp_dir("pin-all") do |dir|
      Dir.mkdir_p(File.join(dir, "app/javascript/controllers/nested"))
      File.write(File.join(dir, "app/javascript/controllers/hello_controller.js"), "export default class {}\n")
      File.write(File.join(dir, "app/javascript/controllers/nested/inner.js"), "export default 1\n")
      File.write(File.join(dir, "app/javascript/controllers/README.md"), "not a controller\n")

      with_frontend_assets_root(dir) do
        Saci::Importmap.reset!
        manifest = Saci::Importmap.draw do |map|
          map.pin_all_from "app/javascript/controllers", under: "controllers"
        end
        manifest.pins.map(&.name).should eq([
          "controllers/hello_controller",
          "controllers/nested/inner",
        ])
        imports = JSON.parse(manifest.to_json)["imports"]
        imports["controllers/hello_controller"].as_s.should eq("/assets/controllers/hello_controller.js")
        imports["controllers/nested/inner"].as_s.should eq("/assets/controllers/nested/inner.js")
      end
    end
  end

  it "resolves digest-fingerprinted paths through Saci::Assets" do
    frontend_tmp_dir("digest") do |dir|
      source = File.join(dir, "app/javascript")
      Dir.mkdir_p(File.join(source, "controllers"))
      File.write(File.join(source, "application.js"), "console.log('app')\n")
      File.write(File.join(source, "controllers/hello_controller.js"), "export default class {}\n")

      with_frontend_assets_root(dir) do
        Saci::Assets.build_manifest(source, File.join(dir, "public/assets"))
        Saci::Importmap.reset!
        manifest = Saci::Importmap.draw do |map|
          map.pin "application", to: "app/javascript/application.js", preload: true
          map.pin_all_from "app/javascript/controllers", under: "controllers"
        end

        imports = JSON.parse(manifest.to_json)["imports"]
        imports["application"].as_s.should match(%r{\A/assets/application-[0-9a-f]{64}\.js\z})
        imports["controllers/hello_controller"].as_s.should match(
          %r{\A/assets/controllers/hello_controller-[0-9a-f]{64}\.js\z}
        )

        # Explicit /assets paths are digest-aware too.
        manifest.pin("explicit", to: "/assets/application.js")
        Saci::Importmap.resolve(manifest.pins.last).should eq(imports["application"].as_s)
      end
    end
  end

  it "escapes inline JSON so pin names cannot close the script element" do
    Saci::Importmap.reset!
    Saci::Importmap.pin(%(evil</script><!--<script>alert(1)</script>), to: "/assets/evil.js")
    manifest = Saci::Importmap.default
    tags = Saci::Importmap.importmap_tags(manifest, preload: false)

    tags.scan("</script>").size.should eq(1)
    tags.should_not contain("</script><script>")
    tags.should contain("evil<\\/script>")
    inline_json = tags[(tags.index('>').not_nil! + 1)..].sub("</script>", "")
    JSON.parse(inline_json)["imports"].as_h.size.should eq(1)
    JSON.parse(manifest.to_json)["imports"].as_h.size.should eq(1)
  end

  it "renders modulepreload links for flagged pins" do
    Saci::Importmap.reset!
    Saci::Importmap.pin("application", to: "app/javascript/application.js", preload: true)
    tags = Saci::Importmap.importmap_tags
    tags.should start_with(%(<script type="importmap">))
    tags.should contain(%(<link rel="modulepreload" href="/assets/application.js">))
    tags.should contain(%("/assets/application.js"))
  end

  it "writes config/importmap.json and leaves rooted paths alone" do
    frontend_tmp_dir("write") do |dir|
      path = File.join(dir, "config/importmap.json")
      Saci::Importmap.reset!
      Saci::Importmap.pin("custom", to: "/custom/name.js")
      Saci::Importmap.write(path, Saci::Importmap.default).should eq(path)
      content = File.read(path)
      content.ends_with?("\n").should be_true
      JSON.parse(content)["imports"]["custom"].as_s.should eq("/custom/name.js")
    end
  end
end

describe "Saci::TurboDrive" do
  it "ships the vendored dependency-free implementation as a resource" do
    js = Saci::TurboDrive::JS
    js.should contain("DOMParser")
    js.should contain("pushState")
    js.should contain("replaceState")
    js.should contain("popstate")
    js.should contain("before-fetch-request")
    js.should contain("data-turbo")
    js.should contain("SaciTurboDrive")
    js.should_not contain("import ")
  end

  it "emits a meta marker and module script when enabled" do
    previous = Saci.config.turbo_drive
    begin
      Saci.config.turbo_drive = true
      tags = Saci::TurboDrive.turbo_drive_tags
      tags.should contain(%(<meta name="turbo-drive" content="enabled">))
      tags.should contain(%(<script type="module" data-turbo-drive>))
      tags.should contain("SaciTurboDrive")
      Saci.turbo_drive?.should be_true
    ensure
      Saci.config.turbo_drive = previous
    end
  end

  it "returns nothing when globally disabled but allows a local override" do
    previous = Saci.config.turbo_drive
    begin
      Saci.config.turbo_drive = false
      Saci::TurboDrive.turbo_drive_tags.should eq("")
      Saci::TurboDrive.turbo_drive_tags(enabled: true).should contain("data-turbo-drive")
    ensure
      Saci.config.turbo_drive = previous
    end
  end
end

describe "Saci::Stimulus" do
  it "stores a controller manifest and emits the loader" do
    Saci::Stimulus.reset!
    manifest = Saci::Stimulus.draw do |map|
      map.controller "hello", path: "controllers/hello_controller"
      map.controller "world"
    end

    manifest.stimulus_controllers.map(&.identifier).should eq(["hello", "world"])
    manifest.to_h["world"].should eq("controllers/world_controller")
    tags = Saci::Stimulus.stimulus_tags(manifest)
    tags.should contain(%(<meta name="stimulus-controllers" content="hello world">))
    tags.should contain(%(window.__SACI_STIMULUS_MODULES__ = {"hello":"controllers/hello_controller","world":"controllers/world_controller"};))
    tags.should contain(%(<script type="module" data-stimulus>))
  end

  it "vendors data-controller, data-action, targets and values support" do
    js = Saci::Stimulus::JS
    js.should contain("data-controller")
    js.should contain("data-action")
    js.should contain("-target")
    js.should contain("-value")
    js.should contain("SaciStimulus")
    js.should contain("MutationObserver")
    js.should contain("turbo:load")
    js.should_not contain("import {")
  end

  it "generates controller templates and normalizes identifiers" do
    Saci::Stimulus.identifier_for("HelloController").should eq("hello")
    Saci::Stimulus.identifier_for("hello_controller").should eq("hello")
    Saci::Stimulus.identifier_for("nested/MyWidget").should eq("nested-my-widget")

    source = Saci::Stimulus.stimulus_controller("HelloController", ["greet"])
    source.should contain(%(export default class extends window.SaciStimulus.Controller))
    source.should contain(%(data-controller="hello"))
    source.should contain(%(data-action="click->hello#greet"))
    source.should contain("greet(event)")
    Saci::CLI::Generate.stimulus_controller("hello").should eq(Saci::Stimulus.controller_template("hello"))
  end
end

describe "Saci::PWA" do
  it "generates a parseable web app manifest" do
    json = Saci::PWA.manifest_json(
      name: "Saci App",
      short_name: "Saci",
      start_url: "/app",
      theme_color: "#123456",
      description: nil
    )
    parsed = JSON.parse(json)
    parsed["name"].as_s.should eq("Saci App")
    parsed["short_name"].as_s.should eq("Saci")
    parsed["start_url"].as_s.should eq("/app")
    parsed["theme_color"].as_s.should eq("#123456")
    parsed["display"].as_s.should eq("standalone")
    parsed["icons"].as_a.size.should eq(2)
    parsed.as_h.has_key?("description").should be_false
  end

  it "supports custom icons and writes manifest/service-worker templates" do
    frontend_tmp_dir("pwa") do |dir|
      manifest_path = File.join(dir, "public/manifest.json")
      worker_path = File.join(dir, "public/service-worker.js")
      icons = [Saci::PWA::Icon.new("/custom.png", "144x144", "image/png")]

      Saci::PWA.write_manifest(manifest_path, name: "PWA", icons: icons).should eq(manifest_path)
      JSON.parse(File.read(manifest_path))["icons"].as_a.first["src"].as_s.should eq("/custom.png")

      Saci::PWA.write_service_worker(
        worker_path,
        version: "v7",
        precache: ["/", "/app.js"],
        offline_url: "/offline.html"
      ).should eq(worker_path)
      source = File.read(worker_path)
      source.should contain(%(const VERSION = "v7";))
      source.should contain(%(const CACHE_NAME = "saci-pwa-v7";))
      source.should contain(%(const PRECACHE_URLS = ["/","/app.js"];))
      source.should contain(%(const OFFLINE_URL = "/offline.html";))
      source.should contain("cache.match(OFFLINE_URL)")
      source.should contain("skipWaiting")
    end
  end

  it "renders manifest, theme and service-worker registration tags" do
    tags = Saci::PWA.pwa_tags(
      manifest_path: "/manifest.json",
      service_worker: "/service-worker.js",
      theme_color: "#0f172a",
      icon: "/icon-192.png"
    )
    tags.should contain(%(<link rel="manifest" href="/manifest.json">))
    tags.should contain(%(<meta name="theme-color" content="#0f172a">))
    tags.should contain(%(<link rel="apple-touch-icon" href="/icon-192.png">))
    tags.should contain(%(navigator.serviceWorker.register("/service-worker.js", { scope: "/" })))
    Saci::PWA.pwa_tags(service_worker: nil).should_not contain("serviceWorker")
  end
end

class FrontendDemoController < Saci::Controller
  def index
    html = [
      importmap_tags,
      turbo_drive_tags,
      stimulus_tags,
      pwa_tags(theme_color: "#000000"),
      turbo_stream_from("room:1"),
      turbo_stream("append", target: "msgs", html: "<p>hi</p>"),
      turbo_frame_tag("profile") { "<p>x</p>" },
    ].join("\n")
    render html: html
  end
end

def frontend_router : Saci::Router
  Saci::Router.new.draw do |r|
    r.get "/frontend", FrontendDemoController, :index
  end
end

describe "frontend tag helpers" do
  it "exposes every helper in controller/ECR context exactly once" do
    Saci::Importmap.reset!
    Saci::Stimulus.reset!
    Saci::TestSession.serve(frontend_router) do |app|
      response = app.get("/frontend")
      response.status_code.should eq(200)
      response.body.should contain(%(<script type="importmap">))
      response.body.should contain(%(<script type="module" data-turbo-drive>))
      response.body.should contain(%(data-stimulus))
      response.body.should contain(%(<link rel="manifest" href="/manifest.json">))
      response.body.should contain(%(<turbo-cable-stream-source channel="Saci::Turbo::StreamsChannel" stream="room:1">))
      response.body.should contain(%(<turbo-stream action="append" target="msgs"><template><p>hi</p></template></turbo-stream>))
      response.body.should contain(%(<turbo-frame id="profile"><p>x</p></turbo-frame>))
    end
  end

  it "escapes stream names and targets in tag helpers" do
    Saci::Turbo.turbo_stream_from(%(a"b)).should contain(%(stream="a&quot;b"))
    Saci::Turbo.turbo_stream("append", target: %(a"b), html: "<p>x</p>").should contain(%(target="a&quot;b"))
    Saci::Turbo.turbo_stream("append", "msgs", "<p>x</p>").should eq(
      %(<turbo-stream action="append" target="msgs"><template><p>x</p></template></turbo-stream>)
    )
    Saci::Views.turbo_frame_tag("profile") { "<p>raw</p>" }.should eq(
      %(<turbo-frame id="profile"><p>raw</p></turbo-frame>)
    )
  end

  it "does not redefine turbo_frame_tag on Controller" do
    source = File.read("src/saci/frontend.cr")
    source.scan(/def self\.turbo_frame_tag/).size.should eq(1)
    source.scan(/def turbo_frame_tag/).size.should eq(0)

    controller_definitions = Dir.glob("src/saci/**/*.cr").sum do |path|
      File.read(path).scan(/def turbo_frame_tag/).size
    end
    controller_definitions.should eq(1)
  end
end

describe "Saci::CLI::ImportmapCommand" do
  it "installs config/importmap.json and scaffolds application.js" do
    frontend_tmp_dir("cli-install") do |dir|
      Dir.cd(dir) do
        Saci::Importmap.reset!
        io = IO::Memory.new
        Saci::CLI::ImportmapCommand.run(["install"], io).should eq(0)
        File.file?("config/importmap.json").should be_true
        File.file?("app/javascript/application.js").should be_true
        imports = JSON.parse(File.read("config/importmap.json"))["imports"]
        imports["application"].as_s.should eq("/assets/application.js")
        io.to_s.should contain("Wrote config/importmap.json")

        json_io = IO::Memory.new
        Saci::CLI::ImportmapCommand.run(["json"], json_io).should eq(0)
        JSON.parse(json_io.to_s)["imports"]["application"].as_s.should eq("/assets/application.js")
      end
    end
  end

  it "pins a package and prints an explicit manifest path" do
    frontend_tmp_dir("cli-pin") do |dir|
      Dir.cd(dir) do
        Saci::Importmap.reset!
        io = IO::Memory.new
        Saci::CLI::ImportmapCommand.run(["pin", "turbo", "--to=vendor/javascript/turbo.js", "--preload"], io).should eq(0)
        imports = JSON.parse(File.read("config/importmap.json"))["imports"]
        imports["turbo"].as_s.should eq("/assets/turbo.js")

        output = IO::Memory.new
        Saci::CLI::ImportmapCommand.run(["json", "--output=config/printed.json"], output).should eq(0)
        File.file?("config/printed.json").should be_true
        JSON.parse(File.read("config/printed.json"))["imports"]["turbo"].as_s.should eq("/assets/turbo.js")
      end
    end
  end
end
