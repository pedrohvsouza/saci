module Saci
  module Record
    # Adapter-specific SQL fragment builders (G311). Each helper returns a
    # SQL *expression string* — callers splice it into `where`, `select`,
    # `order`, etc. Values/columns are treated as raw SQL (quote identifiers
    # yourself with `Saci::Record.quote` when needed); string literals such
    # as timezone names are escaped here.
    #
    # ```
    # Saci::Record::Dialect.extract(:year, "created_at") # SQLite
    # Saci::Record::Dialect.extract(:year, "created_at", :mysql)
    # Saci::Record::Dialect.timestampdiff(:day, "starts_at", "ends_at", :postgres)
    # Saci::Record::Dialect.json_extract("meta.color", "meta", :mysql)
    # Saci::Record::Dialect.convert_tz("created_at", "UTC", "America/Sao_Paulo")
    # ```
    module Dialect
      # Maps `EXTRACT` parts to SQLite `strftime` format strings.
      SQLITE_STRFTIME = {
        "YEAR"      => "%Y",
        "MONTH"     => "%m",
        "DAY"       => "%d",
        "HOUR"      => "%H",
        "MINUTE"    => "%M",
        "SECOND"    => "%S",
        "DOW"       => "%w",
        "DOY"       => "%j",
        "WEEK"      => "%W",
        "QUARTER"   => nil,
        "EPOCH"     => "%s",
        "DAYOFWEEK" => "%w",
        "DAYOFYEAR" => "%j",
      }

      # `EXTRACT(<part> FROM <col>)` on PostgreSQL/MySQL; SQLite emulates
      # the common parts through `strftime` (returned as INTEGER).
      def self.extract(part : String | Symbol, col : String, adapter : Adapter = :sqlite) : String
        p = part.to_s.upcase
        case adapter
        when :postgres, :mysql
          "EXTRACT(#{p} FROM #{col})"
        when :sqlite
          if p == "QUARTER"
            "((CAST(strftime('%m', #{col}) AS INTEGER) + 2) / 3)"
          else
            fmt = SQLITE_STRFTIME[p]?
            raise ArgumentError.new("Dialect.extract: unsupported SQLite part #{part.inspect}") if fmt.nil?
            "CAST(strftime('#{fmt}', #{col}) AS INTEGER)"
          end
        else
          raise ArgumentError.new("Dialect.extract: unsupported adapter #{adapter.inspect}")
        end
      end

      # `TIMESTAMPDIFF(unit, start, end)` equivalent. PostgreSQL uses
      # `EXTRACT(EPOCH ...)` / `age()`; SQLite uses `julianday` arithmetic
      # (MONTH/YEAR are approximations of 30.4375/365.25 days).
      def self.timestampdiff(unit : String | Symbol, start_col : String, end_col : String, adapter : Adapter = :sqlite) : String
        u = unit.to_s.upcase
        case adapter
        when :mysql
          "TIMESTAMPDIFF(#{u}, #{start_col}, #{end_col})"
        when :postgres
          case u
          when "SECOND" then "CAST(EXTRACT(EPOCH FROM (#{end_col} - #{start_col})) AS BIGINT)"
          when "MINUTE" then "CAST(EXTRACT(EPOCH FROM (#{end_col} - #{start_col})) / 60 AS BIGINT)"
          when "HOUR"   then "CAST(EXTRACT(EPOCH FROM (#{end_col} - #{start_col})) / 3600 AS BIGINT)"
          when "DAY"    then "CAST(EXTRACT(EPOCH FROM (#{end_col} - #{start_col})) / 86400 AS BIGINT)"
          when "WEEK"   then "CAST(EXTRACT(EPOCH FROM (#{end_col} - #{start_col})) / 604800 AS BIGINT)"
          when "MONTH"  then "CAST(EXTRACT(YEAR FROM age(#{end_col}, #{start_col})) * 12 + EXTRACT(MONTH FROM age(#{end_col}, #{start_col})) AS BIGINT)"
          when "YEAR"   then "CAST(EXTRACT(YEAR FROM age(#{end_col}, #{start_col})) AS BIGINT)"
          else
            raise ArgumentError.new("Dialect.timestampdiff: unsupported PostgreSQL unit #{unit.inspect}")
          end
        when :sqlite
          days = "(julianday(#{end_col}) - julianday(#{start_col}))"
          expr = case u
                 when "SECOND" then "#{days} * 86400"
                 when "MINUTE" then "#{days} * 1440"
                 when "HOUR"   then "#{days} * 24"
                 when "DAY"    then days
                 when "WEEK"   then "#{days} / 7"
                 when "MONTH"  then "#{days} / 30.4375"
                 when "YEAR"   then "#{days} / 365.25"
                 else
                   raise ArgumentError.new("Dialect.timestampdiff: unsupported SQLite unit #{unit.inspect}")
                 end
          "CAST(#{expr} AS INTEGER)"
        else
          raise ArgumentError.new("Dialect.timestampdiff: unsupported adapter #{adapter.inspect}")
        end
      end

      # `JSON_EXTRACT(col, '$.path')` (SQLite/MySQL) or PostgreSQL's
      # `col #>> '{path,parts}'` text extraction.
      def self.json_extract(path : String | Array(String), col : String, adapter : Adapter = :sqlite) : String
        parts = path.is_a?(Array) ? path : path.split('.')
        case adapter
        when :postgres
          pg_path = "{" + parts.map { |p| p.gsub("\\", "\\\\").gsub("}", "\\}").gsub(",", "\\,") }.join(",") + "}"
          "#{col} #>> '#{pg_path.gsub("'", "''")}'"
        when :mysql, :sqlite
          json_path = "$." + parts.join(".")
          "JSON_EXTRACT(#{col}, '#{json_path.gsub("'", "''")}')"
        else
          raise ArgumentError.new("Dialect.json_extract: unsupported adapter #{adapter.inspect}")
        end
      end

      # `CONVERT_TZ(col, from, to)` on MySQL; PostgreSQL's double
      # `AT TIME ZONE`; SQLite has no timezone database, so it normalizes
      # through `datetime()` (documented no-op conversion).
      def self.convert_tz(col : String, from : String, to : String, adapter : Adapter = :sqlite) : String
        case adapter
        when :mysql
          "CONVERT_TZ(#{col}, '#{from.gsub("'", "''")}', '#{to.gsub("'", "''")}')"
        when :postgres
          "(#{col} AT TIME ZONE '#{from.gsub("'", "''")}' AT TIME ZONE '#{to.gsub("'", "''")}')"
        when :sqlite
          "datetime(#{col})"
        else
          raise ArgumentError.new("Dialect.convert_tz: unsupported adapter #{adapter.inspect}")
        end
      end
    end
  end
end
