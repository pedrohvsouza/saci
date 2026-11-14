require "spec"
require "file_utils"
require "../src/saci/cli/util"
require "../src/saci/cli/test_command"

private def in_tmp_app(&) : Nil
  dir = File.join(Dir.tempdir, "saci-compile-source-#{Process.pid}-#{Random.rand(1_000_000)}")
  Dir.mkdir_p(dir)
  begin
    Dir.cd(dir) { yield }
  ensure
    FileUtils.rm_rf(dir)
  end
end

describe Saci::CLI::Compile do
  it "keeps one source path per key so the compiler cache carries over" do
    Saci::CLI::Compile.source_path("runner").should eq(File.join("tmp", ".saci-runner.cr"))
    Saci::CLI::Compile.source_path("db-db:seed:replant").should eq(File.join("tmp", ".saci-db-db-seed-replant.cr"))
    Saci::CLI::Compile.source_path("runner").should eq(Saci::CLI::Compile.source_path("runner"))
  end

  it "writes the source for the block and removes it afterwards" do
    in_tmp_app do
      seen = nil
      ok = Saci::CLI::Compile.with_source("runner", "puts 1\n") do |path|
        seen = File.read(path)
        path.should eq(File.join("tmp", ".saci-runner.cr"))
        true
      end
      ok.should be_true
      seen.should eq("puts 1\n")
      File.exists?(File.join("tmp", ".saci-runner.cr")).should be_false
    end
  end

  it "removes the source when the block raises" do
    in_tmp_app do
      expect_raises(Exception, "boom") do
        Saci::CLI::Compile.with_source("task", "x") { raise "boom" }
      end
      File.exists?(File.join("tmp", ".saci-task.cr")).should be_false
    end
  end

  it "serializes concurrent users of the same key" do
    in_tmp_app do
      inside = 0
      max_inside = 0
      done = Channel(Nil).new
      2.times do |i|
        spawn do
          # Each fiber takes the lock from its own file descriptor, as two
          # `saci` processes would.
          Saci::CLI::Compile.with_source("runner", "puts #{i}\n") do |path|
            inside += 1
            max_inside = {max_inside, inside}.max
            File.read(path).should eq("puts #{i}\n")
            sleep 20.milliseconds
            inside -= 1
            true
          end
          done.send(nil)
        end
      end
      2.times { done.receive }
      max_inside.should eq(1)
    end
  end
end
