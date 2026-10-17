require "html"

module Saci
  # Rich text (ActionText equivalent, stdlib-only — no Trix bundle, no new
  # dependencies).
  #
  # Storage is a plain `String` column: `has_rich_text :body` works on any
  # existing text/string column with NO migration. For new fields add one:
  #
  # ```
  # class CreatePosts < Saci::Record::Migration
  #   def change
  #     create_table :posts do |t|
  #       t.string :title, null: false
  #       t.text :body
  #       t.timestamps
  #     end
  #   end
  # end
  #
  # class Post < Saci::Record::Base
  #   column id : Int64, primary: true
  #   column title : String
  #   column body : String
  #   has_rich_text :body
  # end
  # ```
  #
  # Security model: input is NEVER trusted. `RichText.sanitize` /
  # `Content#to_s` escape everything first, then re-emit only an allowlist
  # of tags/attributes (see `ALLOWED_TAGS`). Render with `rich_text` and
  # always sanitize on READ — sanitizing on write gives a false sense of
  # safety (rows written before a fix, or outside the app, stay dangerous).
  module RichText
    # Tags that survive sanitizing. Everything else (script, style, iframe,
    # table, img, div, span, headings h4+, ...) is escaped as literal text,
    # never emitted.
    ALLOWED_TAGS = %w(p br strong em a ul ol li code pre blockquote h1 h2 h3)

    # Tags that render without a closing tag.
    VOID_TAGS = %w(br)

    # `<a href>` allowlist: http/https/mailto plus site-local `/path` and
    # `#anchor` links. Anything else (javascript:, data:, vbscript:,
    # file:, bare relatives like `page.html`, ...) drops the href but keeps
    # the link text.
    ALLOWED_HREF_SCHEMES = %w(http:// https:// mailto:)

    # Matches one tag-or-comment delimiter for the split-based tokenizer.
    # Attribute values are quote-aware so a `>` inside `href="..."` never
    # splits a tag in half.
    TAG_PART_RE = /\A(<!--.*?-->|<\/?[a-zA-Z0-9]+(?:\s+(?:[^<>"']|"[^"]*"|'[^']*')*)?\s*\/?>|<[^<>]*>?)\z/m

    # Sanitizes `raw` HTML with an escape-then-allowlist pass: the input is
    # split into text/tag pieces, text is HTML-escaped, and only allowlisted
    # tags with safe attributes are re-emitted. `nil` renders as `""`.
    def self.sanitize(raw : String?) : String
      return "" if raw.nil? || raw.empty?
      raw.split(/(<!--.*?-->|<\/?[a-zA-Z0-9]+(?:\s+(?:[^<>"']|"[^"]*"|'[^']*')*)?\s*\/?>|<[^<>]*>?)/m).map do |piece|
        if piece.match(TAG_PART_RE)
          sanitize_tag(piece)
        else
          HTML.escape(piece)
        end
      end.join
    end

    # Plain-text extraction for search indexes, notifications and excerpts:
    # tags become spaces, entities decode, whitespace collapses.
    def self.plain_text(raw : String?) : String
      return "" if raw.nil? || raw.empty?
      text = raw.gsub(/<!--.*?-->/m, " ").gsub(/<[^>]*>?/, " ")
      decode_entities(text).gsub(/\s+/, " ").strip
    end

    # Truncates `text` to `length` characters, appending `omission` when cut.
    def self.truncate(text : String, length : Int32 = 200, omission : String = "…") : String
      return text if text.size <= length
      text[0, length].rstrip + omission
    end

    # Value object returned by `<name>_rich_text`. `#to_s` is sanitized
    # HTML (safe to emit with `<%= %>`), `#to_plain_text` is the
    # search/notification text, `#blank?` covers nil/empty/whitespace and
    # markup-without-text (`"<br>"`, `"<!-- x -->"`, ...).
    struct Content
      getter raw : String?

      def initialize(@raw : String? = nil)
      end

      def to_s : String
        RichText.sanitize(@raw)
      end

      def to_s(io : IO) : Nil
        io << to_s
      end

      def to_plain_text(limit : Int32? = nil) : String
        text = RichText.plain_text(@raw)
        limit ? RichText.truncate(text, limit) : text
      end

      def excerpt(length : Int32 = 200, omission : String = "…") : String
        RichText.truncate(to_plain_text, length, omission)
      end

      def blank? : Bool
        to_plain_text.empty?
      end

      def present? : Bool
        !blank?
      end

      def ==(other : Content) : Bool
        raw == other.raw
      end
    end

    # -- sanitizer internals ------------------------------------------------

    # Sanitizes one tag-shaped piece: comments are dropped, allowlisted
    # tags are re-emitted with safe attributes only, everything else is
    # escaped as literal text (so `<script>` can never execute — it renders
    # as visible text).
    private def self.sanitize_tag(tag : String) : String
      return "" if tag.starts_with?("<!--")
      if m = tag.match(/\A<\/\s*([a-zA-Z0-9]+)\s*>\z/)
        name = m[1].downcase
        return "</#{name}>" if ALLOWED_TAGS.includes?(name) && !VOID_TAGS.includes?(name)
        return HTML.escape(tag)
      end
      if m = tag.match(/\A<\s*([a-zA-Z0-9]+)((?:\s+(?:[^<>"']|"[^"]*"|'[^']*')*)?)\s*\/?>\z/m)
        name = m[1].downcase
        return HTML.escape(tag) unless ALLOWED_TAGS.includes?(name)
        if name == "a"
          if hm = (m[2]? || "").match(/href\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)/i)
            href = hm[1]
            if href.size >= 2 && ((href.starts_with?('"') && href.ends_with?('"')) || (href.starts_with?('\'') && href.ends_with?('\'')))
              href = href[1...-1]
            end
            return %(<a href="#{HTML.escape(href)}">) if safe_href?(href)
          end
          return "<a>"
        end
        return "<br>" if name == "br"
        return "<#{name}>"
      end
      HTML.escape(tag)
    end

    # True when `value` is an allowed link target. The value is
    # entity-decoded and stripped of ASCII control/whitespace first, so
    # `java\tscript:`, `&#106;avascript:` and case tricks (`JaVaScRiPt:`)
    # all normalize to a blocked scheme before comparison.
    private def self.safe_href?(value : String) : Bool
      flat = decode_entities(value).gsub(/[\x00-\x20]+/, "").downcase
      return true if ALLOWED_HREF_SCHEMES.any? { |scheme| flat.starts_with?(scheme) }
      flat.starts_with?("/") || flat.starts_with?("#")
    end

    private NAMED_ENTITIES = {
      "amp"   => "&",
      "lt"    => "<",
      "gt"    => ">",
      "quot"  => "\"",
      "apos"  => "'",
      "nbsp"  => "\u00A0",
    }

    # Single-pass entity decoding (no recursive re-decoding, so `&amp;lt;`
    # stays the literal text `&lt;` instead of becoming `<`).
    private def self.decode_entities(text : String) : String
      text.gsub(/&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z]+);/) do |full, m|
        body = m[1]
        if body.starts_with?("#x") || body.starts_with?("#X")
          code = body[2..].to_i?(16)
          code && valid_codepoint?(code) ? code.chr : full
        elsif body.starts_with?("#")
          code = body[1..].to_i?
          code && valid_codepoint?(code) ? code.chr : full
        else
          NAMED_ENTITIES[body.downcase]? || full
        end
      end
    end

    private def self.valid_codepoint?(code : Int) : Bool
      code >= 0 && code <= 0x10FFFF && !(0xD800 <= code <= 0xDFFF)
    end
  end

  class Record::Base
    # Declares a rich-text value object over an existing `String` column —
    # no migration needed for basic use (the column stores raw HTML, which
    # is sanitized on every read, never trusted):
    #
    # ```
    # class Post < Saci::Record::Base
    #   column body : String
    #   has_rich_text :body
    # end
    #
    # post.body_rich_text.to_s          # sanitized HTML
    # post.body_rich_text.to_plain_text # excerpt/plain text
    # post.body_rich_text.blank?        # true when no visible text
    # post.body_rich_text = "<p>hi</p>" # raw write (sanitized on read)
    # ```
    macro has_rich_text(name)
      # Reads the backing column as a `RichText::Content` value object.
      def {{name.id}}_rich_text : Saci::RichText::Content
        Saci::RichText::Content.new({{name.id}})
      end

      def {{name.id}}_rich_text=(value : Saci::RichText::Content) : Saci::RichText::Content
        self.{{name.id}} = value.raw
        value
      end

      def {{name.id}}_rich_text=(value : String?) : String?
        self.{{name.id}} = value
        value
      end
    end
  end

  module Views
    # Renders rich text as sanitized HTML. The result is ALREADY SAFE — and
    # `<%= %>` does NOT escape, so emit it directly WITHOUT `h()` (wrapping
    # it in `h()` double-escapes and shows literal tags):
    #
    # ```
    # <%= rich_text(@post.body) %>             <!-- String column -->
    # <%= rich_text(@post.body_rich_text) %>   <!-- Content, same output -->
    # ```
    def self.rich_text(value : String | RichText::Content | Nil) : String
      case value
      when RichText::Content then value.to_s
      when String             then RichText.sanitize(value)
      else                         ""
      end
    end
  end

  class FormBuilder
    # Textarea for rich-text columns. Emits a plain textarea (works with no
    # JavaScript) tagged `data-rich-text="true"` so the documented Trix CDN
    # snippet can progressively enhance it. The value is the RAW column
    # content (escaped for the textarea) — the server accepts plain HTML
    # from this field and sanitizes on read, never trusting input.
    def rich_text_area(name : String, value : String? = nil, rows : Int32 = 8) : String
      %(<textarea name="#{HTML.escape(field_name(name))}" id="#{HTML.escape(field_id(name))}" rows="#{rows}" data-rich-text="true"#{error_class(name)}>#{HTML.escape(value || model_string(name) || "")}</textarea>)
    end
  end

  class Controller
    # Sanitized rich-text HTML for templates — emit WITHOUT `h()` (see
    # `Saci::Views.rich_text`): `<%= rich_text(@post.body) %>`.
    def rich_text(value : String | Saci::RichText::Content | Nil) : String
      Views.rich_text(value)
    end
  end
end
