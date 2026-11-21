require "spec"
require "file_utils"
require "../src/saci/cli/util"
require "../src/saci/cli/router_edit"

private def with_router_dir(name : String = "router_demo", & : String ->) : Nil
  dir = File.join("/tmp/opencode", "saci-router-edit-#{Random.rand(1_000_000)}")
  begin
    Dir.mkdir_p(File.join(dir, "src"))
    File.write(File.join(dir, "shard.yml"), "name: #{name}\n")
    File.write(File.join(dir, "src", "#{name}.cr"), <<-CRYSTAL)
    require "saci"

    router = Router.new.draw do |r|
      r.get "/up", HealthController, :show
    end

    Application.new(router).listen_gracefully(3000)
    CRYSTAL
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

describe Saci::CLI::RouterEdit do
  it "adds routes once and keeps reruns idempotent" do
    with_router_dir do |dir|
      Dir.cd(dir) do
        io = IO::Memory.new
        Saci::CLI::RouterEdit.add([%(r.get "/pages", PagesController, :index)], io: io).should eq(Saci::CLI::RouterEdit::Result::Updated)
        source = File.read("src/router_demo.cr")
        source.should contain(%(  r.get "/pages", PagesController, :index))
        io.to_s.should contain("add routes")

        Saci::CLI::RouterEdit.add([%(r.get "/pages", PagesController, :index)], io: IO::Memory.new)
          .should eq(Saci::CLI::RouterEdit::Result::Unchanged)
        source.scan(%(r.get "/pages")).size.should eq(1)
      end
    end
  end

  it "uses the draw block's variable and removes receiver variants" do
    with_router_dir do |dir|
      Dir.cd(dir) do
        File.write("src/router_demo.cr", <<-CRYSTAL)
        router = Router.new.draw do |router|
          router.get "/up", HealthController, :show
        end
        CRYSTAL
        Saci::CLI::RouterEdit.add([%(r.get "/pages", PagesController, :index), "Routes.draw_pages(r)"],
          io: IO::Memory.new)
        source = File.read("src/router_demo.cr")
        source.should contain(%(  router.get "/pages", PagesController, :index))
        source.should contain("  Routes.draw_pages(router)")

        Saci::CLI::RouterEdit.remove([%(r.get "/pages", PagesController, :index), "Routes.draw_pages(r)"],
          io: IO::Memory.new)
        source = File.read("src/router_demo.cr")
        source.should_not contain("PagesController")
        source.should_not contain("Routes.draw_pages")
      end
    end
  end

  it "prefers src/routes.cr when present" do
    with_router_dir do |dir|
      Dir.cd(dir) do
        File.write("src/routes.cr", <<-CRYSTAL)
        Saci::Routes.define AppRoutes do |r|
          r.get "/up", HealthController, :show
        end
        CRYSTAL
        Saci::CLI::RouterEdit.add([%(r.get "/pages", PagesController, :index)], io: IO::Memory.new)
          .should eq(Saci::CLI::RouterEdit::Result::Updated)
        File.read("src/routes.cr").should contain(%(r.get "/pages", PagesController, :index))
        File.read("src/router_demo.cr").should_not contain("PagesController")
      end
    end
  end

  it "creates and reuses an admin namespace" do
    with_router_dir do |dir|
      Dir.cd(dir) do
        Saci::CLI::RouterEdit.add_namespace("/admin", "posts", "Admin::PostsController", io: IO::Memory.new)
          .should eq(Saci::CLI::RouterEdit::Result::Updated)
        Saci::CLI::RouterEdit.add_namespace("/admin", "users", "Admin::UsersController", io: IO::Memory.new)
          .should eq(Saci::CLI::RouterEdit::Result::Updated)
        source = File.read("src/router_demo.cr")
        source.scan(%(namespace("/admin"))).size.should eq(1)
        source.should contain(%(    a.resources "posts", Admin::PostsController))
        source.should contain(%(    a.resources "users", Admin::UsersController))

        Saci::CLI::RouterEdit.add_namespace("/admin", "posts", "Admin::PostsController", io: IO::Memory.new)
          .should eq(Saci::CLI::RouterEdit::Result::Unchanged)
      end
    end
  end

  it "adds and removes requires after the last existing require" do
    with_router_dir do |dir|
      Dir.cd(dir) do
        Saci::CLI::RouterEdit.add(["Routes.draw_posts(r)"],
          requires: [%(require "./routes/posts_routes")], io: IO::Memory.new)
        lines = File.read("src/router_demo.cr").lines
        require_at = lines.index! { |line| line.includes?("posts_routes") }
        lines[require_at - 1].should eq(%(require "saci"))
        lines[require_at + 1].should be_empty

        Saci::CLI::RouterEdit.remove(["Routes.draw_posts(r)"],
          requires: [%(require "./routes/posts_routes")], io: IO::Memory.new)
        source = File.read("src/router_demo.cr")
        source.should_not contain("posts_routes")
        source.should_not contain("Routes.draw_posts")
      end
    end
  end

  it "does not write in pretend mode and falls back when no draw block exists" do
    with_router_dir do |dir|
      Dir.cd(dir) do
        io = IO::Memory.new
        Saci::CLI::RouterEdit.add([%(r.get "/pages", PagesController, :index)], pretend: true, io: io)
          .should eq(Saci::CLI::RouterEdit::Result::Updated)
        io.to_s.should contain("would update")
        File.read("src/router_demo.cr").should_not contain("PagesController")

        File.write("src/router_demo.cr", %(puts "no router"\n))
        Saci::CLI::RouterEdit.add([%(r.get "/pages", PagesController, :index)])
          .should eq(Saci::CLI::RouterEdit::Result::NotFound)
      end
    end
  end
end
