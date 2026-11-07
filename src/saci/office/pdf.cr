require "./support"

module Saci
  module Office
    # Direct PDF 1.4 writer with the standard Helvetica fonts.
    #
    # ```
    # pdf = Saci::Office::PDF.new(title: "Quarterly report")
    # pdf.heading("Quarterly report")
    # pdf.paragraph("Revenue grew 12% ...")
    # pdf.table(
    #   headers: ["Region", "Revenue"],
    #   rows: [["North", "$12,000"], ["South", "$8,500"]],
    # )
    # pdf.write("report.pdf")
    # ```
    #
    # Text uses WinAnsi-encoded standard Type 1 fonts, so no font files need
    # to be embedded. Content is generated page by page; tables repeat their
    # header on page breaks. JPEG/PNG embedding is intentionally not
    # implemented (see the README/gap notes); use `draw_text`, `line` and
    # `rectangle` to compose custom graphics.
    class PDF
      alias Color = Tuple(Float64, Float64, Float64)

      A4     = {595.28, 841.89}
      A5     = {420.94, 595.28}
      LETTER = {612.0, 792.0}
      LEGAL  = {612.0, 1008.0}

      CONTENT_TYPE   = "application/pdf"
      FILE_EXTENSION = "pdf"

      # Helvetica advance widths (1/1000 em) for printable ASCII. Used for
      # line wrapping and table layout; bold/oblique reuse the regular
      # metrics with a small factor, which is close enough for layout.
      HELVETICA_WIDTHS = [
        278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278,
        556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556,
        1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778,
        667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556,
        333, 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556,
        556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584,
      ]

      class Page
        # IO::Memory (unlike String::Builder) can be converted to a String
        # repeatedly, which keeps `#to_bytes` idempotent.
        getter content = IO::Memory.new
      end

      getter page_width : Float64
      getter page_height : Float64
      getter margin : Float64
      getter title : String?
      getter author : String?

      def initialize(page_size : Symbol | Tuple(Float64, Float64) = :a4,
                     margins : Number = 50.0,
                     @title : String? = nil,
                     @author : String? = nil,
                     @footer : String? = nil)
        @page_width, @page_height = resolve_page_size(page_size)
        @margin = margins.to_f64
        raise ArgumentError.new("PDF margins must be >= 0") if @margin < 0
        raise ArgumentError.new("PDF margins leave no content area") if content_width <= 0 || content_height <= 0
        @pages = [Page.new] of Page
        @cursor_y = @page_height - @margin
      end

      def page_count : Int32
        @pages.size
      end

      def content_width : Float64
        @page_width - 2.0 * @margin
      end

      def content_height : Float64
        @page_height - 2.0 * @margin
      end

      # Y coordinate (from the bottom) of the next flowing element.
      def cursor_y : Float64
        @cursor_y
      end

      # Starts a new page and resets the flow cursor to the top margin.
      def new_page : Nil
        @pages << Page.new
        @cursor_y = @page_height - @margin
      end

      def page_break : Nil
        new_page
      end

      # Moves the flow cursor down, adding a page if the space is not
      # available.
      def move_down(amount : Number) : Nil
        height = amount.to_f64
        ensure_space(height)
        @cursor_y -= height
      end

      def move_up(amount : Number) : Nil
        @cursor_y = Math.min(@page_height - @margin, @cursor_y + amount.to_f64)
      end

      # Draws text at absolute PDF coordinates (origin bottom-left), one
      # line per `\n`. This bypasses the flow cursor.
      def draw_text(text : String, x : Number, y : Number, size : Number = 12,
                    font : Symbol = :helvetica, color : Color? = nil) : Nil
        size_f = size.to_f64
        leading = size_f * 1.2
        text.split('\n').each_with_index do |line, index|
          draw_text_line(line, x.to_f64, y.to_f64 - index * leading, size_f, font, color)
        end
      end

      # Flowing paragraph with automatic wrapping and page breaks.
      def paragraph(text : String, size : Number = 11, leading : Number? = nil,
                    font : Symbol = :helvetica, color : Color? = nil,
                    space_after : Number = 6) : Nil
        size_f = size.to_f64
        leading_f = leading ? leading.to_f64 : size_f * 1.35
        wrap_text(text, content_width, size_f, font).each do |line|
          ensure_space(leading_f)
          draw_text_line(line, @margin, @cursor_y - size_f, size_f, font, color)
          @cursor_y -= leading_f
        end
        @cursor_y -= space_after.to_f64
      end

      def heading(text : String, size : Number = 18, color : Color? = nil,
                  space_after : Number = 8) : Nil
        paragraph(text, size: size, font: :bold, color: color, space_after: space_after)
      end

      def line(x1 : Number, y1 : Number, x2 : Number, y2 : Number,
               width : Number = 0.5, color : Color = {0.0, 0.0, 0.0}) : Nil
        @pages.last.content << String.build do |io|
          io << "q\n" << color_command(color, :stroke) << number(width) << " w\n"
          io << number(x1) << " " << number(y1) << " m\n"
          io << number(x2) << " " << number(y2) << " l\nS\nQ\n"
        end
      end

      def rectangle(x : Number, y : Number, width : Number, height : Number,
                    fill : Color? = nil, stroke : Color? = nil,
                    line_width : Number = 0.5) : Nil
        @pages.last.content << String.build do |io|
          io << "q\n"
          io << color_command(fill, :fill) if fill
          if stroke
            io << color_command(stroke, :stroke)
            io << number(line_width) << " w\n"
          end
          io << number(x) << " " << number(y) << " " << number(width) << " " << number(height) << " re\n"
          if fill && stroke
            io << "B\n"
          elsif fill
            io << "f\n"
          elsif stroke
            io << "S\n"
          end
          io << "Q\n"
        end
      end

      # Draws a table at the current flow cursor. Column widths are in
      # points; if omitted they are distributed evenly. The header row is
      # shaded, borders are drawn between cells, and the header repeats when
      # the table continues on a new page.
      def table(*, headers, rows, title : String? = nil, column_widths = nil,
                header_fill : Color = {0.90, 0.93, 0.97},
                grid_color : Color = {0.72, 0.72, 0.72},
                header_color : Color = {0.05, 0.05, 0.05},
                font_size : Number = 9,
                header_font_size : Number? = nil,
                padding : Number = 4,
                repeat_headers : Bool = true,
                border_width : Number = 0.5,
                space_after : Number = 10) : Nil
        body = rows.map { |row| row.to_a.map(&.to_s) }.to_a
        header_values = headers.to_a.map(&.to_s)
        column_count = header_values.size
        column_count = body.first?.try(&.size) || 0 if column_count == 0
        return if column_count == 0

        if header_values.empty?
          header_values = Array(String).new(column_count, "")
        end
        body = body.map do |row|
          values = row.dup
          (column_count - values.size).times { values << "" } if values.size < column_count
          values.first(column_count)
        end

        font_size_f = font_size.to_f64
        header_size = header_font_size ? header_font_size.to_f64 : font_size_f + 0.5
        padding_f = padding.to_f64
        widths = resolve_column_widths(column_widths, column_count, content_width)
        header_height = table_row_height(header_values, widths, header_size, padding_f)

        if title
          title_size = Math.max(font_size_f + 3.0, 11.0)
          ensure_space(title_size * 1.3 + 6.0)
          draw_text_line(title, @margin, @cursor_y - title_size, title_size, :bold, header_color)
          @cursor_y -= title_size * 1.3 + 6.0
        end

        ensure_space(header_height)
        draw_table_row(header_values, widths, header_height, header_size, padding_f,
          header: true, header_fill: header_fill, grid_color: grid_color,
          text_color: header_color, border_width: border_width)

        body.each do |values|
          height = table_row_height(values, widths, font_size_f, padding_f)
          if @cursor_y - height < @margin
            new_page
            if repeat_headers
              draw_table_row(header_values, widths, header_height, header_size, padding_f,
                header: true, header_fill: header_fill, grid_color: grid_color,
                text_color: header_color, border_width: border_width)
            end
          end
          draw_table_row(values, widths, height, font_size_f, padding_f,
            header: false, header_fill: header_fill, grid_color: grid_color,
            text_color: {0.1, 0.1, 0.1}, border_width: border_width)
        end

        @cursor_y -= space_after.to_f64
      end

      # One-shot table document:
      #
      # ```
      # pdf = Saci::Office::PDF.table(
      #   title: "Users",
      #   headers: ["Name", "Email"],
      #   rows: [["Ada", "ada@example.com"]],
      #   path: "users.pdf",
      # )
      # ```
      def self.table(*, title : String, headers, rows, path : String? = nil,
                     page_size : Symbol | Tuple(Float64, Float64) = :a4,
                     margins : Number = 50.0, column_widths = nil) : PDF
        pdf = new(page_size: page_size, margins: margins, title: title)
        pdf.heading(title)
        pdf.table(headers: headers, rows: rows, column_widths: column_widths)
        pdf.write(path) if path
        pdf
      end

      # Width of *text* in points using the approximate Helvetica metrics.
      def text_width(text : String, size : Number = 11, font : Symbol = :helvetica) : Float64
        factor = bold?(font) ? 1.03 : 1.0
        text.each_char.reduce(0.0) do |total, char|
          total + char_width(char) * size.to_f64 / 1000.0 * factor
        end
      end

      # Wraps *text* to *max_width* points. Explicit newlines are preserved;
      # words longer than the available width are split character-wise.
      def wrap_text(text : String, max_width : Number, size : Number = 11,
                    font : Symbol = :helvetica) : Array(String)
        width = max_width.to_f64
        return [""] if text.empty?

        lines = [] of String
        text.split('\n').each do |paragraph|
          if paragraph.empty?
            lines << ""
            next
          end

          current = ""
          paragraph.split(' ').each do |word|
            candidate = current.empty? ? word : "#{current} #{word}"
            if text_width(candidate, size, font) <= width
              current = candidate
            else
              lines << current unless current.empty?
              current = ""
              if text_width(word, size, font) > width
                chunks = split_long_word(word, width, size, font)
                lines.concat(chunks[0...-1]) unless chunks.size <= 1
                current = chunks.last? || ""
              else
                current = word
              end
            end
          end
          lines << current unless current.empty?
        end
        lines.empty? ? [""] : lines
      end

      def write(path : String) : Nil
        File.open(path, "wb") do |file|
          write(file)
        end
      end

      def write(io : IO) : Nil
        io.write(to_bytes)
      end

      def to_bytes : Bytes
        io = IO::Memory.new
        io << "%PDF-1.4\n"
        # Binary marker: keeps the file from being treated as plain text by
        # naive transfer tools (recommended by the PDF spec).
        io.write(Bytes[0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A])

        total_objects = 6 + @pages.size * 2
        offsets = {} of Int32 => Int64
        page_numbers = [] of Int32

        write_object(io, offsets, 1, "<< /Type /Catalog /Pages 2 0 R >>")

        page_object_numbers = [] of Int32
        @pages.each_index do |index|
          page_object_numbers << 7 + index * 2
        end
        kids = page_object_numbers.map { |number| "#{number} 0 R" }.join(" ")
        write_object(io, offsets, 2, "<< /Type /Pages /Kids [#{kids}] /Count #{@pages.size} >>")

        write_object(io, offsets, 3,
          "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
        write_object(io, offsets, 4,
          "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>")
        write_object(io, offsets, 5,
          "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Oblique /Encoding /WinAnsiEncoding >>")

        info = String.build do |builder|
          builder << "<< /Producer (Saci Office PDF) "
          builder << "/CreationDate (D:#{Time.utc.to_s("%Y%m%d%H%M%S")}Z) "
          if title = @title
            builder << "/Title (#{pdf_escape(title)}) "
          end
          if author = @author
            builder << "/Author (#{pdf_escape(author)}) "
          end
          builder << ">>"
        end
        write_object(io, offsets, 6, info)

        @pages.each_with_index do |page, index|
          page_number = 7 + index * 2
          content_number = page_number + 1
          page_numbers << page_number

          content = page.content.to_s
          if footer = @footer
            text = footer.gsub("{page}", (index + 1).to_s).gsub("{total}", @pages.size.to_s)
            footer_y = @margin / 2.0
            footer_x = Math.max(@margin, (@page_width - text_width(text, 8)) / 2.0)
            content += text_command(text, footer_x, footer_y, 8.0, :helvetica, {0.4, 0.4, 0.4})
          end

          stream = String.build do |builder|
            builder << "<< /Length " << content.bytesize << " >>\nstream\n"
            builder << content
            builder << "\nendstream"
          end
          page_body = String.build do |builder|
            builder << "<< /Type /Page /Parent 2 0 R "
            builder << "/MediaBox [0 0 #{number(@page_width)} #{number(@page_height)}] "
            builder << "/Resources << /Font << /F1 3 0 R /F2 4 0 R /F3 5 0 R >> >> "
            builder << "/Contents #{content_number} 0 R >>"
          end
          write_object(io, offsets, page_number, page_body)
          write_object(io, offsets, content_number, stream)
        end

        xref_offset = io.pos
        io << "xref\n0 #{total_objects + 1}\n"
        io << "0000000000 65535 f \n"
        (1..total_objects).each do |number|
          offset = offsets[number]? || raise Error.new("Missing PDF object #{number}")
          io << offset.to_s.rjust(10, '0') << " 00000 n \n"
        end
        io << "trailer\n<< /Size #{total_objects + 1} /Root 1 0 R /Info 6 0 R >>\n"
        io << "startxref\n" << xref_offset << "\n%%EOF\n"
        io.to_slice
      end

      class Error < Exception
      end

      private def resolve_page_size(page_size : Symbol | Tuple(Float64, Float64)) : Tuple(Float64, Float64)
        case page_size
        when :a4     then A4
        when :a5     then A5
        when :letter then LETTER
        when :legal  then LEGAL
        else
          page_size.is_a?(Tuple(Float64, Float64)) ? page_size : raise ArgumentError.new("Unknown PDF page size: #{page_size}")
        end
      end

      private def ensure_space(height : Float64) : Nil
        new_page if @cursor_y - height < @margin
      end

      private def draw_text_line(text : String, x : Float64, y : Float64, size : Float64,
                                 font : Symbol, color : Color?) : Nil
        @pages.last.content << text_command(text, x, y, size, font, color)
      end

      private def text_command(text : String, x : Float64, y : Float64, size : Float64,
                               font : Symbol, color : Color?) : String
        String.build do |io|
          io << "q\n"
          io << color_command(color, :fill) if color
          io << "BT\n/" << font_resource(font) << " " << number(size) << " Tf\n"
          io << number(x) << " " << number(y) << " Td\n(" << pdf_escape(text) << ") Tj\nET\nQ\n"
        end
      end

      private def color_command(color : Color, mode : Symbol) : String
        operator = mode == :stroke ? "RG" : "rg"
        "#{number(color[0])} #{number(color[1])} #{number(color[2])} #{operator}\n"
      end

      private def font_resource(font : Symbol) : String
        case font
        when :bold, :helvetica_bold, :bold_italic  then "F2"
        when :italic, :oblique, :helvetica_oblique then "F3"
        else                                            "F1"
        end
      end

      private def bold?(font : Symbol) : Bool
        font == :bold || font == :helvetica_bold || font == :bold_italic
      end

      private def char_width(char : Char) : Int32
        codepoint = char.ord
        if 32 <= codepoint <= 126
          HELVETICA_WIDTHS[codepoint - 32]
        elsif codepoint == 0x00A0
          278
        else
          556
        end
      end

      private def split_long_word(word : String, max_width : Float64, size : Float64,
                                  font : Symbol) : Array(String)
        chunks = [] of String
        current = ""
        word.each_char do |char|
          candidate = current + char.to_s
          if !current.empty? && text_width(candidate, size, font) > max_width
            chunks << current
            current = char.to_s
          else
            current = candidate
          end
        end
        chunks << current unless current.empty?
        chunks.empty? ? [""] : chunks
      end

      private def table_row_height(values : Array(String), widths : Array(Float64),
                                   size : Float64, padding : Float64) : Float64
        leading = size * 1.25
        max_lines = 1
        values.each_with_index do |value, index|
          inner_width = Math.max(widths[index] - 2.0 * padding, 1.0)
          line_count = wrap_text(value, inner_width, size, :helvetica).size
          max_lines = line_count if line_count > max_lines
        end
        max_lines * leading + 2.0 * padding
      end

      private def draw_table_row(values : Array(String), widths : Array(Float64),
                                 height : Float64, size : Float64, padding : Float64,
                                 header : Bool, header_fill : Color, grid_color : Color,
                                 text_color : Color, border_width : Float64) : Nil
        top = @cursor_y
        bottom = top - height
        total_width = widths.sum
        font = header ? :bold : :helvetica
        leading = size * 1.25

        rectangle(@margin, bottom, total_width, height, fill: header_fill) if header

        # Borders: top/bottom plus one vertical per column boundary.
        line(@margin, top, @margin + total_width, top, width: border_width, color: grid_color)
        line(@margin, bottom, @margin + total_width, bottom, width: border_width, color: grid_color)
        x = @margin
        widths.each do |width|
          line(x, top, x, bottom, width: border_width, color: grid_color)
          x += width
        end
        line(x, top, x, bottom, width: border_width, color: grid_color)

        x = @margin
        values.each_with_index do |value, index|
          inner_width = Math.max(widths[index] - 2.0 * padding, 1.0)
          lines = wrap_text(value, inner_width, size, font)
          baseline = top - padding - size
          lines.each_with_index do |line_text, line_index|
            draw_text_line(line_text, x + padding, baseline - line_index * leading, size, font, text_color)
          end
          x += widths[index]
        end
        @cursor_y = bottom
      end

      private def resolve_column_widths(column_widths, column_count : Int32,
                                        available : Float64) : Array(Float64)
        widths = if column_widths
                   column_widths.to_a.map(&.to_f64)
                 else
                   [] of Float64
                 end

        if widths.size < column_count
          remaining = column_count - widths.size
          widths.concat(Array(Float64).new(remaining, available / column_count))
        elsif widths.size > column_count
          widths = widths.first(column_count)
        end
        widths = Array(Float64).new(column_count, available / column_count) if widths.sum <= 0

        total = widths.sum
        if total > available
          scale = available / total
          widths = widths.map { |width| width * scale }
        end
        widths
      end

      private def number(value : Number) : String
        float = value.to_f64
        if float == float.round
          float.to_i64.to_s
        else
          float.round(3).to_s
        end
      end

      private def write_object(io : IO, offsets : Hash(Int32, Int64), number : Int32,
                               body : String) : Nil
        offsets[number] = io.pos
        io << number << " 0 obj\n" << body << "\nendobj\n"
      end

      # PDF literal-string escaping. Text is converted from UTF-8 to WinAnsi
      # so the standard Helvetica encoding renders Latin-1 accents and common
      # typographic characters; unsupported characters become `?`.
      private def pdf_escape(text : String) : String
        String.build do |io|
          text.each_char do |char|
            each_win_ansi_byte(char) do |byte|
              case byte
              when 0x28_u8 # (
                io << "\\("
              when 0x29_u8 # )
                io << "\\)"
              when 0x5C_u8 # backslash
                io << "\\\\"
              when 0x20_u8..0x7E_u8
                io.write_byte(byte)
              else
                io << '\\' << byte.to_s(8).rjust(3, '0')
              end
            end
          end
        end
      end

      private def each_win_ansi_byte(char : Char, & : UInt8 ->) : Nil
        codepoint = char.ord
        byte = case codepoint
               when 0x20..0x7E, 0xA0..0xFF
                 codepoint.to_u8
               when 0x2013           then 0x96_u8
               when 0x2014           then 0x97_u8
               when 0x2018           then 0x91_u8
               when 0x2019           then 0x92_u8
               when 0x201A           then 0x82_u8
               when 0x201C           then 0x93_u8
               when 0x201D           then 0x94_u8
               when 0x201E           then 0x84_u8
               when 0x2020           then 0x86_u8
               when 0x2021           then 0x87_u8
               when 0x2022           then 0x95_u8
               when 0x2026           then 0x85_u8
               when 0x2030           then 0x89_u8
               when 0x2039           then 0x8B_u8
               when 0x203A           then 0x9B_u8
               when 0x20AC           then 0x80_u8
               when 0x2122           then 0x99_u8
               when 0x0152           then 0x8C_u8
               when 0x0153           then 0x9C_u8
               when 0x0160           then 0x8A_u8
               when 0x0161           then 0x9A_u8
               when 0x0178           then 0x9F_u8
               when 0x017D           then 0x8E_u8
               when 0x017E           then 0x9E_u8
               when 0x0192           then 0x83_u8
               when 0x02C6           then 0x88_u8
               when 0x02DC           then 0x98_u8
               when 0x09, 0x0A, 0x0D then 0x20_u8
               else                       0x3F_u8
               end
        yield byte
      end
    end
  end
end
