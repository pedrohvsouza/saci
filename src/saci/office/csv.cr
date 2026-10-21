require "./support"

module Saci
  module Office
    # RFC 4180 CSV generation and a small parser.
    #
    # ```
    # Saci::Office::CSV.generate([["name", "note"], ["Ada", "a, b"]])
    # # => "name,note\r\nAda,\"a, b\"\r\n"
    #
    # Saci::Office::CSV.open("export.csv") do |csv|
    #   csv << ["name", "age"]
    #   csv << ["Ada", 36]
    # end
    # ```
    module CSV
      DEFAULT_DELIMITER   = ','
      DEFAULT_LINE_ENDING = "\r\n"

      class Error < Exception
      end

      # Serializes *rows* (anything enumerable of enumerables) to a String.
      def self.generate(rows : Enumerable, delimiter : Char = DEFAULT_DELIMITER,
                        line_ending : String = DEFAULT_LINE_ENDING,
                        always_quote : Bool = false) : String
        String.build do |io|
          write_rows(io, rows, delimiter, line_ending, always_quote)
        end
      end

      # Writes rows to *path* using streaming IO (no full-file buffering).
      def self.write(path : String, rows : Enumerable, delimiter : Char = DEFAULT_DELIMITER,
                     line_ending : String = DEFAULT_LINE_ENDING,
                     always_quote : Bool = false) : Nil
        File.open(path, "w") do |file|
          write_rows(file, rows, delimiter, line_ending, always_quote)
        end
      end

      def self.write_rows(io : IO, rows : Enumerable, delimiter : Char = DEFAULT_DELIMITER,
                          line_ending : String = DEFAULT_LINE_ENDING,
                          always_quote : Bool = false) : Nil
        rows.each do |row|
          write_row(io, row, delimiter, line_ending, always_quote)
        end
      end

      # Writes a single record. The caller owns the IO (and any newline
      # conventions); a line ending is appended after every row.
      def self.write_row(io : IO, row : Enumerable, delimiter : Char = DEFAULT_DELIMITER,
                         line_ending : String = DEFAULT_LINE_ENDING,
                         always_quote : Bool = false) : Nil
        first = true
        row.each do |value|
          io << delimiter unless first
          field = field_to_s(value)
          if always_quote
            io << '"'
            field.each_char { |char| char == '"' ? (io << "\"\"") : (io << char) }
            io << '"'
          else
            io << escape(field, delimiter)
          end
          first = false
        end
        io << line_ending
      end

      # Quotes a field when RFC 4180 requires it (delimiter, quote, CR/LF) or
      # when surrounding whitespace would otherwise be lost by readers.
      def self.escape(field : String, delimiter : Char = DEFAULT_DELIMITER) : String
        needs_quote = field.includes?(delimiter) || field.includes?('"') ||
                      field.includes?('\n') || field.includes?('\r') ||
                      field.starts_with?(' ') || field.ends_with?(' ')
        return field unless needs_quote

        String.build(field.bytesize + 8) do |io|
          io << '"'
          field.each_char do |char|
            if char == '"'
              io << "\"\""
            else
              io << char
            end
          end
          io << '"'
        end
      end

      # Parses RFC 4180 input into rows of strings. Handles quoted fields,
      # escaped quotes, embedded delimiters/newlines and CRLF or LF endings.
      def self.parse(input : String | IO, delimiter : Char = DEFAULT_DELIMITER) : Array(Array(String))
        text = input.is_a?(IO) ? input.gets_to_end : input
        rows = [] of Array(String)
        row = [] of String
        field = ""
        in_quotes = false
        field_started = false
        index = 0
        chars = text.chars

        while index < chars.size
          char = chars[index]
          if in_quotes
            if char == '"'
              if index + 1 < chars.size && chars[index + 1] == '"'
                field += "\""
                index += 1
              else
                in_quotes = false
              end
            else
              field += char.to_s
            end
            index += 1
            next
          end

          case char
          when delimiter
            row << field
            field = ""
            field_started = false
          when '"'
            if field.empty?
              in_quotes = true
              field_started = true
            else
              field += char.to_s
            end
          when '\r'
            row << field
            rows << row
            row = [] of String
            field = ""
            field_started = false
            index += 1 if index + 1 < chars.size && chars[index + 1] == '\n'
          when '\n'
            row << field
            rows << row
            row = [] of String
            field = ""
            field_started = false
          else
            field += char.to_s
            field_started = true
          end
          index += 1
        end

        raise Error.new("Unterminated quoted CSV field") if in_quotes

        unless field.empty? && row.empty? && !field_started
          row << field
          rows << row
        end
        rows
      end

      # Streaming CSV writer. Prefer `CSV.open` so the file is always closed.
      class Writer
        getter io : IO

        def initialize(@io : IO, @delimiter : Char = DEFAULT_DELIMITER,
                       @line_ending : String = DEFAULT_LINE_ENDING,
                       @always_quote : Bool = false)
        end

        def <<(row : Enumerable) : self
          CSV.write_row(@io, row, @delimiter, @line_ending, @always_quote)
          self
        end

        def write_row(row : Enumerable) : Nil
          CSV.write_row(@io, row, @delimiter, @line_ending, @always_quote)
        end

        def flush : Nil
          @io.flush
        end

        def close : Nil
          @io.close
        end

        def self.open(path : String, delimiter : Char = DEFAULT_DELIMITER,
                      line_ending : String = DEFAULT_LINE_ENDING,
                      always_quote : Bool = false, & : Writer ->) : Nil
          File.open(path, "w") do |file|
            writer = new(file, delimiter, line_ending, always_quote)
            yield writer
          end
        end

        def self.open(io : IO, delimiter : Char = DEFAULT_DELIMITER,
                      line_ending : String = DEFAULT_LINE_ENDING,
                      always_quote : Bool = false, & : Writer ->) : Nil
          writer = new(io, delimiter, line_ending, always_quote)
          yield writer
        end
      end

      private def self.field_to_s(value) : String
        case value
        when Nil
          ""
        else
          value.to_s
        end
      end
    end
  end
end
