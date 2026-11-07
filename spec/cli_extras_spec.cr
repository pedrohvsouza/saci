require "spec"
require "file_utils"
require "../src/saci"
require "../src/saci/tasks"
require "../src/saci/ci"
require "../src/saci/db_tasks"
require "../src/saci/cli"

def with_extras_app(name : String = "cli_extras_app", & : String ->) : Nil
  dir = File.join("/tmp/opencode", "saci-cli-extras-#{name}-#{Random.rand(1_000_000)}")
  begin
    Saci::CLI::New.create(name, dir: dir, skip_shards: true, skip_git: true)
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

# Symlink the framework's lib into a fixture app so bare `db`/`sqlite3`
# requires resolve without `shards install` (fixtures skip shards).
def link_extras_framework_lib! : Nil
  framework_lib = File.join(Saci::CLI::New::SACI_ROOT, "lib")
  File.symlink(framework_lib, "lib") unless File.exists?("lib")
end

def capture_extras_output(& : ->) : Tuple(String, String)
  out_mem = IO::Memory.new
  err_mem = IO::Memory.new
  Saci::CLI::Generate.output = out_mem
  Saci::CLI::Generate.error = err_mem
  begin
    yield
  ensure
    Saci::CLI::Generate.reset_output!
  end
  {out_mem.to_s, err_mem.to_s}
end

def with_extras_input(answer : String, & : ->) : Nil
  Saci::CLI::Generate.input = IO::Memory.new(answer)
  begin
    yield
  ensure
    Saci::CLI::Generate.reset_input!
  end
end

def without_database_env(& : ->) : Nil
  previous_url = ENV["DATABASE_URL"]?
  previous_env = ENV["APP_ENV"]?
  ENV.delete("DATABASE_URL")
  ENV.delete("APP_ENV")
  begin
    yield
  ensure
    if previous_url
      ENV["DATABASE_URL"] = previous_url
    else
      ENV.delete("DATABASE_URL")
    end
    if previous_env
      ENV["APP_ENV"] = previous_env
    else
      ENV.delete("APP_ENV")
    end
  end
end

def sqlite_scalar(dir : String, app : String, env : String, sql : String)
  path = File.join(dir, "db", "#{app}_#{env}.db")
  return nil unless File.exists?(path)
  DB.open("sqlite3://#{path}") do |db|
    db.scalar(sql)
  end
end

describe "saci destroy" do
  it "removes model/controller output but keeps unrelated files and shared dirs" do
    with_extras_app(name: "destroy_model") do |dir|
      Dir.cd(dir) do
        Saci::CLI::Generate.run(["model", "Post", "title:string"])
        File.write("src/models/keep_me.cr", "class KeepMe < ApplicationRecord\nend\n")
        File.write("spec/models/other_spec.cr", "require \"../spec_helper\"\n")

        capture_extras_output do
          Saci::CLI::Destroy.run(["model", "Post"]).should eq(0)
        end

        File.exists?("src/models/post.cr").should be_false
        File.exists?("spec/models/post_spec.cr").should be_false
        Dir.glob("db/migrate/*_create_posts.cr").should be_empty
        File.exists?("src/models/keep_me.cr").should be_true
        File.exists?("spec/models/other_spec.cr").should be_true
        Dir.exists?("src/models").should be_true
        Dir.exists?("spec/models").should be_true
        File.read("db/migrations.cr").should_not contain("CreatePosts")
      end
    end
  end

  it "prompts on modified files, skips on n, and removes with --force" do
    with_extras_app(name: "destroy_prompt") do |dir|
      Dir.cd(dir) do
        Saci::CLI::Generate.run(["job", "Welcome"])
        File.write("src/jobs/welcome_job.cr", "stale")

        out, err = capture_extras_output do
          with_extras_input("n\n") do
            Saci::CLI::Destroy.run(["job", "Welcome"]).should eq(0)
          end
        end
        File.read("src/jobs/welcome_job.cr").should eq("stale")
        out.should contain("skip src/jobs/welcome_job.cr")
        err.should contain("warning")

        capture_extras_output do
          with_extras_input("") do
            Saci::CLI::Destroy.run(["job", "Welcome", "--force"]).should eq(0)
          end
        end
        File.exists?("src/jobs/welcome_job.cr").should be_false
      end
    end
  end

  it "--pretend prints the plan and changes nothing" do
    with_extras_app(name: "destroy_pretend") do |dir|
      Dir.cd(dir) do
        Saci::CLI::Generate.run(["model", "Post", "title:string"])
        out, _ = capture_extras_output do
          Saci::CLI::Destroy.run(["model", "Post", "--pretend"]).should eq(0)
        end
        out.should contain("remove src/models/post.cr")
        out.should contain("pretend: manifest rebuild skipped")
        File.exists?("src/models/post.cr").should be_true
        Dir.glob("db/migrate/*_create_posts.cr").size.should eq(1)
      end
    end
  end

  it "removes scaffold_controller views and prunes the now-empty view dir" do
    with_extras_app(name: "destroy_scaffold_controller") do |dir|
      Dir.cd(dir) do
        Saci::CLI::Generate.run(["model", "Post", "title:string"])
        Saci::CLI::Generate.run(["scaffold_controller", "Posts", "title:string"])
        File.exists?("src/views/posts/index.ecr").should be_true

        capture_extras_output do
          Saci::CLI::Destroy.run(["scaffold_controller", "Posts"]).should eq(0)
        end
        File.exists?("src/controllers/posts_controller.cr").should be_false
        File.exists?("src/views/posts/index.ecr").should be_false
        Dir.exists?("src/views/posts").should be_false
        Dir.exists?("src/views").should be_true
      end
    end
  end

  it "removes a scaffold stack" do
    with_extras_app(name: "destroy_scaffold") do |dir|
      Dir.cd(dir) do
        Saci::CLI::Generate.run(["scaffold", "Post", "title:string"])
        File.write("src/models/other.cr", "class Other < ApplicationRecord\nend\n")

        capture_extras_output do
          Saci::CLI::Destroy.run(["scaffold", "Post"]).should eq(0)
        end
        File.exists?("src/models/post.cr").should be_false
        File.exists?("src/controllers/posts_controller.cr").should be_false
        File.exists?("spec/models/post_spec.cr").should be_false
        File.exists?("spec/requests/posts_controller_spec.cr").should be_false
        Dir.glob("db/migrate/*_create_posts.cr").should be_empty
        File.exists?("src/models/other.cr").should be_true
      end
    end
  end

  it "removes a resource stack including the route helper" do
    with_extras_app(name: "destroy_resource") do |dir|
      Dir.cd(dir) do
        Saci::CLI::Generate.run(["resource", "Post", "title:string"])
        File.exists?("src/routes/posts_routes.cr").should be_true

        capture_extras_output do
          Saci::CLI::Destroy.run(["resource", "Post"]).should eq(0)
        end
        File.exists?("src/routes/posts_routes.cr").should be_false
        File.exists?("src/controllers/posts_controller.cr").should be_false
        File.exists?("src/models/post.cr").should be_false
        Dir.exists?("src/routes").should be_false
      end
    end
  end

  it "removes migrations and rebuilds db/migrations.cr" do
    with_extras_app(name: "destroy_migration") do |dir|
      Dir.cd(dir) do
        Saci::CLI::Generate.run(["migration", "AddBioToUsers", "bio:text"])
        Dir.glob("db/migrate/*_add_bio_to_users.cr").size.should eq(1)

        capture_extras_output do
          Saci::CLI::Destroy.run(["migration", "AddBioToUsers"]).should eq(0)
        end
        Dir.glob("db/migrate/*_add_bio_to_users.cr").should be_empty
        File.read("db/migrations.cr").should_not contain("AddBioToUsers")
      end
    end
  end

  it "removes authentication output and restores the stock ApplicationController" do
    with_extras_app(name: "destroy_auth") do |dir|
      Dir.cd(dir) do
        Saci::CLI::Generate.run(["authentication"])
        File.read("src/controllers/application_controller.cr").should contain("include Authentication")

        capture_extras_output do
          Saci::CLI::Destroy.run(["authentication"]).should eq(0)
        end
        File.exists?("src/models/user.cr").should be_false
        File.exists?("src/controllers/sessions_controller.cr").should be_false
        File.exists?("src/controllers/authentication.cr").should be_false
        File.read("src/controllers/application_controller.cr").should eq(Saci::CLI::New.application_controller)
      end
    end
  end
end

describe "saci generate extras" do
  it "generates tasks under lib/tasks with namespaced subdirectories" do
    with_extras_app(name: "gen_task") do |dir|
      Dir.cd(dir) do
        Saci::CLI::Generate.run(["task", "reports:daily"])
        path = "lib/tasks/reports/daily.cr"
        File.exists?(path).should be_true
        File.read(path).should contain(%(task "reports:daily"))
        File.read(path).should contain("saci task reports:daily")
      end
    end
  end

  it "generates helpers, tests, integration tests and benchmarks" do
    with_extras_app(name: "gen_misc") do |dir|
      Dir.cd(dir) do
        Saci::CLI::Generate.run(["helper", "Posts"])
        File.read("src/helpers/posts_helper.cr").should contain("module PostsHelper")
        File.exists?("spec/helpers/posts_helper_spec.cr").should be_true

        Saci::CLI::Generate.run(["test", "Post"])
        File.read("spec/models/post_test.cr").should contain(%(describe "Post model"))

        Saci::CLI::Generate.run(["integration_test", "Posts"])
        File.read("spec/integration/posts_test.cr").should contain("pending")

        Saci::CLI::Generate.run(["benchmark", "Post#import"])
        File.read("benchmarks/post_import_benchmark.cr").should contain("Benchmark.ips")

        Saci::CLI::Generate.run(["application_record"]).should eq(0)
        File.read("src/models/application_record.cr").should contain("ApplicationRecord < Saci::Record::Base")
      end
    end
  end

  it "generates a resource stack with a route helper" do
    with_extras_app(name: "gen_resource") do |dir|
      Dir.cd(dir) do
        Saci::CLI::Generate.run(["resource", "Post", "title:string"])
        File.read("src/models/post.cr").should contain("class Post < ApplicationRecord")
        File.read("src/controllers/posts_controller.cr").should contain("class PostsController")
        File.read("src/controllers/posts_controller.cr").should contain("render json:")
        File.read("src/routes/posts_routes.cr").should contain("def self.draw_posts(r : Saci::Router)")
        File.read("src/routes/posts_routes.cr").should contain(%(r.resources "posts", PostsController))
        Dir.glob("db/migrate/*_create_posts.cr").size.should eq(1)
      end
    end
  end

  it "generates scaffold_controller views for an existing model" do
    with_extras_app(name: "gen_scaffold_controller") do |dir|
      Dir.cd(dir) do
        Saci::CLI::Generate.run(["model", "Post", "title:string", "published:boolean"])
        Saci::CLI::Generate.run(["scaffold_controller", "Posts"])

        controller = File.read("src/controllers/posts_controller.cr")
        controller.should contain("class PostsController")
        controller.should contain("render_template :index")
        controller.should contain("render_template :new, status: 422")
        File.read("src/views/posts/index.ecr").should contain("@posts.each")
        File.read("src/views/posts/show.ecr").should contain("h(@post.title.to_s)")
        File.read("src/views/posts/new.ecr").should contain("form_with")
        File.read("src/views/posts/edit.ecr").should contain("method: \"patch\"")
      end
    end
  end

  it "honors --no-spec / --no-migration / --no-views flags" do
    with_extras_app(name: "gen_flags") do |dir|
      Dir.cd(dir) do
        Saci::CLI::Generate.run(["channel", "Chat", "--no-spec"])
        File.exists?("src/channels/chat_channel.cr").should be_true
        File.exists?("spec/channels/chat_channel_spec.cr").should be_false

        Saci::CLI::Generate.run(["model", "Draft", "title:string", "--no-spec", "--no-migration"])
        File.exists?("src/models/draft.cr").should be_true
        File.exists?("spec/models/draft_spec.cr").should be_false
        Dir.glob("db/migrate/*_create_drafts.cr").should be_empty

        Saci::CLI::Generate.run(["model", "Note", "title:string"])
        Saci::CLI::Generate.run(["scaffold_controller", "Notes", "title:string", "--no-views"])
        File.exists?("src/controllers/notes_controller.cr").should be_true
        Dir.exists?("src/views/notes").should be_false
      end
    end
  end

  it "generates a self-contained authentication stack" do
    with_extras_app(name: "gen_auth") do |dir|
      Dir.cd(dir) do
        Saci::CLI::Generate.run(["authentication"])
        File.read("src/models/user.cr").should contain("has_secure_password")
        File.read("src/controllers/authentication.cr").should contain("memoize_current_user User")
        File.read("src/controllers/sessions_controller.cr").should contain("allow_unauthenticated_access")
        File.read("src/controllers/sessions_controller.cr").should contain("authenticate_by")
        File.read("src/controllers/passwords_controller.cr").should contain("signed_id(purpose: \"password_reset\"")
        File.read("src/mailers/password_mailer.cr").should contain("class PasswordMailer")
        File.exists?("src/views/sessions/new.ecr").should be_true
        File.exists?("src/views/passwords/edit.ecr").should be_true
        File.read("src/controllers/application_controller.cr").should contain("include Authentication")
        File.read("src/controllers/application_controller.cr").should contain("require \"./authentication\"")
        Dir.glob("db/migrate/*_create_users.cr").size.should eq(1)
        migration = File.read(Dir.glob("db/migrate/*_create_users.cr").first)
        migration.should contain("t.string :password_digest, null: false")
        migration.should contain("add_index :users, :email, unique: true")
      end
    end
  end
end

describe "saci task" do
  it "registers and runs tasks through the DSL" do
    Saci::Task.reset!
    marker = File.join("/tmp/opencode", "saci-task-dsl-#{Random.rand(1_000_000)}.txt")
    begin
      Saci::Task.define("spec:demo") { File.write(marker, "ran") }
      Saci::Task.names.should contain("spec:demo")
      Saci::Task.run("spec:demo")
      File.read(marker).should eq("ran")

      expect_raises(Saci::Task::NotFound, /nope/) { Saci::Task.run("nope") }
    ensure
      Saci::Task.reset!
      File.delete(marker) if File.exists?(marker)
    end
  end

  it "lists task files statically and runs one end-to-end in app context" do
    with_extras_app(name: "task_run") do |dir|
      Dir.cd(dir) do
        link_extras_framework_lib!
        Dir.mkdir_p("lib/tasks")
        File.write("lib/tasks/marker.cr", <<-CRYSTAL)
          task "spec:marker", "Write a marker" do
            File.write("task_marker.txt", "ran")
          end
          CRYSTAL

        entries = Saci::CLI::TaskCommand.scan
        entries.map(&.name).should contain("spec:marker")
        entries.first.description.should eq("Write a marker")

        Saci::CLI.run(["task:list"]).should eq(0)
        Saci::CLI.run(["task", "spec:marker"]).should eq(0)
        File.read("task_marker.txt").should eq("ran")

        Saci::CLI::Inspect::Runner.wrapper_source(code_body: "1").should contain("../lib/tasks/*")
      end
    end
  end

  it "errors clearly when no task files exist" do
    with_extras_app(name: "task_missing") do |dir|
      Dir.cd(dir) do
        expect_raises(Saci::CLI::Error, /No task files/) do
          Saci::CLI::TaskCommand.run(["nope"])
        end
        Saci::CLI::TaskCommand.run(["list"]).should eq(0)
      end
    end
  end
end

describe "saci db:* surface" do
  it "prepares, reports status/version, loads fixtures, dumps the schema cache and resets" do
    with_extras_app(name: "db_surface") do |dir|
      Dir.cd(dir) do
        link_extras_framework_lib!
        Saci::CLI::Generate.run(["model", "Post", "title:string"])
        File.write("db/seed.cr", <<-CRYSTAL)
          File.open("seed_runs.txt", "a") { |f| f.puts "seed" }
          CRYSTAL

        without_database_env do
          Saci::CLI.run(["db:prepare"]).should eq(0)
          File.exists?("db/db_surface_development.db").should be_true
          sqlite_scalar(dir, "db_surface", "development", "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'posts'").should eq(1)
          File.exists?("seed_runs.txt").should be_true
          File.read("seed_runs.txt").lines.size.should eq(1)

          Saci::CLI.run(["db:version"]).should eq(0)
          Saci::CLI.run(["db:migrate:status"]).should eq(0)
          Saci::CLI.run(["db:schema:cache:dump"]).should eq(0)
          File.read("db/schema_cache.yml").should contain("posts")
          File.read("db/schema_cache.yml").should contain("title")

          Dir.mkdir_p("spec/fixtures")
          File.write("spec/fixtures/posts.yml", <<-YAML)
            one:
              title: Hello
            YAML
          Saci::CLI.run(["db:fixtures:load"]).should eq(0)
          sqlite_scalar(dir, "db_surface", "development", "SELECT COUNT(*) FROM posts").should eq(1)

          Saci::CLI.run(["db:drop", "--pretend"]).should eq(0)
          File.exists?("db/db_surface_development.db").should be_true

          Saci::CLI.run(["db:reset"]).should eq(0)
          File.exists?("db/db_surface_development.db").should be_true
          sqlite_scalar(dir, "db_surface", "development", "SELECT COUNT(*) FROM posts").should eq(0)
          File.read("seed_runs.txt").lines.size.should eq(2)

          Saci::CLI.run(["db:drop"]).should eq(0)
          File.exists?("db/db_surface_development.db").should be_false
        end
      end
    end
  end

  it "reports version/status without creating a missing database" do
    with_extras_app(name: "db_missing") do |dir|
      Dir.cd(dir) do
        Saci::CLI::Generate.run(["model", "Post", "title:string"])
        without_database_env do
          File.exists?("db/db_missing_development.db").should be_false
          Saci::CLI.run(["db:version"]).should eq(0)
          Saci::CLI.run(["db:migrate:status"]).should eq(0)
          File.exists?("db/db_missing_development.db").should be_false
        end
      end
    end
  end

  it "resolves test database URLs and refuses production drops" do
    with_extras_app(name: "db_urls") do |dir|
      Dir.cd(dir) do
        without_database_env do
          test_url = Saci::CLI::Db.url_for("db_urls", "sqlite", "test", test: true)
          test_url.should contain("db_urls_test.db")
          targets = Saci::CLI::Db.targets(true, "db_urls", "sqlite", "development")
          targets.map(&.name).should eq(["primary"])

          begin
            ENV["APP_ENV"] = "production"
            Saci::CLI.run(["db:drop"]).should eq(1)
            File.exists?("db/db_urls_production.db").should be_false
          ensure
            ENV.delete("APP_ENV")
          end
        end
      end
    end
  end
end

describe "saci credentials:fetch" do
  it "prints, writes and fails on missing keys" do
    with_extras_app(name: "credentials_fetch") do |dir|
      Dir.cd(dir) do
        secret = Saci::Credentials.dig("secret_key_base")
        secret.should_not be_nil

        Saci::CLI.run(["credentials:fetch", "secret_key_base"]).should eq(0)
        Saci::CLI.run(["credentials:fetch", "missing_key"]).should eq(1)

        data = YAML.parse("aws:\n  key: AKIAEXAMPLE\n").as_h.transform_keys(&.to_s)
        Saci::Credentials.write(data)
        Saci::CLI.run(["credentials:fetch", "aws.key", "--to", "tmp_token.txt"]).should eq(0)
        File.read("tmp_token.txt").should eq("AKIAEXAMPLE")
        Saci::CLI.run(["credentials:fetch", "aws.missing"]).should eq(1)
      end
    end
  end
end

describe "saci routes --expanded/--grep" do
  it "filters rows case-insensitively and rejects bad patterns" do
    with_extras_app(name: "routes_grep") do |dir|
      Dir.cd(dir) do
        File.write("src/routes.cr", <<-CRYSTAL)
          router = Saci::Router.new.draw do |r|
            r.resources "posts", PostsController
            r.get "/about", HomeController, :index
          end
          CRYSTAL
        rows = Saci::CLI::Inspect::Routes.parse(File.read("src/routes.cr"))
        Saci::CLI::Inspect::Routes.filter(rows, "POSTS").size.should eq(8)
        Saci::CLI::Inspect::Routes.filter(rows, "about").size.should eq(1)

        Saci::CLI.run(["routes", "--grep", "about"]).should eq(0)
        Saci::CLI.run(["routes", "--expanded"]).should eq(0)
        expect_raises(Saci::CLI::Error, /Invalid --grep/) do
          Saci::CLI::Inspect::Routes.filter(rows, "[")
        end
      end
    end
  end
end

describe "saci ci" do
  it "runs steps with timing, fails loudly and reports a summary" do
    Saci::CI.reset!
    marker = File.join("/tmp/opencode", "saci-ci-dsl-#{Random.rand(1_000_000)}.txt")
    begin
      Saci::CI.step("write") { File.write(marker, "ok") }
      Saci::CI.run("true-command", "true")
      output = IO::Memory.new
      Saci::CI.run_all(output).should eq(0)
      File.read(marker).should eq("ok")
      output.to_s.should contain("== write ==")
      output.to_s.should contain("PASS")
      output.to_s.should contain("2 steps, 0 failures")

      Saci::CI.reset!
      Saci::CI.step("boom") { Saci::CI.fail!("nope") }
      output = IO::Memory.new
      Saci::CI.run_all(output).should eq(1)
      output.to_s.should contain("FAIL")
      output.to_s.should contain("1 step, 1 failure")
      output.to_s.should contain("failed: boom")
    ensure
      Saci::CI.reset!
      File.delete(marker) if File.exists?(marker)
    end
  end

  it "executes config/ci.cr end-to-end" do
    with_extras_app(name: "ci_run") do |dir|
      Dir.cd(dir) do
        link_extras_framework_lib!
        File.write("config/ci.cr", <<-CRYSTAL)
          Saci::CI.step "Marker" do
            File.write("ci_marker.txt", "ok")
          end

          Saci::CI.run "Shell", "true"
          CRYSTAL
        Saci::CLI::CICommand.locate.should eq("config/ci.cr")
        Saci::CLI.run(["ci"]).should eq(0)
        File.read("ci_marker.txt").should eq("ok")
      end
    end
  end

  it "prints a template and exits 1 without config/ci.cr" do
    with_extras_app(name: "ci_missing") do |dir|
      Dir.cd(dir) do
        # `saci new` now generates config/ci.cr; this example covers the
        # missing-file path.
        File.delete("config/ci.cr") if File.exists?("config/ci.cr")
        Saci::CLI::CICommand.locate.should be_nil
        Saci::CLI.run(["ci"]).should eq(1)
        Saci::CLI::CICommand.template.should contain("Saci::CI.step")
      end
    end
  end
end

describe "saci app:update" do
  it "creates missing files and keeps customized ones unless --force" do
    with_extras_app(name: "app_update") do |dir|
      Dir.cd(dir) do
        File.delete("src/views/home/index.ecr")
        File.write("src/controllers/home_controller.cr", "# custom\n")

        capture_extras_output do
          with_extras_input("n\n") do
            Saci::CLI.run(["app:update"]).should eq(0)
          end
        end
        File.exists?("src/views/home/index.ecr").should be_true
        File.read("src/controllers/home_controller.cr").should eq("# custom\n")

        capture_extras_output do
          Saci::CLI.run(["app:update", "--force"]).should eq(0)
        end
        File.read("src/controllers/home_controller.cr").should contain("class HomeController")
      end
    end
  end

  it "--pretend writes nothing" do
    with_extras_app(name: "app_update_pretend") do |dir|
      Dir.cd(dir) do
        File.delete("db/seed.cr")
        out, _ = capture_extras_output do
          Saci::CLI.run(["app:update", "--pretend"]).should eq(0)
        end
        out.should contain("create db/seed.cr")
        File.exists?("db/seed.cr").should be_false
      end
    end
  end
end

describe "saci info commands" do
  it "answers about/stats/notes/middleware/dbconsole and the cache/tmp helpers" do
    with_extras_app(name: "info_cmds") do |dir|
      Dir.cd(dir) do
        Saci::CLI.run(["about"]).should eq(0)
        Saci::CLI.run(["stats"]).should eq(0)
        Saci::CLI.run(["notes"]).should eq(0)
        Saci::CLI.run(["middleware"]).should eq(0)
        Saci::CLI.run(["dbconsole"]).should eq(0)
        Saci::CLI.run(["dev:cache", "--on"]).should eq(0)
        File.exists?("tmp/caching-dev.txt").should be_true
        Saci::CLI.run(["dev:cache", "--off"]).should eq(0)
        File.exists?("tmp/caching-dev.txt").should be_false
        Saci::CLI.run(["log:clear"]).should eq(0)
        Saci::CLI.run(["tmp:clear"]).should eq(0)
        Saci::CLI.run(["restart"]).should eq(0)
        File.exists?("tmp/restart.txt").should be_true
        Saci::CLI::Info.discover_time_zones.size.should be > 0
        Saci::CLI.run(["initializers"]).should eq(0)
      end
    end
  end

  it "lists and runs initializers in app context" do
    with_extras_app(name: "info_initializers") do |dir|
      Dir.cd(dir) do
        link_extras_framework_lib!
        Dir.mkdir_p("config/initializers")
        File.write("config/initializers/marker.cr", "File.write(\"init_marker.txt\", \"ran\")\n")
        Saci::CLI::Info.initializer_files.should contain("config/initializers/marker.cr")
        Saci::CLI::Info.initializer_files.size.should be >= 1
        Saci::CLI.run(["initializers:run", "marker"]).should eq(0)
        File.read("init_marker.txt").should eq("ran")
      end
    end
  end
end

describe "saci CLI help surface" do
  it "keeps --help working for every new command" do
    [
      "destroy", "task", "task:list", "ci", "app:update", "db", "db:prepare",
      "db:version", "db:migrate:status", "db:fixtures:load", "db:test:prepare",
      "credentials:fetch", "about", "stats", "notes", "middleware",
      "initializers", "dbconsole", "dev:cache", "log:clear", "tmp:clear",
      "time:zones", "restart", "routes", "generate",
    ].each do |topic|
      Saci::CLI.run(["help", topic]).should eq(0)
    end
    Saci::CLI.run(["db"]).should eq(0)
  end
end
