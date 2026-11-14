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

  it "lets garbage accumulate up to the budget once the divisor is at 1" do
    mb = 1024_u64 * 1024
    # 20 MB live, 380 MB budget: (380 - 20) / 1.25 = 288 MB, capped at 190.
    Saci::GCTuner.allowance_for(20_u64 * mb, 380_u64 * mb).should eq(190_u64 * mb)
    # 150 MB live: (380 - 150) / 1.25 = 184 MB, above live.
    Saci::GCTuner.allowance_for(150_u64 * mb, 380_u64 * mb).should eq(184_u64 * mb)
    # No more room than collecting every `live` bytes already gives.
    Saci::GCTuner.allowance_for(200_u64 * mb, 380_u64 * mb).should eq(1)
    Saci::GCTuner.allowance_for(400_u64 * mb, 380_u64 * mb).should eq(1)
  end

  it "estimates live data without counting unmapped memory twice" do
    mb = 1024_u64 * 1024
    # heap_size and free_bytes already exclude unmapped memory.
    Saci::GCTuner.live_estimate(100_u64 * mb, 30_u64 * mb, 20_u64 * mb).should eq(50_u64 * mb)
    # Allocation since the last GC beyond the used heap keeps the used figure.
    Saci::GCTuner.live_estimate(100_u64 * mb, 30_u64 * mb, 90_u64 * mb).should eq(70_u64 * mb)
    # Never underflows.
    Saci::GCTuner.live_estimate(10_u64 * mb, 30_u64 * mb, 0_u64).should eq(0)
  end

  it "applies the divisor and the allowance for the current heap" do
    previous = Saci::GCTuner.divisor
    previous_min = Saci::GCTuner.min_bytes_allocd
    begin
      Saci::GCTuner.start(1024_u64 ** 3) # 1 GiB: plenty of room for a spec run
      Saci::GCTuner.divisor.should eq(1)
      Saci::GCTuner.min_bytes_allocd.should be > 100_u64 * 1024 * 1024
    ensure
      Saci::GCTuner.stop
      Saci::GCTuner::LibGCTune.set_free_space_divisor(previous)
      Saci::GCTuner::LibGCTune.set_min_bytes_allocd(previous_min)
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
