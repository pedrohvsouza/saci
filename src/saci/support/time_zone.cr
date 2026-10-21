require "time"

module Saci
  # `Saci::Time` is an alias for Crystal's `Time`, so `Saci::Time.zone` reads
  # naturally alongside Rails examples.
  alias Time = ::Time

  # Rails-style time zone support built on Crystal's `Time::Location`.
  #
  # ```
  # Saci::TimeZone.default = "Europe/Madrid"
  # Saci::TimeZone.with_zone("America/New_York") do
  #   Time.current   # => 2026-10-21 08:00:00 -04:00
  #   Time.zone.name # => "America/New_York"
  #   Time.current.in_time_zone("UTC")
  # end
  # ```
  #
  # The current zone is fiber-local (like `Saci::I18n.locale`), so concurrent
  # requests never leak zones. `SACI_TIME_ZONE` sets the process default.
  # IANA names are provided by the system tzdata through `Time::Location`.
  class TimeZone
    class UnknownTimeZone < Exception
    end

    # Read from (and keep in sync with) the system zoneinfo database.
    ZONEINFO_DIRS = ["/usr/share/zoneinfo", "/usr/lib/zoneinfo", "/usr/share/lib/zoneinfo"]

    getter name : String
    getter location : Time::Location

    def initialize(name : String)
      @name = name
      @location = begin
        Time::Location.load(name)
      rescue ex : Time::Location::InvalidLocationNameError
        raise UnknownTimeZone.new("Unknown time zone #{name.inspect}: #{ex.message}")
      end
    end

    def initialize(@location : Time::Location)
      @name = @location.name
    end

    # Accepts a zone name, a `TimeZone`, or a Crystal location.
    def self.coerce(value : String | Symbol | TimeZone | Time::Location) : TimeZone
      case value
      when TimeZone       then value
      when Time::Location then TimeZone.new(value)
      when Symbol         then new(value.to_s)
      else                     new(value)
      end
    end

    def self.find(name : String | Symbol) : TimeZone
      new(name.to_s)
    end

    def self.find?(name : String | Symbol) : TimeZone?
      find(name)
    rescue UnknownTimeZone
      nil
    end

    # Process default: explicit override, then `SACI_TIME_ZONE`, then UTC.
    def self.default : TimeZone
      @@default_mutex.synchronize do
        if zone = @@default_override
          zone
        else
          name = ENV["SACI_TIME_ZONE"]?.presence || "UTC"
          find?(name) || new("UTC")
        end
      end
    end

    def self.default=(value : String | Symbol | TimeZone | Time::Location) : Nil
      zone = coerce(value)
      @@default_mutex.synchronize { @@default_override = zone }
    end

    def self.reset_default! : Nil
      @@default_mutex.synchronize { @@default_override = nil }
    end

    # Fiber-local override (falls back to `default`).
    def self.current : TimeZone
      @@zone_mutex.synchronize { @@fiber_zones[Fiber.current.object_id]? } || default
    end

    def self.current=(value : String | Symbol | TimeZone | Time::Location) : Nil
      zone = coerce(value)
      @@zone_mutex.synchronize { @@fiber_zones[Fiber.current.object_id] = zone }
    end

    def self.clear! : Nil
      @@zone_mutex.synchronize { @@fiber_zones.delete(Fiber.current.object_id) }
    end

    # Scoped zone override; nestable and fiber-local.
    def self.with_zone(value : String | Symbol | TimeZone | Time::Location, & : -> T) : T forall T
      key = Fiber.current.object_id
      previous = @@zone_mutex.synchronize { @@fiber_zones[key]? }
      self.current = value
      begin
        yield
      ensure
        @@zone_mutex.synchronize do
          if previous
            @@fiber_zones[key] = previous
          else
            @@fiber_zones.delete(key)
          end
        end
      end
    end

    # IANA zone names known to the host (`zone.tab`/`zone1970.tab`, with a
    # small built-in fallback for minimal containers).
    def self.names : Array(String)
      @@names_mutex.synchronize do
        @@names ||= load_names
      end
    end

    def self.list : Array(String)
      names
    end

    def self.all : Array(TimeZone)
      names.compact_map { |name| find?(name) }
    end

    private def self.load_names : Array(String)
      dir = ENV["TZDIR"]?.presence
      unless dir
        found = ZONEINFO_DIRS.find { |d| Dir.exists?(d) }
        dir = found
      end
      if dir
        ["zone1970.tab", "zone.tab"].each do |file|
          path = File.join(dir, file)
          next unless File.exists?(path)
          names = File.read_lines(path).compact_map do |line|
            next if line.empty? || line.starts_with?('#')
            fields = line.split('\t')
            fields[2]?.try(&.strip)
          end
          return names.uniq.sort unless names.empty?
        end
      end
      %w[UTC Africa/Cairo Africa/Johannesburg America/Chicago America/Los_Angeles
        America/New_York America/Sao_Paulo Asia/Dubai Asia/Kolkata Asia/Shanghai
        Asia/Tokyo Australia/Sydney Europe/Berlin Europe/London Europe/Madrid
        Europe/Paris Europe/Rome Pacific/Auckland]
    end

    def now : Time
      Time.utc.in(@location)
    end

    def today : Date
      t = now
      Date.new(t.year, t.month, t.day)
    end

    def at(seconds : Int) : Time
      Time.unix(seconds).in(@location)
    end

    def utc_offset(at : Time = Time.utc) : Time::Span
      at.in(@location).utc_offset
    end

    def dst?(at : Time = Time.utc) : Bool
      @location.lookup(at.in(@location)).dst?
    end

    # Local wall-clock time in this zone.
    def local(year : Int, month : Int, day : Int, hour : Int = 0, minute : Int = 0, second : Int = 0, *, nanosecond : Int = 0) : Time
      Time.local(year, month, day, hour, minute, second, nanosecond: nanosecond, location: @location)
    end

    def parse(value : String, pattern : String = "%F %T") : Time
      Time.parse(value, pattern, @location)
    end

    def to_s(io : IO) : Nil
      io << @name
    end

    def inspect(io : IO) : Nil
      io << "#<Saci::TimeZone " << @name << '>'
    end

    def ==(other : TimeZone) : Bool
      @name == other.name
    end

    @@default_override : TimeZone? = nil
    @@default_mutex = Mutex.new
    @@fiber_zones = {} of UInt64 => TimeZone
    @@zone_mutex = Mutex.new
    @@names : Array(String)? = nil
    @@names_mutex = Mutex.new
  end
end

# `Time.zone`, `Time.current`, and `Time.use_zone` (Rails `TimeWithZone`
# facade). The zone object is `Saci::TimeZone`; instants remain ordinary
# `Time` values carrying a `Time::Location`.
struct Time
  def self.zone : Saci::TimeZone
    Saci::TimeZone.current
  end

  def self.zone=(value : String | Symbol | Saci::TimeZone | Time::Location) : Nil
    Saci::TimeZone.current = value
  end

  def self.zone_default : Saci::TimeZone
    Saci::TimeZone.default
  end

  def self.zone_default=(value : String | Symbol | Saci::TimeZone | Time::Location) : Nil
    Saci::TimeZone.default = value
  end

  def self.use_zone(value : String | Symbol | Saci::TimeZone | Time::Location, & : -> T) : T forall T
    Saci::TimeZone.with_zone(value) { yield }
  end

  # Current instant in `Time.zone` (Rails `Time.current`).
  def self.current : Time
    Saci::TimeZone.current.now
  end

  # Converts the same instant to *zone* (defaults to `Time.zone`).
  def in_time_zone(zone : String | Symbol | Saci::TimeZone | Time::Location | Nil = nil) : Time
    target = zone.nil? ? Saci::TimeZone.current : Saci::TimeZone.coerce(zone)
    self.in(target.location)
  end
end
