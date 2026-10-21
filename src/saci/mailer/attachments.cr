require "base64"
require "json"
require "uri"

module Saci
  module Mailer
    # Raised when an attachment would exceed the configured size limits.
    class AttachmentTooLarge < ArgumentError
    end

    # A single MIME attachment. Content is always stored as bytes so binary
    # files (images, PDFs, ...) survive `to_mime` and the JSON payload used by
    # `deliver_later` without an encoding round-trip in user code.
    class Attachment
      getter filename : String
      getter mime_type : String
      getter content : Bytes
      getter content_id : String?

      def initialize(@filename : String, content : Bytes | String, mime_type : String? = nil,
                     @inline : Bool = false, @content_id : String? = nil)
        raise ArgumentError.new("attachment filename is required") if @filename.strip.empty?
        bytes = content.is_a?(String) ? content.to_slice : content
        @content = bytes.dup
        @mime_type = mime_type || Mailer.mime_type_for(@filename)
        # Inline parts need a Content-ID for `cid:` references. Make the
        # filename the default so templates can use the obvious value (fall
        # back to an ASCII-safe name for non-ASCII filenames).
        @content_id = @inline ? (@content_id || (@filename.ascii_only? ? @filename : ascii_fallback)) : @content_id
        validate_size!
      end

      def inline? : Bool
        @inline
      end

      def size : Int32
        @content.size
      end

      def bytesize : Int32
        @content.size
      end

      # Wrapped at 76 columns (RFC 2045).
      def encoded_content : String
        encoded = Base64.strict_encode(@content)
        String.build do |io|
          i = 0
          while i < encoded.size
            io << encoded[i, 76] << "\r\n"
            i += 76
          end
        end
      end

      # `Content-Disposition` with RFC 2231 filename encoding for non-ASCII
      # names. A conservative ASCII fallback is emitted for old clients.
      def content_disposition : String
        kind = @inline ? "inline" : "attachment"
        if @filename.ascii_only?
          %(#{kind}; filename="#{escape_quoted(@filename)}")
        else
          %(#{kind}; filename="#{escape_quoted(ascii_fallback)}"; filename*=UTF-8''#{rfc2231_encode(@filename)})
        end
      end

      # `Content-Type`. The `name=` parameter mirrors Content-Disposition.
      def content_type : String
        if @filename.ascii_only?
          %(#{@mime_type}; name="#{escape_quoted(@filename)}")
        else
          %(#{@mime_type}; name="#{escape_quoted(ascii_fallback)}"; name*=UTF-8''#{rfc2231_encode(@filename)})
        end
      end

      def to_h : Hash(String, JSON::Any)
        {
          "filename"   => JSON::Any.new(@filename),
          "mime_type"  => JSON::Any.new(@mime_type),
          "content"    => JSON::Any.new(Base64.strict_encode(@content)),
          "inline"     => JSON::Any.new(@inline),
          "content_id" => JSON::Any.new(@content_id),
        }
      end

      def self.from_h(hash : Hash(String, JSON::Any)) : Attachment
        content = hash["content"]?.try(&.as_s?) || ""
        new(
          hash["filename"]?.try(&.as_s?) || "attachment",
          Base64.decode(content),
          hash["mime_type"]?.try(&.as_s?),
          inline: hash["inline"]?.try(&.as_bool?) || false,
          content_id: hash["content_id"]?.try(&.as_s?)
        )
      end

      def self.from_json_any(value : JSON::Any) : Attachment
        h = value.as_h? || raise ArgumentError.new("invalid attachment payload")
        from_h(h)
      end

      private def validate_size! : Nil
        limit = Mailer.max_attachment_size
        if limit > 0 && @content.size.to_i64 > limit
          raise AttachmentTooLarge.new("attachment #{@filename.inspect} is #{@content.size} bytes (limit #{limit})")
        end
      end

      private def escape_quoted(value : String) : String
        value.gsub(/[\r\n]/, " ").gsub('\\', "\\\\").gsub('"', "\\\"")
      end

      private def ascii_fallback : String
        fallback = @filename.each_char.map { |ch| ch.ascii? && ch != '"' && ch != '\\' ? ch : '_' }.join
        fallback.empty? ? "attachment" : fallback
      end

      private def rfc2231_encode(value : String) : String
        String.build do |io|
          value.each_byte do |byte|
            char = byte.unsafe_chr
            if char.ascii_alphanumeric? || char.in?('-', '.', '_', '~')
              io << char
            else
              io << '%' << byte.to_s(16).rjust(2, '0').upcase
            end
          end
        end
      end
    end

    # Ordered attachment collection with Rails-like assignment syntax:
    #
    # ```
    # attachments["report.pdf"] = {mime_type: "application/pdf", path: path}
    # attachments["notes.txt"] = "hello"
    # attachments.inline["logo.png"] = {mime_type: "image/png", content: png}
    # ```
    #
    # Re-assigning the same filename replaces the previous entry (dedupe).
    # `inline` returns a lightweight view over the same collection, so inline
    # and regular attachments preserve insertion order together.
    class Attachments
      include Enumerable(Attachment)

      def initialize(@items : Array(Attachment) = [] of Attachment, @inline_default : Bool = false)
      end

      def inline : Attachments
        Attachments.new(@items, true)
      end

      def inline? : Bool
        @inline_default
      end

      def each(& : Attachment ->) : Nil
        @items.each { |item| yield item }
      end

      def size : Int32
        @items.size
      end

      def empty? : Bool
        @items.empty?
      end

      def to_a : Array(Attachment)
        @items.dup
      end

      def filenames : Array(String)
        @items.map(&.filename)
      end

      def [](filename : String) : Attachment
        self[filename]? || raise KeyError.new("attachment not found: #{filename}")
      end

      def [](index : Int32) : Attachment
        @items[index]
      end

      def []?(filename : String) : Attachment?
        @items.find { |item| item.filename == filename }
      end

      def []?(index : Int32) : Attachment?
        @items[index]?
      end

      def add(attachment : Attachment) : Attachment
        index = @items.index { |item| item.filename == attachment.filename }
        previous = index ? @items[index] : nil
        total = @items.sum(&.size.to_i64) - (previous ? previous.size.to_i64 : 0_i64) + attachment.size
        limit = Mailer.max_total_attachment_size
        if limit > 0 && total > limit
          raise AttachmentTooLarge.new("total attachment size #{total} bytes exceeds limit #{limit}")
        end
        if index
          @items[index] = attachment
        else
          @items << attachment
        end
        attachment
      end

      def add(filename : String, content : Bytes | String, mime_type : String? = nil,
              inline : Bool = false, content_id : String? = nil) : Attachment
        add(Attachment.new(filename, content, mime_type, inline: inline, content_id: content_id))
      end

      def add(filename : String, *, path : String, mime_type : String? = nil,
              inline : Bool = false, content_id : String? = nil) : Attachment
        add(Attachment.new(filename, Attachments.read_path(path), mime_type, inline: inline, content_id: content_id))
      end

      def []=(filename : String, value : NamedTuple(mime_type: String, content: String | Bytes)) : Nil
        add(filename, value[:content], value[:mime_type], inline: @inline_default)
      end

      def []=(filename : String, value : NamedTuple(mime_type: String, content: String | Bytes, content_id: String)) : Nil
        add(filename, value[:content], value[:mime_type], inline: @inline_default, content_id: value[:content_id])
      end

      def []=(filename : String, value : NamedTuple(mime_type: String, path: String)) : Nil
        add(filename, path: value[:path], mime_type: value[:mime_type], inline: @inline_default)
      end

      def []=(filename : String, value : NamedTuple(content: String | Bytes)) : Nil
        add(filename, value[:content], inline: @inline_default)
      end

      def []=(filename : String, value : NamedTuple(content: String | Bytes, content_id: String)) : Nil
        add(filename, value[:content], inline: @inline_default, content_id: value[:content_id])
      end

      def []=(filename : String, value : NamedTuple(path: String)) : Nil
        add(filename, path: value[:path], inline: @inline_default)
      end

      def []=(filename : String, value : String | Bytes) : Nil
        add(filename, value, inline: @inline_default)
      end

      # Hash form (string or symbol keys), handy when options are built
      # dynamically:
      #   attachments["a.pdf"] = {"mime_type" => "application/pdf", "content" => body}
      def []=(filename : String, value : Hash(String, String)) : Nil
        add(filename, value["content"]? || "", value["mime_type"]? || value["content_type"]?,
          inline: @inline_default, content_id: value["content_id"]?)
      end

      def []=(filename : String, value : Hash(Symbol, String)) : Nil
        add(filename, value[:content]? || "", value[:mime_type]? || value[:content_type]?,
          inline: @inline_default, content_id: value[:content_id]?)
      end

      def valid? : Bool
        total = @items.sum(&.size.to_i64)
        limit = Mailer.max_total_attachment_size
        limit <= 0 || total <= limit
      end

      def self.read_path(path : String) : Bytes
        File.open(path, "rb") { |file| file.getb_to_end }
      end
    end

    MIME_TYPES = {
      "txt"  => "text/plain",
      "html" => "text/html",
      "htm"  => "text/html",
      "css"  => "text/css",
      "csv"  => "text/csv",
      "json" => "application/json",
      "xml"  => "application/xml",
      "pdf"  => "application/pdf",
      "zip"  => "application/zip",
      "png"  => "image/png",
      "jpg"  => "image/jpeg",
      "jpeg" => "image/jpeg",
      "gif"  => "image/gif",
      "webp" => "image/webp",
      "svg"  => "image/svg+xml",
      "ico"  => "image/x-icon",
      "mp3"  => "audio/mpeg",
      "mp4"  => "video/mp4",
      "wav"  => "audio/wav",
      "ics"  => "text/calendar",
    }

    # Best-effort MIME type by extension. Callers can always pass an explicit
    # `mime_type:`; unknown extensions fall back to application/octet-stream.
    def self.mime_type_for(filename : String) : String
      ext = File.extname(filename).lchop('.').downcase
      MIME_TYPES[ext]? || "application/octet-stream"
    end

    @@max_attachment_size : Int64 = 25_i64 * 1024 * 1024
    @@max_total_attachment_size : Int64 = 50_i64 * 1024 * 1024
    @@attachment_limits_mutex = Mutex.new

    def self.max_attachment_size : Int64
      @@attachment_limits_mutex.synchronize { @@max_attachment_size }
    end

    def self.max_attachment_size=(bytes : Int64 | Int32) : Nil
      @@attachment_limits_mutex.synchronize { @@max_attachment_size = bytes.to_i64 }
    end

    def self.max_total_attachment_size : Int64
      @@attachment_limits_mutex.synchronize { @@max_total_attachment_size }
    end

    def self.max_total_attachment_size=(bytes : Int64 | Int32) : Nil
      @@attachment_limits_mutex.synchronize { @@max_total_attachment_size = bytes.to_i64 }
    end

    # Re-check the collection against current limits (limits may change after
    # an attachment was created).
    def self.validate_attachments!(attachments : Array(Attachment)) : Nil
      total = 0_i64
      max = max_attachment_size
      attachments.each do |attachment|
        size = attachment.size.to_i64
        if max > 0 && size > max
          raise AttachmentTooLarge.new("attachment #{attachment.filename.inspect} is #{size} bytes (limit #{max})")
        end
        total += size
      end
      total_limit = max_total_attachment_size
      if total_limit > 0 && total > total_limit
        raise AttachmentTooLarge.new("total attachment size #{total} bytes exceeds limit #{total_limit}")
      end
    end
  end
end
