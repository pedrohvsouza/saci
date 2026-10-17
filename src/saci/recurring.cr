require "mutex"
require "set"

module Saci
  # Registry-form recurring jobs (cron / every-interval). No `Job::Base`
  # edits needed — blocks typically enqueue one job:
  #
  # ```
  # Saci::Recurring.every(5.minutes, "expire-ribbons") do
  #   ExpireRibbonsJob.perform_later({}) # adapter decides (:async/:db/...)
  # end
  # Saci::Recurring.cron("*/5 * * * *", "refresh-stats") do
  #   RefreshStatsJob.perform_later({})
  # end
  #
  # # In your server entrypoint (ONE replica — see dedup note below):
  # Saci::Recurring.start
  # ```
  #
  # Semantics:
  # - Timezone: UTC everywhere. Cron fields are evaluated against `Time.utc`.
  # - Missed ticks collapse to a single catch-up run: after firing, the next
  #   due time is computed from *now*, never replayed as a burst. Jobs MUST
  #   still be idempotent (at-least-once, like every other queue).
  # - Single-flight per key: a fire is skipped while its key is already
  #   running (extra ticks skip, never overlap, never queue).
  # - Blocks must be fast (a single `perform_later`): `run_due` executes
  #   blocks inline, so a slow block delays the scheduler tick. Long work
  #   belongs in the job, which can additionally declare
  #   `limits_concurrency to: 1` for its own overlap guard.
  # - Multi-replica: run `start` on ONE replica. If every replica must run
  #   the loop, set `cache_dedup = true` with a shared (`RedisStore`) Cache
  #   backend so duplicate fires for the same due-minute collapse to one.
  #   The claim is `exist?`+`write` (no atomic SET NX in the Cache API), so
  #   it is best-effort under exact-tie races — idempotent jobs stay
  #   required. Cache failures fail OPEN (the job still runs; the in-process
  #   single-flight guard always applies). Default is in-memory only.
  module Recurring
    DEFAULT_TICK = 30.seconds
    DEFAULT_DEDUP_TTL = 1.hour

    # Five-field cron (minute hour dom month dow), parsed stdlib-only.
    # Each field: `*`, `*/n`, `n`, `a-b`, `a-b/n`, lists (`1,15,30`).
    # Month/DOW accept numbers or 3-letter names (`JAN`, `MON`); DOW `0`
    # and `7` are both Sunday. NOT supported (raise `ArgumentError`): `L`,
    # `W`, `#`, `?`, seconds/year fields. Day-of-month vs day-of-week
    # follows standard cron: when both are restricted, either may match.
    class CronExpr
      getter minutes : Set(Int32)?
      getter hours : Set(Int32)?
      getter days : Set(Int32)?
      getter months : Set(Int32)?
      getter weekdays : Set(Int32)?

      MONTH_NAMES = {
        "JAN" => 1, "FEB" => 2, "MAR" => 3, "APR" => 4,
        "MAY" => 5, "JUN" => 6, "JUL" => 7, "AUG" => 8,
        "SEP" => 9, "OCT" => 10, "NOV" => 11, "DEC" => 12,
      }
      DOW_NAMES = {
        "SUN" => 0, "MON" => 1, "TUE" => 2, "WED" => 3,
        "THU" => 4, "FRI" => 5, "SAT" => 6,
      }

      # Days scanned for the next match (~4 years, so Feb 29 resolves).
      SCAN_DAYS = 1462

      def initialize(@minutes, @hours, @days, @months, @weekdays)
      end

      def self.parse(expr : String) : CronExpr
        parts = expr.split
        unless parts.size == 5
          raise ArgumentError.new("recurring: cron needs 5 fields, got #{parts.size} in #{expr.inspect}")
        end
        new(
          parse_field(parts[0], 0, 59),
          parse_field(parts[1], 0, 23),
          parse_field(parts[2], 1, 31),
          parse_field(parts[3], 1, 12, MONTH_NAMES),
          parse_field(parts[4], 0, 7, DOW_NAMES, sunday_seven: true),
        )
      end

      def matches?(time : Time) : Bool
        return false unless date_matches?(time)
        return false if (h = @hours) && !h.includes?(time.hour)
        return false if (m = @minutes) && !m.includes?(time.minute)
        true
      end

      # Strictly after `after`, at minute resolution.
      def next_after(after : Time) : Time
        from = Time.utc(after.year, after.month, after.day, after.hour, after.minute) + 1.minute
        day0 = Time.utc(from.year, from.month, from.day)
        SCAN_DAYS.times do |offset|
          day = day0 + offset.days
          next unless date_matches?(day)
          if offset == 0
            finish = day + 1.day
            t = from
            while t < finish
              return t if matches?(t)
              t += 1.minute
            end
          else
            hours = @hours
            minutes = @minutes
            hour = hours ? hours.min : 0
            minute = minutes ? minutes.min : 0
            return Time.utc(day.year, day.month, day.day, hour, minute)
          end
        end
        raise ArgumentError.new("recurring: cron expression has no match within #{SCAN_DAYS} days")
      end

      private def date_matches?(time : Time) : Bool
        return false if (mo = @months) && !mo.includes?(time.month)
        dom = @days
        dow = @weekdays
        wday = time.day_of_week.value % 7 # Crystal: Monday=1..Sunday=7; cron: Sunday=0
        case
        when dom.nil? && dow.nil? then true
        when dom.nil?              then dow.not_nil!.includes?(wday)
        when dow.nil?              then dom.includes?(time.day)
        else                            dom.includes?(time.day) || dow.includes?(wday)
        end
      end

      private def self.parse_field(raw : String, min : Int32, max : Int32,
                                   names : Hash(String, Int32)? = nil,
                                   sunday_seven : Bool = false) : Set(Int32)?
        raise ArgumentError.new("recurring: empty cron field") if raw.empty?
        return nil if raw == "*"
        values = Set(Int32).new
        raw.split(",").each do |part|
          range_src = part
          step = 1
          if part.includes?("/")
            bits = part.split("/")
            unless bits.size == 2
              raise ArgumentError.new("recurring: bad cron step #{part.inspect} (expected <range>/<n>)")
            end
            range_src = bits[0]
            step = bits[1].to_i?
            if step.nil? || step < 1
              raise ArgumentError.new("recurring: bad cron step #{part.inspect} (n must be >= 1)")
            end
          end
          lo = min
          hi = max
          unless range_src == "*"
            if range_src.includes?("-")
              bounds = range_src.split("-")
              unless bounds.size == 2
                raise ArgumentError.new("recurring: bad cron range #{range_src.inspect}")
              end
              lo = field_num(bounds[0], names)
              hi = field_num(bounds[1], names)
              if lo.nil? || hi.nil?
                raise ArgumentError.new("recurring: bad cron value #{range_src.inspect} (L/W/#/? unsupported — numbers, ranges, steps, lists only)")
              end
            else
              n = field_num(range_src, names)
              if n.nil?
                raise ArgumentError.new("recurring: bad cron value #{range_src.inspect} (L/W/#/? unsupported — numbers, ranges, steps, lists only)")
              end
              lo = hi = n
            end
          end
          unless lo >= min && hi <= max && lo <= hi
            raise ArgumentError.new("recurring: cron value out of range #{range_src.inspect} (expected #{min}..#{max})")
          end
          v = lo
          while v <= hi
            values << (sunday_seven && v == 7 ? 0 : v)
            v += step.not_nil!
          end
        end
        raise ArgumentError.new("recurring: empty cron field") if values.empty?
        values
      end

      private def self.field_num(token : String, names : Hash(String, Int32)?) : Int32?
        if names && (mapped = names[token.upcase]?)
          return mapped
        end
        token.to_i?
      end
    end

    abstract class Schedule
      abstract def next_after(after : Time) : Time
    end

    # Fixed cadence. First fire is one interval after registration
    # (no immediate run); missed ticks collapse to one catch-up run.
    class Interval < Schedule
      getter span : Time::Span

      def initialize(@span : Time::Span)
        raise ArgumentError.new("recurring: interval must be positive") if @span <= Time::Span.zero
      end

      def next_after(after : Time) : Time
        after + @span
      end
    end

    # Wall-clock cron schedule (UTC). Registration is due for the current
    # minute when it matches, so a matching minute fires on the first tick.
    class Cron < Schedule
      getter expr : CronExpr
      getter source : String

      def initialize(@source : String)
        @expr = CronExpr.parse(@source)
      end

      def next_after(after : Time) : Time
        @expr.next_after(after)
      end
    end

    class Entry
      getter name : String
      getter schedule : Schedule
      getter block : Proc(Nil)
      property last_run : Time?
      property next_due : Time

      def initialize(@name : String, @schedule : Schedule, @block : Proc(Nil), @next_due : Time)
      end
    end

    @@entries = {} of String => Entry
    @@inflight = Set(String).new
    @@mutex = Mutex.new
    @@running = false
    @@cache_dedup = false
    @@dedup_ttl : Time::Span = DEFAULT_DEDUP_TTL

    # Fixed-cadence entry. `name` must be unique (else `ArgumentError`).
    def self.every(span : Time::Span, name : String, &block : ->) : Entry
      register(name, Interval.new(span), Time.utc + span, &block)
    end

    # Cron entry (`"*/5 * * * *"`). Raises `ArgumentError` on bad syntax
    # or an expression with no match in ~4 years (e.g. Feb 30).
    def self.cron(expr : String, name : String, &block : ->) : Entry
      schedule = Cron.new(expr)
      register(name, schedule, schedule.next_after(Time.utc - 1.minute), &block)
    end

    # Next wall-clock time strictly after `after` matching `expr` (UTC).
    def self.next_after(expr : String, after : Time) : Time
      CronExpr.parse(expr).next_after(after)
    end

    def self.entries : Array(Entry)
      @@mutex.synchronize { @@entries.values.dup }
    end

    def self.find(name : String) : Entry?
      @@mutex.synchronize { @@entries[name]? }
    end

    def self.size : Int32
      @@mutex.synchronize { @@entries.size }
    end

    # Removes `name`. Returns false when missing.
    def self.remove(name : String) : Bool
      @@mutex.synchronize do
        return false unless @@entries.has_key?(name)
        @@entries.delete(name)
        true
      end
    end

    # Drops all entries and in-flight marks (keeps loop/dedup settings).
    def self.clear : Nil
      @@mutex.synchronize do
        @@entries.clear
        @@inflight.clear
      end
    end

    # Spec isolation: stops the loop, clears entries, resets dedup options.
    def self.reset! : Nil
      @@mutex.synchronize do
        @@running = false
        @@entries.clear
        @@inflight.clear
        @@cache_dedup = false
        @@dedup_ttl = DEFAULT_DEDUP_TTL
      end
    end

    def self.cache_dedup : Bool
      @@mutex.synchronize { @@cache_dedup }
    end

    def self.cache_dedup=(value : Bool) : Nil
      @@mutex.synchronize { @@cache_dedup = value }
    end

    def self.dedup_ttl : Time::Span
      @@mutex.synchronize { @@dedup_ttl }
    end

    def self.dedup_ttl=(ttl : Time::Span) : Nil
      @@mutex.synchronize { @@dedup_ttl = ttl }
    end

    def self.running? : Bool
      @@mutex.synchronize { @@running }
    end

    # Fires every entry with `next_due <= now` (default `Time.utc`),
    # inline. Returns the number fired. A fire advances `next_due` past
    # now first (missed ticks collapse to ONE catch-up run), skips while
    # its key is already running (single-flight), and reports block
    # errors through `Saci::Job.report_error` without failing the tick.
    def self.run_due(now : Time = Time.utc) : Int32
      due = @@mutex.synchronize { @@entries.values.select { |e| e.next_due <= now } }
      fired = 0
      due.each do |entry|
        claimed = @@mutex.synchronize do
          if @@inflight.includes?(entry.name)
            false
          else
            @@inflight << entry.name
            true
          end
        end
        next unless claimed
        begin
          if cache_dedup
            unless cache_claim(entry.name, entry.next_due)
              next
            end
          end
          entry.last_run = now
          entry.next_due = entry.schedule.next_after(now)
          begin
            entry.block.call
          rescue ex
            Job.report_error("recurring:#{entry.name}", ex)
          end
          fired += 1
        ensure
          @@mutex.synchronize { @@inflight.delete(entry.name) }
        end
      end
      fired
    end

    # Supervised scheduler loop: `run_due` every `tick` (default 30s).
    # Idempotent while running. The loop never dies on entry errors
    # (`run_due` rescues per entry; a last-resort rescue guards the tick).
    def self.start(tick : Time::Span = DEFAULT_TICK) : Nil
      raise ArgumentError.new("recurring: tick must be positive") if tick <= Time::Span.zero
      @@mutex.synchronize do
        return if @@running
        @@running = true
      end
      spawn do
        while running?
          begin
            run_due
          rescue ex
            Job.report_error("recurring:scheduler", ex)
          end
          sleep tick
        end
      end
    end

    def self.stop : Nil
      @@mutex.synchronize { @@running = false }
    end

    # Multi-replica lease key for (`name`, due-minute slot). Public so
    # specs/ops can inspect the claim left by a fire.
    def self.claim_key(name : String, slot : Time) : String
      "recurring:#{name}:#{Time.utc(slot.year, slot.month, slot.day, slot.hour, slot.minute).to_unix}"
    end

    private def self.register(name : String, schedule : Schedule, first_due : Time, &block : ->) : Entry
      @@mutex.synchronize do
        raise ArgumentError.new("recurring: duplicate entry #{name.inspect}") if @@entries.has_key?(name)
        entry = Entry.new(name, schedule, block, first_due)
        @@entries[name] = entry
        entry
      end
    end

    # Best-effort cross-replica claim via Cache (see module docs).
    private def self.cache_claim(name : String, slot : Time) : Bool
      key = claim_key(name, slot)
      ttl = @@mutex.synchronize { @@dedup_ttl }
      begin
        return false if Cache.exist?(key)
        Cache.write(key, "1", expires_in: ttl)
        true
      rescue
        true
      end
    end
  end
end
