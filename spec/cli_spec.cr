require "spec"
require "file_utils"
require "../src/saci"
require "../src/saci/cli/util"
require "../src/saci/cli/new_command"
require "../src/saci/cli/generate_command"
require "../src/saci/cli/serve_command"
require "../src/saci/cli/test_command"
require "../src/saci/cli/secret_command"
require "../src/saci/cli/credentials_command"
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
        req.should contain("/posts/index")
      end
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
