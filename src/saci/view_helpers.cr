require "html"
require "uri"

module Saci
  # General Action View-style helpers. Everything lives on `Saci::Views` as
  # module functions (easy to test without a request) and the stateful or
  # token-dependent ones are also exposed as `Saci::Controller` instance
  # methods so ECR templates can call them directly.
  #
  # Output convention: helper-generated markup is returned as a String and
  # is *not* re-escaped by ECR (`<%= helper %>` writes it verbatim). Text
  # arguments to tag/link helpers are escaped; a block's return value is
  # treated as already-built HTML (same idea as Rails' safe buffers, but
  # explicit rather than tracked).
  module Views
    # Builds an HTML tag:
    #
    # ```
    # tag("br") # => "<br>"
    # tag("input", {"type" => "text", "name" => "q"})
    # tag("div", {class: "card", data: {id: 3}}, "Hi") # => ... data-id="3">Hi</div>
    # tag("div", class: "card") { "Hi" }               # block content is raw HTML
    # ```
    #
    # `nil`/`false` attributes are omitted, `true` renders a boolean
    # attribute (`defer`, `checked`, ...), arrays join with spaces and nested
    # hashes/named tuples become `data-*` / `aria-*` attributes.
    def self.tag(name : String | Symbol, options : Hash, content : String? = nil) : String
      build_tag(name.to_s, options, content, escape_content: true)
    end

    def self.tag(name : String | Symbol, options : NamedTuple, content : String? = nil) : String
      build_tag(name.to_s, options, content, escape_content: true)
    end

    def self.tag(name : String | Symbol, options : Nil, content : String? = nil) : String
      build_tag(name.to_s, nil, content, escape_content: true)
    end

    def self.tag(name : String | Symbol, content : String) : String
      build_tag(name.to_s, nil, content, escape_content: true)
    end

    def self.tag(name : String | Symbol, **attributes) : String
      build_tag(name.to_s, attributes, nil, escape_content: true)
    end

    def self.tag(name : String | Symbol, content : String, **attributes) : String
      build_tag(name.to_s, attributes, content, escape_content: true)
    end

    def self.tag(name : String | Symbol, options : Hash, &block : -> String) : String
      build_tag(name.to_s, options, block.call, escape_content: false)
    end

    def self.tag(name : String | Symbol, options : NamedTuple, &block : -> String) : String
      build_tag(name.to_s, options, block.call, escape_content: false)
    end

    def self.tag(name : String | Symbol, **attributes, &block : -> String) : String
      build_tag(name.to_s, attributes, block.call, escape_content: false)
    end

    # Like `tag`, but always emits a closing tag and supports a block.
    def self.content_tag(name : String | Symbol, content : String? = nil, **attributes) : String
      build_tag(name.to_s, attributes, content || "", escape_content: true)
    end

    def self.content_tag(name : String | Symbol, options : Hash, content : String? = nil) : String
      build_tag(name.to_s, options, content || "", escape_content: true)
    end

    def self.content_tag(name : String | Symbol, **attributes, &block : -> String) : String
      build_tag(name.to_s, attributes, block.call, escape_content: false)
    end

    def self.content_tag(name : String | Symbol, options : Hash, &block : -> String) : String
      build_tag(name.to_s, options, block.call, escape_content: false)
    end

    # `<button>` with `type="submit"` by default. String content is escaped;
    # block content is raw HTML.
    def self.button_tag(content : String? = nil, **attributes) : String
      build_tag("button", attributes, content || "Save", escape_content: true, defaults: {"type" => "submit"})
    end

    def self.button_tag(**attributes, &block : -> String) : String
      build_tag("button", attributes, block.call, escape_content: false, defaults: {"type" => "submit"})
    end

    # `<form>` mini-form containing a submit button. Non-GET/POST methods are
    # sent as POST with a hidden `_method` override; `authenticity_token`
    # includes the CSRF token when one is supplied (the controller method
    # supplies it automatically).
    def self.button_to(text : String, url : String, method : String | Symbol = "post", authenticity_token : String? = nil, **attributes) : String
      button_to_form(text, url, method, authenticity_token, attributes)
    end

    def self.button_to(url : String, method : String | Symbol = "post", authenticity_token : String? = nil, **attributes, &block : -> String) : String
      button_to_form(block.call, url, method, authenticity_token, attributes)
    end

    # `content_tag` for a record, with `id`/`class` from `dom_id`/`dom_class`.
    def self.div_for(record : Saci::Record::Base, **attributes, &block : -> String) : String
      attrs = attributes_hash(attributes)
      attrs["id"] = dom_id(record) unless attrs.has_key?("id")
      base_class = dom_class(record)
      if existing = attrs["class"]?
        attrs["class"] = "#{existing} #{base_class}"
      else
        attrs["class"] = base_class
      end
      build_tag("div", attrs, block.call, escape_content: false)
    end

    # Escapes text except for existing HTML entities (`&amp;` stays
    # `&amp;`, a bare `&` becomes `&amp;`).
    def self.escape_once(text : String) : String
      String.build do |io|
        pos = 0
        text.scan(/&(?:[a-zA-Z][a-zA-Z0-9]*|#\d+|#x[0-9a-fA-F]+);/) do |m|
          io << HTML.escape(text[pos...m.begin(0)])
          io << m[0]
          pos = m.end(0)
        end
        io << HTML.escape(text[pos..]) if pos < text.size
      end
    end

    # Escapes each part and joins them. `nil` entries render empty (Rails
    # `safe_join` without the hidden `html_safe` marker).
    def self.safe_join(parts : Array, separator : String = "") : String
      parts.map { |part| part.nil? ? "" : HTML.escape(part.to_s) }.join(separator)
    end

    # Escaped text with blank-line paragraphs and `<br>` line breaks.
    def self.simple_format(text : String, wrapper_tag : String = "p", **attributes) : String
      escaped = HTML.escape(text)
      escaped.split(/\n{2,}/).reject(&.empty?).map do |paragraph|
        body = paragraph.gsub(/\n/, "<br>")
        build_tag(wrapper_tag, attributes, body, escape_content: false)
      end.join("\n")
    end

    # Truncates to `length` characters, appending `omission` when cut.
    # `separator` cuts at the last occurrence instead of mid-word.
    def self.truncate(text : String, length : Int32 = 30, omission : String = "...", separator : String? = nil) : String
      return text if text.size <= length
      cut = text[0, (length - omission.size).clamp(0, text.size)]
      if sep = separator
        if idx = cut.rindex(sep)
          cut = cut[0, idx]
        end
      end
      HTML.escape(cut.rstrip + omission)
    end

    # Truncates after `words` words.
    def self.truncate_words(text : String, words : Int32 = 30, omission : String = "...") : String
      list = text.split(/\s+/).reject(&.empty?)
      return text if list.size <= words
      HTML.escape(list[0, words].join(" ") + omission)
    end

    # HTML-escaped snippet around the first occurrence of `phrase`.
    def self.excerpt(text : String, phrase : String, radius : Int32 = 100, omission : String = "...") : String
      escaped = HTML.escape(text)
      needle = HTML.escape(phrase)
      idx = escaped.index(needle)
      return "" if idx.nil?
      start = (idx - radius).clamp(0, escaped.size)
      finish = (idx + needle.size + radius).clamp(0, escaped.size)
      result = escaped[start...finish]
      result = omission + result if start > 0
      result = result + omission if finish < escaped.size
      result
    end

    # "1 post" / "2 posts" (`plural` defaults to a small English inflector).
    def self.pluralize(count : Int | Float | String, singular : String, plural : String? = nil) : String
      word = count == 1 ? singular : (plural || Record::Inflector.pluralize(singular))
      "#{count} #{word}"
    end

    # Removes HTML comments and tags (keeps text and entities).
    def self.strip_tags(html : String) : String
      html.gsub(/<!--.*?-->/m, "").gsub(/<[^>]*>?/, "")
    end

    # Removes `<a>` wrappers, keeping their text (and any other markup).
    def self.strip_links(html : String) : String
      html.gsub(/<a\b[^>]*>(.*?)<\/a\s*>/mi, "\\1")
    end

    # Escapes text and wraps every occurrence of `phrase` in `highlighter`.
    # `highlighter` may contain `\\1` (the matched text).
    def self.highlight(text : String, phrase : String, highlighter : String = "<mark>\\1</mark>", sanitize : Bool = true) : String
      escaped = sanitize ? HTML.escape(text) : text
      needle = sanitize ? HTML.escape(phrase) : phrase
      return escaped if needle.empty?
      escaped.gsub(/(#{Regex.escape(needle)})/i, highlighter)
    end

    # Wraps words to `line_width` columns. Existing newlines are kept.
    def self.word_wrap(text : String, line_width : Int32 = 80, break_sequence : String = "\n") : String
      escaped = HTML.escape(text)
      escaped.split("\n", remove_empty: false).map do |line|
        words = line.split(" ")
        next "" if words.empty?
        lines = [] of String
        current = ""
        words.each do |word|
          if current.empty?
            current = word
          elsif current.size + 1 + word.size <= line_width
            current += " " + word
          else
            lines << current
            current = word
          end
        end
        lines << current unless current.empty?
        lines.join(break_sequence)
      end.join("\n")
    end

    # Rails-like allowlist sanitizer. Text is escaped; only allowlisted tags
    # and attributes are re-emitted. Scripts/styles/iframes/forms are
    # dropped (their inner text is kept), and unsafe `href`/`src` schemes
    # are removed. Pass `tags:`/`attributes:` to narrow or extend the
    # defaults.
    DEFAULT_SANITIZE_TAGS       = %w(a b blockquote br code dd del div dl dt em h1 h2 h3 h4 h5 h6 hr i img ins li ol p pre s span strong sub sup table tbody td th thead tr u ul)
    DEFAULT_SANITIZE_ATTRIBUTES = %w(alt class colspan height href id name rel rowspan src title width)
    SANITIZE_VOID_TAGS          = %w(br hr img)

    def self.sanitize(html : String, tags : Array(String)? = nil, attributes : Array(String)? = nil) : String
      allowed_tags = (tags || DEFAULT_SANITIZE_TAGS).map(&.downcase)
      allowed_attrs = (attributes || DEFAULT_SANITIZE_ATTRIBUTES).map(&.downcase)
      pieces = html.split(/(<!--.*?-->|<\/?[a-zA-Z][a-zA-Z0-9:-]*(?:\s+(?:[^<>"']|"[^"]*"|'[^']*')*)?\s*\/?>)/m)
      String.build do |io|
        pieces.each do |piece|
          if piece.starts_with?("<!--")
            next
          elsif m = piece.match(/\A<\s*\/\s*([a-zA-Z0-9:-]+)\s*>\z/)
            name = m[1].downcase
            io << "</#{name}>" if allowed_tags.includes?(name) && !SANITIZE_VOID_TAGS.includes?(name)
          elsif m = piece.match(/\A<\s*([a-zA-Z0-9:-]+)((?:\s+(?:[^<>"']|"[^"]*"|'[^']*')*)?)\s*\/?>\z/m)
            name = m[1].downcase
            next unless allowed_tags.includes?(name)
            io << '<' << name
            sanitize_attributes(m[2]? || "", allowed_attrs, io)
            io << '>'
          elsif piece.starts_with?("<")
            next
          else
            io << escape_once(piece)
          end
        end
      end
    end

    # Escapes a string for inclusion inside a JavaScript string literal.
    def self.escape_javascript(text : String) : String
      text.gsub("\\", "\\\\")
        .gsub("\r", "\\r")
        .gsub("\n", "\\n")
        .gsub("\t", "\\t")
        .gsub("\"", "\\\"")
        .gsub("'", "\\'")
        .gsub("\u2028", "\\u2028")
        .gsub("\u2029", "\\u2029")
        .gsub("</", "<\\/")
    end

    # `<script>` block. JS content is emitted as-is; attributes are escaped.
    def self.javascript_tag(content : String? = nil, **attributes) : String
      build_tag("script", attributes, content || "", escape_content: false)
    end

    def self.javascript_tag(**attributes, &block : -> String) : String
      build_tag("script", attributes, block.call, escape_content: false)
    end

    # Escapes JSON for safe embedding in HTML (`<`, `>`, `&`, U+2028/2029).
    def self.json_escape(json : String) : String
      json.gsub("<", "\\u003c").gsub(">", "\\u003e").gsub("&", "\\u0026")
        .gsub("\u2028", "\\u2028").gsub("\u2029", "\\u2029")
    end

    def self.number_with_delimiter(number : Int | Float, delimiter : String = ",", separator : String = ".") : String
      number_with_delimiter(number.to_s, delimiter: delimiter, separator: separator)
    end

    # String overload preserves significant trailing zeros (`"1.000"`).
    def self.number_with_delimiter(number : String, delimiter : String = ",", separator : String = ".") : String
      string = number
      integer, _, fraction = string.partition('.')
      sign = integer.starts_with?("-") ? "-" : ""
      digits = sign.empty? ? integer : integer[1..]
      grouped = String.build do |io|
        digits.size.times do |i|
          io << delimiter if i > 0 && (digits.size - i) % 3 == 0
          io << digits[i]
        end
      end
      fraction.empty? ? "#{sign}#{grouped}" : "#{sign}#{grouped}#{separator}#{fraction}"
    end

    def self.number_with_precision(number : Int | Float, precision : Int32 = 3, significant : Bool = false, strip_insignificant_zeros : Bool = false, delimiter : String = ",", separator : String = ".") : String
      formatted = if significant
                    significant_digits(number.to_f, precision)
                  else
                    ("%.#{precision}f" % number)
                  end
      if strip_insignificant_zeros
        formatted = formatted.sub(/\.?0+\z/, "") if formatted.includes?(".")
      end
      number_with_delimiter(formatted, delimiter: delimiter, separator: separator)
    rescue ArgumentError
      number.to_s
    end

    # Rounds to `precision` significant digits without scientific notation
    # (Rails `significant: true`).
    private def self.significant_digits(value : Float64, precision : Int32) : String
      digits = precision < 1 ? 1 : precision
      return "0" if value == 0
      exponent = Math.log10(value.abs).floor.to_i
      decimals = digits - 1 - exponent
      factor = 10.0 ** decimals
      rounded = (value * factor).round / factor
      decimals > 0 ? ("%.#{decimals}f" % rounded) : ("%.0f" % rounded)
    end

    def self.number_to_currency(number : Int | Float, unit : String = "$", precision : Int32 = 2, delimiter : String = ",", separator : String = ".", format : String = "%u%n", negative_format : String? = nil) : String
      negative = number < 0
      amount = number_with_precision(number.abs, precision: precision, delimiter: delimiter, separator: separator)
      pattern = if negative
                  negative_format || "-#{format}"
                else
                  format
                end
      pattern.gsub("%u", unit).gsub("%n", amount)
    end

    def self.number_to_percentage(number : Int | Float, precision : Int32 = 3, delimiter : String = ",", separator : String = ".", format : String = "%n%") : String
      amount = number_with_precision(number, precision: precision, delimiter: delimiter, separator: separator)
      format.gsub("%n", amount)
    end

    HUMAN_UNITS = [
      {"", 1_i64},
      {"Thousand", 1_000_i64},
      {"Million", 1_000_000_i64},
      {"Billion", 1_000_000_000_i64},
      {"Trillion", 1_000_000_000_000_i64},
      {"Quadrillion", 1_000_000_000_000_000_i64},
    ] of Tuple(String, Int64)

    def self.number_to_human(number : Int | Float, precision : Int32 = 3, delimiter : String = ",", separator : String = ".", strip_insignificant_zeros : Bool = true) : String
      sign = number < 0 ? "-" : ""
      value = number.to_f.abs
      unit, divisor = HUMAN_UNITS.reverse.find { |(_, div)| value >= div } || HUMAN_UNITS.first
      amount = if divisor == 1
                 number_with_delimiter(value.to_i64, delimiter: delimiter, separator: separator)
               else
                 number_with_precision(value / divisor, precision: precision, significant: true,
                   strip_insignificant_zeros: strip_insignificant_zeros, delimiter: delimiter, separator: separator)
               end
      unit.empty? ? "#{sign}#{amount}" : "#{sign}#{amount} #{unit}"
    end

    SIZE_UNITS = [
      {"Bytes", 1_i64},
      {"KB", 1024_i64},
      {"MB", 1024_i64 ** 2},
      {"GB", 1024_i64 ** 3},
      {"TB", 1024_i64 ** 4},
      {"PB", 1024_i64 ** 5},
      {"EB", 1024_i64 ** 6},
    ] of Tuple(String, Int64)

    def self.number_to_human_size(number : Int | Float, precision : Int32 = 3, delimiter : String = ",", separator : String = ".", strip_insignificant_zeros : Bool = true) : String
      sign = number < 0 ? "-" : ""
      value = number.to_f.abs
      unit, divisor = SIZE_UNITS.reverse.find { |(_, div)| value >= div } || SIZE_UNITS.first
      amount = if divisor == 1
                 value.to_i64.to_s
               else
                 number_with_precision(value / divisor, precision: precision, significant: true,
                   strip_insignificant_zeros: strip_insignificant_zeros, delimiter: delimiter, separator: separator)
               end
      name = unit == "Bytes" && amount == "1" ? "Byte" : unit
      "#{sign}#{amount} #{name}"
    end

    def self.distance_of_time_in_words(from_time : Time, to_time : Time = Time.utc, include_seconds : Bool = false) : String
      seconds = (to_time - from_time).total_seconds.abs
      if include_seconds
        return "less than 5 seconds" if seconds < 5
        return "less than 10 seconds" if seconds < 10
        return "less than 20 seconds" if seconds < 20
        return "half a minute" if seconds < 40
        return "less than a minute" if seconds < 60
      end
      minutes = (seconds / 60).round.to_i
      return "less than a minute" if minutes < 1
      return "1 minute" if minutes == 1
      return "#{minutes} minutes" if minutes < 45
      return "about 1 hour" if minutes < 90
      hours = (minutes / 60.0).round.to_i
      return "about #{hours} hours" if hours < 24
      days = (hours / 24.0).round.to_i
      return "1 day" if days == 1
      return "#{days} days" if days < 30
      months = (days / 30.0).round.to_i
      return "about 1 month" if months <= 1
      return "#{months} months" if months < 12
      years = (days / 365.0).round.to_i
      return "about 1 year" if years <= 1
      return "over #{years} years" if years > 2
      "almost 2 years"
    end

    def self.distance_of_time_in_words(seconds : Int | Float, to_time : Time = Time.utc, include_seconds : Bool = false) : String
      distance_of_time_in_words(to_time - seconds.seconds, to_time, include_seconds)
    end

    def self.time_ago_in_words(from_time : Time, include_seconds : Bool = false) : String
      distance_of_time_in_words(from_time, Time.utc, include_seconds)
    end

    def self.time_tag(time : Time, content : String? = nil, **attributes) : String
      attrs = attributes_hash(attributes)
      attrs["datetime"] = time.to_utc.to_s("%Y-%m-%dT%H:%M:%SZ") unless attrs.has_key?("datetime")
      tag("time", attrs, content || time.to_s("%Y-%m-%d %H:%M:%S"))
    end

    # Localizes a Time/String through `Saci::I18n` (`time.formats.*`,
    # `date.formats.*`), falling back to strftime defaults when the
    # translation is missing. `l()` is the Rails-style short name.
    def self.l(value : Time, format : String | Symbol | Nil = nil, locale : String | Symbol | Nil = nil) : String
      fmt = format.try(&.to_s)
      key = "time.formats.#{fmt || "default"}"
      translated = I18n.t(key, locale: locale.try(&.to_s))
      if translated.starts_with?("translation missing:")
        pattern = case fmt
                  when "short"   then "%d %b %H:%M"
                  when "long"    then "%B %d, %Y %H:%M"
                  when "default" then "%a, %d %b %Y %H:%M:%S %z"
                  else                fmt || "%a, %d %b %Y %H:%M:%S %z"
                  end
        value.to_s(pattern)
      else
        translated
      end
    end

    def self.l(value : String, format : String | Symbol | Nil = nil, locale : String | Symbol | Nil = nil) : String
      I18n.t(value, locale: locale.try(&.to_s))
    end

    def self.link_to(text : String, url : String, **attributes) : String
      attrs = attributes_hash(attributes)
      attrs["href"] = url
      tag("a", attrs, text)
    end

    def self.link_to(url : String, **attributes, &block : -> String) : String
      attrs = attributes_hash(attributes)
      attrs["href"] = url
      tag("a", attrs, &block)
    end

    def self.link_to_if(condition : Bool, text : String, url : String, **attributes) : String
      condition ? link_to(text, url, **attributes) : HTML.escape(text)
    end

    def self.link_to_if(condition : Bool, url : String, **attributes, &block : -> String) : String
      condition ? link_to(url, **attributes, &block) : block.call
    end

    def self.link_to_unless(condition : Bool, text : String, url : String, **attributes) : String
      link_to_if(!condition, text, url, **attributes)
    end

    def self.link_to_unless(condition : Bool, url : String, **attributes, &block : -> String) : String
      link_to_if(!condition, url, **attributes, &block)
    end

    def self.mail_to(email : String, text : String? = nil, cc : String? = nil, bcc : String? = nil, subject : String? = nil, body : String? = nil, **attributes) : String
      href = mailto_href(email, cc, bcc, subject, body)
      link_to(text || email, href, **attributes)
    end

    def self.mail_to(email : String, cc : String? = nil, bcc : String? = nil, subject : String? = nil, body : String? = nil, **attributes, &block : -> String) : String
      attrs = attributes_hash(attributes)
      attrs["href"] = mailto_href(email, cc, bcc, subject, body)
      tag("a", attrs, &block)
    end

    def self.phone_to(phone : String, text : String? = nil, **attributes) : String
      link_to(text || phone, "tel:#{phone.gsub(/[^0-9+]/, "")}", **attributes)
    end

    def self.phone_to(phone : String, **attributes, &block : -> String) : String
      link_to("tel:#{phone.gsub(/[^0-9+]/, "")}", **attributes, &block)
    end

    def self.sms_to(phone : String, text : String? = nil, body : String? = nil, **attributes) : String
      href = "sms:#{phone.gsub(/[^0-9+]/, "")}"
      href += "?body=#{URI.encode_path_segment(body)}" if body
      link_to(text || phone, href, **attributes)
    end

    def self.sms_to(phone : String, body : String? = nil, **attributes, &block : -> String) : String
      href = "sms:#{phone.gsub(/[^0-9+]/, "")}"
      href += "?body=#{URI.encode_path_segment(body)}" if body
      attrs = attributes_hash(attributes)
      attrs["href"] = href
      tag("a", attrs, &block)
    end

    # `post_12` / `new_post` (Rails `dom_id`). `prefix` may be a String or
    # Symbol (`dom_id(post, :edit)` -> `edit_post_12`).
    def self.dom_id(record : Saci::Record::Base, prefix : String | Symbol | Nil = nil) : String
      base = dom_class(record)
      pre = prefix.try(&.to_s)
      if record.new_record?
        pre ? "#{pre}_new_#{base}" : "new_#{base}"
      else
        id_value = record.__saci_get_attr(record.class.primary_key_name)
        suffix = id_value.nil? ? "" : "_#{id_value}"
        pre ? "#{pre}_#{base}#{suffix}" : "#{base}#{suffix}"
      end
    end

    # `post` (demodulized, underscored class name); `edit_post` with prefix.
    def self.dom_class(record : Saci::Record::Base, prefix : String | Symbol | Nil = nil) : String
      base = Record::Inflector.underscore(record.class.name.split("::").last)
      pre = prefix.try(&.to_s)
      pre ? "#{pre}_#{base}" : base
    end

    def self.csrf_meta_tags(authenticity_token : String) : String
      %(<meta name="csrf-param" content="#{HTML.escape(CSRF::PARAM_NAME)}">\n) +
        %(<meta name="csrf-token" content="#{HTML.escape(authenticity_token)}">)
    end

    # Emits the CSP nonce meta tag when a nonce is available (explicit
    # `nonce:` or a `'nonce-...'` source in the configured policy). Returns
    # "" when no nonce is configured — safe to call unconditionally.
    def self.csp_meta_tag(nonce : String? = nil, policy : String? = nil) : String
      value = nonce
      unless value
        source = policy || SecureHeaders.headers["Content-Security-Policy"]?
        if source && (m = source.match(/'nonce-([^']+)'/))
          value = m[1]
        end
      end
      value ? %(<meta name="csp-nonce" content="#{HTML.escape(value)}">) : ""
    end

    # Normalizes a named-tuple/hash of HTML attributes into an explicitly
    # typed mutable hash (an empty NamedTuple otherwise infers `NoReturn`
    # values, which cannot be assigned to later). Nested hashes/named tuples
    # (e.g. `data: {controller: "x"}`) stay nested for `data-*` expansion.
    alias AttributeValue = String | Bool | Int64 | Float64 | Hash(String, String | Bool | Int64 | Float64)

    def self.attributes_hash(attributes) : Hash(String, AttributeValue)
      result = {} of String => AttributeValue
      attributes.each do |key, value|
        result[key.to_s] = normalize_attribute_value(value)
      end
      result
    end

    private def self.normalize_attribute_value(value) : AttributeValue
      case value
      when Bool  then value
      when Int   then value.to_i64
      when Float then value.to_f64
      when Nil   then ""
      when Hash
        nested = {} of String => String | Bool | Int64 | Float64
        value.each { |k, v| nested[k.to_s] = normalize_simple_attribute(v) }
        nested
      when NamedTuple
        nested = {} of String => String | Bool | Int64 | Float64
        value.each { |k, v| nested[k.to_s] = normalize_simple_attribute(v) }
        nested
      else
        value.to_s
      end
    end

    private def self.normalize_simple_attribute(value) : String | Bool | Int64 | Float64
      case value
      when Bool  then value
      when Int   then value.to_i64
      when Float then value.to_f64
      when Nil   then ""
      else            value.to_s
      end
    end

    # Fragment-cache the block only when `condition` is true.
    def self.cache_if(condition : Bool, key, expires_in : Time::Span? = nil, version : Int? = nil, &block : -> String) : String
      condition ? cache(key, expires_in, version, &block) : block.call
    end

    # Fragment-cache the block only when `condition` is false.
    def self.cache_unless(condition : Bool, key, expires_in : Time::Span? = nil, version : Int? = nil, &block : -> String) : String
      cache_if(!condition, key, expires_in, version, &block)
    end

    # True when a fragment key is present (Redis outages read as false).
    def self.cache?(key, version : Int? = nil) : Bool
      !!Cache.read(expand_fragment_key(key, version))
    rescue Cache::RedisDown
      false
    end

    private def self.build_tag(name : String, options, content : String?, *, escape_content : Bool, defaults : Hash(String, String)? = nil) : String
      String.build do |io|
        io << '<' << name
        if defaults
          defaults.each do |key, value|
            next if has_attribute?(options, key)
            io << ' ' << key << %(=") << HTML.escape(value) << '"'
          end
        end
        render_attributes(io, options) if options
        io << '>'
        if content
          io << (escape_content ? HTML.escape(content) : content)
          io << "</" << name << '>'
        end
      end
    end

    private def self.render_attributes(io : IO, options) : Nil
      options.each do |key, value|
        append_attribute(io, key.to_s, value)
      end
    end

    private def self.append_attribute(io : IO, key : String, value) : Nil
      case value
      when Nil, false
        return
      when true
        io << ' ' << attribute_name(key)
      when Hash
        value.each { |k, v| append_attribute(io, "#{key}-#{k}", v) }
      when NamedTuple
        value.each { |k, v| append_attribute(io, "#{key}-#{k}", v) }
      when Array
        append_attribute(io, key, value.join(" "))
      else
        io << ' ' << attribute_name(key) << %(=") << HTML.escape(value.to_s) << '"'
      end
    end

    private def self.attribute_name(key : String) : String
      HTML.escape(key.gsub('_', '-'))
    end

    private def self.has_attribute?(options, key : String) : Bool
      return false if options.nil?
      options.each do |k, _|
        return true if k.to_s == key
      end
      false
    end

    private def self.button_to_form(text : String, url : String, method : String | Symbol, authenticity_token : String?, attributes) : String
      verb = method.to_s.downcase
      form_method = verb == "get" ? "get" : "post"
      attrs = attributes_hash(attributes)
      form_attrs = {} of String => String
      if form_class = attrs.delete("form_class")
        form_attrs["class"] = form_class.to_s
      end
      String.build do |io|
        io << %(<form action=") << HTML.escape(url) << %(" method=") << form_method << '"'
        form_attrs.each { |k, v| io << ' ' << k << %(=") << HTML.escape(v) << '"' }
        io << '>'
        if form_method == "post" && verb != "post"
          io << %(<input type="hidden" name="_method" value=") << HTML.escape(verb.upcase) << %(">)
        end
        if token = authenticity_token
          io << %(<input type="hidden" name=") << CSRF::PARAM_NAME << %(" value=") << HTML.escape(token) << %(">)
        end
        io << %(<button type="submit")
        attrs.each do |key, value|
          next if key == "type"
          append_attribute(io, key, value)
        end
        io << '>' << HTML.escape(text) << %(</button></form>)
      end
    end

    private def self.mailto_href(email : String, cc : String?, bcc : String?, subject : String?, body : String?) : String
      href = "mailto:#{email}"
      query = [] of String
      query << "cc=#{URI.encode_path_segment(cc)}" if cc
      query << "bcc=#{URI.encode_path_segment(bcc)}" if bcc
      query << "subject=#{URI.encode_path_segment(subject)}" if subject
      query << "body=#{URI.encode_path_segment(body)}" if body
      query.empty? ? href : "#{href}?#{query.join("&")}"
    end

    private def self.sanitize_attributes(segment : String, allowed : Array(String), io : IO) : Nil
      segment.scan(/\s+([a-zA-Z_:][-a-zA-Z0-9_:.]*)(?:\s*=\s*("[^"]*"|'[^']*'|[^\s"'>]+))?/) do |m|
        name = m[1].downcase
        next unless allowed.includes?(name)
        raw = m[2]?
        if raw
          value = raw
          value = value[1...-1] if value.size >= 2 && ((value.starts_with?('"') && value.ends_with?('"')) || (value.starts_with?('\'') && value.ends_with?('\'')))
          next if (name == "href" || name == "src") && !safe_sanitize_url?(value)
          io << ' ' << name << %(=") << escape_once(value) << '"'
        else
          io << ' ' << name
        end
      end
    end

    private def self.safe_sanitize_url?(value : String) : Bool
      cleaned = value.strip.downcase
      return true if cleaned.starts_with?("/") || cleaned.starts_with?("#") || cleaned.starts_with?("?")
      return false if cleaned.includes?(":") && !(cleaned.starts_with?("http://") || cleaned.starts_with?("https://") || cleaned.starts_with?("mailto:") || cleaned.starts_with?("tel:"))
      true
    end
  end

  # Stateful view helpers (slots, capture, cache predicates, meta tags) and
  # controller conveniences. `content` stays in views.cr for backward
  # compatibility; `content_for` is the named-slot API:
  #
  # ```
  # <% content_for(:head) { "<meta name=\"x\" content=\"y\">" } %>
  # <% content_for(:head) do %>
  #   <link rel="stylesheet" href="/page.css">
  # <% end %>
  # <%= content_for(:head) %>  <!-- in layouts/application.ecr -->
  # ```
  #
  # Both block forms work in ECR: markup written inside a `do ... end`
  # block is captured (see `Views::OutputBuffer`) instead of leaking into
  # the template at the call site.
  #
  # ECR has no `yield(:name)` (templates compile into controller methods),
  # so `yield(:head)` is spelled `content_for(:head)`; `yield_content(:head)`
  # is provided as a reading alias.
  class Controller
    def content_for(name : String | Symbol, value : String) : String
      slots = (@__content_for ||= {} of String => String)
      key = name.to_s
      slots[key] = (slots[key]? || "") + value
      ""
    end

    def content_for(name : String | Symbol, & : -> _) : String
      content_for(name, __saci_capture { yield })
    end

    def content_for(name : String | Symbol) : String
      (@__content_for ||= {} of String => String)[name.to_s]? || ""
    end

    def content_for?(name : String | Symbol) : Bool
      slots = @__content_for
      return false unless slots
      value = slots[name.to_s]?
      !!value && !value.empty?
    end

    def yield_content(name : String | Symbol) : String
      content_for(name)
    end

    # The markup a block renders: ECR written inside
    # `<% html = capture do %>…<% end %>`, or the block's String value.
    def capture(& : -> _) : String
      __saci_capture { yield }
    end

    def safe_join(parts : Array, separator : String = "") : String
      Views.safe_join(parts, separator)
    end

    def escape_once(text : String) : String
      Views.escape_once(text)
    end

    def cache_if(condition : Bool, key, expires_in : Time::Span? = nil, version : Int? = nil, &block : -> String) : String
      condition ? cache(key, expires_in, version, &block) : block.call
    end

    def cache_unless(condition : Bool, key, expires_in : Time::Span? = nil, version : Int? = nil, &block : -> String) : String
      cache_if(!condition, key, expires_in, version, &block)
    end

    def cache?(key, version : Int? = nil) : Bool
      full = Views.expand_fragment_key(key, version)
      !!Cache.read(full)
    rescue Cache::RedisDown
      false
    end

    def csrf_meta_tags : String
      Views.csrf_meta_tags(form_authenticity_token)
    end

    def csp_meta_tag(nonce : String? = nil, policy : String? = nil) : String
      Views.csp_meta_tag(nonce: nonce, policy: policy)
    end

    def number_to_currency(number : Int | Float, **options) : String
      Views.number_to_currency(number, **options)
    end

    def number_with_delimiter(number : Int | Float, **options) : String
      Views.number_with_delimiter(number, **options)
    end

    def number_with_precision(number : Int | Float, **options) : String
      Views.number_with_precision(number, **options)
    end

    def number_to_percentage(number : Int | Float, **options) : String
      Views.number_to_percentage(number, **options)
    end

    def number_to_human(number : Int | Float, **options) : String
      Views.number_to_human(number, **options)
    end

    def number_to_human_size(number : Int | Float, **options) : String
      Views.number_to_human_size(number, **options)
    end

    def time_ago_in_words(from_time : Time, include_seconds : Bool = false) : String
      Views.time_ago_in_words(from_time, include_seconds)
    end

    def distance_of_time_in_words(from_time : Time, to_time : Time = Time.utc, include_seconds : Bool = false) : String
      Views.distance_of_time_in_words(from_time, to_time, include_seconds)
    end

    def time_tag(time : Time, content : String? = nil, **attributes) : String
      Views.time_tag(time, content, **attributes)
    end

    def l(value : Time, format : String | Symbol | Nil = nil, locale : String | Symbol | Nil = nil) : String
      Views.l(value, format, locale)
    end

    def l(value : String, format : String | Symbol | Nil = nil, locale : String | Symbol | Nil = nil) : String
      Views.l(value, format, locale)
    end

    def simple_format(text : String, **attributes) : String
      Views.simple_format(text, **attributes)
    end

    def truncate(text : String, **options) : String
      Views.truncate(text, **options)
    end

    def truncate_words(text : String, **options) : String
      Views.truncate_words(text, **options)
    end

    def excerpt(text : String, phrase : String, **options) : String
      Views.excerpt(text, phrase, **options)
    end

    def pluralize(count : Int | Float | String, singular : String, plural : String? = nil) : String
      Views.pluralize(count, singular, plural)
    end

    def strip_tags(html : String) : String
      Views.strip_tags(html)
    end

    def strip_links(html : String) : String
      Views.strip_links(html)
    end

    def highlight(text : String, phrase : String, **options) : String
      Views.highlight(text, phrase, **options)
    end

    def word_wrap(text : String, **options) : String
      Views.word_wrap(text, **options)
    end

    def sanitize(html : String, **options) : String
      Views.sanitize(html, **options)
    end

    def escape_javascript(text : String) : String
      Views.escape_javascript(text)
    end

    def javascript_tag(content : String? = nil, **attributes) : String
      Views.javascript_tag(content, **attributes)
    end

    def javascript_tag(**attributes, &block : -> String) : String
      Views.javascript_tag(**attributes, &block)
    end

    def json_escape(json : String) : String
      Views.json_escape(json)
    end

    def tag(name : String | Symbol, options : Hash, content : String? = nil) : String
      Views.tag(name, options, content)
    end

    def tag(name : String | Symbol, options : NamedTuple, content : String? = nil) : String
      Views.tag(name, options, content)
    end

    def tag(name : String | Symbol, **attributes) : String
      Views.tag(name, **attributes)
    end

    def tag(name : String | Symbol, content : String, **attributes) : String
      Views.tag(name, content, **attributes)
    end

    def content_tag(name : String | Symbol, content : String? = nil, **attributes) : String
      Views.content_tag(name, content, **attributes)
    end

    def content_tag(name : String | Symbol, options : Hash, content : String? = nil) : String
      Views.content_tag(name, options, content)
    end

    def content_tag(name : String | Symbol, **attributes, &block : -> String) : String
      Views.content_tag(name, **attributes, &block)
    end

    def content_tag(name : String | Symbol, options : Hash, &block : -> String) : String
      Views.content_tag(name, options, &block)
    end

    def button_tag(content : String? = nil, **attributes) : String
      Views.button_tag(content, **attributes)
    end

    def button_tag(**attributes, &block : -> String) : String
      Views.button_tag(**attributes, &block)
    end

    def div_for(record : Saci::Record::Base, **attributes, &block : -> String) : String
      Views.div_for(record, **attributes, &block)
    end

    def button_to(text : String, url : String, method : String | Symbol = "post", **attributes) : String
      verb = method.to_s.downcase
      token = (verb == "get") ? nil : form_authenticity_token
      Views.button_to(text, url, method, token, **attributes)
    end

    def button_to(url : String, method : String | Symbol = "post", **attributes, &block : -> String) : String
      verb = method.to_s.downcase
      token = (verb == "get") ? nil : form_authenticity_token
      Views.button_to(url, method, token, **attributes, &block)
    end

    def link_to_if(condition : Bool, text : String, url : String, **attributes) : String
      Views.link_to_if(condition, text, url, **attributes)
    end

    def link_to_if(condition : Bool, url : String, **attributes, &block : -> String) : String
      Views.link_to_if(condition, url, **attributes, &block)
    end

    def link_to_unless(condition : Bool, text : String, url : String, **attributes) : String
      Views.link_to_unless(condition, text, url, **attributes)
    end

    def link_to_unless(condition : Bool, url : String, **attributes, &block : -> String) : String
      Views.link_to_unless(condition, url, **attributes, &block)
    end

    def mail_to(email : String, text : String? = nil, cc : String? = nil, bcc : String? = nil, subject : String? = nil, body : String? = nil, **attributes) : String
      Views.mail_to(email, text, cc, bcc, subject, body, **attributes)
    end

    def mail_to(email : String, cc : String? = nil, bcc : String? = nil, subject : String? = nil, body : String? = nil, **attributes, &block : -> String) : String
      Views.mail_to(email, cc, bcc, subject, body, **attributes, &block)
    end

    def phone_to(phone : String, text : String? = nil, **attributes) : String
      Views.phone_to(phone, text, **attributes)
    end

    def phone_to(phone : String, **attributes, &block : -> String) : String
      Views.phone_to(phone, **attributes, &block)
    end

    def sms_to(phone : String, text : String? = nil, body : String? = nil, **attributes) : String
      Views.sms_to(phone, text, body, **attributes)
    end

    def sms_to(phone : String, body : String? = nil, **attributes, &block : -> String) : String
      Views.sms_to(phone, body, **attributes, &block)
    end

    def dom_id(record : Saci::Record::Base, prefix : String | Symbol | Nil = nil) : String
      Views.dom_id(record, prefix)
    end

    def dom_class(record : Saci::Record::Base, prefix : String | Symbol | Nil = nil) : String
      Views.dom_class(record, prefix)
    end
  end
end
