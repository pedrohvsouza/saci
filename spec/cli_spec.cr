require "spec"
require "file_utils"
require "../src/saci"
require "../src/saci/cli/util"
require "../src/saci/cli/new_command"
require "../src/saci/cli/generate_command"
require "../src/saci/cli/serve_command"
require "../src/saci/cli/inspect_command"
require "../src/saci/cli/schema_command"
require "../src/saci/cli/schema_check_command"
require "../src/saci/cli/test_command"
require "../src/saci/cli/secret_command"
require "../src/saci/cli/credentials_command"
require "../src/saci/cli/inspect_command"
require "../src/saci/cli"

def with_tmp_app(name : String = "cli_test_app", & : String ->) : Nil
  dir = File.join("/tmp/opencode", "saci-cli-#{name}-#{Random.rand(1_000_000)}")
  begin
    Saci::CLI::New.create(name, dir: dir, skip_shards: true, skip_git: true)
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

# Symlink the framework's lib into a fixture app so bare `db`/`sqlite3`
# requires resolve without a `shards install` (fixtures skip shards).
# The runner wrapper itself requires the framework via a file-relative path.
def link_framework_lib! : Nil
  framework_lib = File.join(Saci::CLI::New::SACI_ROOT, "lib")
  File.symlink(framework_lib, "lib") unless File.exists?("lib")
end

describe "Saci::CLI::Util" do
  it "validates app names" do
    Saci::CLI::Util.check_app_name!("blog").should eq("blog")
    expect_raises(Saci::CLI::Error) { Saci::CLI::Util.check_app_name!("Blog") }
    expect_raises(Saci::CLI::Error) { Saci::CLI::Util.check_app_name!("has-dash") }
  end

  it "converts names" do
    Saci::CLI::Util.class_name("blog_post").should eq("BlogPost")
    Saci::CLI::Util.file_name("BlogPost").should eq("blog_post")
  end

  it "parses fields and rejects bad ones" do
    Saci::CLI::Generate.parse_fields(["title:string", "n:integer"]).should eq([{"title", "string"}, {"n", "integer"}])
    expect_raises(Saci::CLI::Error) { Saci::CLI::Generate.parse_fields(["title"]) }
    expect_raises(Saci::CLI::Error) { Saci::CLI::Generate.parse_fields(["title:uuid"]) }
  end
end

describe "saci new" do
  it "generates a complete skeleton" do
    with_tmp_app do |dir|
      File.exists?(File.join(dir, "shard.yml")).should be_true
      File.read(File.join(dir, "shard.yml")).should contain("name: cli_test_app")
      File.exists?(File.join(dir, "src", "cli_test_app.cr")).should be_true
      File.exists?(File.join(dir, "src", "controllers", "home_controller.cr")).should be_true
      File.exists?(File.join(dir, "src", "channels", ".gitkeep")).should be_true
      File.exists?(File.join(dir, "src", "models", "application_record.cr")).should be_true
      File.exists?(File.join(dir, "db", "migrate.cr")).should be_true
      File.exists?(File.join(dir, "db", "migrations.cr")).should be_true
      File.exists?(File.join(dir, "config", "environments", "development.cr")).should be_true
      File.exists?(File.join(dir, "config", "environments", "test.cr")).should be_true
      File.exists?(File.join(dir, "config", "environments", "production.cr")).should be_true
      File.exists?(File.join(dir, "config", "locales", "en.yml")).should be_true
      File.exists?(File.join(dir, "config", "master.key")).should be_true
      File.exists?(File.join(dir, "config", "credentials.yml.enc")).should be_true
      File.exists?(File.join(dir, "src", "views", "layouts", "application.ecr")).should be_true
      File.exists?(File.join(dir, "src", "views", "home", "index.ecr")).should be_true
      File.read(File.join(dir, ".gitignore")).should contain("/config/master.key")
      File.read(File.join(dir, "db", "migrations.cr")).should contain("SACI_MIGRATIONS = [] of Saci::Record::Migration.class")
      File.exists?(File.join(dir, "spec", "spec_helper.cr")).should be_true
      File.read(File.join(dir, "spec", "spec_helper.cr")).should contain("APP_ENV")
      File.read(File.join(dir, "spec", "spec_helper.cr")).should contain("Migrator.migrate")
      File.read(File.join(dir, "spec", "spec_helper.cr")).should contain("src/channels/*")
      File.read(File.join(dir, "src", "cli_test_app.cr")).should contain("APP_ENV")
    end
  end

  it "refuses non-empty directories" do
    dir = File.join("/tmp/opencode", "saci-cli-nonempty-#{Random.rand(1_000_000)}")
    begin
      Dir.mkdir_p(dir)
      File.write(File.join(dir, "x.txt"), "x")
      expect_raises(Saci::CLI::Error) do
        Saci::CLI::New.create("whatever", dir: dir, skip_shards: true, skip_git: true)
      end
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end

describe "saci generate" do
  it "generates a model, migration and manifest entry" do
    with_tmp_app do |dir|
      Dir.cd(dir) do
        Saci::CLI::Generate.run(["model", "Post", "title:string", "views:integer", "published:boolean"])
        model = File.read("src/models/post.cr")
        model.should contain("class Post < ApplicationRecord")
        model.should contain("column title : String")
        model.should contain("column views : Int64")
        model.should contain("column published : Bool")
        model.should contain("timestamps")

        migrations = Dir.glob("db/migrate/*_create_posts.cr")
        migrations.size.should eq(1)
        mig = File.read(migrations.first)
        mig.should contain("class CreatePosts < Saci::Record::Migration")
        mig.should contain("create_table :posts")
        mig.should contain("t.string :title")
        mig.should contain("t.timestamps")

        File.read("db/migrations.cr").should contain("CreatePosts")
      end
    end
  end

  it "generates a model spec alongside the model" do
    with_tmp_app do |dir|
      Dir.cd(dir) do
        Saci::CLI::Generate.run(["model", "Post", "title:string"])
        spec = File.read("spec/models/post_spec.cr")
        spec.should contain("describe Post")
        spec.should contain("clean_database!")
      end
    end
  end

  it "generates a controller with actions" do
    with_tmp_app do |dir|
      Dir.cd(dir) do
        Saci::CLI::Generate.run(["controller", "Posts", "index", "show"])
        src = File.read("src/controllers/posts_controller.cr")
        src.should contain("class PostsController < ApplicationController")
        src.should contain("def index")
        src.should contain("def show")

        req = File.read("spec/requests/posts_controller_spec.cr")
        req.should contain("TestSession.serve")
        req.should contain("r.get \"/posts\", PostsController, :index")
        req.should contain("r.get \"/posts/:id\", PostsController, :show")
        req.should contain("app.get(\"/posts\")")
        req.should contain("app.get(\"/posts/1\")")
      end
    end
  end

  it "generates request specs with real verbs (create->POST, update->PATCH, destroy->DELETE)" do
    with_tmp_app do |dir|
      Dir.cd(dir) do
        Saci::CLI::Generate.run(["controller", "Posts", "index", "show", "create", "update", "destroy"])
        req = File.read("spec/requests/posts_controller_spec.cr")
        req.should contain("r.get \"/posts\", PostsController, :index")
        req.should contain("r.get \"/posts/:id\", PostsController, :show")
        req.should contain("r.post \"/posts\", PostsController, :create")
        req.should contain("r.patch \"/posts/:id\", PostsController, :update")
        req.should contain("r.delete \"/posts/:id\", PostsController, :destroy")
        req.should contain("app.get(\"/posts\")")
        req.should contain("app.get(\"/posts/1\")")
        req.should contain("app.post(\"/posts\")")
        req.should contain("app.patch(\"/posts/1\")")
        req.should contain("app.delete(\"/posts/1\")")
      end
    end
  end

  it "generates AddIndex migrations with add_index (not add_column)" do
    with_tmp_app do |dir|
      Dir.cd(dir) do
        Saci::CLI::Generate.run(["migration", "AddIndexToFollows", "follower_id:integer", "--unique"])
        migrations = Dir.glob("db/migrate/*_add_index_to_follows.cr")
        migrations.size.should eq(1)
        mig = File.read(migrations.first)
        mig.should contain("add_index :follows, :follower_id, unique: true")
        mig.should_not contain("add_column")
        File.read("db/migrations.cr").should contain("AddIndexToFollows")
      end
    end
  end

  it "generates non-unique AddIndex migrations from the name pattern alone" do
    with_tmp_app do |dir|
      Dir.cd(dir) do
        Saci::CLI::Generate.run(["migration", "AddIndexToFollows", "follower_id"])
        mig = File.read(Dir.glob("db/migrate/*_add_index_to_follows.cr").first)
        mig.should contain("add_index :follows, :follower_id")
        mig.should_not contain("unique: true")
        mig.should_not contain("add_column")
      end
    end
  end

  it "generates composite unique indexes" do
    with_tmp_app do |dir|
      Dir.cd(dir) do
        Saci::CLI::Generate.run(["migration", "AddIndexToFollows", "follower_id:integer", "followed_id:integer", "--unique"])
        mig = File.read(Dir.glob("db/migrate/*_add_index_to_follows.cr").first)
        mig.should contain("add_index :follows, [:follower_id, :followed_id], unique: true")
      end
    end
  end

  it "emits add_index for --unique even with a generic AddXToY name" do
    with_tmp_app do |dir|
      Dir.cd(dir) do
        Saci::CLI::Generate.run(["migration", "AddFollowedToFollows", "followed_id:integer", "--unique"])
        mig = File.read(Dir.glob("db/migrate/*_add_followed_to_follows.cr").first)
        mig.should contain("add_index :follows")
        mig.should_not contain("add_column")
      end
    end
  end

  it "parses db:migrate --all without running crystal" do
    parsed = Saci::CLI::Db.parse(["--all"])
    parsed[:all].should be_true
    parsed[:script_args].should eq(["--all"])

    parsed = Saci::CLI::Db.parse([] of String)
    parsed[:all].should be_false

    parsed = Saci::CLI::Db.parse(["2", "--all"])
    parsed[:all].should be_true
    parsed[:script_args].should contain("2")
    parsed[:script_args].should contain("--all")

    parsed = Saci::CLI::Db.parse(["--", "--link-flags=-Lx"])
    parsed[:crystal_flags].should eq(["--link-flags=-Lx"])
  end

  it "migrate runner template migrates all databases with --all" do
    runner = Saci::CLI::New.migrate_runner("blog")
    runner.should contain("--all")
    runner.should contain("configuration_names")
    runner.should contain("Migrated")
  end

  it "clean_all! truncates every connected database" do
    primary_path = "/tmp/opencode/saci_clean_all_primary_#{Random.rand(1_000_000)}.db"
    extra_path = "/tmp/opencode/saci_clean_all_extra_#{Random.rand(1_000_000)}.db"
    begin
      Saci::Record.connect("sqlite3://#{primary_path}")
      # Reuse the conventional "analytics" name so later multidb specs
      # (which assert exact configuration_names) are not polluted.
      Saci::Record.establish_connection("analytics", "sqlite3://#{extra_path}")
      Saci::Record.database("primary").exec("CREATE TABLE \"things\" (\"id\" INTEGER PRIMARY KEY AUTOINCREMENT, \"name\" TEXT)")
      Saci::Record.database("analytics").exec("CREATE TABLE \"things\" (\"id\" INTEGER PRIMARY KEY AUTOINCREMENT, \"name\" TEXT)")
      Saci::Record.database("primary").exec("INSERT INTO \"things\" (\"name\") VALUES (?)", "a")
      Saci::Record.database("analytics").exec("INSERT INTO \"things\" (\"name\") VALUES (?)", "b")
      Saci::Record.clean_all!
      Saci::Record.database("primary").scalar("SELECT COUNT(*) FROM \"things\"").should eq(0)
      Saci::Record.database("analytics").scalar("SELECT COUNT(*) FROM \"things\"").should eq(0)
    ensure
      begin
        Saci::Record.database("primary").close
      rescue
      end
      begin
        Saci::Record.database("analytics").close
      rescue
      end
      File.delete(primary_path) if File.exists?(primary_path)
      File.delete(extra_path) if File.exists?(extra_path)
      File.delete("#{primary_path}-wal") if File.exists?("#{primary_path}-wal")
      File.delete("#{primary_path}-shm") if File.exists?("#{primary_path}-shm")
      File.delete("#{extra_path}-wal") if File.exists?("#{extra_path}-wal")
      File.delete("#{extra_path}-shm") if File.exists?("#{extra_path}-shm")
    end
  end

  it "picks postgres/mysql/sqlite drivers, requires and URLs (template-level)" do
    Saci::CLI::New.normalize_db("postgres").should eq("postgres")
    Saci::CLI::New.normalize_db("postgresql").should eq("postgres")
    Saci::CLI::New.normalize_db("mysql").should eq("mysql")
    Saci::CLI::New.normalize_db("sqlite").should eq("sqlite")
    expect_raises(Saci::CLI::Error) { Saci::CLI::New.normalize_db("oracle") }

    opts = Saci::CLI::New.parse_opts(["blog", "--db=postgres"])
    opts[:db].should eq("postgres")
    opts = Saci::CLI::New.parse_opts(["blog", "--db", "mysql"])
    opts[:db].should eq("mysql")
    opts = Saci::CLI::New.parse_opts(["blog"])
    opts[:db].should eq("sqlite")

    Saci::CLI::New.shard_yml("blog", "/tmp/saci", "postgres").should contain("will/crystal-pg")
    Saci::CLI::New.shard_yml("blog", "/tmp/saci", "mysql").should contain("crystal-mysql")
    Saci::CLI::New.shard_yml("blog", "/tmp/saci", "sqlite").should contain("# pg:")

    Saci::CLI::New.entrypoint("blog", "postgres").should contain("require \"pg\"")
    Saci::CLI::New.entrypoint("blog", "postgres").should contain("postgres://localhost/blog_")
    Saci::CLI::New.entrypoint("blog", "mysql").should contain("require \"mysql\"")
    Saci::CLI::New.entrypoint("blog", "mysql").should contain("mysql://root@localhost/blog_")
    Saci::CLI::New.entrypoint("blog", "sqlite").should contain("sqlite3://./db/blog_")
    Saci::CLI::New.entrypoint("blog", "sqlite").should_not contain("require \"pg\"")

    Saci::CLI::New.migrate_runner("blog", "postgres").should contain("require \"pg\"")
    Saci::CLI::New.migrate_runner("blog", "postgres").should contain("postgres://localhost/blog_")
    Saci::CLI::New.spec_helper("blog", "mysql").should contain("require \"mysql\"")
    Saci::CLI::New.spec_helper("blog", "mysql").should contain("mysql://root@localhost/blog_test")
  end

  it "creates apps with the picked database" do
    dir = File.join("/tmp/opencode", "saci-cli-db-pick-#{Random.rand(1_000_000)}")
    begin
      Saci::CLI::New.create("dbpickapp", dir: dir, skip_shards: true, skip_git: true, db: "postgres")
      File.read(File.join(dir, "shard.yml")).should contain("will/crystal-pg")
      File.read(File.join(dir, "src", "dbpickapp.cr")).should contain("require \"pg\"")
      File.read(File.join(dir, "db", "migrate.cr")).should contain("--all")
      File.read(File.join(dir, "spec", "spec_helper.cr")).should contain("postgres://localhost/dbpickapp_test")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "generates AddXToY migrations with columns" do
    with_tmp_app do |dir|
      Dir.cd(dir) do
        Saci::CLI::Generate.run(["migration", "AddBioToUsers", "bio:text"])
        migrations = Dir.glob("db/migrate/*_add_bio_to_users.cr")
        migrations.size.should eq(1)
        File.read(migrations.first).should contain("add_column :users, :bio, :text")
        File.read("db/migrations.cr").should contain("AddBioToUsers")
      end
    end
  end

  it "fails fast on migration filename/class mismatches and duplicates" do
    with_tmp_app do |dir|
      Dir.cd(dir) do
        Saci::CLI::Generate.run(["migration", "AddBioToUsers", "bio:text"])
        bad = Dir.glob("db/migrate/*_add_bio_to_users.cr").first
        File.write(bad, File.read(bad).sub("class AddBioToUsers", "class AddBiographyToUsers"))
        expect_raises(Saci::CLI::Error, /AddBiographyToUsers.*AddBioToUsers|AddBioToUsers.*AddBiographyToUsers/) do
          Saci::CLI::Generate.regenerate_manifest!
        end

        File.delete(bad)
        Saci::CLI::Generate.run(["migration", "AddBioToUsers", "bio:text"])
        # A second identical migration creates a second file with the same
        # class — regenerate (called at the end of `run`) must refuse.
        expect_raises(Saci::CLI::Error, /uplicate/) do
          Saci::CLI::Generate.run(["migration", "AddBioToUsers", "bio:text"])
        end
      end
    end
  end

  it "generates a channel with a spec" do
    with_tmp_app do |dir|
      Dir.cd(dir) do
        Saci::CLI::Generate.run(["channel", "Chat"])
        src = File.read("src/channels/chat_channel.cr")
        src.should contain("class ChatChannel < Saci::Cable::Channel")
        src.should contain("stream_from")
        req = File.read("spec/channels/chat_channel_spec.cr")
        req.should contain("TestClient")
        req.should contain("r.cable \"/cable\", ChatChannel")
      end
    end
  end

  it "generates jobs and mailers with specs" do
    with_tmp_app do |dir|
      Dir.cd(dir) do
        Saci::CLI::Generate.run(["job", "Welcome"])
        File.read("src/jobs/welcome_job.cr").should contain("class WelcomeJob < Saci::Job::Base")
        File.read("spec/jobs/welcome_job_spec.cr").should contain("perform_later")

        Saci::CLI::Generate.run(["mailer", "User"])
        File.read("src/mailers/user_mailer.cr").should contain("class UserMailer < Saci::Mailer::Base")
        File.read("spec/mailers/user_mailer_spec.cr").should contain("deliver_now")
      end
    end
  end

  it "generates a full scaffold stack" do
    with_tmp_app do |dir|
      Dir.cd(dir) do
        Saci::CLI::Generate.run(["scaffold", "Post", "title:string"])
        File.read("src/models/post.cr").should contain("class Post < ApplicationRecord")
        File.read("src/controllers/posts_controller.cr").should contain("PostsController")
        Dir.glob("db/migrate/*_create_posts.cr").size.should eq(1)
        File.exists?("spec/models/post_spec.cr").should be_true
        File.exists?("spec/requests/posts_controller_spec.cr").should be_true
        File.read("db/migrations.cr").should contain("CreatePosts")
      end
    end
  end

  it "rejects bad input outside an app" do
    dir = File.join("/tmp/opencode", "saci-cli-plain-#{Random.rand(1_000_000)}")
    begin
      Dir.mkdir_p(dir)
      Dir.cd(dir) do
        expect_raises(Saci::CLI::Error) { Saci::CLI::Generate.run(["model", "Post"]) }
        expect_raises(Saci::CLI::Error) { Saci::CLI::Generate.run(["bogus", "X"]) }
      end
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end

describe "Saci::CLI dispatch" do
  it "generates secrets" do
    Saci::CLI::Secret.generate.size.should eq(128)
    Saci::CLI.run(["secret"]).should eq(0)
  end

  it "handles version and unknown commands" do
    Saci::CLI.run(["version"]).should eq(0)
    Saci::CLI.run(["help"]).should eq(0)
    Saci::CLI.run(["help", "generate"]).should eq(0)
    Saci::CLI.run(["help", "test"]).should eq(0)
    Saci::CLI.run(["nope"]).should eq(1)
  end

  it "parses serve options" do
    opts = Saci::CLI::Serve.parse([] of String)
    opts[:port].should eq("3000")
    opts[:mt].should be_false

    opts = Saci::CLI::Serve.parse(["--port", "4000", "--mt", "--workers=8", "--", "--link-flags=-Lx"])
    opts[:port].should eq("4000")
    opts[:mt].should be_true
    opts[:workers].should eq(8)
    opts[:crystal_extra].should eq(["--link-flags=-Lx"])

    opts = Saci::CLI::Serve.parse(["-w", "--watch-interval=0.2"])
    opts[:watch].should be_true
    opts[:interval].should be_close(0.2, 0.001)

    expect_raises(Saci::CLI::Error) { Saci::CLI::Serve.parse(["--bogus"]) }
  end

  it "splits test args on --" do
    script, flags = Saci::CLI::Test.split_args(["spec/models", "--verbose", "--", "--link-flags=-Lx"])
    script.should eq(["spec/models", "--verbose"])
    flags.should eq(["--link-flags=-Lx"])
  end

  it "refuses to test outside an app" do
    dir = File.join("/tmp/opencode", "saci-cli-notapp-#{Random.rand(1_000_000)}")
    begin
      Dir.mkdir_p(dir)
      Dir.cd(dir) do
        expect_raises(Saci::CLI::Error) { Saci::CLI::Test.run([] of String) }
      end
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end

describe "saci new db/seed.cr" do
  it "scaffolds a conventional starter seed" do
    with_tmp_app do |dir|
      seed = File.read(File.join(dir, "db", "seed.cr"))
      seed.should contain("saci db:seed")
      seed.should contain("Post.create!")
    end
  end
end

describe "saci routes" do
  it "falls back to the entrypoint when src/routes.cr is absent" do
    with_tmp_app(name: "cli_routes_app") do |dir|
      Dir.cd(dir) do
        Saci::CLI::Inspect::Routes.locate!("cli_routes_app").should eq("src/cli_routes_app.cr")
        rows = Saci::CLI::Inspect::Routes.parse(File.read("src/cli_routes_app.cr"))
        rows.map { |r| "#{r.verb} #{r.path} #{r.target}" }.should contain("GET / HomeController#index")
        Saci::CLI::Inspect::Routes.run([] of String).should eq(0)
      end
    end
  end

  it "prefers src/routes.cr and expands resources, constraints, namespaces, redirects and blocks" do
    with_tmp_app(name: "cli_routes_src") do |dir|
      Dir.cd(dir) do
        File.write("src/routes.cr", <<-CRYSTAL)
          router = Saci::Router.new.draw do |r|
            r.root HomeController, :index
            r.get "/hello", HomeController, :index
            r.post "/users", UsersController, :create, constraints: {"id" => /\\d+/}
            r.get("/ping") { |ctx, params| ctx.response.print("pong") }
            r.redirect("/u/:username", to: "/~%{username}", status: 301)
            r.resources "posts", PostsController, only: [:index, :show]
            r.namespace("/api") do |api|
              api.get "/hello", HomeController, :index
            end
          end
          CRYSTAL
        Saci::CLI::Inspect::Routes.locate!("cli_routes_src").should eq("src/routes.cr")
        rows = Saci::CLI::Inspect::Routes.parse(File.read("src/routes.cr"))
        lines = rows.map { |r| "#{r.verb} #{r.path} #{r.target}" }
        lines.should contain("GET / HomeController#index")
        lines.should contain("GET /hello HomeController#index")
        lines.should contain("POST /users UsersController#create [constraints]")
        lines.should contain("GET /ping (block)")
        lines.should contain("GET /u/:username redirect -> /~%{username}")
        lines.should contain("GET /posts PostsController#index")
        lines.should contain("GET /posts/:id PostsController#show")
        lines.any? { |l| l.includes?("PostsController#create") }.should be_false
        lines.should contain("GET /api/hello HomeController#index")
        Saci::CLI.run(["routes"]).should eq(0)
        Saci::CLI.run(["help", "routes"]).should eq(0)
      end
    end
  end

  it "errors clearly outside an app" do
    dir = File.join("/tmp/opencode", "saci-cli-noroutes-#{Random.rand(1_000_000)}")
    begin
      Dir.mkdir_p(dir)
      File.write(File.join(dir, "shard.yml"), "name: plainapp\n")
      Dir.cd(dir) do
        expect_raises(Saci::CLI::Error, /src\/routes\.cr/) { Saci::CLI::Inspect::Routes.run([] of String) }
      end
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end

describe "saci runner" do
  it "builds wrappers with app context and verbatim code" do
    with_tmp_app(name: "cli_runner_src") do |dir|
      Dir.cd(dir) do
        src = Saci::CLI::Inspect::Runner.wrapper_source(code_body: "puts \"#{40 + 2} \#{x}\"")
        src.should contain("Saci::Record.connect")
        src.should contain("require \"../src/models/*\"")
        src.should contain("puts \"#{40 + 2} \#{x}\"")
      end
    end
  end

  it "relativizes require paths" do
    Saci::CLI::Inspect::Runner.relativize("/a/b/tmp", "/a/b/src/x.cr").should eq("../src/x.cr")
    Saci::CLI::Inspect::Runner.relativize("/a/tmp", "/x/y.cr").should eq("../../x/y.cr")
  end

  it "rejects bad input" do
    with_tmp_app(name: "cli_runner_bad") do |dir|
      Dir.cd(dir) do
        expect_raises(Saci::CLI::Error) { Saci::CLI::Inspect::Runner.run([] of String) }
        expect_raises(Saci::CLI::Error) { Saci::CLI::Inspect::Runner.run(["-e", "1", "x.cr"]) }
        expect_raises(Saci::CLI::Error) { Saci::CLI::Inspect::Runner.run_file("nope.cr") }
        expect_raises(Saci::CLI::Error) { Saci::CLI::Inspect::Runner.run(["--bogus"]) }
      end
    end
  end

  # Symlink the framework's lib so bare `db`/`sqlite3` requires resolve
  # without a `shards install` (fixtures skip shards; no network here).
  # The wrapper itself requires the framework via a file-relative path.
  it "executes -e code in app context (models loaded, DB connected)" do
    with_tmp_app(name: "cli_runner_eval") do |dir|
      Dir.cd(dir) do
        link_framework_lib!
        File.write("src/models/widget.cr", "class Widget < ApplicationRecord\n  def self.greet : String\n    \"widget-ok\"\n  end\nend\n")
        code = "File.write(\"runner_marker.txt\", \"\#{Widget.greet}:\#{Saci::Record.connection.scalar(\"SELECT 1\")}\")"
        Saci::CLI::Inspect::Runner.run_code(code).should eq(0)
        File.read("runner_marker.txt").should eq("widget-ok:1")
      end
    end
  end

  it "executes a file in app context" do
    with_tmp_app(name: "cli_runner_file") do |dir|
      Dir.cd(dir) do
        link_framework_lib!
        File.write("ops_script.cr", "File.write(\"file_marker.txt\", \"file-ok\")\n")
        Saci::CLI::Inspect::Runner.run_file("ops_script.cr").should eq(0)
        File.read("file_marker.txt").should eq("file-ok")
        Saci::CLI.run(["help", "runner"]).should eq(0)
      end
    end
  end
end

describe "saci db:seed" do
  it "prefers db/seed.cr over db/seeds.cr" do
    with_tmp_app(name: "cli_seed_order") do |dir|
      Dir.cd(dir) do
        File.write("db/seeds.cr", "puts 1\n")
        Saci::CLI::Inspect::Seed.resolve.should eq("db/seed.cr")
        File.delete("db/seed.cr")
        Saci::CLI::Inspect::Seed.resolve.should eq("db/seeds.cr")
        File.delete("db/seeds.cr")
        Saci::CLI::Inspect::Seed.resolve.should be_nil
      end
    end
  end

  it "prints the conventional template and exits 1 when no seed exists" do
    with_tmp_app(name: "cli_seed_missing") do |dir|
      Dir.cd(dir) do
        File.delete("db/seed.cr")
        Saci::CLI::Inspect::Seed.run([] of String).should eq(1)
        Saci::CLI.run(["help", "db:seed"]).should eq(0)
      end
    end
  end

  it "runs the seed file in app context" do
    with_tmp_app(name: "cli_seed_run") do |dir|
      Dir.cd(dir) do
        File.symlink(File.join(Saci::CLI::New::SACI_ROOT, "lib"), "lib") unless File.exists?("lib")
        File.write("db/seed.cr", "File.write(\"seed_marker.txt\", \"seeded\")\n")
        Saci::CLI::Inspect::Seed.run([] of String).should eq(0)
        File.read("seed_marker.txt").should eq("seeded")
      end
    end
  end
end

describe "saci console" do
  it "quits the loop on exit without compiling" do
    Saci::CLI::Inspect::Console.run([] of String, IO::Memory.new("exit\n")).should eq(0)
    Saci::CLI::Inspect::Console.run([] of String, IO::Memory.new("  \nquit\n")).should eq(0)
    Saci::CLI.run(["help", "console"]).should eq(0)
  end

  it "runs -e code like runner" do
    with_tmp_app(name: "cli_console_eval") do |dir|
      Dir.cd(dir) do
        File.symlink(File.join(Saci::CLI::New::SACI_ROOT, "lib"), "lib") unless File.exists?("lib")
        Saci::CLI::Inspect::Console.run(["-e", "File.write(\"console_marker.txt\", \"console-ok\")"]).should eq(0)
        File.read("console_marker.txt").should eq("console-ok")
      end
    end
  end
end
