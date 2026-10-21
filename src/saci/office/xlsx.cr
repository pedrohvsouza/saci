require "./support"
require "./zip"

module Saci
  module Office
    # A small, dependency-free XLSX (Office Open XML) writer.
    #
    # ```
    # xlsx = Saci::Office::XLSX.new
    # sheet = xlsx.add_sheet("People")
    # sheet.header(["Name", "Age", "Joined"])
    # sheet.add_row(["Ada", 36, Time.utc(2020, 1, 2)])
    # sheet.freeze_panes(rows: 1)
    # xlsx.write("people.xlsx")
    # ```
    #
    # Strings are written as inline strings (the `sharedStrings.xml` part is
    # therefore optional and omitted), numbers as numeric cells, booleans as
    # `t="b"` and `Time` values as Excel date serials with a date/datetime
    # number format. The package is a plain ZIP (STORE or DEFLATE).
    class XLSX
      CONTENT_TYPE   = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
      FILE_EXTENSION = "xlsx"

      alias CellValue = String | Int64 | Float64 | Bool | Time | Nil

      # Formats map to entries in `xl/styles.xml` (see `#style_index`).
      enum CellFormat
        General
        Text
        Integer
        Decimal
        Currency
        Percent
        Date
        DateTime
        Header
      end

      struct Cell
        getter value : CellValue
        getter format : CellFormat

        def initialize(@value : CellValue, @format : CellFormat = CellFormat::General)
        end
      end

      # Normalizes a Ruby/Crystal value into one of the supported cell types.
      # Unknown objects fall back to `to_s` so exporting records does not
      # require every column to be one of the primitive types.
      def self.coerce(value : Nil) : CellValue
        nil
      end

      def self.coerce(value : String) : CellValue
        value
      end

      def self.coerce(value : Bool) : CellValue
        value
      end

      def self.coerce(value : Int) : CellValue
        value.to_i64
      end

      def self.coerce(value : Float) : CellValue
        number = value.to_f64
        number.finite? ? number : number.to_s
      end

      def self.coerce(value : Time) : CellValue
        value
      end

      def self.coerce(value : Char) : CellValue
        value.to_s
      end

      def self.coerce(value : Symbol) : CellValue
        value.to_s
      end

      def self.coerce(value) : CellValue
        value.to_s
      end

      # Excel style index for a cell format. Keep in sync with `STYLES_XML`.
      def self.style_index(format : CellFormat) : Int32
        case format
        when CellFormat::General  then 0
        when CellFormat::Text     then 1
        when CellFormat::Integer  then 2
        when CellFormat::Decimal  then 3
        when CellFormat::Currency then 4
        when CellFormat::Percent  then 5
        when CellFormat::Date     then 6
        when CellFormat::DateTime then 7
        when CellFormat::Header   then 8
        else                           0
        end
      end

      # Converts a 1-based column index to an Excel column name (1 -> A).
      def self.column_letter(column : Int32) : String
        raise ArgumentError.new("Column index must be >= 1") if column < 1
        letters = ""
        number = column
        while number > 0
          number -= 1
          letters = (65 + (number % 26)).to_u8.chr.to_s + letters
          number //= 26
        end
        letters
      end

      class Worksheet
        getter name : String
        getter rows = {} of Int32 => Hash(Int32, Cell)
        getter column_widths = {} of Int32 => Float64

        property freeze_rows : Int32 = 0
        property freeze_columns : Int32 = 0
        property? auto_filter : Bool = false

        @next_row : Int32 = 1

        def initialize(@name : String)
        end

        # Appends a row of values. *formats* (optional, one per cell) and
        # *format* (applied to every cell without a specific format) control
        # number/date display. Returns the 1-based row number.
        def add_row(values : Enumerable, formats : Enumerable? = nil, format : CellFormat? = nil) : Int32
          row_number = @next_row
          cells = {} of Int32 => Cell
          format_list = formats.try(&.to_a)
          values.each_with_index do |value, index|
            column = index + 1
            coerced = XLSX.coerce(value)
            chosen = format_list.try(&.[index]?) || format || infer_format(coerced)
            cells[column] = Cell.new(coerced, chosen)
          end
          @rows[row_number] = cells
          @next_row = row_number + 1
          row_number
        end

        # Adds a bold, shaded header row.
        def header(values : Enumerable) : Int32
          add_row(values, format: CellFormat::Header)
        end

        # Sets one cell using 1-based Excel coordinates, creating the row if
        # necessary. Useful for sparse reports.
        def set_cell(row : Int32, column : Int32, value, format : CellFormat? = nil) : Nil
          raise ArgumentError.new("Row must be >= 1") if row < 1
          raise ArgumentError.new("Column must be >= 1") if column < 1
          cells = @rows[row] ||= {} of Int32 => Cell
          coerced = XLSX.coerce(value)
          cells[column] = Cell.new(coerced, format || infer_format(coerced))
          @next_row = row + 1 if row >= @next_row
        end

        # Sets column widths in points, starting at column A.
        def column_widths(*widths : Number) : Nil
          widths.each_with_index do |width, index|
            set_column_width(index + 1, width)
          end
        end

        # 1-based column index.
        def set_column_width(column : Int32, width : Number) : Nil
          raise ArgumentError.new("Column must be >= 1") if column < 1
          raise ArgumentError.new("Column width must be positive") if width <= 0
          @column_widths[column] = width.to_f64
        end

        # Freezes rows above and columns left of the given counts. `rows: 1`
        # keeps the header visible while scrolling.
        def freeze_panes(rows : Int32 = 1, columns : Int32 = 0) : Nil
          raise ArgumentError.new("Freeze rows must be >= 0") if rows < 0
          raise ArgumentError.new("Freeze columns must be >= 0") if columns < 0
          @freeze_rows = rows
          @freeze_columns = columns
        end

        def row_count : Int32
          @rows.empty? ? 0 : @rows.keys.max
        end

        def column_count : Int32
          @rows.values.reduce(0) { |max, cells| Math.max(max, cells.keys.max? || 0) }
        end

        def to_xml(first : Bool = false) : String
          max_row = [row_count, 1].max
          max_column = [column_count, 1].max

          String.build do |io|
            io << %(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n)
            io << %(<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" )
            io << %(xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\n)
            io << %(<dimension ref="A1:#{XLSX.column_letter(max_column)}#{max_row}"/>\n)
            io << %(<sheetViews><sheetView)
            io << %( tabSelected="1") if first
            io << %( workbookViewId="0">)
            io << pane_xml
            io << %(</sheetView></sheetViews>\n)
            io << %(<sheetFormatPr defaultRowHeight="15"/>\n)
            io << columns_xml
            io << %(<sheetData>\n)
            @rows.keys.sort.each do |row_number|
              cells = @rows[row_number]
              io << %(<row r="#{row_number}">)
              cells.keys.sort.each do |column|
                write_cell(io, row_number, column, cells[column])
              end
              io << %(</row>\n)
            end
            io << %(</sheetData>\n)
            if auto_filter? && max_row > 0
              io << %(<autoFilter ref="A1:#{XLSX.column_letter(max_column)}#{max_row}"/>\n)
            end
            io << %(<pageMargins left="0.7" right="0.7" top="0.75" bottom="0.75" header="0.3" footer="0.3"/>\n)
            io << %(<pageSetup orientation="portrait" paperSize="9"/>\n)
            io << %(</worksheet>\n)
          end
        end

        private def infer_format(value : CellValue) : CellFormat
          case value
          when Time
            if value.hour == 0 && value.minute == 0 && value.second == 0 && value.nanosecond == 0
              CellFormat::Date
            else
              CellFormat::DateTime
            end
          else
            CellFormat::General
          end
        end

        private def pane_xml : String
          return "" if @freeze_rows == 0 && @freeze_columns == 0
          top_left = "#{XLSX.column_letter(@freeze_columns + 1)}#{@freeze_rows + 1}"
          active_pane = if @freeze_rows > 0 && @freeze_columns > 0
                          "bottomRight"
                        elsif @freeze_rows > 0
                          "bottomLeft"
                        else
                          "topRight"
                        end
          String.build do |io|
            io << %(<pane)
            io << %( xSplit="#{@freeze_columns}") if @freeze_columns > 0
            io << %( ySplit="#{@freeze_rows}") if @freeze_rows > 0
            io << %( topLeftCell="#{top_left}" activePane="#{active_pane}" state="frozen"/>)
          end
        end

        private def columns_xml : String
          return "" if @column_widths.empty?
          String.build do |io|
            io << %(<cols>)
            @column_widths.keys.sort.each do |column|
              width = @column_widths[column]
              formatted = width == width.round ? width.to_i.to_s : width.to_s
              io << %(<col min="#{column}" max="#{column}" width="#{formatted}" customWidth="1"/>)
            end
            io << %(</cols>\n)
          end
        end

        private def write_cell(io : IO, row : Int32, column : Int32, cell : Cell) : Nil
          value = cell.value
          return if value.nil?

          reference = "#{XLSX.column_letter(column)}#{row}"
          style = XLSX.style_index(cell.format)
          style_attribute = style == 0 ? "" : %( s="#{style}")

          case value
          when String
            io << %(<c r="#{reference}"#{style_attribute} t="inlineStr"><is><t)
            io << %( xml:space="preserve") if Office.preserve_space?(value)
            io << ">" << Office.xml_escape(value) << %(</t></is></c>)
          when Bool
            io << %(<c r="#{reference}"#{style_attribute} t="b"><v>#{value ? 1 : 0}</v></c>)
          when Int64
            io << %(<c r="#{reference}"#{style_attribute}><v>#{value}</v></c>)
          when Float64
            io << %(<c r="#{reference}"#{style_attribute}><v>#{format_number(value)}</v></c>)
          when Time
            serial = Office.excel_serial(value)
            io << %(<c r="#{reference}"#{style_attribute}><v>#{format_number(serial.round(6))}</v></c>)
          end
        end

        private def format_number(value : Float64) : String
          value == value.round ? value.to_i64.to_s : value.to_s
        end
      end

      getter sheets = [] of Worksheet
      getter compression : Symbol

      def initialize(@compression : Symbol = :deflate)
        unless @compression == :store || @compression == :deflate
          raise ArgumentError.new("XLSX compression must be :store or :deflate")
        end
      end

      # Adds a worksheet. Invalid Excel characters are replaced with `_`,
      # names are capped at 31 characters and duplicates get a numeric
      # suffix, so the workbook is always structurally valid.
      def add_sheet(name : String? = nil) : Worksheet
        candidate = normalize_sheet_name(name || "Sheet#{@sheets.size + 1}")
        sheet = Worksheet.new(candidate)
        @sheets << sheet
        sheet
      end

      def sheet(name : String) : Worksheet?
        @sheets.find { |worksheet| worksheet.name.downcase == name.downcase }
      end

      def [](name : String) : Worksheet?
        sheet(name)
      end

      def write(path : String) : Nil
        File.open(path, "wb") do |file|
          write(file)
        end
      end

      def write(io : IO) : Nil
        add_sheet if @sheets.empty?
        archive = ZIP::Writer.new(io, @compression)
        archive.add_file("[Content_Types].xml", content_types_xml)
        archive.add_file("_rels/.rels", root_rels_xml)
        archive.add_file("xl/workbook.xml", workbook_xml)
        archive.add_file("xl/_rels/workbook.xml.rels", workbook_rels_xml)
        archive.add_file("xl/styles.xml", STYLES_XML)
        @sheets.each_with_index do |worksheet, index|
          archive.add_file("xl/worksheets/sheet#{index + 1}.xml", worksheet.to_xml(first: index == 0))
        end
        archive.close
      end

      def to_bytes : Bytes
        io = IO::Memory.new
        write(io)
        io.to_slice
      end

      # Builds a workbook from records and a compile-time column list:
      #
      # ```
      # Saci::Office::XLSX.from_records(User.all, columns: [:id, :email, :created_at])
      # ```
      #
      # Columns must be a literal array of symbols so Crystal can call the
      # record methods statically. When the column list is not a literal, the
      # call falls back to `#build_from_records`, which uses `record[column]`
      # (supported by `Saci::Record::Base` and Hash).
      macro from_records(records, columns, sheet_name = "Sheet1", headers = nil)
        {% if columns.is_a?(ArrayLiteral) %}
          {% for column in columns %}
            {% unless column.is_a?(SymbolLiteral) %}
              {% raise "XLSX.from_records columns must be an array literal of symbols (got #{column})" %}
            {% end %}
          {% end %}
          begin
            __saci_office_xlsx = Saci::Office::XLSX.new
            __saci_office_sheet = __saci_office_xlsx.add_sheet({{sheet_name}})
            {% if headers.is_a?(NilLiteral) %}
              __saci_office_sheet.header([
                {% for column in columns %}
                  Saci::Office.humanize({{column.id.stringify}}),
                {% end %}
              ] of String)
            {% else %}
              __saci_office_sheet.header({{headers}})
            {% end %}
            __saci_office_sheet.freeze_panes(rows: 1)
            ({{records}}).each do |__saci_office_record|
              __saci_office_sheet.add_row([
                {% for column in columns %}
                  Saci::Office::XLSX.coerce(__saci_office_record.{{column.id}}),
                {% end %}
              ] of Saci::Office::XLSX::CellValue)
            end
            __saci_office_xlsx
          end
        {% else %}
          Saci::Office::XLSX.build_from_records({{records}}, {{columns}}, sheet_name: {{sheet_name}}, headers: {{headers}})
        {% end %}
      end

      # Runtime variant used by `from_records` when columns are not a literal
      # array. Each record must respond to `[](String | Symbol)`.
      def self.build_from_records(records, columns, sheet_name : String = "Sheet1", headers = nil) : XLSX
        column_list = columns.to_a
        xlsx = new
        sheet = xlsx.add_sheet(sheet_name)
        header_values = if headers
                          headers.to_a.map(&.to_s)
                        else
                          column_list.map { |column| Office.humanize(column.to_s) }
                        end
        sheet.header(header_values)
        sheet.freeze_panes(rows: 1)
        records.each do |record|
          sheet.add_row(column_list.map { |column| coerce(record[column]) })
        end
        xlsx
      end

      private def normalize_sheet_name(name : String) : String
        candidate = name.gsub(/[\[\]:*?\/\\]/, "_")
        candidate = candidate.gsub(/\A'+|'+\z/, "")
        candidate = candidate.strip
        candidate = "Sheet#{@sheets.size + 1}" if candidate.empty?
        candidate = candidate.chars.first(31).join

        base = candidate
        suffix = 2
        while @sheets.any? { |worksheet| worksheet.name.downcase == candidate.downcase }
          marker = " (#{suffix})"
          stem = base.chars.first(31 - marker.size).join
          candidate = "#{stem}#{marker}"
          suffix += 1
        end
        candidate
      end

      private def content_types_xml : String
        String.build do |io|
          io << %(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n)
          io << %(<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\n)
          io << %(<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\n)
          io << %(<Default Extension="xml" ContentType="application/xml"/>\n)
          io << %(<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\n)
          io << %(<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\n)
          @sheets.each_index do |index|
            io << %(<Override PartName="/xl/worksheets/sheet#{index + 1}.xml" )
            io << %(ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>\n)
          end
          io << %(</Types>\n)
        end
      end

      private def root_rels_xml : String
        <<-XML
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        </Relationships>
        XML
      end

      private def workbook_xml : String
        String.build do |io|
          io << %(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n)
          io << %(<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" )
          io << %(xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\n)
          io << %(<bookViews><workbookView xWindow="0" yWindow="0" windowWidth="24000" windowHeight="15000"/></bookViews>\n)
          io << %(<sheets>\n)
          @sheets.each_with_index do |worksheet, index|
            io << %(<sheet name="#{Office.xml_escape(worksheet.name)}" sheetId="#{index + 1}" r:id="rId#{index + 1}"/>\n)
          end
          io << %(</sheets>\n)
          io << %(<calcPr calcId="191029"/>\n)
          io << %(</workbook>\n)
        end
      end

      private def workbook_rels_xml : String
        String.build do |io|
          io << %(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n)
          io << %(<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\n)
          @sheets.each_index do |index|
            io << %(<Relationship Id="rId#{index + 1}" )
            io << %(Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" )
            io << %(Target="worksheets/sheet#{index + 1}.xml"/>\n)
          end
          io << %(<Relationship Id="rId#{@sheets.size + 1}" )
          io << %(Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\n)
          io << %(</Relationships>\n)
        end
      end

      STYLES_XML = <<-XML
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
      <numFmts count="3">
      <numFmt numFmtId="164" formatCode="&quot;$&quot;#,##0.00"/>
      <numFmt numFmtId="165" formatCode="yyyy-mm-dd"/>
      <numFmt numFmtId="166" formatCode="yyyy-mm-dd hh:mm:ss"/>
      </numFmts>
      <fonts count="2">
      <font><sz val="11"/><color theme="1"/><name val="Calibri"/><family val="2"/><scheme val="minor"/></font>
      <font><b/><sz val="11"/><color theme="1"/><name val="Calibri"/><family val="2"/><scheme val="minor"/></font>
      </fonts>
      <fills count="3">
      <fill><patternFill patternType="none"/></fill>
      <fill><patternFill patternType="gray125"/></fill>
      <fill><patternFill patternType="solid"><fgColor rgb="FFD9E1F2"/><bgColor indexed="64"/></patternFill></fill>
      </fills>
      <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
      <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
      <cellXfs count="9">
      <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
      <xf numFmtId="49" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
      <xf numFmtId="1" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
      <xf numFmtId="4" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
      <xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
      <xf numFmtId="10" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
      <xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
      <xf numFmtId="166" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
      <xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/>
      </cellXfs>
      <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
      <dxfs count="0"/>
      <tableStyles count="0" defaultTableStyle="TableStyleMedium2" defaultPivotStyle="PivotStyleLight16"/>
      </styleSheet>
      XML
    end
  end
end
