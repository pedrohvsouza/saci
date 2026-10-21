require "./time_zone"

# Rails-compatible calendar/date helpers.
#
# Crystal ships `Time#at_beginning_of_*`/`at_end_of_*`; Saci adds the Rails
# spellings (`beginning_of_*`, `end_of_*`), `advance`, `change`, `all_day`,
# `on_day?`, `to_date`, and `to_fs` formats. Crystal has no `Date` type, so
# Saci provides a small value-type `Date` (`Date.current` respects Time.zone).
struct Time
  # Rails `Time#utc_offset` returns a `Time::Span`.
  def utc_offset : Time::Span
    offset.seconds
  end

  # Rails `Time#beginning_of_week` (week starts Monday unless told otherwise).
  def beginning_of_week(start_day : Symbol = :monday) : Time
    at_beginning_of_week(day_of_week(start_day))
  end

  def beginning_of_day : Time
    at_beginning_of_day
  end

  def beginning_of_month : Time
    at_beginning_of_month
  end

  def beginning_of_year : Time
    at_beginning_of_year
  end

  def beginning_of_quarter : Time
    at_beginning_of_quarter
  end

  def end_of_week(start_day : Symbol = :monday) : Time
    beginning_of_week(start_day).shift(days: 6).at_end_of_day
  end

  def end_of_day : Time
    at_end_of_day
  end

  def end_of_month : Time
    at_end_of_month
  end

  def end_of_year : Time
    at_end_of_year
  end

  def end_of_quarter : Time
    at_end_of_quarter
  end

  # Shifts calendar units in the receiver's location. Months/years clamp to
  # the last valid day (Jan 31 + 1 month => Feb 28/29), matching Rails.
  def advance(*, seconds : Int = 0, minutes : Int = 0, hours : Int = 0,
              days : Int = 0, weeks : Int = 0, months : Int = 0, years : Int = 0) : Time
    shift(years: years, months: months, weeks: weeks, days: days,
      hours: hours, minutes: minutes, seconds: seconds)
  end

  def advance(span : Time::Span) : Time
    self + span
  end

  def advance(span : Time::MonthSpan) : Time
    self + span
  end

  # Replaces selected wall-clock fields, preserving the rest and the zone.
  def change(*, year : Int? = nil, month : Int? = nil, day : Int? = nil,
             hour : Int? = nil, minute : Int? = nil, second : Int? = nil,
             nanosecond : Int? = nil) : Time
    y = year || self.year
    mo = month || self.month
    d = day || self.day
    h = hour || self.hour
    mi = minute || self.minute
    s = second || self.second
    ns = nanosecond || self.nanosecond
    Time.local(y, mo, d, h, mi, s, nanosecond: ns, location: location)
  end

  # Whole-day range (exclusive end, like Rails' `all_day`).
  def all_day : Range(Time, Time)
    beginning_of_day...end_of_day
  end

  def on_day?(other : Time) : Bool
    year == other.year && month == other.month && day == other.day
  end

  def on_day?(other : Date) : Bool
    year == other.year && month == other.month && day == other.day
  end

  def to_date : Date
    Date.new(year, month, day)
  end

  # `:short`, `:long`, `:db`, `:number`, `:default` (Rails `to_fs`).
  def to_fs(format : Symbol = :default) : String
    to_s(Time.format_pattern(format))
  end

  def to_s(format : Symbol) : String
    to_fs(format)
  end

  def to_fs(format : String) : String
    to_s(format)
  end

  def to_formatted_s(format : Symbol | String = :default) : String
    format.is_a?(Symbol) ? to_fs(format) : to_s(format)
  end

  # Internal shared map; also used by `Saci::I18n.l` fallbacks.
  def self.format_pattern(format : Symbol) : String
    case format
    when :short   then "%d %b %H:%M"
    when :long    then "%B %d, %Y %H:%M"
    when :db      then "%Y-%m-%d %H:%M:%S"
    when :number  then "%Y%m%d%H%M%S"
    when :rfc3339 then "%FT%T%:z"
    when :default then "%Y-%m-%d %H:%M:%S"
    else               "%Y-%m-%d %H:%M:%S"
    end
  end

  private def day_of_week(name : Symbol) : Time::DayOfWeek
    case name
    when :monday    then Time::DayOfWeek::Monday
    when :tuesday   then Time::DayOfWeek::Tuesday
    when :wednesday then Time::DayOfWeek::Wednesday
    when :thursday  then Time::DayOfWeek::Thursday
    when :friday    then Time::DayOfWeek::Friday
    when :saturday  then Time::DayOfWeek::Saturday
    when :sunday    then Time::DayOfWeek::Sunday
    else                 raise ArgumentError.new("Unknown week start #{name.inspect}")
    end
  end
end

# Minimal civil date (Crystal stdlib has no `Date`). Month/day arithmetic is
# calendar-aware and UTC-backed; use `#to_time(location)` to attach a zone.
struct Date
  include Comparable(Date)

  getter year : Int32
  getter month : Int32
  getter day : Int32

  def initialize(@year : Int32, @month : Int32, @day : Int32)
    raise ArgumentError.new("Invalid date #{@year}-#{@month}-#{@day}") unless 1 <= @month <= 12 && 1 <= @day <= Time.days_in_month(@year, @month)
  end

  def self.new(time : Time) : Date
    new(time.year, time.month, time.day)
  end

  # Rails `Date.current`: today in `Time.zone`.
  def self.current : Date
    new(Time.current)
  end

  # System-local today (Rails `Date.today`).
  def self.today : Date
    new(Time.local)
  end

  def self.parse(value : String) : Date
    time = Time.parse_utc(value, "%F")
    new(time.year, time.month, time.day)
  end

  def self.parse(value : String, pattern : String) : Date
    time = Time.parse_utc(value, pattern)
    new(time.year, time.month, time.day)
  end

  def to_time(location : Time::Location = Saci::TimeZone.current.location) : Time
    Time.local(@year, @month, @day, location: location)
  end

  def to_time(hour : Int, minute : Int = 0, second : Int = 0, location : Time::Location = Saci::TimeZone.current.location) : Time
    Time.local(@year, @month, @day, hour, minute, second, location: location)
  end

  def in_time_zone(zone : String | Symbol | Saci::TimeZone | Time::Location | Nil = nil) : Time
    target = zone.nil? ? Saci::TimeZone.current : Saci::TimeZone.coerce(zone)
    to_time(target.location)
  end

  def +(days : Int) : Date
    shifted = utc_time.shift(days: days)
    Date.new(shifted.year, shifted.month, shifted.day)
  end

  def -(days : Int) : Date
    self + (-days)
  end

  def -(other : Date) : Int32
    ((utc_time - other.utc_time).total_days).to_i32
  end

  def <=>(other : Date) : Int32
    {year, month, day} <=> {other.year, other.month, other.day}
  end

  def advance(*, days : Int = 0, weeks : Int = 0, months : Int = 0, years : Int = 0) : Date
    shifted = utc_time.shift(years: years, months: months, weeks: weeks, days: days)
    Date.new(shifted.year, shifted.month, shifted.day)
  end

  def change(*, year : Int? = nil, month : Int? = nil, day : Int? = nil) : Date
    Date.new(year || self.year, month || self.month, day || self.day)
  end

  def beginning_of_week(start_day : Symbol = :monday) : Date
    Date.new(to_time(Time::Location::UTC).beginning_of_week(start_day))
  end

  def end_of_week(start_day : Symbol = :monday) : Date
    Date.new(to_time(Time::Location::UTC).end_of_week(start_day))
  end

  def beginning_of_month : Date
    Date.new(year, month, 1)
  end

  def end_of_month : Date
    Date.new(year, month, Time.days_in_month(year, month))
  end

  def beginning_of_year : Date
    Date.new(year, 1, 1)
  end

  def end_of_year : Date
    Date.new(year, 12, 31)
  end

  def all_day : Range(Time, Time)
    time = to_time
    time.beginning_of_day...time.end_of_day
  end

  def on_day?(other : Date) : Bool
    self == other
  end

  def on_day?(other : Time) : Bool
    year == other.year && month == other.month && day == other.day
  end

  def to_fs(format : Symbol = :default) : String
    to_s(Date.format_pattern(format))
  end

  def to_fs(format : String) : String
    to_s(format)
  end

  def to_formatted_s(format : Symbol | String = :default) : String
    format.is_a?(Symbol) ? to_fs(format) : to_s(format)
  end

  def self.format_pattern(format : Symbol) : String
    case format
    when :short   then "%b %d"
    when :long    then "%B %d, %Y"
    when :db      then "%Y-%m-%d"
    when :iso8601 then "%Y-%m-%d"
    when :us      then "%m/%d/%Y"
    when :default then "%Y-%m-%d"
    else               "%Y-%m-%d"
    end
  end

  def to_s(io : IO) : Nil
    io << @year.to_s.rjust(4, '0') << '-' << @month.to_s.rjust(2, '0') << '-' << @day.to_s.rjust(2, '0')
  end

  def to_s(format : String) : String
    to_time(Time::Location::UTC).to_s(format)
  end

  def to_s(format : Symbol) : String
    to_s(Date.format_pattern(format))
  end

  def inspect(io : IO) : Nil
    io << "#<Date " << to_s << '>'
  end

  protected def utc_time : Time
    Time.utc(@year, @month, @day)
  end
end
