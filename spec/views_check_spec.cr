require "spec"
require "file_utils"
require "../src/saci/cli/util"
require "../src/saci/cli/views_check_command"

private def with_views_dir(& : String ->) : Nil
  dir = File.join("/tmp/opencode", "saci-views-check-#{Random.rand(1_000_000)}")
  begin
    Dir.mkdir_p(File.join(dir, "posts"))
    Dir.mkdir_p(File.join(dir, "shared"))
    File.write(File.join(dir, "posts", "row.ecr"), "<p><%= @post %></p>\n")
    File.write(File.join(dir, "shared", "row.ecr"), "<p>row</p>\n")
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

describe Saci::CLI::ViewsCheck do
  it "accepts templates whose helpers, strings and partials are valid" do
    with_views_dir do |dir|
      File.write(File.join(dir, "posts", "index.ecr"), <<-ECR)
      <% form_with("/posts") do |f| %>
        <%= f.text_field("title") %>
      <% end %>
      <%= render_partial("posts/row", post: @post) %>
      <%= cache("sidebar") { render_partial("shared/row") } %>
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
