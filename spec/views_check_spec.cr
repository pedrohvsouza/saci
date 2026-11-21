require "spec"
require "file_utils"
require "../src/saci/cli/util"
require "../src/saci/cli/views_check_command"

private def with_views_dir(& : String ->) : Nil
  root = File.join("/tmp/opencode", "saci-views-check-#{Random.rand(1_000_000)}")
  dir = File.join(root, "src", "views")
  begin
    Dir.mkdir_p(File.join(dir, "posts"))
    Dir.mkdir_p(File.join(dir, "shared"))
    Dir.mkdir_p(File.join(dir, "layouts"))
    File.write(File.join(dir, "layouts", "application.ecr"), "<html><%= content %></html>\n")
    File.write(File.join(dir, "posts", "row.ecr"), "<p><%= @post %></p>\n")
    File.write(File.join(dir, "shared", "row.ecr"), "<p>row</p>\n")
    yield dir
  ensure
    FileUtils.rm_rf(root)
  end
end

private def controller_file(dir : String) : String
  controllers = File.join(File.dirname(dir), "controllers")
  Dir.mkdir_p(controllers)
  File.join(controllers, "posts_controller.cr")
end

describe Saci::CLI::ViewsCheck do
  it "accepts templates whose helpers, strings, comments and partials are valid" do
    with_views_dir do |dir|
      File.write(File.join(dir, "posts", "index.ecr"), <<-ECR)
      <%
        form_with("/posts") do |f|
      %>
        <%= f.text_field("title") %>
      <% end %>
      <%= render_partial("posts/row", post: @post) %>
      <%= cache("sidebar") { render_partial("shared/row") } %>
      <%= "<%" %>
      <%= "a <% b" %>
      ECR

      Saci::CLI::ViewsCheck.check(dir).should be_empty
    end
  end

  it "finds block helpers, nested tags and missing partials with their lines" do
    with_views_dir do |dir|
      File.write(File.join(dir, "posts", "index.ecr"), <<-ECR)
      <%= form_with("/posts") do |f| %>
      <%= "<%= @title %>" %>
      <%= render_partial("posts/missing") %>
      <%# render_partial("posts/also_missing") %>
      <%= render partial: "posts/row" %>
      ECR

      issues = Saci::CLI::ViewsCheck.check(dir)
      issues.map(&.line).should eq([1, 2, 3])
      issues[0].message.should contain("block helper")
      issues[1].message.should contain("string literal")
      issues[2].message.should contain("partial 'posts/missing'")
    end
  end

  it "reports issues inside multiline ECR tags on the tag's own lines" do
    with_views_dir do |dir|
      File.write(File.join(dir, "posts", "index.ecr"), <<-ECR)
      <%=
        form_with("/posts") do |f|
      %>
        <%= f.text_field("title") %>
      <% end %>

      <%=
        render_partial(
          "posts/missing"
        )
      %>
      ECR

      issues = Saci::CLI::ViewsCheck.check(dir)
      issues.map(&.line).should eq([1, 8])
      issues[0].message.should contain("block helper")
      issues[1].message.should contain("partial 'posts/missing'")
    end
  end

  it "ignores ECR comments, escaped tags and partial examples in prose" do
    with_views_dir do |dir|
      File.write(File.join(dir, "posts", "index.ecr"), <<-ECR)
      <%#
        form_with("/posts") do |f|
        render_partial("posts/missing")
      %>
      <%# render_partial("posts/also_missing") %>
      <p>Render it with render_partial("posts/missing") in prose.</p>
      <%%= escaped <%= example %> %>
      ECR

      Saci::CLI::ViewsCheck.check(dir).should be_empty
    end
  end

  it "does not mistake escaped quotes, char literals or :do for problems" do
    with_views_dir do |dir|
      File.write(File.join(dir, "posts", "index.ecr"), <<-ECR)
      <%= "prefix <%= @title %> suffix" %>
      <%= :do %>
      <%= @do %>
      <%= '"' %>
      ECR

      issues = Saci::CLI::ViewsCheck.check(dir)
      issues.size.should eq(1)
      issues[0].line.should eq(1)
      issues[0].message.should contain("string literal")
    end
  end

  it "reports unterminated tags instead of raising" do
    with_views_dir do |dir|
      File.write(File.join(dir, "posts", "index.ecr"), "<p><%= @title</p>\n")

      issues = Saci::CLI::ViewsCheck.check(dir)
      issues.size.should eq(1)
      issues[0].line.should eq(1)
      issues[0].message.should contain("unterminated ECR tag")
    end
  end

  it "recognizes symbols, quoted symbols and render_to_string partials" do
    with_views_dir do |dir|
      File.write(File.join(dir, "posts", "index.ecr"), <<-ECR)
      <%= render_partial(:shared) %>
      <%= render partial: :"shared/row" %>
      <%= render_to_string(partial: "shared/missing") %>
      ECR

      issues = Saci::CLI::ViewsCheck.check(dir)
      issues.map(&.message).should contain("partial 'shared' not found (expected #{File.join(dir, "shared.ecr")})")
      issues.map(&.message).should contain("partial 'shared/missing' not found (expected #{File.join(dir, "shared/missing.ecr")})")
      issues.size.should eq(2)
    end
  end

  it "flags block helpers with a trim marker or an inline comment" do
    with_views_dir do |dir|
      File.write(File.join(dir, "posts", "index.ecr"), <<-ECR)
      <%= form_with("/posts") do |f| -%>
      <%= form_with("/posts") do # fields %>
      ECR

      Saci::CLI::ViewsCheck.check(dir).size.should eq(2)
    end
  end

  it "reports missing explicit layouts from controllers, skipping false, dynamic and partial calls" do
    with_views_dir do |dir|
      File.write(File.join(dir, "layouts", "admin.ecr"), "<html><%= content %></html>\n")
      controller = controller_file(dir)
      File.write(controller, <<-CR)
      class PostsController < ApplicationController
        def index
          render_template :index, layout: "application"
        end

        def show
          render_template :show, layout: "admin"
        end

        def edit
          render action: :edit, layout: "missing/admin"
        end

        def new
          render_template :new, layout: false
        end

        def create
          render_template :create, layout: "\#{@layout}"
        end

        def preview
          render partial: "posts/row", layout: "not_a_layout"
        end
      end
      CR

      issues = Saci::CLI::ViewsCheck.check(dir)
      issues.size.should eq(1)
      issues[0].path.should eq(controller)
      issues[0].line.should eq(11)
      issues[0].message.should eq("layout 'missing/admin' not found (expected #{File.join(dir, "layouts", "missing/admin.ecr")})")
    end
  end

  it "ignores layout examples in controller comments and string literals" do
    with_views_dir do |dir|
      controller = controller_file(dir)
      File.write(controller, <<-CR)
      class PostsController < ApplicationController
        # render_template :index, layout: "from_docs"
        NOTE = "render_template :index, layout: \\"from_string\\""

        def index
          render_template :index, layout: "application"
        end
      end
      CR

      Saci::CLI::ViewsCheck.check(dir).should be_empty
    end
  end

  it "prints issues and returns 1, or returns 0 when clean" do
    with_views_dir do |dir|
      File.write(File.join(dir, "posts", "index.ecr"), "<%= render_partial(\"posts/missing\") %>\n")

      io = IO::Memory.new
      Saci::CLI::ViewsCheck.run([dir], io).should eq(1)
      io.to_s.should contain("posts/missing")
      io.to_s.should contain("1 issue(s)")

      File.write(File.join(dir, "posts", "index.ecr"), "<p>clean</p>\n")
      ok = IO::Memory.new
      Saci::CLI::ViewsCheck.run([dir], ok).should eq(0)
      ok.to_s.should contain("no issues")
    end

    expect_raises(Saci::CLI::Error, /No views directory/) do
      Saci::CLI::ViewsCheck.run(["/tmp/opencode/saci-views-check-missing"], IO::Memory.new)
    end
  end
end
