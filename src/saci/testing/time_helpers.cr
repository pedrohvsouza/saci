module Saci
  module Testing
    # Per-fiber time-travel stack. A stack (instead of one value) makes
    # nested `travel_to` blocks restore exactly one level; `travel_back`
    # clears the whole stack like Rails.
    @@travel_times = {} of UInt64 => Array(Time)
    @@travel_mutex = Mutex.new

    # Current (possibly traveled) time for the calling fiber. Outside a
    # `travel_to`/`travel`/`freeze_time` block this is the real wall clock.
    def self.current_time : Time
      stack = @@travel_mutex.synchronize { @@travel_times[Fiber.current.object_id]?.try(&.dup) }
      stack.try(&.last?) || Time.utc
    end

    # `true` while the current fiber has a time override.
    def self.time_traveled? : Bool
      @@travel_mutex.synchronize do
        @@travel_times[Fiber.current.object_id]?.try(&.any?) || false
      end
    end

    # Freezes `Time.current`, `Time.now`, `Time.utc` (no-arg), `Time.local`
    # (no-arg) and `Date.current` at `time` for the duration of the block.
    # Stacks with other `travel_to` calls and is restored in `ensure`, so it
    # cannot leak outside the block.
    def self.travel_to(time : Time, & : -> T) : T forall T
      travel_to(time)
      begin
        yield
      ensure
        pop_time
      end
    end

    # Non-block form: freezes time until `travel_back` (or the automatic
    # per-example cleanup installed by `saci/testing`).
    def self.travel_to(time : Time) : Nil
      @@travel_mutex.synchronize do
        (@@travel_times[Fiber.current.object_id] ||= [] of Time) << time
      end
    end

    # Moves the clock forward by `duration` (relative to the current,
    # possibly already-traveled time) inside the block.
    def self.travel(duration : Time::Span, & : -> T) : T forall T
      travel_to(current_time + duration)
      begin
        yield
      ensure
        pop_time
      end
    end

    # Non-block `travel(duration)`; pair with `travel_back`.
    def self.travel(duration : Time::Span) : Nil
      travel_to(current_time + duration)
    end

    # Freezes the clock at its current value (real or traveled) for the
    # duration of the block.
    def self.freeze_time(& : -> T) : T forall T
      travel_to(current_time)
      begin
        yield
      ensure
        pop_time
      end
    end

    # Freezes at `time` — Rails' `freeze_time(time)` form.
    def self.freeze_time(time : Time, & : -> T) : T forall T
      travel_to(time) { yield }
    end

    # Restores real time for the current fiber (pops the entire stack).
    def self.travel_back : Nil
      @@travel_mutex.synchronize do
        @@travel_times.delete(Fiber.current.object_id)
      end
    end

    # Pops one travel entry (used by the ensure path of block helpers so
    # nested `travel_to` calls restore exactly one level).
    protected def self.pop_time : Nil
      @@travel_mutex.synchronize do
        key = Fiber.current.object_id
        if stack = @@travel_times[key]?
          stack.pop
          @@travel_times.delete(key) if stack.empty?
        end
      end
    end

    # Alias used by the automatic per-example cleanup.
    def self.reset_time! : Nil
      travel_back
    end
  end
end

struct Time
  # Rails-style `Time.current`: the traveled clock when active, otherwise
  # the framework's zone-aware implementation (`Saci::Time.current`). Using
  # `previous_def` keeps `Time.use_zone` / `SACI_TIME_ZONE` working in tests
  # that travel time.
  def self.current : Time
    if Saci::Testing.time_traveled?
      Saci::Testing.current_time.in(Saci::TimeZone.current.location)
    else
      previous_def
    end
  end

  # Convenience alias (Crystal has no `Time.now` in the stdlib).
  def self.now : Time
    self.current
  end

  # Patching the no-argument constructors makes ORM timestamps
  # (`Time.utc` in `Record::Base`) and typical app code honor travel.
  # Explicit-date overloads are untouched. `previous_def` preserves the
  # stdlib implementation when no travel override is active.
  def self.utc : Time
    if Saci::Testing.time_traveled?
      Saci::Testing.current_time
    else
      previous_def
    end
  end

  def self.local(location : Location = Location.local) : Time
    if Saci::Testing.time_traveled?
      Saci::Testing.current_time.in(location)
    else
      previous_def
    end
  end
end

# Crystal's stdlib has no `Date` type. To keep `Date.current` working in
# specs, provide a tiny compatibility value type only when nothing else has
# defined `Date` (for example a date shard required first). Applications
# can ignore it and keep using `Time`.
{% unless @type.has_constant?("Date") %}
  struct Date
    getter year : Int32
    getter month : Int32
    getter day : Int32

    def initialize(@year : Int32, @month : Int32, @day : Int32)
    end

    def self.current : Date
      time = Saci::Testing.current_time
      new(time.year, time.month, time.day)
    end

    def self.today : Date
      current
    end

    def to_time(location : Time::Location = Time::Location::UTC) : Time
      Time.local(@year, @month, @day, location: location)
    end

    def to_s(io : IO) : Nil
      io << @year.to_s.rjust(4, '0') << '-' << @month.to_s.rjust(2, '0') << '-' << @day.to_s.rjust(2, '0')
    end

    def ==(other : self) : Bool
      @year == other.year && @month == other.month && @day == other.day
    end
  end
{% end %}

module Saci
  module Testing
    # The current date, independent of whether a global `Date` shim exists.
    def self.current_date : Tuple(Int32, Int32, Int32)
      time = current_time
      {time.year, time.month, time.day}
    end
  end
end

# Top-level DSL delegates. These are included into `Object` by
# `saci/testing.cr`, so they work inside `it` blocks without a receiver.
module Saci
  module Testing
    module TimeDSL
      def travel_to(time : Time, & : -> T) : T forall T
        Saci::Testing.travel_to(time) { yield }
      end

      def travel_to(time : Time) : Nil
        Saci::Testing.travel_to(time)
      end

      def travel(duration : Time::Span, & : -> T) : T forall T
        Saci::Testing.travel(duration) { yield }
      end

      def travel(duration : Time::Span) : Nil
        Saci::Testing.travel(duration)
      end

      def freeze_time(& : -> T) : T forall T
        Saci::Testing.freeze_time { yield }
      end

      def freeze_time(time : Time, & : -> T) : T forall T
        Saci::Testing.freeze_time(time) { yield }
      end

      def travel_back : Nil
        Saci::Testing.travel_back
      end
    end
  end
end
