require "spec"
require "digest/crc32"
require "compress/deflate"
require "../src/saci"
require "../src/saci/office"

# -- helpers ---------------------------------------------------------------

OFFICE_SPEC_TMP = "/tmp/opencode"
Dir.mkdir_p(OFFICE_SPEC_TMP)

def office_tool?(name : String) : Bool
  Process.run("which", [name], output: IO::Memory.new, error: IO::Memory.new).success?
end

def office_find_bytes(bytes : Bytes, needle : String) : Int32
  target = needle.to_slice
  return -1 if target.size > bytes.size
  (0..(bytes.size - target.size)).each do |index|
    return index if bytes[index, target.size] == target
  end
  -1
end

def office_bytes_include?(bytes : Bytes, needle : String) : Bool
  office_find_bytes(bytes, needle) >= 0
end

# Parsed subset of one central-directory entry, enough to validate the ZIP
# contract (name, method, sizes, checksum, local-header offset).
struct OfficeSpecZipEntry
  getter name : String
  getter crc32 : UInt32
  getter method : UInt16
  getter compressed_size : UInt32
  getter size : UInt32
  getter local_offset : UInt32

  def initialize(@name, @crc32, @method, @compressed_size, @size, @local_offset)
  end
end

def office_zip_u16(io : IO) : UInt16
  io.read_bytes(UInt16, IO::ByteFormat::LittleEndian)
end

def office_zip_u32(io : IO) : UInt32
  io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
end

def office_zip_entries(bytes : Bytes) : Array(OfficeSpecZipEntry)
  io = IO::Memory.new(bytes)
  raise "ZIP too small" if bytes.size < 22
  io.pos = bytes.size - 22
  raise "missing EOCD" unless office_zip_u32(io) == 0x06054b50_u32
  office_zip_u16(io) # disk number
  office_zip_u16(io) # central directory disk
  office_zip_u16(io) # entries on disk
  entry_count = office_zip_u16(io)
  office_zip_u32(io) # central directory size
  central_offset = office_zip_u32(io)
  office_zip_u16(io) # comment length

  io.pos = central_offset
  entries = [] of OfficeSpecZipEntry
  entry_count.times do
    raise "missing central header" unless office_zip_u32(io) == 0x02014b50_u32
    office_zip_u16(io) # version made by
    office_zip_u16(io) # version needed
    office_zip_u16(io) # flags
    method = office_zip_u16(io)
    office_zip_u16(io) # time
    office_zip_u16(io) # date
    crc = office_zip_u32(io)
    compressed_size = office_zip_u32(io)
    size = office_zip_u32(io)
    name_length = office_zip_u16(io)
    extra_length = office_zip_u16(io)
    comment_length = office_zip_u16(io)
    office_zip_u16(io) # disk start
    office_zip_u16(io) # internal attributes
    office_zip_u32(io) # external attributes
    local_offset = office_zip_u32(io)
    name = io.read_string(name_length)
    io.pos += extra_length.to_i + comment_length.to_i
    entries << OfficeSpecZipEntry.new(name, crc, method, compressed_size, size, local_offset)
  end
  entries
end

def office_zip_payload(bytes : Bytes, entry : OfficeSpecZipEntry) : Bytes
  io = IO::Memory.new(bytes)
  io.pos = entry.local_offset
  raise "missing local header for #{entry.name}" unless office_zip_u32(io) == 0x04034b50_u32
  office_zip_u16(io) # version
  office_zip_u16(io) # flags
  method = office_zip_u16(io)
  office_zip_u16(io) # time
  office_zip_u16(io) # date
  office_zip_u32(io) # crc
  office_zip_u32(io) # compressed size
  office_zip_u32(io) # size
  name_length = office_zip_u16(io)
  extra_length = office_zip_u16(io)
  local_name = io.read_string(name_length)
  io.pos += extra_length.to_i
  raise "local/central name mismatch for #{entry.name}" unless local_name == entry.name
  raise "local/central method mismatch for #{entry.name}" unless method == entry.method

  compressed = Bytes.new(entry.compressed_size)
  io.read_fully(compressed)
  if entry.method == 0
    compressed
  elsif entry.method == 8
    Compress::Deflate::Reader.new(IO::Memory.new(compressed)).gets_to_end.to_slice
  else
    raise "unsupported ZIP method #{entry.method}"
  end
end

def office_zip_entry(bytes : Bytes, name : String) : OfficeSpecZipEntry
  office_zip_entries(bytes).find { |entry| entry.name == name } ||
    raise "missing ZIP entry #{name}"
end

def office_zip_text(bytes : Bytes, name : String) : String
  entry = office_zip_entry(bytes, name)
  String.new(office_zip_payload(bytes, entry))
end

# Returns the parsed xref offsets (entry 0 is the free-list entry).
def office_pdf_xref_offsets(bytes : Bytes) : Array(Int64)
  marker = office_find_bytes(bytes, "startxref")
  raise "missing startxref" if marker < 0
  index = marker + "startxref".bytesize
  index += 1
  while index < bytes.size && (bytes[index] == 0x20 || bytes[index] == 0x0A || bytes[index] == 0x0D)
    index += 1
  end
  offset = 0_i64
  while index < bytes.size && bytes[index] >= 0x30 && bytes[index] <= 0x39
    offset = offset * 10 + (bytes[index] - 0x30)
    index += 1
  end

  io = IO::Memory.new(bytes)
  io.pos = offset
  raise "startxref does not point at xref" unless io.gets('\n').try(&.strip) == "xref"
  header = io.gets('\n').not_nil!.strip.split(' ')
  count = header[1].to_i
  offsets = [] of Int64
  count.times do
    line = io.gets('\n').not_nil!.strip.split(' ')
    offsets << line[0].to_i64
  end
  offsets
end

def office_pdf_text(bytes : Bytes) : String
  String.new(bytes)
end

# -- CRC32 / ZIP -----------------------------------------------------------

describe "Saci::Office::CRC32 and ZIP" do
  it "computes the standard CRC-32 test vector" do
    Saci::Office::CRC32.checksum("123456789").should eq(0xCBF43926_u32)
    Saci::Office::CRC32.checksum("").should eq(0_u32)
  end

  it "writes a valid STORE archive with central-directory offsets and CRCs" do
    bytes = Saci::Office::ZIP::Writer.build(:store) do |zip|
      zip.add_file("a.txt", "hello")
      zip.add_file("nested/b.txt", "world\n")
    end

    entries = office_zip_entries(bytes)
    entries.map(&.name).should eq(["a.txt", "nested/b.txt"])
    entries.each do |entry|
      payload = office_zip_payload(bytes, entry)
      String.new(payload).should eq(entry.name == "a.txt" ? "hello" : "world\n")
      Digest::CRC32.checksum(payload).should eq(entry.crc32)
      entry.method.should eq(0_u16)
    end
  end

  it "writes a valid DEFLATE archive" do
    source = "compress me " * 100
    bytes = Saci::Office::ZIP::Writer.build(:deflate) do |zip|
      zip.add_file("data.txt", source)
    end
    entry = office_zip_entry(bytes, "data.txt")
    entry.method.should eq(8_u16)
    entry.compressed_size.should be < entry.size
    String.new(office_zip_payload(bytes, entry)).should eq(source)
    Digest::CRC32.checksum(source.to_slice).should eq(entry.crc32)
  end
end

# -- XLSX ------------------------------------------------------------------

describe "Saci::Office::XLSX" do
  it "builds a multi-sheet package with typed cells, widths, filters and frozen panes" do
    workbook = Saci::Office::XLSX.new
    sales = workbook.add_sheet("Sales")
    sales.header(["Region", "Amount", "Closed", "Active", "Date", "Note"])
    sales.add_row(["North & South", 1200_i64, true, false, Time.utc(2024, 5, 6), "a < b"])
    sales.add_row(["Zoë", 12.5, false, true, Time.utc(2024, 5, 6, 12, 30), nil])
    sales.column_widths(22, 12, 8)
    sales.freeze_panes(rows: 1, columns: 1)
    sales.auto_filter = true

    notes = workbook.add_sheet("Notes")
    notes.add_row(["Hello", "world"])

    bytes = workbook.to_bytes
    entries = office_zip_entries(bytes)
    names = entries.map(&.name)
    names.should contain("[Content_Types].xml")
    names.should contain("_rels/.rels")
    names.should contain("xl/workbook.xml")
    names.should contain("xl/_rels/workbook.xml.rels")
    names.should contain("xl/styles.xml")
    names.should contain("xl/worksheets/sheet1.xml")
    names.should contain("xl/worksheets/sheet2.xml")

    # Every entry's CRC and uncompressed size must agree with its payload.
    entries.each do |entry|
      payload = office_zip_payload(bytes, entry)
      Digest::CRC32.checksum(payload).should eq(entry.crc32)
      payload.size.should eq(entry.size)
    end

    sheet = office_zip_text(bytes, "xl/worksheets/sheet1.xml")
    sheet.should contain(%(<dimension ref="A1:F3"/>))
    sheet.should contain(%(<pane xSplit="1" ySplit="1" topLeftCell="B2" activePane="bottomRight" state="frozen"/>))
    sheet.should contain(%(<col min="1" max="1" width="22" customWidth="1"/>))
    sheet.should contain(%(<autoFilter ref="A1:F3"/>))
    sheet.should contain(%(t="inlineStr"><is><t>North &amp; South</t>))
    sheet.should contain(%(t="inlineStr"><is><t>a &lt; b</t>))
    sheet.should contain(%(<c r="B2"><v>1200</v></c>))
    sheet.should contain(%(<c r="B3"><v>12.5</v></c>))
    sheet.should contain(%(<c r="C2" t="b"><v>1</v></c>))
    sheet.should contain(%(<c r="D2" t="b"><v>0</v></c>))
    sheet.should contain(%(<c r="E2" s="6"><v>45418</v></c>))        # date
    sheet.should contain(%(<c r="E3" s="7"><v>45418.520833</v></c>)) # datetime
    sheet.should contain(%(<c r="A1" s="8" t="inlineStr">))          # header style

    workbook_xml = office_zip_text(bytes, "xl/workbook.xml")
    workbook_xml.should contain(%(<sheet name="Sales" sheetId="1" r:id="rId1"/>))
    workbook_xml.should contain(%(<sheet name="Notes" sheetId="2" r:id="rId2"/>))
    rels = office_zip_text(bytes, "xl/_rels/workbook.xml.rels")
    rels.should contain(%(Target="worksheets/sheet2.xml"))
    rels.should contain(%(Target="styles.xml"))

    content_types = office_zip_text(bytes, "[Content_Types].xml")
    content_types.should contain(%(PartName="/xl/workbook.xml"))
    content_types.should contain(%(PartName="/xl/worksheets/sheet2.xml"))
    content_types.should contain(%(PartName="/xl/styles.xml"))
    office_zip_text(bytes, "_rels/.rels").should contain(%(Target="xl/workbook.xml"))

    if office_tool?("unzip")
      path = File.join(OFFICE_SPEC_TMP, "saci_office_xlsx_spec.xlsx")
      File.write(path, bytes)
      output = IO::Memory.new
      status = Process.run("unzip", ["-t", path], output: output, error: output)
      status.success?.should be_true
      File.delete(path)
    end
  end

  it "supports STORE compression and validates with unzip" do
    workbook = Saci::Office::XLSX.new(compression: :store)
    workbook.add_sheet("Plain").add_row(["ok", 1])
    bytes = workbook.to_bytes
    office_zip_entries(bytes).each { |entry| entry.method.should eq(0_u16) }

    if office_tool?("unzip")
      path = File.join(OFFICE_SPEC_TMP, "saci_office_xlsx_store_spec.xlsx")
      File.write(path, bytes)
      output = IO::Memory.new
      status = Process.run("unzip", ["-t", path], output: output, error: output)
      status.success?.should be_true
      File.delete(path)
    end
  end

  it "applies explicit number, currency, percent, text and date formats" do
    workbook = Saci::Office::XLSX.new
    sheet = workbook.add_sheet("Formats")
    sheet.add_row(
      [12.5, 0.25, 7, "0042"],
      formats: [
        Saci::Office::XLSX::CellFormat::Currency,
        Saci::Office::XLSX::CellFormat::Percent,
        Saci::Office::XLSX::CellFormat::Integer,
        Saci::Office::XLSX::CellFormat::Text,
      ],
    )
    sheet.set_cell(2, 1, Time.utc(2024, 1, 1), Saci::Office::XLSX::CellFormat::Date)
    xml = office_zip_text(workbook.to_bytes, "xl/worksheets/sheet1.xml")
    xml.should contain(%(<c r="A1" s="4"><v>12.5</v></c>))
    xml.should contain(%(<c r="B1" s="5"><v>0.25</v></c>))
    xml.should contain(%(<c r="C1" s="2"><v>7</v></c>))
    xml.should contain(%(<c r="D1" s="1" t="inlineStr"><is><t>0042</t></is></c>))
    xml.should contain(%(<c r="A2" s="6"><v>45292</v></c>))
  end

  it "sanitizes and de-duplicates sheet names" do
    workbook = Saci::Office::XLSX.new
    workbook.add_sheet("Bad/Name[1]")
    workbook.add_sheet("Bad/Name[1]")
    workbook.add_sheet("A" * 40)
    workbook.sheets.map(&.name).should eq(["Bad_Name_1_", "Bad_Name_1_ (2)", "A" * 31])
  end

  it "builds a sheet from records with compile-time columns" do
    people = [
      OfficeSpecPerson.new("Ada", 36, Time.utc(2020, 1, 2)),
      OfficeSpecPerson.new("Grace", 85, Time.utc(1959, 1, 1)),
    ]
    workbook = Saci::Office::XLSX.from_records(people, columns: [:name, :age, :joined])
    xml = office_zip_text(workbook.to_bytes, "xl/worksheets/sheet1.xml")

    xml.should contain(%(<t>Name</t>))
    xml.should contain(%(<t>Age</t>))
    xml.should contain(%(<t>Joined</t>))
    xml.should contain(%(<t>Ada</t>))
    xml.should contain(%(<v>36</v>))
    xml.should contain(%(ySplit="1"))
  end

  it "supports explicit headers and a runtime column list" do
    people = [OfficeSpecPerson.new("Ada", 36, Time.utc(2020, 1, 2))]
    custom = Saci::Office::XLSX.from_records(people, columns: [:name, :age],
      headers: ["Full name", "Years"])
    xml = office_zip_text(custom.to_bytes, "xl/worksheets/sheet1.xml")
    xml.should contain(%(<t>Full name</t>))
    xml.should contain(%(<t>Years</t>))

    columns = ["name", "age"]
    hashes = [{"name" => "Ada", "age" => 36}]
    runtime = Saci::Office::XLSX.from_records(hashes, columns: columns)
    runtime_xml = office_zip_text(runtime.to_bytes, "xl/worksheets/sheet1.xml")
    runtime_xml.should contain(%(<t>Name</t>))
    runtime_xml.should contain(%(<t>Ada</t>))
    runtime_xml.should contain(%(<v>36</v>))
  end
end

struct OfficeSpecPerson
  getter name : String
  getter age : Int32
  getter joined : Time

  def initialize(@name, @age, @joined)
  end
end

# -- CSV -------------------------------------------------------------------

describe "Saci::Office::CSV" do
  it "quotes fields per RFC 4180" do
    csv = Saci::Office::CSV.generate([
      ["name", "note"],
      ["Ada", "a, b"],
      ["Quote", "a\"b"],
      ["Multi", "line\nbreak"],
      ["Space", " padded "],
      ["Empty", nil],
    ])
    csv.should eq(%(name,note\r\nAda,"a, b"\r\nQuote,"a""b"\r\nMulti,"line\nbreak"\r\nSpace," padded "\r\nEmpty,\r\n))
  end

  it "parses quoted fields, escaped quotes and embedded newlines" do
    rows = Saci::Office::CSV.parse(%(a,b\r\n"x,y","he said ""hi"""\r\n"multi\nline",z\r\n))
    rows.should eq([
      ["a", "b"],
      ["x,y", %(he said "hi")],
      ["multi\nline", "z"],
    ])
  end

  it "streams rows to an IO and to a file" do
    io = IO::Memory.new
    Saci::Office::CSV::Writer.open(io) do |writer|
      writer << ["a", "b"]
      writer << ["1", "2"]
    end
    io.to_s.should eq("a,b\r\n1,2\r\n")

    path = File.join(OFFICE_SPEC_TMP, "saci_office_csv_spec.csv")
    Saci::Office::CSV.write(path, [["x", "y"], ["3", "4"]])
    File.read(path).should eq("x,y\r\n3,4\r\n")
    File.delete(path)
  end
end

# -- PDF -------------------------------------------------------------------

describe "Saci::Office::PDF" do
  it "writes a valid PDF with text, tables and page breaks" do
    pdf = Saci::Office::PDF.new(title: "Sales report", author: "Saci", footer: "Page {page} of {total}")
    pdf.heading("Sales report")
    pdf.paragraph("A long paragraph that must wrap over several lines. " * 6)
    pdf.draw_text("At coords", 100, 700, size: 14, font: :bold)
    rows = (1..80).map { |index| ["Region #{index}", "Description #{index} with enough text to wrap", index] }
    pdf.table(
      headers: ["Region", "Description", "Count"],
      rows: rows,
      column_widths: [110, 260, 70],
      header_fill: {0.9, 0.93, 0.97},
    )

    pdf.page_count.should be >= 2
    bytes = pdf.to_bytes

    String.new(bytes[0, 8]).should eq("%PDF-1.4")
    office_bytes_include?(bytes, "%%EOF").should be_true
    office_bytes_include?(bytes, "/Type /Catalog").should be_true
    office_bytes_include?(bytes, "/Type /Pages").should be_true
    office_bytes_include?(bytes, "/Type /Page ").should be_true
    office_bytes_include?(bytes, "/MediaBox [0 0 595.28 841.89]").should be_true
    office_bytes_include?(bytes, "/BaseFont /Helvetica").should be_true
    office_bytes_include?(bytes, "(Sales report) Tj").should be_true
    office_bytes_include?(bytes, "(Region 1) Tj").should be_true
    office_bytes_include?(bytes, "100 700 Td\n(At coords) Tj").should be_true
    office_bytes_include?(bytes, "/F2 14 Tf").should be_true
    # Header shading fill and grid strokes are present.
    office_bytes_include?(bytes, "0.9 0.93 0.97 rg").should be_true
    office_bytes_include?(bytes, " re\n").should be_true
    office_bytes_include?(bytes, " RG\n").should be_true
    # Repeated table headers and page footer.
    office_bytes_include?(bytes, "(Page 2 of ").should be_true

    offsets = office_pdf_xref_offsets(bytes)
    offsets.size.should be > 1
    (1...offsets.size).each do |object_number|
      object_offset = offsets[object_number].to_i
      prefix = String.new(bytes[object_offset, Math.min(24, bytes.size - object_offset)])
      prefix.starts_with?("#{object_number} 0 obj").should be_true
    end

    path = File.join(OFFICE_SPEC_TMP, "saci_office_pdf_spec.pdf")
    pdf.write(path)
    File.size(path).should be > 1000

    if office_tool?("pdfinfo")
      output = IO::Memory.new
      status = Process.run("pdfinfo", [path], output: output, error: output)
      status.success?.should be_true
      output.to_s.match(/Pages:\s+#{pdf.page_count}\b/).should_not be_nil
      output.to_s.match(/PDF version:\s+1\.4/).should_not be_nil
    end

    if office_tool?("pdftotext")
      output = IO::Memory.new
      status = Process.run("pdftotext", [path, "-"], output: output, error: output)
      status.success?.should be_true
      text = output.to_s
      text.should contain("Sales report")
      text.should contain("Region 1")
      text.should contain("Region 80")
    end

    File.delete(path)
  end

  it "provides a one-shot table document" do
    pdf = Saci::Office::PDF.table(
      title: "Users",
      headers: ["Name", "Email"],
      rows: [["Ada", "ada@example.com"], ["Grace", "grace@example.com"]],
    )
    pdf.page_count.should eq(1)
    bytes = pdf.to_bytes
    pdf.to_bytes.size.should eq(bytes.size)
    office_bytes_include?(bytes, "(Users) Tj").should be_true
    office_bytes_include?(bytes, "(ada@example.com) Tj").should be_true
  end

  it "wraps long words and preserves explicit newlines" do
    pdf = Saci::Office::PDF.new
    lines = pdf.wrap_text("abcdefghij\nsecond paragraph", 200, 10)
    lines.should eq(["abcdefghij", "second paragraph"])

    long_word = pdf.wrap_text("abcdefghijklmnopqrstuvwxyz", 30, 10)
    long_word.size.should be > 1
    long_word.join.should eq("abcdefghijklmnopqrstuvwxyz")
    pdf.text_width("abc", 10).should be > 0
  end
end

# -- Controller integration ------------------------------------------------

class OfficeSpecDownloadsController < Saci::Controller
  def xlsx
    workbook = Saci::Office::XLSX.new
    workbook.add_sheet("Data").add_row(["ok", 1])
    send_xlsx(workbook, filename: "report.xlsx")
  end

  def pdf
    pdf = Saci::Office::PDF.new(title: "Download")
    pdf.draw_text("Hello", 50, 700)
    send_pdf(pdf, filename: "../evil.pdf")
  end

  def csv
    send_csv([["a", "b"], ["1", "2"]], filename: "data.csv")
  end
end

def office_download(action : Symbol) : Tuple(HTTP::Headers, Int64, String)
  memory = IO::Memory.new
  response = HTTP::Server::Response.new(memory)
  request = HTTP::Request.new("GET", "/office-download")
  context = HTTP::Server::Context.new(request, response)
  params = Saci::Params.build(request, {} of String => String)
  controller = OfficeSpecDownloadsController.new(context, params, action)
  controller.call_action(action)
  response.close
  {response.headers, response.content_length || 0_i64, memory.to_s}
end

describe "Saci::Controller office downloads" do
  it "sends XLSX with the right MIME type and filename" do
    headers, length, body = office_download(:xlsx)
    headers["Content-Type"].should eq(Saci::Office::XLSX::CONTENT_TYPE)
    headers["Content-Disposition"].should eq(%(attachment; filename="report.xlsx"))
    length.should be > 0
    body.should contain("PK")
  end

  it "sends PDF and sanitizes the download filename" do
    headers, length, body = office_download(:pdf)
    headers["Content-Type"].should eq("application/pdf")
    headers["Content-Disposition"].should eq(%(attachment; filename="evil.pdf"))
    length.should be > 0
    body.should contain("%PDF-1.4")
  end

  it "sends CSV with a UTF-8 content type" do
    headers, _length, body = office_download(:csv)
    headers["Content-Type"].should eq("text/csv; charset=utf-8")
    headers["Content-Disposition"].should eq(%(attachment; filename="data.csv"))
    body.should contain("a,b\r\n1,2\r\n")
  end
end
