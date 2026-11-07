require "base64"
require "json"
require "time"

module Saci
  # Action Mailbox-style inbound email handling.
  #
  # The entry point for the MIME side is `Saci::Mailbox::Message.parse`
  # (aliased as `Saci::Mailbox::Mail`), a focused RFC 822/MIME parser with
  # no external dependencies. It intentionally covers the subset used by
  # inbound email providers: address headers, folded/RFC 2047 headers,
  # `multipart/*` trees, `text/plain` + `text/html` alternatives,
  # quoted-printable/base64 transfer encodings and attachments.
  module Mailbox
    class Error < Exception
    end

    # Raised when raw input cannot be parsed as an email.
    class ParseError < Error
    end

    # RFC 2047 encoded-word + quoted-printable helpers shared by the MIME
    # parser. Kept public so applications can decode provider metadata.
    module HeaderDecoder
      extend self

      # Decodes RFC 2047 encoded-words (`=?UTF-8?B?...?=`, `=?UTF-8?Q?...?=`).
      # Whitespace between adjacent encoded-words is removed, as required by
      # RFC 2047 §6.2. Unknown charsets/encodings pass through untouched.
      def decode(value : String) : String
        return value unless value.includes?("=?")
        # Adjacent encoded words are concatenated without the separating
        # whitespace. The trick keeps the two `?=`/`=?` markers adjacent so
        # the scan below sees both words.
        merged = value.gsub(/\?=\s+=\?/, "?==?")
        merged.gsub(/=\?[^?]+\?[bBqQ]\?[^?]*\?=/) do |word|
          decode_word(word)
        end
      end

      # Decodes a single encoded-word, returning it unchanged on failure.
      def decode_word(word : String) : String
        match = word.match(/\A=\?([^?]+)\?([bBqQ])\?([^?]*)\?=\z/)
        return word unless match
        charset = match[1]
        encoding = match[2].upcase
        payload = match[3]
        bytes = case encoding
                when "B" then Base64.decode(payload)
                when "Q" then decode_q(payload)
                else          return word
                end
        decode_charset(bytes, charset)
      rescue
        word
      end

      # Quoted-printable decoding for MIME bodies (`_` is *not* a space in
      # bodies; that rule only applies to Q encoded-words).
      def decode_quoted_printable(value : String) : String
        # Soft line breaks: `=\n` (or `=\r\n`) is removed; the previous
        # line ending is intentionally not preserved.
        value = value.gsub(/=\r?\n/, "")
        bytes = IO::Memory.new
        i = 0
        while i < value.bytesize
          byte = value.to_slice[i]
          if byte == '='.ord && i + 2 < value.bytesize
            hex = value.to_slice[i + 1, 2]
            begin
              bytes.write_byte(String.new(hex).to_u8(16))
              i += 3
            rescue
              bytes.write_byte(byte)
              i += 1
            end
          else
            bytes.write_byte(byte)
            i += 1
          end
        end
        # Keep the raw bytes: `parse_entity` applies the part's charset
        # afterwards (scrubbing here would destroy Latin-1 bytes).
        String.new(bytes.to_slice)
      end

      # Joins folded header lines and decodes RFC 2047 words. Used by
      # address/subject parsing.
      def unfold(value : String) : String
        value.gsub(/\r?\n[ \t]+/, " ").strip
      end

      # Splits a parameterized header (`text/plain; charset=UTF-8;
      # name="a.txt"`) into its main value and a parameter hash.
      def parse_parameters(value : String) : {String, Hash(String, String)}
        pieces = split_header_pieces(value)
        main = pieces.shift?.try(&.strip) || ""
        params = {} of String => String
        pieces.each do |piece|
          key, sep, raw = piece.partition('=')
          next if sep.empty?
          name = key.strip.downcase
          param = unquote(raw.strip)
          params[name] = param
        end
        # RFC 2231 extended parameters (`filename*=UTF-8''na%C3%AFve.txt`).
        params.each do |key, param|
          next unless key.ends_with?("*")
          base = key[0...-1]
          params[base] = decode_extended_parameter(param)
        end
        {main, params}
      end

      # Percent-decodes an RFC 2231 value (`UTF-8''caf%C3%A9.txt`).
      def decode_extended_parameter(value : String) : String
        # The charset and language prefix are advisory; UTF-8 is assumed.
        payload = if idx = value.index("''")
                    value[(idx + 2)..]
                  elsif idx = value.index("'")
                    # `charset'language'text`
                    rest = value[(idx + 1)..]
                    rest.index("'").try { |i| rest[(i + 1)..] } || rest
                  else
                    value
                  end
        bytes = IO::Memory.new
        i = 0
        while i < payload.bytesize
          byte = payload.to_slice[i]
          if byte == '%'.ord && i + 2 < payload.bytesize
            begin
              bytes.write_byte(String.new(payload.to_slice[i + 1, 2]).to_u8(16))
              i += 3
            rescue
              bytes.write_byte(byte)
              i += 1
            end
          else
            bytes.write_byte(byte)
            i += 1
          end
        end
        String.new(bytes.to_slice).scrub
      end

      private def decode_q(payload : String) : Bytes
        bytes = IO::Memory.new
        i = 0
        while i < payload.bytesize
          byte = payload.to_slice[i]
          if byte == '_'.ord
            bytes.write_byte(' '.ord.to_u8)
            i += 1
          elsif byte == '='.ord && i + 2 < payload.bytesize
            begin
              bytes.write_byte(String.new(payload.to_slice[i + 1, 2]).to_u8(16))
              i += 3
            rescue
              bytes.write_byte(byte)
              i += 1
            end
          else
            bytes.write_byte(byte)
            i += 1
          end
        end
        bytes.to_slice
      end

      # Minimal charset support. UTF-8/ASCII pass through; Latin-1 and
      # Windows-1252 are converted to Unicode code points so `subject`
      # strings stay valid UTF-8. Everything else is treated as UTF-8
      # (scrubbed on invalid bytes).
      def decode_charset(bytes : Bytes, charset : String) : String
        case charset.downcase
        when "utf-8", "utf8", "us-ascii", "ascii", ""
          String.new(bytes).scrub
        when "iso-8859-1", "latin1", "latin-1", "windows-1252", "cp1252"
          String.build do |io|
            bytes.each do |byte|
              codepoint = windows_1252_codepoint(byte)
              io << codepoint.chr
            end
          end
        else
          String.new(bytes).scrub
        end
      end

      # Windows-1252 differs from Latin-1 only in 0x80..0x9F.
      private def windows_1252_codepoint(byte : UInt8) : Int32
        case byte
        when 0x80 then 0x20AC
        when 0x82 then 0x201A
        when 0x83 then 0x0192
        when 0x84 then 0x201E
        when 0x85 then 0x2026
        when 0x86 then 0x2020
        when 0x87 then 0x2021
        when 0x88 then 0x02C6
        when 0x89 then 0x2030
        when 0x8A then 0x0160
        when 0x8B then 0x2039
        when 0x8C then 0x0152
        when 0x8E then 0x017D
        when 0x91 then 0x2018
        when 0x92 then 0x2019
        when 0x93 then 0x201C
        when 0x94 then 0x201D
        when 0x95 then 0x2022
        when 0x96 then 0x2013
        when 0x97 then 0x2014
        when 0x98 then 0x02DC
        when 0x99 then 0x2122
        when 0x9A then 0x0161
        when 0x9B then 0x203A
        when 0x9C then 0x0153
        when 0x9E then 0x017E
        when 0x9F then 0x0178
        else           byte.to_i32
        end
      end

      private def split_header_pieces(value : String) : Array(String)
        pieces = [] of String
        current = IO::Memory.new
        quoted = false
        escaped = false
        value.each_char do |char|
          if escaped
            current << char
            escaped = false
          elsif char == '\\' && quoted
            current << char
            escaped = true
          elsif char == '"'
            quoted = !quoted
            current << char
          elsif char == ';' && !quoted
            pieces << current.to_s
            current = IO::Memory.new
          else
            current << char
          end
        end
        pieces << current.to_s
        pieces
      end

      private def unquote(value : String) : String
        if value.size >= 2 && value.starts_with?('"') && value.ends_with?('"')
          value[1...-1].gsub(/\\(.)/, "\\1")
        else
          value
        end
      end
    end

    # One decoded MIME attachment. `body` is binary-safe (Crystal strings
    # hold arbitrary bytes); use `bytes` when handing it to an IO.
    class Attachment
      getter filename : String?
      getter content_type : String
      getter body : String
      getter content_id : String?
      getter inline : Bool

      def initialize(@filename : String?, @content_type : String, @body : String, @content_id : String? = nil, @inline : Bool = false)
      end

      def bytes : Bytes
        @body.to_slice
      end

      def size : Int32
        @body.bytesize
      end

      def read : String
        @body
      end

      def to_h : Hash(String, JSON::Any)
        {
          "filename"     => JSON::Any.new(@filename),
          "content_type" => JSON::Any.new(@content_type),
          "size"         => JSON::Any.new(@body.bytesize.to_i64),
          "content_id"   => JSON::Any.new(@content_id),
          "inline"       => JSON::Any.new(@inline),
        }
      end
    end

    # A parsed inbound email. Fields are decoded (folded headers unfolded,
    # RFC 2047 words decoded, transfer encodings applied) and safe to read
    # from mailbox code.
    #
    # ```
    # mail = Saci::Mailbox::Message.parse(raw_email)
    # mail.from    # => "support@example.com"
    # mail.to      # => ["inbox@example.com"]
    # mail.subject # => "Re: Hello"
    # mail.text_body
    # mail.html_body
    # mail.attachments.each { |a| puts "#{a.filename} (#{a.content_type})" }
    # ```
    class Message
      ParseError = Saci::Mailbox::ParseError

      getter raw : String
      getter headers : Hash(String, String)
      getter from : String
      getter from_name : String?
      getter to : Array(String)
      getter cc : Array(String)
      getter bcc : Array(String)
      getter reply_to : Array(String)
      getter subject : String
      getter date : Time?
      getter message_id : String
      getter in_reply_to : String?
      getter references : Array(String)
      getter text_body : String
      getter html_body : String?
      getter attachments : Array(Attachment)
      getter content_type : String

      def initialize(@raw : String = "", @headers : Hash(String, String) = {} of String => String,
                     @from : String = "", @from_name : String? = nil,
                     @to : Array(String) = [] of String, @cc : Array(String) = [] of String,
                     @bcc : Array(String) = [] of String, @reply_to : Array(String) = [] of String,
                     @subject : String = "", @date : Time? = nil, @message_id : String = "",
                     @in_reply_to : String? = nil, @references : Array(String) = [] of String,
                     @text_body : String = "", @html_body : String? = nil,
                     @attachments : Array(Attachment) = [] of Attachment,
                     @content_type : String = "text/plain")
      end

      # Raw (unfolded but RFC 2047-decoded) value of one header, if present.
      def header(name : String) : String?
        @headers[name.downcase]?.try { |value| HeaderDecoder.decode(HeaderDecoder.unfold(value)) }
      end

      # Alias for `text_body` (Rails' `mail.body.decoded`-style convenience).
      def body : String
        @text_body
      end

      def has_attachments? : Bool
        !@attachments.empty?
      end

      def attachment(filename : String) : Attachment?
        @attachments.find { |attachment| attachment.filename == filename }
      end

      def to_h : Hash(String, JSON::Any)
        headers = {} of String => JSON::Any
        @headers.each { |key, value| headers[key] = JSON::Any.new(value) }
        {
          "from"         => JSON::Any.new(@from),
          "from_name"    => JSON::Any.new(@from_name),
          "to"           => JSON::Any.new(@to.map { |address| JSON::Any.new(address) }),
          "cc"           => JSON::Any.new(@cc.map { |address| JSON::Any.new(address) }),
          "bcc"          => JSON::Any.new(@bcc.map { |address| JSON::Any.new(address) }),
          "reply_to"     => JSON::Any.new(@reply_to.map { |address| JSON::Any.new(address) }),
          "subject"      => JSON::Any.new(@subject),
          "date"         => JSON::Any.new(@date.try(&.to_rfc3339)),
          "message_id"   => JSON::Any.new(@message_id),
          "in_reply_to"  => JSON::Any.new(@in_reply_to),
          "references"   => JSON::Any.new(@references.map { |reference| JSON::Any.new(reference) }),
          "text_body"    => JSON::Any.new(@text_body),
          "html_body"    => JSON::Any.new(@html_body),
          "content_type" => JSON::Any.new(@content_type),
          "attachments"  => JSON::Any.new(@attachments.map { |attachment| JSON::Any.new(attachment.to_h) }),
          "headers"      => JSON::Any.new(headers),
        }
      end

      # Rebuilds metadata-only mail (used after `InboundEmail#incinerate`
      # removes the raw source). Attachment bodies are unavailable here;
      # filenames/content types/sizes remain in the metadata.
      def self.from_metadata(payload : JSON::Any) : Message
        hash = payload.as_h? || {} of String => JSON::Any
        string = ->(key : String) { hash[key]?.try(&.as_s?) }
        strings = ->(key : String) {
          hash[key]?.try(&.as_a?).try(&.compact_map(&.as_s?)) || [] of String
        }
        headers = {} of String => String
        if raw_headers = hash["headers"]?.try(&.as_h?)
          raw_headers.each { |key, value| headers[key] = value.as_s? || value.to_s }
        end
        attachments = (hash["attachments"]?.try(&.as_a?) || [] of JSON::Any).compact_map do |item|
          data = item.as_h?
          next unless data
          Attachment.new(
            data["filename"]?.try(&.as_s?),
            data["content_type"]?.try(&.as_s?) || "application/octet-stream",
            "",
            data["content_id"]?.try(&.as_s?),
            data["inline"]?.try(&.as_bool?) || false
          )
        end
        date = string.call("date").try { |value| Time.parse_rfc3339(value) rescue nil }
        new(
          headers: headers,
          from: string.call("from") || "",
          from_name: string.call("from_name"),
          to: strings.call("to"),
          cc: strings.call("cc"),
          bcc: strings.call("bcc"),
          reply_to: strings.call("reply_to"),
          subject: string.call("subject") || "",
          date: date,
          message_id: string.call("message_id") || "",
          in_reply_to: string.call("in_reply_to"),
          references: strings.call("references"),
          text_body: string.call("text_body") || "",
          html_body: string.call("html_body"),
          attachments: attachments,
          content_type: string.call("content_type") || "text/plain"
        )
      end

      def self.from_metadata(json : String) : Message
        from_metadata(JSON.parse(json))
      end

      # Parses a raw RFC 822/MIME document. CRLF and bare-LF input are both
      # accepted; header lines are unfolded and MIME parts are flattened
      # into `text_body`/`html_body`/`attachments`.
      def self.parse(raw : String) : Message
        raise ParseError.new("Email source is empty") if raw.strip.empty?
        normalized = raw.gsub("\r\n", "\n").gsub('\r', '\n')
        header_text, body = split_headers_body(normalized)
        headers = parse_headers(header_text)
        content_type, _params = HeaderDecoder.parse_parameters(headers["content-type"]? || "text/plain")
        collector = BodyCollector.new
        parse_entity(headers, body, collector)
        from_addresses, from_name = parse_from(headers["from"]?)
        new(
          raw: raw,
          headers: headers,
          from: from_addresses,
          from_name: from_name,
          to: parse_addresses(headers["to"]?),
          cc: parse_addresses(headers["cc"]?),
          bcc: parse_addresses(headers["bcc"]?),
          reply_to: parse_addresses(headers["reply-to"]?),
          subject: HeaderDecoder.decode(HeaderDecoder.unfold(headers["subject"]? || "")),
          date: parse_date(headers["date"]?),
          message_id: clean_message_id(headers["message-id"]?),
          in_reply_to: optional_message_id(headers["in-reply-to"]?),
          references: parse_references(headers["references"]?),
          text_body: collector.text,
          html_body: collector.html,
          attachments: collector.attachments,
          content_type: content_type.downcase
        )
      end

      # Collects the first text/plain and text/html bodies plus every
      # attachment while walking the MIME tree.
      private class BodyCollector
        property text : String = ""
        property html : String? = nil
        getter attachments : Array(Attachment) = [] of Attachment

        def add_text(value : String) : Nil
          @text = value if @text.empty?
        end

        def add_html(value : String) : Nil
          @html ||= value
        end
      end

      private def self.split_headers_body(text : String) : {String, String}
        if index = text.index("\n\n")
          {text[0...index], text[(index + 2)..]? || ""}
        elsif text.starts_with?("\n")
          {"", text[1..]? || ""}
        else
          {text, ""}
        end
      end

      private def self.parse_headers(text : String) : Hash(String, String)
        headers = {} of String => String
        current_name : String? = nil
        current_value = IO::Memory.new

        flush = -> do
          if name = current_name
            value = current_value.to_s.strip
            if existing = headers[name]?
              headers[name] = existing + ", " + value
            else
              headers[name] = value
            end
          end
          current_name = nil
          current_value = IO::Memory.new
        end

        text.split('\n').each do |line|
          if line.starts_with?(' ') || line.starts_with?('\t')
            current_value << " " << line.strip
            next
          end
          flush.call
          index = line.index(':')
          next unless index
          current_name = line[0...index].strip.downcase
          current_value << line[(index + 1)..].strip
        end
        flush.call
        headers
      end

      private def self.parse_entity(headers : Hash(String, String), body : String, collector : BodyCollector) : Nil
        raw_content_type = headers["content-type"]? || "text/plain"
        content_type, params = HeaderDecoder.parse_parameters(raw_content_type)
        media_type = content_type.downcase.strip
        media_type = "text/plain" if media_type.empty?

        disposition, disposition_params = HeaderDecoder.parse_parameters(headers["content-disposition"]? || "")
        disposition = disposition.downcase.strip
        filename = disposition_params["filename"]? || params["name"]?
        content_id = headers["content-id"]?.try { |value| value.strip.gsub(/\A<|>\z/, "") }

        if media_type.starts_with?("multipart/")
          boundary = params["boundary"]?
          if boundary && !boundary.empty?
            parts = split_multipart(body, boundary)
            unless parts.empty?
              parts.each do |part|
                part_headers, part_body = split_headers_body(part)
                parse_entity(parse_headers(part_headers), part_body, collector)
              end
              return
            end
          end
          # Malformed multipart (missing boundary/delimiters): keep the raw
          # body as text instead of dropping the message.
          collector.add_text(body)
          return
        end

        decoded = decode_body(body, headers["content-transfer-encoding"]?)
        textual = media_type.starts_with?("text/")
        # Text parts are transcoded to UTF-8; binary bodies stay byte-for-byte.
        if textual
          charset = params["charset"]? || "UTF-8"
          decoded = HeaderDecoder.decode_charset(decoded.to_slice, charset)
        end

        # Everything that is not a plain text/html body part is exposed as
        # an attachment (including message/rfc822 and inline images).
        attachment = disposition == "attachment" || !filename.nil? || !textual
        inline = disposition == "inline"

        if attachment
          fallback = case media_type
                     when "message/rfc822" then "message.eml"
                     else                       "attachment"
                     end
          collector.attachments << Attachment.new(filename || fallback, media_type, decoded, content_id, inline)
        elsif media_type == "text/html"
          collector.add_html(decoded)
        elsif media_type == "text/plain"
          collector.add_text(decoded)
        else
          # Unknown non-text, non-attachment parts are exposed as attachments
          # rather than silently discarded.
          collector.attachments << Attachment.new(filename, media_type, decoded, content_id, inline)
        end
      end

      private def self.decode_body(body : String, transfer_encoding : String?) : String
        case transfer_encoding.try(&.downcase.strip)
        when "base64"
          compact = body.gsub(/\s+/, "")
          begin
            Base64.decode_string(compact)
          rescue
            body
          end
        when "quoted-printable"
          HeaderDecoder.decode_quoted_printable(body)
        else
          body
        end
      end

      private def self.split_multipart(body : String, boundary : String) : Array(String)
        marker = "--#{boundary}"
        closing = "#{marker}--"
        parts = [] of String
        current : IO::Memory? = nil
        body.split('\n').each do |line|
          stripped = line.rstrip
          if stripped == marker
            parts << current.to_s if current
            current = IO::Memory.new
          elsif stripped == closing
            parts << current.to_s if current
            current = nil
            break
          elsif buffer = current
            buffer << line << '\n'
          end
          # Lines before the first delimiter are the preamble and ignored.
        end
        parts << current.to_s if current
        # The line break immediately preceding a delimiter belongs to the
        # delimiter, not the part body.
        parts.map { |part| part.ends_with?('\n') ? part[0...-1] : part }
      end

      private def self.parse_from(value : String?) : {String, String?}
        return {"", nil} unless value
        tokens = split_address_list(value)
        return {"", nil} if tokens.empty?
        token = tokens.first
        name = if index = token.index('<')
                 raw_name = token[0...index].strip
                 raw_name = raw_name[1...-1] if raw_name.size >= 2 && raw_name.starts_with?('"') && raw_name.ends_with?('"')
                 decoded = HeaderDecoder.decode(raw_name).strip
                 decoded.empty? ? nil : decoded
               end
        {extract_address(token), name}
      end

      private def self.parse_addresses(value : String?) : Array(String)
        return [] of String unless value
        split_address_list(value).map { |token| extract_address(token) }.reject(&.empty?)
      end

      private def self.extract_address(token : String) : String
        if match = token.match(/<([^<>]+)>/)
          return match[1].strip
        end
        cleaned = token.gsub(/\([^)]*\)/, "").strip
        cleaned = cleaned[1...-1] if cleaned.size >= 2 && cleaned.starts_with?('"') && cleaned.ends_with?('"')
        if match = cleaned.match(/[A-Za-z0-9.!#$%&'*+\/=?^_`{|}~-]+@[A-Za-z0-9.-]+/)
          match[0]
        else
          cleaned
        end
      end

      # Splits a comma-separated address list without breaking on commas
      # inside quoted display names, angle brackets or comments.
      private def self.split_address_list(value : String) : Array(String)
        tokens = [] of String
        current = IO::Memory.new
        quoted = false
        escaped = false
        angle = 0
        paren = 0
        value.each_char do |char|
          if escaped
            current << char
            escaped = false
            next
          end
          case char
          when '\\'
            current << char
            escaped = true if quoted
          when '"'
            quoted = !quoted
            current << char
          when '<'
            angle += 1 unless quoted
            current << char
          when '>'
            angle -= 1 if angle > 0 && !quoted
            current << char
          when '('
            paren += 1 unless quoted
            current << char
          when ')'
            paren -= 1 if paren > 0 && !quoted
            current << char
          when ','
            if quoted || angle > 0 || paren > 0
              current << char
            else
              tokens << current.to_s.strip
              current = IO::Memory.new
            end
          else
            current << char
          end
        end
        tokens << current.to_s.strip
        tokens.reject(&.empty?)
      end

      private def self.clean_message_id(value : String?) : String
        return "" unless value
        cleaned = value.strip
        if match = cleaned.match(/<([^>]+)>/)
          match[1].strip
        else
          cleaned
        end
      end

      private def self.optional_message_id(value : String?) : String?
        cleaned = clean_message_id(value)
        cleaned.empty? ? nil : cleaned
      end

      private def self.parse_references(value : String?) : Array(String)
        return [] of String unless value
        ids = [] of String
        value.scan(/<([^>]+)>/) { |match| ids << match[1].strip }
        if ids.empty?
          value.split(/\s+/).each do |piece|
            cleaned = piece.strip
            ids << cleaned unless cleaned.empty?
          end
        end
        ids
      end

      private def self.parse_date(value : String?) : Time?
        return nil unless value
        cleaned = HeaderDecoder.unfold(value).strip
        begin
          return Time::Format::RFC_2822.parse(cleaned)
        rescue
          # Try the looser patterns below (weekday-less dates and common
          # non-standard provider formats).
        end
        cleaned = cleaned.gsub(/\([^)]*\)/, "").strip
        formats = [
          "%d %b %Y %H:%M:%S %z",
          "%a, %d %b %Y %H:%M:%S %z",
          "%d %b %Y %H:%M:%S %Z",
          "%a, %d %b %y %H:%M:%S %z",
        ]
        formats.each do |format|
          begin
            return Time.parse(cleaned, format, Time::Location::UTC)
          rescue
            # Try the next format.
          end
        end
        nil
      end
    end

    # Rails' `Mail::Message` counterpart; a short alias for application code.
    alias Mail = Message
  end
end
