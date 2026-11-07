# Adaptive garbage-collector pacing under a heap budget (in the spirit of
# Go's GOMEMLIMIT).
#
# Boehm collects whenever the bytes allocated since the last collection
# reach (roughly) live data / free_space_divisor. A high divisor keeps the
# heap small but collects often: under request load, marking the live heap
# (and every fiber stack) again and again can take a third of the CPU. A
# divisor of 1 collects rarely but lets the heap grow to about twice the
# live data.
#
# The tuner samples the heap every `interval` and picks the smallest
# divisor whose expected peak (live * (1 + 1/divisor), with a safety margin)
# still fits in `limit`: collections stay rare while there is room, and get
# more frequent only as live data approaches the budget.
#
# Enabled by `SACI_GC_HEAP_LIMIT` (bytes, or with a K/M/G suffix): a
# per-process budget, so with several processes divide the container's
# memory among them. Without it nothing changes (Boehm's own setting, e.g.
# `GC_FREE_SPACE_DIVISOR`, stays in effect).
module Saci::GCTuner
  lib LibGCTune
    fun set_free_space_divisor = GC_set_free_space_divisor(value : LibGC::Word)
    fun get_free_space_divisor = GC_get_free_space_divisor : LibGC::Word
  end

  MIN_DIVISOR =  1_u64
  MAX_DIVISOR = 64_u64
  MARGIN      =   1.25

  @@started = Atomic(Bool).new(false)
  @@limit = 0_u64

  def self.limit : UInt64
    @@limit
  end

  def self.divisor : UInt64
    {% if flag?(:gc_none) %}
      0_u64
    {% else %}
      LibGCTune.get_free_space_divisor.to_u64
    {% end %}
  end

  # "512M", "1G", "300000000" -> bytes (nil when unparsable or empty).
  def self.parse_size(value : String) : UInt64?
    v = value.strip.upcase.rchop("B")
    return nil if v.empty?
    mult = case v[-1]
           when 'K' then 1024_u64
           when 'M' then 1024_u64 ** 2
           when 'G' then 1024_u64 ** 3
           else          1_u64
           end
    number = mult == 1 ? v : v[0...-1]
    number.to_f64?.try { |n| n > 0 ? (n * mult).to_u64 : nil }
  end

  # The divisor that keeps live * (1 + MARGIN / divisor) <= limit.
  def self.divisor_for(live : UInt64, limit : UInt64) : UInt64
    return MAX_DIVISOR if live >= limit
    headroom = (limit - live).to_f64
    wanted = (live.to_f64 * MARGIN / headroom).ceil
    wanted.to_u64.clamp(MIN_DIVISOR, MAX_DIVISOR)
  end

  def self.start_from_env : Nil
    raw = ENV["SACI_GC_HEAP_LIMIT"]?
    return if raw.nil? || raw.empty?
    if limit = parse_size(raw)
      start(limit)
    else
      STDERR.puts "saci: ignoring invalid SACI_GC_HEAP_LIMIT=#{raw.inspect}"
    end
  end

  def self.start(limit : UInt64, interval : Time::Span = 200.milliseconds) : Nil
    {% unless flag?(:gc_none) %}
      return if @@started.swap(true)
      @@limit = limit
      adjust
      spawn(name: "saci-gc-tuner") do
        loop do
          sleep interval
          adjust
        end
      end
    {% end %}
  end

  # Samples the heap once and applies the divisor for it.
  def self.adjust : Nil
    {% unless flag?(:gc_none) %}
      s = GC.prof_stats
      used = s.heap_size - s.free_bytes - s.unmapped_bytes
      # Bytes allocated since the last collection are mostly garbage the
      # next one reclaims: what remains is the live-data estimate.
      live = used > s.bytes_since_gc ? used - s.bytes_since_gc : used
      wanted = divisor_for(live, @@limit)
      LibGCTune.set_free_space_divisor(wanted) if wanted != divisor
    {% end %}
  end
end
