require "spec"
require "file_utils"
require "json"
require "yaml"
require "../src/saci"
require "../src/saci/cli/util"
require "../src/saci/cli/generate_command"
require "../src/saci/cli/new_command"

private def with_deploy_app(name : String, db : String = "sqlite", devcontainer : Bool = false, & : String ->) : Nil
  dir = File.join("/tmp/opencode", "saci-deploy-#{name}-#{Random.rand(1_000_000)}")
  begin
    Saci::CLI::New.create(name, dir: dir, skip_shards: true, skip_git: true, db: db, devcontainer: devcontainer)
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

private def deploy_file(dir : String, *parts : String) : String
  File.read(File.join(dir, *parts))
end

private def deploy_config(dir : String, name : String | Symbol, env : String = "production") : Saci::ConfigFile::Section
  Saci::ConfigFile.config_for(name, env: env, path: File.join(dir, "config", "#{name}.yml"))
end

describe "deployment/config scaffold" do
  describe "config/database.yml (G147)" do
    it "generates the four environments with the selected adapter" do
      {"sqlite" => "sqlite3", "postgres" => "postgres", "mysql" => "mysql"}.each do |flavor, adapter|
        with_deploy_app("dbconf#{flavor}", db: flavor) do |dir|
          path = File.join(dir, "config", "database.yml")
          parsed = Saci::ConfigFile.load(path)
          %w[development test staging production].each do |env|
            parsed.has_key?(env).should be_true
            section = deploy_config(dir, :database, env)
            section[:adapter].as_s.should eq(adapter)
            section["pool"].as_i?.should eq(5)
            section["database"].as_s.should contain(env)
          end
          deploy_file(dir, "config", "database.yml").should contain("replicas:")
          deploy_file(dir, "config", "database.yml").should contain("DATABASE_URL")
        end
      end
    end

    it "assembles a URL per flavor from the declarative file" do
      with_deploy_app("dbsqlite", db: "sqlite") do |dir|
        url = Saci::ConfigFile.database_url("test", path: File.join(dir, "config", "database.yml"))
        url.should eq("sqlite3://./db/dbsqlite_test.db")
      end
      with_deploy_app("dbpostgres", db: "postgres") do |dir|
        url = Saci::ConfigFile.database_url("test", path: File.join(dir, "config", "database.yml"))
        url.should eq("postgres://postgres@localhost:5432/dbpostgres_test")
      end
      with_deploy_app("dbmysql", db: "mysql") do |dir|
        url = Saci::ConfigFile.database_url("test", path: File.join(dir, "config", "database.yml"))
        url.should eq("mysql://root@localhost:3306/dbmysql_test")
      end
    end
  end

  describe "Saci::ConfigFile" do
    it "interpolates only ENV[...] and ENV.fetch(...)" do
      Saci::ConfigFile.interpolate(%(<%= ENV["SACI_DEPLOY_MISSING"] %>)).should eq("")
      Saci::ConfigFile.interpolate(%(<%= ENV.fetch("SACI_DEPLOY_MISSING", "fallback") %>)).should eq("fallback")

      ENV["SACI_DEPLOY_VALUE"] = "hello"
      begin
        Saci::ConfigFile.interpolate(%(x: <%= ENV["SACI_DEPLOY_VALUE"] %>)).should eq("x: hello")
        Saci::ConfigFile.interpolate(%(x: <%= ENV.fetch("SACI_DEPLOY_VALUE", "nope") %>)).should eq("x: hello")
      ensure
        ENV.delete("SACI_DEPLOY_VALUE")
      end
    end

    it "reads symbol and string keys for an environment section" do
      path = File.join("/tmp/opencode", "saci-config-#{Random.rand(1_000_000)}.yml")
      begin
        ENV["SACI_DEPLOY_URL"] = "postgres://user:secret@db.example.com/app"
        File.write(path, <<-YAML)
        development:
          adapter: postgres
          url: <%= ENV["SACI_DEPLOY_URL"] %>
          pool: 9
        YAML

        section = Saci::ConfigFile.config_for(:database, env: "development", path: path)
        section[:adapter].as_s.should eq("postgres")
        section["adapter"].as_s.should eq("postgres")
        section[:url].as_s.should eq("postgres://user:secret@db.example.com/app")
        section[:pool].as_i?.should eq(9)
        section.dig(:missing).should be_nil

        Saci::ConfigFile.config_for(:database, env: "test", path: path).empty?.should be_true
        Saci::ConfigFile.config_for(:database, env: "development", path: path).path.should eq(path)
        Saci::ConfigFile.config_for(:not_there, env: "development", path: "#{path}.missing").empty?.should be_true
        expect_raises(Saci::ConfigFile::Error) do
          Saci::ConfigFile.config_for!(:database, env: "test", path: path)
        end
      ensure
        ENV.delete("SACI_DEPLOY_URL")
        File.delete(path) if File.exists?(path)
      end
    end

    it "is reachable through Saci.config_for and Configuration#config_for" do
      path = File.join("/tmp/opencode", "saci-config-module-#{Random.rand(1_000_000)}.yml")
      begin
        File.write(path, "production:\n  store: memory\n")
        Saci.config_for(:cache, env: "production", path: path)[:store].as_s.should eq("memory")
        Saci.config.config_for(:cache, env: "production", path: path)[:store].as_s.should eq("memory")
        Saci.config_for(:cache, env: "development", path: path).empty?.should be_true
      ensure
        File.delete(path) if File.exists?(path)
      end
    end
  end

  describe "declarative config files (G148)" do
    it "generates parseable per-environment cache/queue/cable/recurring/storage/server files" do
      with_deploy_app("configs") do |dir|
        {"cache" => "store", "queue" => "adapter", "cable" => "adapter",
         "recurring" => "enabled", "storage" => "service", "server" => "port"}.each do |name, key|
          path = File.join(dir, "config", "#{name}.yml")
          File.exists?(path).should be_true
          parsed = Saci::ConfigFile.load(path)
          %w[development test staging production].each do |env|
            parsed.has_key?(env).should be_true
            section = deploy_config(dir, name, env)
            section.has_key?(key).should be_true
          end
        end

        deploy_config(dir, :cache, "production")[:store].as_s.should eq("memory")
        deploy_config(dir, :queue, "test")[:adapter].as_s.should eq("test")
        deploy_config(dir, :storage, "production")[:service].as_s.should eq("local")
        deploy_config(dir, :server, "production")[:host].as_s.should eq("0.0.0.0")
      end
    end

    it "keeps framework defaults when the files are absent" do
      Saci::ConfigFile.config_for(:cache, env: "production", path: "/tmp/opencode/definitely-missing.yml").empty?.should be_true
      Saci::ConfigFile.database_url("production", path: "/tmp/opencode/definitely-missing.yml").should be_nil
    end
  end

  describe "server config and graceful shutdown (G138/G139)" do
    it "generates config/server.cr and loads config/server.yml" do
      with_deploy_app("serverconf") do |dir|
        server_cr = deploy_file(dir, "config", "server.cr")
        server_cr.should contain("Saci::Deploy::ServerConfig.reload!(\"config/server.yml\")")
        server_cr.should contain("SACI_SHUTDOWN_TIMEOUT")
        server_cr.should contain("SACI_THREADS")

        production = Saci::Deploy::ServerConfig.load(File.join(dir, "config", "server.yml"), "production")
        production.host.should eq("0.0.0.0")
        production.port.should eq(3000)
        production.threads.should eq(4)
        production.reuse_port.should be_true
        production.keep_alive_timeout.should eq(5.seconds)
        production.request_timeout.should eq(30.seconds)
        production.shutdown_timeout.should eq(15.seconds)
        production.summary.should contain("threads=4")

        development = Saci::Deploy::ServerConfig.load(File.join(dir, "config", "server.yml"), "development")
        development.host.should eq("127.0.0.1")
        development.reuse_port.should be_false
        development.shutdown_timeout.should eq(10.seconds)
      end
    end

    it "runs shutdown hooks after draining in-flight work" do
      shutdown = Saci::Deploy::GracefulShutdown.new(timeout: 1.second)
      hooks = [] of String
      shutdown.on_shutdown { hooks << "drained" }

      entered = Channel(Nil).new(0)
      release = Channel(Nil).new(0)
      spawn do
        shutdown.track do
          entered.send(nil)
          release.receive
        end
      end
      entered.receive

      spawn do
        sleep 20.milliseconds
        release.send(nil)
      end

      shutdown.in_flight.should eq(1)
      shutdown.shutdown!.should be_true
      shutdown.in_flight.should eq(0)
      hooks.should eq(["drained"])
      shutdown.shutting_down?.should be_true
      shutdown.shutdown!.should be_true
      hooks.size.should eq(1)
    end

    it "returns false when the drain deadline expires and still runs hooks" do
      shutdown = Saci::Deploy::GracefulShutdown.new(timeout: 30.milliseconds)
      hooks = 0
      shutdown.on_shutdown { hooks += 1 }

      entered = Channel(Nil).new(0)
      release = Channel(Nil).new(0)
      spawn do
        shutdown.track do
          entered.send(nil)
          release.receive
        end
      end
      entered.receive

      shutdown.shutdown!.should be_false
      shutdown.forced?.should be_true
      hooks.should eq(1)
      release.send(nil)
    end

    it "keeps the original listen API and adds listen_gracefully" do
      router = Saci::Router.new.draw { |r| r.get "/up", HealthControllerStub, :show }
      app = Saci::Application.new(router)
      app.responds_to?(:listen).should be_true
      app.responds_to?(:listen_gracefully).should be_true
    end
  end

  describe "ops hooks (G141/G142/G144)" do
    it "checks secrets, database URL and writable directories" do
      with_deploy_app("doctor") do |dir|
        db_url = Saci::ConfigFile.database_url("development", path: File.join(dir, "config", "database.yml"))
        checks = Saci::Deploy.environment_checks(db_url: db_url, root: dir)
        checks.map(&.name).should eq(["SECRET_KEY_BASE", "database", "storage", "log", "tmp"])
        checks.each { |check| check.ok?.should be_true }

        io = IO::Memory.new
        Saci::Deploy.doctor(io, db_url: db_url, root: dir).should eq(0)
        io.to_s.should contain("5 checks, 0 failures")
      end
    end

    it "fails doctor for missing runtime directories and redacts passwords" do
      root = File.join("/tmp/opencode", "saci-doctor-missing-#{Random.rand(1_000_000)}")
      Dir.mkdir_p(root)
      begin
        checks = Saci::Deploy.environment_checks(db_url: "postgres://user:secret@db.example.com/app", root: root)
        checks.find { |c| c.name == "database" }.not_nil!.ok?.should be_true
        checks.find { |c| c.name == "storage" }.not_nil!.ok?.should be_false

        io = IO::Memory.new
        Saci::Deploy.doctor(io, db_url: "postgres://user:secret@db.example.com/app", root: root).should eq(1)
        io.to_s.should contain("[FAIL] storage")
        io.to_s.should_not contain("user:secret@")

        Saci::Deploy.redact_url("postgres://user:secret@db.example.com/app").should eq("postgres://user:***@db.example.com/app")
        summary_io = IO::Memory.new
        Saci::Deploy.boot_summary(summary_io, app: "blog", db_url: "postgres://user:secret@db.example.com/app", server: Saci::Deploy::ServerConfig.new)
        summary_io.to_s.should contain("Saci")
        summary_io.to_s.should contain("blog")
        summary_io.to_s.should_not contain("secret")
      ensure
        FileUtils.rm_rf(root)
      end
    end
  end

  describe "Kamal 2 and Thruster (G165/G166)" do
    it "generates a Kamal 2 config aligned with the Dockerfile and /up" do
      with_deploy_app("kamalpg", db: "postgres") do |dir|
        deploy = YAML.parse(deploy_file(dir, "config", "deploy.yml"))
        deploy["service"].as_s.should eq("kamalpg")
        deploy["image"].as_s.should eq("your-registry-user/kamalpg")
        deploy["proxy"]["app_port"].as_i.should eq(3000)
        deploy["proxy"]["healthcheck"]["path"].as_s.should eq("/up")
        deploy["env"]["secret"].as_a.map(&.as_s).should eq(["RAILS_MASTER_KEY", "DATABASE_URL"])
        deploy["env"]["clear"]["APP_ENV"].as_s.should eq("production")
        deploy["accessories"]["db"]["image"].as_s.should contain("postgres")

        dockerfile = deploy_file(dir, "Dockerfile")
        dockerfile.should contain("EXPOSE 3000")
        dockerfile.should contain("/up")
        dockerfile.should contain("STOPSIGNAL SIGTERM")
        dockerfile.should contain("saci-doctor")

        secrets = deploy_file(dir, ".kamal", "secrets")
        secrets.should contain("RAILS_MASTER_KEY=$(cat config/master.key)")
        secrets.should_not contain("SECRET_KEY_BASE=")
        secrets.should contain("DATABASE_URL=$DATABASE_URL")
        # Uploads persist in a named volume; volumes live at the top level.
        deploy["volumes"].as_a.map(&.as_s).should eq(["kamalpg_storage:/app/storage"])
        deploy["servers"]["web"].as_a?.should_not be_nil
        secrets.should contain("POSTGRES_PASSWORD=$POSTGRES_PASSWORD")
        secrets.should_not contain("POSTGRES_PASSWORD=changeme")
      end
    end

    it "omits the database accessory for SQLite and keeps the docs honest" do
      with_deploy_app("kamalsqlite", db: "sqlite") do |dir|
        deploy = YAML.parse(deploy_file(dir, "config", "deploy.yml"))
        deploy["accessories"]?.try(&.as_h?).try(&.has_key?(YAML::Any.new("db"))).should_not be_true
        # SQLite needs no DATABASE_URL; its file lives in a named volume
        # (writable by the container user, unlike a root-owned bind mount).
        deploy["env"]["secret"].as_a.map(&.as_s).should eq(["RAILS_MASTER_KEY"])
        deploy["volumes"].as_a.map(&.as_s).should eq(["kamalsqlite_storage:/app/storage", "kamalsqlite_db:/app/db"])
        raw = deploy_file(dir, "config", "deploy.yml")
        raw.should contain("# forward_headers: true")
        raw.should_not contain("/var/lib/kamalsqlite/db:/app/db\n  -")
        secrets = deploy_file(dir, ".kamal", "secrets")
        secrets.should_not contain("DATABASE_URL")
        deploy_file(dir, "docs", "thruster.md").should contain("does **not** bundle Thruster")
        deploy_file(dir, "bin", "thrust").should contain("not a proxy")
        deploy_file(dir, "bin", "thrust").should contain("reverse proxy")
        deploy_file(dir, "bin", "kamal").should contain(%(exec "${KAMAL_BIN:-kamal}" "$@"))
      end
    end
  end

  describe "config/ci.cr and bin/ci (G121)" do
    it "generates Saci::CI steps and keeps the plain-spec fallback" do
      with_deploy_app("ciconf") do |dir|
        ci = deploy_file(dir, "config", "ci.cr")
        ci.should contain("Saci::CI.step \"Format\"")
        ci.should contain(%(Saci::CI.run "Specs", "crystal spec --no-color"))
        ci.should contain("crystal build src/ciconf.cr")

        bin_ci = deploy_file(dir, "bin", "ci")
        bin_ci.should contain(%(exec "$SACI" ci "$@"))
        bin_ci.should contain(%(exec "$CRYSTAL" spec "$@"))
        bin_ci.should contain("-Dexecution_context")
        (File.info(File.join(dir, "bin", "ci")).permissions.value & 0o111).should_not eq(0)
      end
    end
  end

  describe "devcontainer (G174)" do
    it "is opt-in and emits parseable JSON plus a Dockerfile" do
      with_deploy_app("nodev") do |dir|
        File.exists?(File.join(dir, ".devcontainer")).should be_false
      end

      with_deploy_app("withdev", devcontainer: true) do |dir|
        json_path = File.join(dir, ".devcontainer", "devcontainer.json")
        File.exists?(json_path).should be_true
        json = JSON.parse(File.read(json_path))
        json["name"].as_s.should eq("withdev")
        json["build"]["dockerfile"].as_s.should eq("Dockerfile")
        json["build"]["context"].as_s.should eq("..")
        json["forwardPorts"].as_a.map(&.as_i).should contain(3000)
        deploy_file(dir, ".devcontainer", "Dockerfile").should contain("crystallang/crystal:1.22.0")
        deploy_file(dir, "README.md").should contain("## Devcontainer")
      end
    end
  end

  describe "existing scaffold behavior" do
    it "still generates the Rails-like surface and executable deployment binstubs" do
      with_deploy_app("surface") do |dir|
        %w[
          bin/saci bin/setup bin/dev bin/ci bin/docker-entrypoint bin/thrust
          bin/doctor bin/kamal bin/systemd
          config/server.cr config/database.yml config/ci.cr config/deploy.yml
          deploy/surface.service docs/thruster.md script/doctor.cr
        ].each do |relative|
          File.exists?(File.join(dir, relative)).should be_true
        end

        %w[saci setup dev ci docker-entrypoint thrust doctor kamal systemd].each do |script|
          path = File.join(dir, "bin", script)
          (File.info(path).permissions.value & 0o111).should_not eq(0)
        end

        entry = deploy_file(dir, "src", "surface.cr")
        entry.should contain(%(require "../config/environments/*"))
        entry.should contain(%(require "../config/server"))
        entry.should contain("Saci::ConfigFile.database_url")
        entry.should contain("listen_gracefully")
        entry.should contain("sqlite3://./db/surface_")

        deploy_file(dir, "spec", "spec_helper.cr").should contain("Saci::ConfigFile.database_url")
        File.exists?(File.join(dir, "config.ru")).should be_false
        File.exists?(File.join(dir, "Rakefile")).should be_false
      end
    end

    it "parses --devcontainer and defaults it to false" do
      Saci::CLI::New.parse_opts(["blog"])[:devcontainer].should be_false
      Saci::CLI::New.parse_opts(["blog", "--devcontainer"])[:devcontainer].should be_true
    end
  end
end

class HealthControllerStub < Saci::Controller
  def show
    render plain: "OK", status: 200
  end
end
