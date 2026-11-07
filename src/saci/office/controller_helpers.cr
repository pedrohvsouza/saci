require "../exceptions"
require "../params"
require "../controller"
require "./xlsx"
require "./pdf"

module Saci
  # Download helpers for office documents. Reopening `Saci::Controller` here
  # keeps the core controller free of document-generation dependencies; the
  # methods simply delegate to the existing `send_data`.
  class Controller
    # Sends an XLSX workbook with the correct MIME type and a download
    # filename. The filename is sanitized before going into the header.
    def send_xlsx(xlsx : Office::XLSX, filename : String = "export.xlsx",
                  disposition : String = "attachment") : Nil
      send_xlsx(xlsx.to_bytes, filename, disposition)
    end

    def send_xlsx(data : Bytes, filename : String = "export.xlsx",
                  disposition : String = "attachment") : Nil
      safe_name = Office.safe_filename(filename, "export.xlsx")
      send_data(data, safe_name, content_type: Office::XLSX::CONTENT_TYPE, disposition: disposition)
    end

    def send_pdf(pdf : Office::PDF, filename : String = "export.pdf",
                 disposition : String = "attachment") : Nil
      send_pdf(pdf.to_bytes, filename, disposition)
    end

    def send_pdf(data : Bytes, filename : String = "export.pdf",
                 disposition : String = "attachment") : Nil
      safe_name = Office.safe_filename(filename, "export.pdf")
      send_data(data, safe_name, content_type: Office::PDF::CONTENT_TYPE, disposition: disposition)
    end

    # Sends CSV generated from *rows* (RFC 4180). Useful for the "export as
    # CSV" companion to a spreadsheet view.
    def send_csv(rows : Enumerable, filename : String = "export.csv",
                 disposition : String = "attachment") : Nil
      safe_name = Office.safe_filename(filename, "export.csv")
      send_data(Office::CSV.generate(rows), safe_name,
        content_type: "text/csv; charset=utf-8", disposition: disposition)
    end
  end
end
