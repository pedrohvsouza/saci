require "spec"
require "../src/saci"

describe Saci::GCTuner do
  it "parses sizes with optional K/M/G suffixes" do
    Saci::GCTuner.parse_size("300000000").should eq(300_000_000_u64)
    Saci::GCTuner.parse_size("512M").should eq(512_u64 * 1024 * 1024)
    Saci::GCTuner.parse_size("1.5g").should eq((1.5 * 1024 ** 3).to_u64)
    Saci::GCTuner.parse_size("64KB").should eq(64_u64 * 1024)
    Saci::GCTuner.parse_size("").should be_nil
    Saci::GCTuner.parse_size("lots").should be_nil
    Saci::GCTuner.parse_size("-5M").should be_nil
  end

  it "collects rarely with room to spare and more often near the limit" do
    mb = 1024_u64 * 1024
    Saci::GCTuner.divisor_for(50_u64 * mb, 300_u64 * mb).should eq(1)
    Saci::GCTuner.divisor_for(200_u64 * mb, 300_u64 * mb).should eq(3)
    Saci::GCTuner.divisor_for(290_u64 * mb, 300_u64 * mb).should eq(37)
    Saci::GCTuner.divisor_for(400_u64 * mb, 300_u64 * mb).should eq(Saci::GCTuner::MAX_DIVISOR)
  end

  it "applies the divisor for the current heap" do
    previous = Saci::GCTuner.divisor
    begin
      Saci::GCTuner.start(1024_u64 ** 4) # 1 TiB: always plenty of room
      Saci::GCTuner.divisor.should eq(1)
    ensure
      Saci::GCTuner::LibGCTune.set_free_space_divisor(previous)
    end
  end
end

describe "Saci::GCTuner memory limit" do
  it "gives the heap what the rest of the process leaves" do
    mb = 1024_u64 * 1024
    Saci::GCTuner.heap_budget(400_u64 * mb, 300_u64 * mb, 100_u64 * mb).should eq(200_u64 * mb)
    Saci::GCTuner.heap_budget(400_u64 * mb, 80_u64 * mb, 100_u64 * mb).should eq(400_u64 * mb)
    Saci::GCTuner.heap_budget(400_u64 * mb, 600_u64 * mb, 100_u64 * mb).should eq(0)
  end

  it "reads the resident set on Linux" do
    {% if flag?(:linux) %}
      Saci::GCTuner.rss.not_nil!.should be > 0
    {% end %}
  end
end
