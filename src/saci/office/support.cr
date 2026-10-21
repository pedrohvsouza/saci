require "file"

module Saci
  # Office document generation (spreadsheets, PDF, CSV).
  #
  # The layer is deliberately dependency-free: XLSX is a ZIP package written
  # with the stdlib DEFLATE implementation, PDF is emitted directly, and CSV
  # uses RFC 4180 quoting. No external shards (caxlsx/prawn equivalents) are
  # needed.
  module Office
    # Excel's day-zero is 1899-12-30 (1900 is treated as a leap year by the
    # format, hence the 2-day offset from the Unix epoch).
    EXCEL_EPOCH_OFFSET = 25_569.0

    # Seconds in a day, used for the fractional part of a date serial.
    SECONDS_PER_DAY = 86_400.0

    # Escapes text for an XML 1.0 text node or attribute value. Characters
    # that XML 1.0 forbids (most C0 controls, lone surrogates) are dropped so
    # a stray control byte in user data cannot corrupt the workbook.
    def self.xml_escape(value : String) : String
      String.build(value.bytesize + 16) do |io|
        value.each_char do |char|
          case char
          when '&'  then io << "&amp;"
          when '<'  then io << "&lt;"
          when '>'  then io << "&gt;"
          when '"'  then io << "&quot;"
          when '\'' then io << "&apos;"
          else
            codepoint = char.ord
            if codepoint == 0x9 || codepoint == 0xA || codepoint == 0xD ||
               (0x20..0xD7FF).includes?(codepoint) ||
               (0xE000..0xFFFD).includes?(codepoint) ||
               (0x10000..0x10FFFF).includes?(codepoint)
              io << char
            end
          end
        end
      end
    end

    # True when XML should preserve leading/trailing whitespace on a cell.
    def self.preserve_space?(value : String) : Bool
      !value.empty? && (value.starts_with?(' ') || value.ends_with?(' ') ||
        value.starts_with?('\t') || value.ends_with?('\t') ||
        value.starts_with?('\n') || value.ends_with?('\n'))
    end

    # Converts a `Time` to an Excel serial date. The timezone of the value is
    # honored (`Time.utc(...)` produces the expected UTC serial).
    def self.excel_serial(time : Time) : Float64
      time.to_unix_f / SECONDS_PER_DAY + EXCEL_EPOCH_OFFSET
    end

    # Rails-ish column header: `first_name` -> `First Name`.
    def self.humanize(name : String) : String
      words = name.gsub('_', ' ').gsub('-', ' ').split
      return name if words.empty?
      words.map(&.capitalize).join(' ')
    end

    # A filename that is safe to put inside a quoted `Content-Disposition`
    # header. Keeps the basename and strips CR/LF, quotes and control chars.
    def self.safe_filename(filename : String, fallback : String = "download") : String
      normalized = filename.gsub('\\', '/')
      base = File.basename(normalized).strip
      base = base.gsub(/[\x00-\x1f\x7f"]/, "_")
      base = base.strip
      return fallback if base.empty? || base == "." || base == ".."
      base
    end
  end
end
