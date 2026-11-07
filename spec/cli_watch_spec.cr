require "spec"
require "file_utils"
require "../src/saci"
require "../src/saci/cli/util"
require "../src/saci/cli/watch"

def with_watch_dir(& : String ->) : Nil
  dir = File.join("/tmp/opencode", "saci-watch-#{Random.rand(1_000_000)}")
  begin
    Dir.mkdir_p(File.join(dir, "src"))
    Dir.mkdir_p(File.join(dir, "db"))
    File.write(File.join(dir, "src", "app.cr"), "puts 1\n")
    File.write(File.join(dir, "db", "app.db"), "binary")
    File.write(File.join(dir, "shard.yml"), "name: x\n")
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

describe Saci::CLI::Watch do
  it "snapshots source files but ignores databases and tooling dirs" do
    with_watch_dir do |dir|
      Dir.cd(dir) do
        snap = Saci::CLI::Watch.snapshot
        snap.has_key?("src/app.cr").should be_true
        snap.has_key?("shard.yml").should be_true
        snap.has_key?("db/app.db").should be_false
      end
    end
  end

  it "ignores log files and tmp/git/lib dirs" do
    with_watch_dir do |dir|
      Dir.cd(dir) do
        Dir.mkdir_p("tmp")
        Dir.mkdir_p("log")
        Dir.mkdir_p("lib/dep")
        File.write("tmp/cache.tmp", "x")
        File.write("log/app.log", "x")
        File.write("lib/dep/a.cr", "x")
        snap = Saci::CLI::Watch.snapshot
        snap.has_key?("tmp/cache.tmp").should be_false
        snap.has_key?("log/app.log").should be_false
        snap.has_key?("lib/dep/a.cr").should be_false
      end
    end
  end

  it "detects modifications, additions and removals" do
    with_watch_dir do |dir|
      Dir.cd(dir) do
        before = Saci::CLI::Watch.snapshot
        Saci::CLI::Watch.changed?(before, Saci::CLI::Watch.snapshot).should be_false

        File.write("src/app.cr", "puts 2\n")
        Saci::CLI::Watch.changed?(before, Saci::CLI::Watch.snapshot).should be_true

        File.write("src/new.cr", "x\n")
        Saci::CLI::Watch.changed?(before, Saci::CLI::Watch.snapshot).should be_true

        File.delete("src/app.cr")
        after = Saci::CLI::Watch.snapshot
        Saci::CLI::Watch.changed?(before, after).should be_true
        Saci::CLI::Watch.changed?(after, after.dup).should be_false
      end
    end
  end

  it "ignores database writes" do
    with_watch_dir do |dir|
      Dir.cd(dir) do
        before = Saci::CLI::Watch.snapshot
        File.write("db/app.db", "binary-CHANGED")
        Saci::CLI::Watch.changed?(before, Saci::CLI::Watch.snapshot).should be_false
      end
    end
  end

  it "watches the src/ of path dependencies declared in shard.yml" do
    with_watch_dir do |dir|
      framework = File.join(dir, "vendor-fw")
      Dir.mkdir_p(File.join(framework, "src", "fw"))
      Dir.mkdir_p(File.join(framework, "spec"))
      File.write(File.join(framework, "src", "fw", "core.cr"), "module Fw; end\n")
      File.write(File.join(framework, "spec", "core_spec.cr"), "x\n")
      app = File.join(dir, "app")
      Dir.mkdir_p(File.join(app, "src"))
      File.write(File.join(app, "src", "app.cr"), "puts 1\n")
      File.write(File.join(app, "shard.yml"), <<-YAML)
        name: app
        dependencies:
          fw:
            path: ../vendor-fw
          pg:
            github: will/crystal-pg
        development_dependencies:
          missing:
            path: ../nope
        YAML

      Dir.cd(app) do
        roots = Saci::CLI::Watch.path_dependency_roots
        roots.size.should eq(1)
        roots.first.should end_with("vendor-fw/src")

        before = Saci::CLI::Watch.snapshot
        before.keys.any?(&.ends_with?("vendor-fw/src/fw/core.cr")).should be_true
        before.keys.any?(&.ends_with?("core_spec.cr")).should be_false

        File.write(File.join(framework, "src", "fw", "core.cr"), "module Fw; X = 1; end\n")
        Saci::CLI::Watch.changed?(before, Saci::CLI::Watch.snapshot).should be_true
      end
    end
  end

  it "keeps watching a dependency that lives under an ignored dir name" do
    with_watch_dir do |dir|
      fw = File.join(dir, "tmp", "fw")
      Dir.mkdir_p(File.join(fw, "src"))
      File.write(File.join(fw, "src", "a.cr"), "x\n")
      File.write(File.join(dir, "shard.yml"), "name: x\ndependencies:\n  fw:\n    path: tmp/fw\n")
      Dir.cd(dir) do
        Saci::CLI::Watch.snapshot.keys.any?(&.ends_with?("tmp/fw/src/a.cr")).should be_true
        File.write("tmp/cache.tmp", "x")
        Saci::CLI::Watch.snapshot.has_key?("tmp/cache.tmp").should be_false
      end
    end
  end
end
