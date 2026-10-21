require "html"

module Saci
  module Testing
    # Minimal CSS-ish selector engine for `assert_select`.
    #
    # Supported: tag names, `#id`, `.class` (multiple), `[attr=value]`, and
    # the descendant combinator (`div#main p.lead`). This is deliberately
    # not a full CSS engine: no pseudo-classes, sibling/child combinators,
    # attribute operators, or specificity.
    module AssertSelect
      class Element
        getter tag : String
        getter attributes : Hash(String, String)
        getter children : Array(Element)
        getter text_parts : Array(String)

        def initialize(@tag : String, @attributes : Hash(String, String) = {} of String => String)
          @children = [] of Element
          @text_parts = [] of String
        end

        # Visible text of this element and its descendants, with runs of
        # whitespace collapsed (matches the usual `assert_select text:`
        # expectation for formatted HTML).
        def text : String
          raw = String.build { |io| append_text(io) }
          raw.gsub(/\s+/, " ").strip
        end

        def append_text(io : IO) : Nil
          @text_parts.each { |part| io << part }
          @children.each(&.append_text(io))
        end

        def descendants : Array(Element)
          result = [] of Element
          @children.each do |child|
            result << child
            result.concat(child.descendants)
          end
          result
        end
      end

      VOID_ELEMENTS = %w(area base br col embed hr img input link meta param source track wbr)

      class Parser
        def self.parse(html : String) : Element
          new.parse(html)
        end

        def parse(html : String) : Element
          root = Element.new("#document")
          stack = [root]
          pos = 0
          size = html.size

          while pos < size
            lt = html.index('<', pos)
            if lt.nil?
              append_text(stack.last, html[pos..-1])
              break
            end
            append_text(stack.last, html[pos...lt]) if lt > pos

            if html[lt, 4]? == "<!--"
              finish = html.index("-->", lt + 4)
              pos = finish ? finish + 3 : size
              next
            end
            if html[lt, 2]? == "<!" || html[lt, 2]? == "<?"
              finish = html.index('>', lt + 2)
              pos = finish ? finish + 1 : size
              next
            end

            close = tag_end(html, lt + 1)
            if close.nil?
              append_text(stack.last, html[lt..-1])
              break
            end

            raw = html[(lt + 1)...close]
            if raw.starts_with?("/")
              name = raw[1..].strip.split(/\s+/, 2)[0]?.try(&.downcase) || ""
              pop_to(stack, name)
              pos = close + 1
              next
            end

            self_closing = raw.ends_with?('/')
            raw = raw[0...-1] if self_closing
            stripped = raw.lstrip
            name = stripped[/\A([A-Za-z][\w:-]*)/, 1]?
            if name.nil? || name.empty?
              pos = close + 1
              next
            end
            name = name.downcase
            attr_source = stripped[name.size..]
            element = Element.new(name, parse_attributes(attr_source))
            stack.last.children << element

            if name == "script" || name == "style"
              # Raw-text elements: everything up to the closing tag is text
              # (never parsed as markup).
              closing = html.index("</#{name}", close + 1)
              if closing
                append_text(element, html[(close + 1)...closing])
                tag_close = html.index('>', closing)
                pos = tag_close ? tag_close + 1 : size
              else
                append_text(element, html[(close + 1)..-1])
                pos = size
              end
              next
            end

            unless self_closing || VOID_ELEMENTS.includes?(name)
              stack << element
            end
            pos = close + 1
          end

          root
        end

        private def append_text(node : Element, text : String) : Nil
          node.text_parts << HTML.unescape(text)
        end

        private def pop_to(stack : Array(Element), name : String) : Nil
          return if name.empty?
          index = stack.rindex { |el| el.tag == name }
          # Pop the matching element itself plus any unclosed children.
          # Never pop the synthetic document root.
          stack.pop(stack.size - index) if index && index > 0
        end

        private def tag_end(html : String, start : Int32) : Int32?
          quote : Char? = nil
          i = start
          while i < html.size
            ch = html[i]
            if q = quote
              quote = nil if ch == q
            elsif ch == '"' || ch == '\''
              quote = ch
            elsif ch == '>'
              return i
            end
            i += 1
          end
          nil
        end

        private def parse_attributes(source : String) : Hash(String, String)
          attrs = {} of String => String
          source.scan(/([A-Za-z_:][-A-Za-z0-9_:.]*)\s*(?:=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?/) do |match|
            name = match[1].downcase
            value = match[2]? || match[3]? || match[4]? || ""
            attrs[name] = HTML.unescape(value)
          end
          attrs
        end
      end

      class SimpleSelector
        getter tag : String?
        getter id : String?
        getter classes : Array(String)
        getter attrs : Array(Tuple(String, String))

        def initialize(@tag : String?, @id : String?, @classes : Array(String), @attrs : Array(Tuple(String, String)))
        end
      end

      # Parses a selector into descendant-combined simple selectors.
      def self.parse_selector(selector : String) : Array(SimpleSelector)
        parts = split_selector(selector)
        raise ArgumentError.new("assert_select: empty selector") if parts.empty?
        parts.map { |part| parse_simple(part) }
      end

      private def self.split_selector(selector : String) : Array(String)
        parts = [] of String
        current = IO::Memory.new
        bracket = 0
        quote : Char? = nil
        selector.each_char do |ch|
          if q = quote
            current << ch
            quote = nil if ch == q
          elsif ch == '"' || ch == '\''
            quote = ch
            current << ch
          elsif ch == '['
            bracket += 1
            current << ch
          elsif ch == ']'
            bracket -= 1 if bracket > 0
            current << ch
          elsif ch.whitespace? && bracket == 0
            value = current.to_s
            parts << value unless value.empty? || value == ">"
            current = IO::Memory.new
          else
            current << ch
          end
        end
        value = current.to_s
        parts << value unless value.empty? || value == ">"
        parts
      end

      private def self.parse_simple(part : String) : SimpleSelector
        i = 0
        size = part.size
        tag : String? = nil
        id : String? = nil
        classes = [] of String
        attrs = [] of Tuple(String, String)

        if i < size && part[i] != '#' && part[i] != '.' && part[i] != '['
          start = i
          while i < size && (part[i].alphanumeric? || part[i] == '-' || part[i] == '_' || part[i] == ':')
            i += 1
          end
          tag = part[start...i].downcase
        end

        while i < size
          case part[i]
          when '#'
            i += 1
            start = i
            while i < size && (part[i].alphanumeric? || part[i] == '-' || part[i] == '_')
              i += 1
            end
            id = part[start...i]
          when '.'
            i += 1
            start = i
            while i < size && (part[i].alphanumeric? || part[i] == '-' || part[i] == '_')
              i += 1
            end
            classes << part[start...i]
          when '['
            finish = part.index(']', i + 1)
            raise ArgumentError.new("assert_select: unterminated attribute selector in #{part.inspect}") unless finish
            content = part[(i + 1)...finish]
            pieces = content.split('=', 2)
            name = pieces[0].strip.downcase
            value = pieces[1]?.try(&.strip) || ""
            if value.size >= 2 && ((value.starts_with?('"') && value.ends_with?('"')) || (value.starts_with?('\'') && value.ends_with?('\'')))
              value = value[1...-1]
            end
            attrs << {name, value}
            i = finish + 1
          else
            raise ArgumentError.new("assert_select: unsupported selector character #{part[i].inspect} in #{part.inspect}")
          end
        end

        if tag.nil? && id.nil? && classes.empty? && attrs.empty?
          raise ArgumentError.new("assert_select: empty simple selector in #{part.inspect}")
        end
        SimpleSelector.new(tag, id, classes, attrs)
      end

      def self.select(html : String, selector : String) : Array(Element)
        root = Parser.parse(html)
        current = [root]
        parse_selector(selector).each do |simple|
          next_level = [] of Element
          current.each do |node|
            node.descendants.each do |candidate|
              next_level << candidate if matches?(candidate, simple)
            end
          end
          current = next_level.uniq
        end
        current
      end

      private def self.matches?(element : Element, simple : SimpleSelector) : Bool
        return false if (tag = simple.tag) && element.tag != tag
        return false if (id = simple.id) && element.attributes["id"]? != id

        unless simple.classes.empty?
          actual = (element.attributes["class"]? || "").split(/\s+/)
          simple.classes.each { |name| return false unless actual.includes?(name) }
        end

        simple.attrs.each do |(name, value)|
          return false unless element.attributes[name]? == value
        end
        true
      end
    end

    # Minimal `assert_select` over an HTTP response or HTML string.
    #
    # ```
    # resp = app.get("/")
    # assert_select resp, "div#main.page", count: 1
    # assert_select resp, "div#main p.lead", text: "Welcome"
    # assert_select resp, "li.item", count: 2
    # ```
    def self.assert_select(html : String | HTTP::Client::Response, selector : String,
                           text : String | Regex | Nil = nil, count : Int32? = nil,
                           message : String? = nil, file : String = __FILE__, line : Int32 = __LINE__) : Array(AssertSelect::Element)
      body = html.is_a?(HTTP::Client::Response) ? html.body : html
      elements = AssertSelect.select(body, selector)
      if expected_text = text
        elements = elements.select do |element|
          if expected_text.is_a?(Regex)
            !(element.text =~ expected_text).nil?
          else
            element.text == expected_text
          end
        end
      end

      if expected = count
        unless elements.size == expected
          detail = "expected #{expected} element(s) matching #{selector.inspect}, got #{elements.size}"
          detail += " with text #{text.inspect}" if text
          raise Spec::AssertionFailed.new(message ? "#{message}: #{detail}" : detail, file, line)
        end
      elsif elements.empty?
        detail = "expected at least one element matching #{selector.inspect}, got none"
        detail += " with text #{text.inspect}" if text
        raise Spec::AssertionFailed.new(message ? "#{message}: #{detail}" : detail, file, line)
      end

      elements
    end

    module AssertSelectDSL
      def assert_select(html : String | HTTP::Client::Response, selector : String,
                        text : String | Regex | Nil = nil, count : Int32? = nil,
                        message : String? = nil, file : String = __FILE__, line : Int32 = __LINE__) : Array(Saci::Testing::AssertSelect::Element)
        Saci::Testing.assert_select(html, selector, text, count, message, file, line)
      end
    end
  end
end
