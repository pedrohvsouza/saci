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
# A divisor cannot go below 1, so with a small live heap (an HTTP server's
# per-request garbage over a few MB of caches) collections would still
# come every few MB allocated, however large the budget. Past that point
# the tuner raises Boehm's floor on bytes allocated between collections
# (`GC_set_min_bytes_allocd`) instead, keeping
# live + MARGIN * allocated <= limit (and allocated <= limit / 2).
#
# Configured per process (with several processes, divide the container's
# memory among them), in bytes or with a K/M/G suffix:
#
# * `SACI_MEMORY_LIMIT`: budget for the whole resident set. Memory outside
#   the GC heap (fiber stacks, buffers, libraries) is measured from
#   /proc/self/statm and subtracted, so the heap gets what is left: the
#   right choice when that part grows too (e.g. thousands of WebSockets).
# * `SACI_GC_HEAP_LIMIT`: budget for the GC heap alone.
#
# Without either nothing changes (Boehm's own setting, e.g.
# `GC_FREE_SPACE_DIVISOR`, stays in effect).
module Saci::GCTuner
  lib LibGCTune
    fun set_free_space_divisor = GC_set_free_space_divisor(value : LibGC::Word)
    fun get_free_space_divisor = GC_get_free_space_divisor : LibGC::Word
    fun set_min_bytes_allocd = GC_set_min_bytes_allocd(value : LibC::SizeT)
    fun get_min_bytes_allocd = GC_get_min_bytes_allocd : LibC::SizeT
  end

  MIN_DIVISOR =  1_u64
  MAX_DIVISOR = 64_u64
  MARGIN      =   1.25

  @@started = Atomic(Bool).new(false)
  @@limit = 0_u64
  @@rss_mode = false

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

  # Bytes to let accumulate between collections once the divisor is at its
  # minimum: what keeps live + MARGIN * allowance within the limit, capped at
  # half the limit (1 when there is no more room than the divisor gives).
  def self.allowance_for(live : UInt64, limit : UInt64) : UInt64
    return 1_u64 if live >= limit
    room = ((limit - live).to_f64 / MARGIN).to_u64
    room = Math.min(room, limit // 2)
    room > live ? room : 1_u64
  end

  def self.min_bytes_allocd : UInt64
    {% if flag?(:gc_none) %}
      0_u64
    {% else %}
      LibGCTune.get_min_bytes_allocd.to_u64
    {% end %}
  end

  def self.start_from_env : Nil
    {"SACI_MEMORY_LIMIT" => true, "SACI_GC_HEAP_LIMIT" => false}.each do |name, rss|
      raw = ENV[name]?
      next if raw.nil? || raw.empty?
      if limit = parse_size(raw)
        return start(limit, rss: rss)
      else
        STDERR.puts "saci: ignoring invalid #{name}=#{raw.inspect}"
      end
    end
  end

  # Resident set size of this process (nil where /proc is unavailable).
  def self.rss : UInt64?
    fields = File.read("/proc/self/statm").split
    pages = fields[1]?.try(&.to_u64?)
    pages.try { |n| n * LibC.sysconf(LibC::SC_PAGESIZE).to_u64 }
  rescue File::Error
    nil
  end

  # Heap budget once memory outside the heap is accounted for.
  def self.heap_budget(limit : UInt64, rss : UInt64, heap_mapped : UInt64) : UInt64
    outside = rss > heap_mapped ? rss - heap_mapped : 0_u64
    limit > outside ? limit - outside : 0_u64
  end

  def self.start(limit : UInt64, interval : Time::Span = 200.milliseconds, rss : Bool = false) : Nil
    {% unless flag?(:gc_none) %}
      return if @@started.swap(true)
      @@limit = limit
      @@rss_mode = rss && !self.rss.nil?
      adjust
      spawn(name: "saci-gc-tuner") do
        while @@started.get
          sleep interval
          adjust if @@started.get
        end
      end
    {% end %}
  end

  # Stops the sampling fiber (the settings it applied stay in effect).
  def self.stop : Nil
    @@started.set(false)
  end

  # Samples the heap once and applies the divisor for it.
  def self.adjust : Nil
    {% unless flag?(:gc_none) %}
      s = GC.prof_stats
      used = s.heap_size - s.free_bytes - s.unmapped_bytes
      # Bytes allocated since the last collection are mostly garbage the
      # next one reclaims: what remains is the live-data estimate.
      live = used > s.bytes_since_gc ? used - s.bytes_since_gc : used
      budget = @@limit
      if @@rss_mode && (resident = rss)
        budget = heap_budget(@@limit, resident, s.heap_size - s.unmapped_bytes)
      end
      wanted = divisor_for(live, budget)
      LibGCTune.set_free_space_divisor(wanted) if wanted != divisor
      allowance = wanted == MIN_DIVISOR ? allowance_for(live, budget) : 1_u64
      LibGCTune.set_min_bytes_allocd(allowance) if allowance != min_bytes_allocd
    {% end %}
  end
end
