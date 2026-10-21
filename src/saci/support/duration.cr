require "./time_zone"
require "./time_helpers"

# Rails-style duration helpers.
#
# Crystal already defines `5.minutes`, `2.days`, `3.weeks`, `1.month` and
# `1.year` (`Int#months`/`#years` return `Time::MonthSpan`). Saci adds:
# * `Time::Span#from_now` / `#ago` (zone-aware),
# * zone-aware `Time::MonthSpan` arithmetic and a `from(time)` helper,
# * byte helpers (`kilobytes`, `megabytes`, ...),
# * `to_fs` human formatting.
#
# Calendar units stay `Time::MonthSpan`, so months/years clamp to the last
# valid day instead of being approximated as 30/365 days.
struct Time::Span
  def from_now : Time
    Time.current + self
  end

  def from_now(zone : String | Symbol | Saci::TimeZone | Time::Location) : Time
    target = Saci::TimeZone.coerce(zone)
    Time.utc.in(target.location) + self
  end

  def ago : Time
    Time.current - self
  end

  def ago(zone : String | Symbol | Saci::TimeZone | Time::Location) : Time
    target = Saci::TimeZone.coerce(zone)
    Time.utc.in(target.location) - self
  end

  # Human-readable duration, e.g. `90.minutes.to_fs(:long) # => "1 hour, 30 minutes"`.
  def to_fs(format : Symbol = :default) : String
    total = total_seconds.to_i64
    sign = total < 0 ? "-" : ""
    total = total.abs
    days, rest = total.divmod(86_400)
    hours, rest = rest.divmod(3_600)
    minutes, seconds = rest.divmod(60)
    parts = [] of Tuple(String, String)
    parts << {days.to_s, "day"} if days > 0
    parts << {hours.to_s, "hour"} if hours > 0
    parts << {minutes.to_s, "minute"} if minutes > 0
    parts << {seconds.to_s, "second"} if seconds > 0 || parts.empty?
    case format
    when :short
      sign + parts.map { |(n, unit)| "#{n}#{unit[0]}" }.join(" ")
    when :db
      sign + "#{days.to_s.rjust(2, '0')}:#{hours.to_s.rjust(2, '0')}:#{minutes.to_s.rjust(2, '0')}:#{seconds.to_s.rjust(2, '0')}"
    else
      sign + parts.map { |(n, unit)| "#{n} #{unit}#{n == "1" ? "" : "s"}" }.join(", ")
    end
  end

  def to_formatted_s(format : Symbol = :default) : String
    to_fs(format)
  end
end

struct Time::MonthSpan
  # Overrides stdlib's `Time.local`-based implementation so duration helpers
  # follow `Time.zone` like Rails (calendar arithmetic is applied in-zone).
  def from_now : Time
    Time.current + self
  end

  def ago : Time
    Time.current - self
  end

  def from_now(zone : String | Symbol | Saci::TimeZone | Time::Location) : Time
    target = Saci::TimeZone.coerce(zone)
    Time.utc.in(target.location) + self
  end

  def ago(zone : String | Symbol | Saci::TimeZone | Time::Location) : Time
    target = Saci::TimeZone.coerce(zone)
    Time.utc.in(target.location) - self
  end

  def from(time : Time) : Time
    time + self
  end

  def before(time : Time) : Time
    time - self
  end

  def to_fs(format : Symbol = :default) : String
    months = value
    sign = months < 0 ? "-" : ""
    months = months.abs
    years, rest = months.divmod(12)
    parts = [] of String
    parts << "#{years} year#{years == 1 ? "" : "s"}" if years > 0
    parts << "#{rest} month#{rest == 1 ? "" : "s"}" if rest > 0 || parts.empty?
    case format
    when :short
      sign + (years > 0 ? "#{years}y " : "") + "#{rest}mo"
    else
      sign + parts.join(", ")
    end
  end

  def to_formatted_s(format : Symbol = :default) : String
    to_fs(format)
  end
end

struct Int
  def kilobytes : Int64
    to_i64 * 1_024_i64
  end

  def kilobyte : Int64
    kilobytes
  end

  def megabytes : Int64
    kilobytes * 1_024_i64
  end

  def megabyte : Int64
    megabytes
  end

  def gigabytes : Int64
    megabytes * 1_024_i64
  end

  def gigabyte : Int64
    gigabytes
  end

  def terabytes : Int64
    gigabytes * 1_024_i64
  end

  def terabyte : Int64
    terabytes
  end

  def petabytes : Int64
    terabytes * 1_024_i64
  end

  def petabyte : Int64
    petabytes
  end

  def exabytes : Int64
    petabytes * 1_024_i64
  end

  def exabyte : Int64
    exabytes
  end

  def fortnights : Time::Span
    (to_i64 * 14).days
  end

  def fortnight : Time::Span
    fortnights
  end
end

struct Float
  def kilobytes : Int64
    (self * 1_024).to_i64
  end

  def kilobyte : Int64
    kilobytes
  end

  def megabytes : Int64
    (self * 1_024 * 1_024).to_i64
  end

  def megabyte : Int64
    megabytes
  end

  def gigabytes : Int64
    (self * 1_024 * 1_024 * 1_024).to_i64
  end

  def gigabyte : Int64
    gigabytes
  end

  def terabytes : Int64
    (self * 1_024 * 1_024 * 1_024 * 1_024).to_i64
  end

  def terabyte : Int64
    terabytes
  end

  # Calendar months have no fixed length; fractional values are truncated.
  def months : Time::MonthSpan
    Time::MonthSpan.new(self.to_i64)
  end

  def years : Time::MonthSpan
    Time::MonthSpan.new((self * 12).to_i64)
  end

  def fortnights : Time::Span
    (self * 14).days
  end
end
