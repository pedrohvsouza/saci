require "./office/support"
require "./office/zip"
require "./office/csv"
require "./office/xlsx"
require "./office/pdf"
require "./office/controller_helpers"

module Saci
  # Spreadsheet/PDF generation (gap G308).
  #
  # Requiring this single file pulls in:
  # * `Saci::Office::XLSX` — minimal XLSX writer and `from_records`
  # * `Saci::Office::PDF` — Helvetica PDF writer with flowing text/tables
  # * `Saci::Office::CSV` — RFC 4180 writer/parser
  # * `Saci::Controller#send_xlsx` / `#send_pdf` / `#send_csv`
  #
  # Nothing here depends on a third-party shard. The coordinator only needs:
  #
  # ```
  # require "./saci/office"
  # ```
  module Office
  end
end
