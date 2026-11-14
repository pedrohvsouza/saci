require "spec"
require "json"
require "../src/saci"

private def log_entry(source : String, message : String, data = Log::Metadata.empty,
                      severity = Log::Severity::Info, exception : Exception? = nil) : Log::Entry
  Log::Entry.new(source, severity, message, data, exception,
    timestamp: Time.local(2026, 11, 14, 3, 15, 2, nanosecond: 494_236_000))
end

private def with_env(values : Hash(String, String?), &) : Nil
  previous = values.keys.to_h { |key| {key, ENV[key]?} }
  values.each { |key, value| value ? (ENV[key] = value) : ENV.delete(key) }
  begin
    yield
  ensure
    previous.each { |key, value| value ? (ENV[key] = value) : ENV.delete(key) }
  end
end

private def formatted(formatter : Log::Formatter, entry : Log::Entry) : String
  String.build { |io| formatter.format(entry, io) }
end

describe Saci::TextLogFormatter do
  it "prints local time, severity, source and message without colors" do
    line = formatted(Saci::TextLogFormatter.new, log_entry("saci", "Completed 200"))
    line.should eq("2026/11/14 03:15:02.494236 INFO  saci: Completed 200")
  end

  it "renders queries with their duration" do
    data = Log::Metadata.build({duration_ms: 1.5, adapter: "sqlite"})
    line = formatted(Saci::TextLogFormatter.new, log_entry(Saci::SQL_LOG_SOURCE, %(SELECT * FROM "posts"), data))
    line.should eq(%(2026/11/14 03:15:02.494236 INFO  SQL (1.5ms)  SELECT * FROM "posts"))
  end

  it "colors queries by kind when color is on" do
    insert = formatted(Saci::TextLogFormatter.new(true), log_entry(Saci::SQL_LOG_SOURCE, "INSERT INTO t VALUES (1)"))
    insert.should contain("\e[1m\e[32mINSERT INTO t VALUES (1)\e[0m")
    query = formatted(Saci::TextLogFormatter.new(true), log_entry(Saci::SQL_LOG_SOURCE, "/* app */ SELECT 1"))
    query.should contain("\e[1m\e[34m/* app */ SELECT 1\e[0m")
  end

  it "appends the exception" do
    line = formatted(Saci::TextLogFormatter.new, log_entry("saci", "boom", severity: Log::Severity::Error, exception: ArgumentError.new("bad")))
    line.should start_with("2026/11/14 03:15:02.494236 ERROR saci: boom\n")
    line.should contain("bad (ArgumentError)")
  end
end

describe Saci::JsonLogFormatter do
  it "writes microsecond timestamps and typed data fields" do
    data = Log::Metadata.build({duration_ms: 2.5, adapter: "pg", cached: true})
    json = JSON.parse(formatted(Saci::JsonLogFormatter.new, log_entry(Saci::SQL_LOG_SOURCE, "SELECT 1", data)))
    json["time"].as_s.should match(/\.494236/)
    json["level"].should eq("INFO")
    json["source"].should eq("saci.sql")
    json["message"].should eq("SELECT 1")
    json["duration_ms"].as_f.should eq(2.5)
    json["adapter"].should eq("pg")
    json["cached"].as_bool.should be_true
  end
end

describe "Saci.log_color?" do
  it "is off for non-terminals and with NO_COLOR, and can be forced" do
    io = IO::Memory.new
    with_env({"SACI_LOG_COLOR" => nil, "NO_COLOR" => nil}) { Saci.log_color?(io).should be_false }
    with_env({"SACI_LOG_COLOR" => "1", "NO_COLOR" => "1"}) { Saci.log_color?(io).should be_true }
    with_env({"SACI_LOG_COLOR" => "never", "NO_COLOR" => nil}) { Saci.log_color?(io).should be_false }
  end
end

describe "Saci.log_queries" do
  it "can be turned off" do
    previous = Saci.log_queries
    begin
      Saci.log_queries = false
      Saci.log_queries.should be_false
      Saci.log_query("SELECT 1", 1.0) # no-op, must not raise
    ensure
      Saci.log_queries = previous
    end
  end
end

# IOBackend dispatches asynchronously by default.
private def wait_for_output(io : IO::Memory, text : String) : Nil
  100.times do
    break if io.to_s.includes?(text)
    sleep 5.milliseconds
  end
end

describe "Saci.setup_logging" do
  it "uses default_level when LOG_LEVEL is unset and Saci's text format" do
    io = IO::Memory.new
    begin
      with_env({"LOG_LEVEL" => nil, "SACI_LOG_FORMAT" => nil}) do
        Saci.setup_logging(io, default_level: :warn)
        Log.for("setup_probe").info { "hidden" }
        Log.for("setup_probe").warn { "shown" }
      end
      wait_for_output(io, "shown")
      io.to_s.should_not contain("hidden")
      io.to_s.should match(/\A\d{4}\/\d\d\/\d\d \d\d:\d\d:\d\d\.\d{6} WARN  setup_probe: shown\n\z/)

      io.clear
      with_env({"LOG_LEVEL" => "debug", "SACI_LOG_FORMAT" => nil}) do
        Saci.setup_logging(io, default_level: :none)
        Log.for("setup_probe").debug { "env wins" }
      end
      wait_for_output(io, "env wins")
      io.to_s.should contain("DEBUG setup_probe: env wins")
    ensure
      # What the suite runs with: Saci's backend, quiet unless LOG_LEVEL is set.
      Saci.setup_logging(default_level: :none)
    end
  end
end
