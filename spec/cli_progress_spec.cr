require "spec"
require "file_utils"
require "../src/saci/cli/util"
require "../src/saci/cli/test_command"

private def with_env(values : Hash(String, String?), &) : Nil
  previous = values.keys.to_h { |key| {key, ENV[key]?} }
  values.each { |key, value| value ? (ENV[key] = value) : ENV.delete(key) }
  begin
    yield
  ensure
    previous.each { |key, value| value ? (ENV[key] = value) : ENV.delete(key) }
  end
end

describe Saci::CLI::Spinner do
  it "prints two plain lines when not animating" do
    io = IO::Memory.new
    ok = Saci::CLI::Spinner.run("Compiling app", "Compiled app", io) { true }
    ok.should be_true
    lines = io.to_s.lines
    lines[0].should eq("Compiling app...")
    lines[1].should match(/\A✓ Compiled app in \d+\.\ds\z/)
  end

  it "reports failure, including when the block raises" do
    io = IO::Memory.new
    Saci::CLI::Spinner.run("Compiling app", "Compiled app", io) { false }.should be_false
    io.to_s.lines.last.should match(/\A✗ Compiling app failed after \d+\.\ds\z/)

    io = IO::Memory.new
    expect_raises(Exception, "boom") do
      Saci::CLI::Spinner.run("Compiling app", "Compiled app", io) { raise "boom" }
    end
    io.to_s.lines.last.should start_with("✗ Compiling app failed")
  end

  it "redraws one line while the block runs, then replaces it with the result" do
    io = IO::Memory.new
    spinner = Saci::CLI::Spinner.new("Compiling app", "Compiled app", io, animate: true, color: false)
    spinner.start
    sleep 200.milliseconds
    spinner.stop(true)
    output = io.to_s
    output.should contain("\r\e[2K⠋ Compiling app… ")
    output.scan("\r\e[2K").size.should be >= 3
    output.should_not contain("Compiling app...")
    output.split("\r\e[2K").last.should match(/\A✓ Compiled app in \d+\.\ds\n\z/)
  end

  it "only animates on a terminal, honoring SACI_SPINNER, CI and TERM=dumb" do
    memory = IO::Memory.new
    with_env({"SACI_SPINNER" => nil, "CI" => nil}) { Saci::CLI::Spinner.animate?(memory).should be_false }
    with_env({"SACI_SPINNER" => "1", "CI" => "true"}) { Saci::CLI::Spinner.animate?(memory).should be_true }
    with_env({"SACI_SPINNER" => "0", "CI" => nil}) { Saci::CLI::Spinner.animate?(STDERR).should be_false }
    with_env({"SACI_SPINNER" => nil, "CI" => "true"}) { Saci::CLI::Spinner.animate?(STDERR).should be_false }
    with_env({"SACI_SPINNER" => nil, "CI" => nil, "TERM" => "dumb"}) { Saci::CLI::Spinner.animate?(STDERR).should be_false }
    with_env({"NO_COLOR" => "1"}) { Saci::CLI::Spinner.color?(STDERR).should be_false }
  end

  it "formats elapsed time" do
    Saci::CLI::Spinner.format_elapsed(4.24.seconds).should eq("4.2s")
    Saci::CLI::Spinner.format_elapsed(67.seconds).should eq("1m 07s")
  end
end

describe "saci test spec selection" do
  it "reads files, directories and file:line like crystal spec" do
    root = File.join("/tmp/opencode", "saci-spec-select-#{Random::Secure.hex(4)}")
    Dir.mkdir_p(File.join(root, "spec", "models"))
    File.write(File.join(root, "spec", "a_spec.cr"), "")
    File.write(File.join(root, "spec", "models", "b_spec.cr"), "")
    File.write(File.join(root, "spec", "models", "helper.cr"), "")
    begin
      Dir.cd(root) do
        files, locations, options = Saci::CLI::Test.select_specs([] of String)
        files.should eq(["spec/a_spec.cr", "spec/models/b_spec.cr"])
        locations.should be_empty
        options.should be_empty

        files, locations, options = Saci::CLI::Test.select_specs(["spec/models", "spec/a_spec.cr:12", "--error-trace"])
        files.should eq(["spec/models/b_spec.cr", "spec/a_spec.cr"])
        locations.should eq([{"spec/a_spec.cr", "12"}])
        options.should eq(["--error-trace"])

        Saci::CLI::Test.location_options(["spec/a_spec.cr"], [{"spec/a_spec.cr", "12"}]).should eq(["-l", "12"])
        Saci::CLI::Test.location_options(files, locations).should eq(["--location", "spec/a_spec.cr:12"])

        expect_raises(Saci::CLI::Error, /is not a file/) { Saci::CLI::Test.select_specs(["spec/missing_spec.cr"]) }

        source = Saci::CLI::Test.runner_source(["spec/a_spec.cr", "spec/models/b_spec.cr"], "tmp")
        source.should eq(%(require "../spec/a_spec.cr"\nrequire "../spec/models/b_spec.cr"\n))
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
