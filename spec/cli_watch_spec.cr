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
end
