require "html"
require "json"
require "./storage"

module Saci
  # Action Text–style embedded attachments.
  #
  # Trix is deliberately NOT bundled. Load it from a CDN in your layout:
  #
  # ```html
  # <link rel="stylesheet" href="https://unpkg.com/trix@2.1.15/dist/trix.css">
  # <script src="https://unpkg.com/trix@2.1.15/dist/trix.js"></script>
  # <trix-editor input="post_body"></trix-editor>
  # ```
  #
  # `FormBuilder#rich_text_area` emits a plain `<textarea data-rich-text>`
  # that the snippet above can progressively enhance. When Trix uploads a
  # file, persist the returned blob signed id in an
  # `<action-text-attachment>` tag; rendering/sanitizing/plain-text
  # extraction is handled here and by `Saci::RichText`.
  module RichText
    # Regex matching one complete attachment tag (paired or self-closing).
    ATTACHMENT_BLOCK_RE = /<action-text-attachment\b[^>]*>.*?<\/action-text-attachment\s*>|<action-text-attachment\b[^>]*\/?>/m

    # One embedded attachment parsed from rich-text HTML.
    #
    # ```
    # blob = Saci::Storage::Blob.create_and_upload!(io, filename: "a.png")
    # html = Saci::RichText.attachment_tag(blob, caption: "Chart")
    # Saci::RichText.attachments(html).first.blob # => blob
    # ```
    class Attachment
      getter sgid : String
      getter content_type : String
      getter filename : String
      getter caption : String

      def initialize(@sgid : String,
                     @content_type : String = "application/octet-stream",
                     @filename : String = "attachment",
                     @caption : String = "")
      end

      def self.for_blob(blob : Saci::Storage::Blob) : Attachment
        new(
          sgid: blob.signed_id,
          content_type: blob.content_type || "application/octet-stream",
          filename: blob.filename || "attachment"
        )
      end

      def self.for_record(record : Saci::Record::Base) : Attachment
        new(
          sgid: RichText.sgid_for(record),
          content_type: "application/octet-stream",
          filename: record.class.name
        )
      end

      # Parses one `<action-text-attachment ...>caption</...>` tag.
      def self.from_tag(tag : String) : Attachment?
        start_tag = tag.match(/\A<action-text-attachment\b[^>]*>/m).try(&.[0]?) || tag
        attrs = RichText.tag_attributes(start_tag)
        sgid = attrs["sgid"]?
        return nil if sgid.nil? || sgid.empty?
        caption = tag.match(/>(.*)<\/action-text-attachment\s*>/m).try(&.[1]?) || ""
        new(
          sgid: sgid,
          content_type: attrs["content-type"]? || "application/octet-stream",
          filename: attrs["filename"]? || "attachment",
          caption: caption
        )
      end

      # Resolves the signed global id through the polymorphic registry.
      # Returns nil for expired tokens or deleted records.
      def attachable : Saci::Record::Base?
        RichText.find_signed(@sgid)
      end

      def blob : Saci::Storage::Blob?
        record = attachable
        record.is_a?(Saci::Storage::Blob) ? record : nil
      end

      def caption? : Bool
        !RichText.plain_text(@caption).empty?
      end

      def with_caption(value : String?) : Attachment
        Attachment.new(@sgid, @content_type, @filename, value || "")
      end

      # Safe HTML: attributes are escaped and the caption is sanitized.
      def to_html : String
        String.build do |io|
          io << '<' << ATTACHMENT_TAG
          io << %( sgid="#{HTML.escape(@sgid)}")
          io << %( content-type="#{HTML.escape(@content_type)}")
          io << %( filename="#{HTML.escape(@filename)}")
          io << '>'
          io << RichText.sanitize(@caption)
          io << "</" << ATTACHMENT_TAG << '>'
        end
      end

      def to_s(io : IO) : Nil
        io << to_html
      end

      # Caption text when present, otherwise the filename. Content-level
      # `RichText.plain_text` intentionally drops attachment blocks.
      def to_plain_text : String
        text = RichText.plain_text(@caption)
        text.empty? ? @filename : text
      end

      def ==(other : Attachment) : Bool
        @sgid == other.sgid
      end
    end

    # Include in a model that can be embedded in rich text. Implement
    # `to_rich_text_attachment` (or use the default below for `Blob`).
    module Attachable
      abstract def to_rich_text_attachment : Attachment

      def attachable_sgid : String
        to_rich_text_attachment.sgid
      end

      def to_plain_text : String
        ""
      end
    end

    # All attachments in `raw`, in document order.
    def self.attachments(raw : String?) : Array(Attachment)
      result = [] of Attachment
      return result if raw.nil? || raw.empty?
      raw.scan(ATTACHMENT_BLOCK_RE) do |match|
        if attachment = Attachment.from_tag(match[0])
          result << attachment
        end
      end
      result
    end

    # Signed global id for any persisted record (see
    # `Storage.signed_global_id`).
    def self.sgid_for(record : Saci::Record::Base) : String
      Storage.signed_global_id(record)
    end

    def self.find_signed(sgid : String) : Saci::Record::Base?
      Storage.resolve_signed_global_id(sgid)
    end

    # Builds an `<action-text-attachment>` tag for a blob/record.
    def self.attachment_tag(attachable : Saci::Record::Base, caption : String? = nil) : String
      attachment = case attachable
                   when Saci::Storage::Blob then Attachment.for_blob(attachable)
                   else                          Attachment.for_record(attachable)
                   end
      attachment.with_caption(caption).to_html
    end

    # Replaces every attachment tag with the block's HTML while sanitizing
    # the surrounding rich text. Block output is trusted application HTML.
    def self.render_attachments(raw : String?, &block : Attachment -> String) : String
      return "" if raw.nil? || raw.empty?
      out = String.build do |io|
        cursor = 0
        raw.scan(ATTACHMENT_BLOCK_RE) do |match|
          start = match.byte_begin(0)
          finish = match.byte_end(0)
          if start > cursor
            io << sanitize(raw.byte_slice(cursor, start - cursor))
          end
          if attachment = Attachment.from_tag(match[0])
            io << block.call(attachment)
          end
          cursor = finish
        end
        if cursor < raw.bytesize
          io << sanitize(raw.byte_slice(cursor, raw.bytesize - cursor))
        end
      end
      out
    end

    # Default rendering: a safe link to the blob's signed URL.
    def self.render_attachments(raw : String?) : String
      render_attachments(raw) do |attachment|
        if blob = attachment.blob
          %(<a href="#{HTML.escape(blob.url)}">#{HTML.escape(blob.filename || attachment.filename)}</a>)
        else
          HTML.escape(attachment.to_plain_text)
        end
      end
    end

    struct Content
      def attachments : Array(Attachment)
        RichText.attachments(@raw)
      end

      def attachables : Array(Saci::Record::Base)
        attachments.compact_map(&.attachable)
      end

      def render_attachments(&block : Attachment -> String) : String
        RichText.render_attachments(@raw, &block)
      end

      def render_attachments : String
        RichText.render_attachments(@raw)
      end
    end
  end

  # Blobs are embeddable Action Text attachables out of the box.
  class Storage::Blob
    include RichText::Attachable

    def to_rich_text_attachment : RichText::Attachment
      RichText::Attachment.for_blob(self)
    end

    def to_plain_text : String
      filename || ""
    end
  end

  module Views
    # Safe HTML for rich text with attachments rendered through a block:
    #
    # ```
    # <%= render_attachments(@post.body_rich_text) { |att| image_tag(att.blob) } %>
    # ```
    def self.render_attachments(value : String | RichText::Content | Nil, &block : RichText::Attachment -> String) : String
      raw = value.is_a?(RichText::Content) ? value.raw : value
      RichText.render_attachments(raw, &block)
    end

    def self.render_attachments(value : String | RichText::Content | Nil) : String
      raw = value.is_a?(RichText::Content) ? value.raw : value
      RichText.render_attachments(raw)
    end
  end

  class Controller
    # Safe HTML with Action Text attachments substituted. Emit WITHOUT
    # `h()`; block output is trusted application HTML.
    def render_attachments(value : String | Saci::RichText::Content | Nil, &block : Saci::RichText::Attachment -> String) : String
      Views.render_attachments(value, &block)
    end

    def render_attachments(value : String | Saci::RichText::Content | Nil) : String
      Views.render_attachments(value)
    end
  end
end
