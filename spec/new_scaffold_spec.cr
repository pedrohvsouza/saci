require "spec"
require "file_utils"
require "yaml"
require "../src/saci"
require "../src/saci/cli/util"
require "../src/saci/cli/generate_command"
require "../src/saci/cli/new_command"

private def with_new_app(name : String, db : String = "sqlite", & : String ->) : Nil
  dir = File.join("/tmp/opencode", "saci-new-#{name}-#{Random.rand(1_000_000)}")
  begin
    Saci::CLI::New.create(name, dir: dir, skip_shards: true, skip_git: true, db: db)
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

private def read_file(dir : String, *parts : String) : String
  File.read(File.join(dir, *parts))
end

# Makes `require "saci"` and the bare driver requires resolve for the
# compile check, without a `shards install` (the generated app's shard.yml
# points at the framework checkout via SACI_ROOT).
private def link_dependencies!(dir : String) : Nil
  lib_dir = File.join(dir, "lib")
  Dir.mkdir_p(lib_dir)
  File.symlink(Saci::CLI::New::SACI_ROOT, File.join(lib_dir, "saci")) unless File.exists?(File.join(lib_dir, "saci"))
  {"db", "sqlite3"}.each do |dep|
    target = File.join(Saci::CLI::New::SACI_ROOT, "lib", dep)
    link = File.join(lib_dir, dep)
    File.symlink(target, link) unless File.exists?(link)
  end
end

describe "saci new scaffold" do
  # Appendix D1: `pg:`/`mysql:` used to be emitted *under* `saci.path`,
  # which made every Postgres/MySQL app fail its first `shards install`.
  describe "shard.yml dependencies (D1)" do
    it "nests saci and pg as sibling dependencies and parses as YAML" do
      with_new_app("newpgapp", db: "postgres") do |dir|
        yaml = YAML.parse(read_file(dir, "shard.yml"))
        deps = yaml["dependencies"].as_h

        deps["saci"]["path"].as_s.should eq(Saci::CLI::New::SACI_ROOT)
        deps["pg"]["github"].as_s.should eq("will/crystal-pg")
        deps["pg"]["version"].as_s.should eq("~> 0.30.0")
        deps.has_key?(YAML::Any.new("mysql")).should be_false
      end
    end

    it "nests saci and mysql as sibling dependencies and parses as YAML" do
      with_new_app("newmysqlapp", db: "mysql") do |dir|
        deps = YAML.parse(read_file(dir, "shard.yml"))["dependencies"].as_h

        deps["saci"]["path"].as_s.should eq(Saci::CLI::New::SACI_ROOT)
        deps["mysql"]["github"].as_s.should eq("crystal-lang/crystal-mysql")
        deps["mysql"]["version"].as_s.should eq("~> 0.17.0")
        deps.has_key?(YAML::Any.new("pg")).should be_false
      end
    end

    it "keeps sqlite dependency-free (drivers documented as comments)" do
      with_new_app("newsqliteapp", db: "sqlite") do |dir|
        raw = read_file(dir, "shard.yml")
        deps = YAML.parse(raw)["dependencies"].as_h

        deps.keys.map(&.as_s).should eq(["saci"])
        raw.should contain("# pg:")
        raw.should contain("# mysql:")
      end
    end

    it "accepts the postgresql alias for --db" do
      Saci::CLI::New.parse_opts(["blog", "--db=postgresql"])[:db].should eq("postgres")
      Saci::CLI::New.shard_yml("blog", "/tmp/saci", "postgresql").should contain("will/crystal-pg")
    end

    it "defaults to sqlite and parses --skip-shards/--skip-git" do
      opts = Saci::CLI::New.parse_opts(["blog", "--skip-shards", "--skip-git"])
      opts[:db].should eq("sqlite")
      opts[:skip_shards].should be_true
      opts[:skip_git].should be_true
    end
  end

  it "generates the Rails-like operating surface" do
    with_new_app("newsurface") do |dir|
      %w[
        bin/saci bin/setup bin/dev bin/ci bin/docker-entrypoint bin/thrust
        Dockerfile .dockerignore .github/workflows/ci.yml .tool-versions
        public/400.html public/404.html public/422.html public/500.html public/robots.txt
        src/controllers/health_controller.cr
        config/initializers/filter_parameter_logging.cr
        config/initializers/cors.cr
        config/initializers/assets.cr
      ].each do |relative|
        File.exists?(File.join(dir, relative)).should be_true
      end

      %w[
        spec/controllers/.gitkeep spec/models/.gitkeep spec/mailers/.gitkeep
        spec/integration/.gitkeep spec/fixtures/.gitkeep
        storage/.gitkeep log/.gitkeep tmp/pids/.gitkeep vendor/.gitkeep script/.gitkeep
      ].each do |relative|
        File.exists?(File.join(dir, relative)).should be_true
      end

      Dir.glob(File.join(dir, "public", ".gitkeep")).should be_empty

      File.exists?(File.join(dir, "config.ru")).should be_false
      File.exists?(File.join(dir, "Rakefile")).should be_false

      read_file(dir, "spec", "app_spec.cr").should contain("HealthController")
      read_file(dir, "spec", "app_spec.cr").should contain("/up")
    end
  end

  it "generates executable binstubs with the expected commands" do
    with_new_app("newbins") do |dir|
      scripts = %w[saci setup dev ci docker-entrypoint thrust]
      scripts.each do |script|
        path = File.join(dir, "bin", script)
        (File.info(path).permissions.value & 0o111).should_not eq(0)
      end

      read_file(dir, "bin", "saci").should contain("exec \"${SACI_BIN:-saci}\" \"$@\"")
      read_file(dir, "bin", "setup").should contain("shards install")
      read_file(dir, "bin", "setup").should contain("db:migrate")
      read_file(dir, "bin", "setup").should contain("db:seed")
      read_file(dir, "bin", "dev").should contain("serve --watch")
      read_file(dir, "bin", "ci").should contain("exec \"$CRYSTAL\" spec")
      read_file(dir, "bin", "ci").should contain("-Dexecution_context")
      read_file(dir, "bin", "docker-entrypoint").should contain("db:migrate")
      read_file(dir, "bin", "docker-entrypoint").should contain("exec \"$@\"")
      read_file(dir, "bin", "thrust").should contain("not a proxy")
      read_file(dir, "bin", "thrust").should contain("reverse proxy")
    end
  end

  it "generates a multi-stage, non-root Dockerfile and CI workflow" do
    with_new_app("newdocker") do |dir|
      dockerfile = read_file(dir, "Dockerfile")
      dockerfile.should contain("FROM crystallang/crystal:1.22.0 AS build")
      dockerfile.should contain("FROM debian:bookworm-slim AS runtime")
      dockerfile.should contain("USER saci")
      dockerfile.should contain("EXPOSE 3000")
      dockerfile.should contain("ENTRYPOINT [\"/app/bin/docker-entrypoint\"]")
      dockerfile.should contain("saci-migrate")
      dockerfile.should contain("HEALTHCHECK")

      read_file(dir, ".dockerignore").should contain("config/master.key")
      ci = read_file(dir, ".github", "workflows", "ci.yml")
      ci.should contain("crystal tool format --check")
      ci.should contain("crystal spec")
      read_file(dir, ".tool-versions").should match(/^crystal \d+\.\d+\.\d+/)
    end
  end

  it "generates a /up health route with no framework dependency beyond render" do
    with_new_app("newhealth") do |dir|
      entry = read_file(dir, "src", "newhealth.cr")
      entry.should contain(%(r.get "/up", HealthController, :show))
      entry.should contain("require \"../config/initializers/*\"")

      health = read_file(dir, "src", "controllers", "health_controller.cr")
      health.should contain("class HealthController < ApplicationController")
      health.should contain(%(render plain: "OK", status: 200))
    end
  end

  it "keeps generated initializers comment-only so fresh apps always compile" do
    with_new_app("newinit") do |dir|
      Dir.glob(File.join(dir, "config", "initializers", "*.cr")).each do |file|
        File.read(file).each_line do |line|
          stripped = line.strip
          next if stripped.empty?
          stripped.starts_with?("#").should be_true
        end
      end
      read_file(dir, "src", "newinit.cr").should contain("require \"../config/initializers/*\"")
      read_file(dir, "spec", "spec_helper.cr").should contain("require \"../config/initializers/*\"")
    end
  end

  it "documents bin/*, Docker, /up and config dirs in the README" do
    with_new_app("newreadme") do |dir|
      readme = read_file(dir, "README.md")
      %w[bin/setup bin/dev bin/ci bin/docker-entrypoint].each do |cmd|
        readme.should contain(cmd)
      end
      readme.should contain("/up")
      readme.should contain("docker build")
      readme.should contain("config/initializers")
      readme.should contain("no `config.ru`")
      readme.should contain("no `Rakefile`")
    end
  end

  it "honours --skip-shards/--skip-git (no install, no git repo)" do
    with_new_app("newskip") do |dir|
      File.exists?(File.join(dir, "shard.lock")).should be_false
      Dir.exists?(File.join(dir, "lib")).should be_false
      Dir.exists?(File.join(dir, ".git")).should be_false
    end
  end

  # The strongest assertion: the generated app typechecks against the
  # framework. It is opt-in (SACI_SCAFFOLD_COMPILE=1) because spawning a
  # nested Crystal compiler from inside `crystal spec` is flaky in some
  # environments (compiler temp-cache races) even though it takes ~10s when
  # warm. Run it explicitly in CI/release checks:
  #
  #   SACI_SCAFFOLD_COMPILE=1 crystal spec spec/new_scaffold_spec.cr
  it "generates an app that compiles (crystal build --no-codegen)" do
    with_new_app("newcompile", db: "sqlite") do |dir|
      read_file(dir, "src", "newcompile.cr").should contain("require \"saci\"")
      read_file(dir, "src", "newcompile.cr").should contain("HealthController")
      next unless ENV["SACI_SCAFFOLD_COMPILE"]? == "1"

      link_dependencies!(dir)
      output = IO::Memory.new
      status = Process.run(
        "crystal",
        args: ["build", "--no-codegen", "src/newcompile.cr"],
        chdir: dir,
        output: output,
        error: output
      )
      unless status.success?
        raise "generated app failed to compile:\n#{output}"
      end
      status.success?.should be_true
    end
  end
end
