require "ecr/lexer"

module Saci
  module CLI
    # `saci views:check [PATH]` — lints ECR templates for mistakes that
    # otherwise only show up when the page renders:
    #
    # - a block helper written as `<%= helper do %>` (ECR does not capture
    #   the block; use `<% helper do %> ... <% end %>`);
    # - an ECR tag inside a Crystal string literal (`"<%= @post.title %>"`);
    # - a `render_partial` / `render partial:` target that does not exist;
    # - an explicit `layout: "name"` whose `layouts/name.ecr` does not exist.
    #
    # Tokens come from the stdlib `ECR::Lexer` (`ecr/lexer`). It is marked
    # `:nodoc:`, like the rest of ECR's compiler plumbing, but `ECR.embed`
    # goes through it: multiline tags, `<%- -%>` trim markers, `<%%` escapes
    # and `<%# %>` comments are tokenized exactly as the compiler sees them.
    # If a future Crystal changes that API the linter stops compiling instead
    # of silently misparsing. An unclosed tag is reported as an issue instead
    # of aborting the run.
    #
    # The default path is `src/views`; a missing directory is an error and
    # any issue makes the command exit 1, so it can gate CI.
    #
    # Layout references live in controllers, so when PATH is a `views`
    # directory the sibling `controllers/**/*.cr` is scanned too. Dynamic
    # names (`"#{...}"`) and `layout: false` are never resolved to files, and
    # the implicit default layout (`application`) is not checked unless a
    # controller names it explicitly.
    module ViewsCheck
      record Issue, path : String, line : Int32, message : String

      PARTIAL_PATTERNS = [
        /render_partial\s*\(?\s*"([^"]+)"/,
        /render_partial\s*\(?\s*:"([^"]+)"/,
        /render_partial\s*\(?\s*:([A-Za-z0-9_\/]+)/,
        /render\s+partial:\s*"([^"]+)"/,
        /render\s+partial:\s*:"([^"]+)"/,
        /render\s+partial:\s*:([A-Za-z0-9_\/]+)/,
        /render_to_string\s*\([^)]*?partial:\s*"([^"]+)"/m,
        /render_to_string\s*\([^)]*?partial:\s*:"([^"]+)"/m,
      ]

      # A `layout:` option on a call that actually renders a layout. The
      # negative character class stops at a semicolon or a brace, which keeps
      # the match from wandering into the next statement or a hash literal.
      LAYOUT_CALL = /\brender(?:_template|_to_string)?\b[^;{}]*?\blayout:\s*"([^"]*)"/

      def self.run(args : Array(String), io : IO = STDOUT) : Int32
        path = "src/views"
        args.each do |arg|
          case arg
          when "-h", "--help"
            io.puts help
            return 0
          when .starts_with?("-")
            raise Error.new("Unknown option '#{arg}' for views:check.")
          else
            path = arg
          end
        end
        unless Dir.exists?(path)
          raise Error.new("No views directory at #{path}. Run from a Saci app or pass a path.")
        end

        issues = check(path)
        if issues.empty?
          io.puts "views:check: no issues in #{path}"
          0
        else
          issues.each { |issue| io.puts "#{issue.path}:#{issue.line}: #{issue.message}" }
          io.puts "views:check: #{issues.size} issue(s) in #{path}"
          1
        end
      end

      def self.help : String
        <<-HELP
        Usage: saci views:check [PATH]

        Checks ECR templates (default: src/views) for:
          - `<%= helper do %>`: block helpers need `<% helper do %> ... <% end %>`
          - ECR tags inside Crystal string literals
          - `render_partial` and `render partial:` targets that do not exist
          - explicit `layout: "name"` targets without `layouts/name.ecr`

        When PATH is a views directory, layout options in the sibling
        controllers directory are checked too. Dynamic paths (`\#{...}`) and
        `layout: false` are skipped.

        Exits 1 when it finds issues, 0 when the templates are clean.
        HELP
      end

      def self.check(dir : String) : Array(Issue)
        files = Dir.glob(File.join(dir, "**", "*.ecr")).sort
        issues = [] of Issue
        files.each { |file| issues.concat(check_file(file, dir)) }
        issues.concat(check_layout_references(dir))
        issues.uniq
      end

      def self.check_file(file : String, views_root : String) : Array(Issue)
        source = File.read(file)
        issues = [] of Issue
        lexer = ECR::Lexer.new(source)

        begin
          loop do
            token = lexer.next_token
            break if token.type.eof?

            code = token.value
            next if token.type.string? || code.starts_with?("#") || code.empty?

            base_line = token.line_number
            # Crystal comments are not template syntax; drop them before any
            # scanning so examples like `# render_partial("old")` stay quiet.
            cleaned = strip_code_comments(code)

            if token.type.output? && block_helper?(cleaned)
              issues << Issue.new(file, base_line,
                "block helper in `<%= %>`; use `<% ... do %> ... <% end %>`")
            end
            if nested_tag_in_string?(cleaned)
              issues << Issue.new(file, base_line,
                "ECR tag inside a string literal; render it outside the quotes")
            end

            issues.concat(partial_issues(file, views_root, cleaned, base_line))
            issues.concat(layout_issues(file, views_root, cleaned, base_line))
          end
        rescue ex : ECR::Lexer::SyntaxException
          # The lexer reports EOF, which for an unclosed tag is the last line
          # of the file. Point at the `<%` that opened it instead.
          line = unclosed_tag_line(source, ex.line_number)
          issues << Issue.new(file, line, "unterminated ECR tag (#{ex.message})")
        end

        issues
      end

      # True for `do` or `do |args|` at the end of an expression tag. A bare
      # `do` needs whitespace in front, which avoids treating `:do` and `@do`
      # as keywords. ECR writes the block body to the template buffer, so
      # wrapping the helper in `<%= %>` either prints the helper's own return
      # value or nothing useful.
      def self.block_helper?(code : String) : Bool
        cleaned = strip_code_comments(code).strip
        !!cleaned.match(/(?:\A|\s)do\s*(?:\|[^|]*\|)?\z/)
      end

      # Finds an ECR opening tag inside a Crystal double-quoted string.
      # Character literals are skipped so their quotes do not open a string,
      # and backslash escapes are honored so `"a \"<%= x %>\""` is caught.
      # A string that closes before the tag ends (`"<%"`, `"a <% b"`) is
      # just literal text; ECR's lexer ends the outer tag at the inner `%>`,
      # so the broken case is the one that leaves the string open.
      def self.nested_tag_in_string?(code : String) : Bool
        chars = code.chars
        index = 0
        in_string = false
        nested = false
        escaped = false

        while index < chars.size
          char = chars[index]

          if in_string
            if escaped
              escaped = false
            elsif char == '\\'
              escaped = true
            elsif char == '"'
              in_string = false
              nested = false
            elsif char == '<' && chars[index + 1]? == '%'
              nested = true
            end
          elsif char == '"'
            in_string = true
            nested = false
          elsif char == '\''
            # Skip the character literal (`'x'`, `'\\''`, ...).
            index += 1
            if index < chars.size
              index += 1 if chars[index] == '\\'
              index += 1
            end
            next
          end

          index += 1
        end

        in_string && nested
      end

      def self.partial_issues(file : String, views_root : String, code : String, base_line : Int32) : Array(Issue)
        issues = [] of Issue
        PARTIAL_PATTERNS.each do |pattern|
          code.scan(pattern) do |match|
            reference = match[1]
            next if reference.empty? || dynamic_reference?(reference)

            expected = partial_path(views_root, reference)
            next if expected && File.file?(expected)

            issues << Issue.new(file, line_for(code, base_line, match.begin(0)),
              "partial '#{reference}' not found (expected #{expected || reference})")
          end
        end
        issues
      end

      def self.layout_issues(file : String, views_root : String, code : String, base_line : Int32) : Array(Issue)
        issues = [] of Issue
        code.scan(LAYOUT_CALL) do |match|
          next unless layout_render_call?(match[0])
          next if inside_string?(code, match.begin(0))

          reference = match[1]
          next if reference.empty? || dynamic_reference?(reference)

          expected = layout_path(views_root, reference)
          next if expected && File.file?(expected)

          offset = match.begin(0) + (match[0].byte_index("layout:") || 0)
          issues << Issue.new(file, line_for(code, base_line, offset),
            "layout '#{reference}' not found (expected #{expected || reference})")
        end
        issues
      end

      # Layouts are controller-level, so a `views` root also pulls in its
      # sibling controllers. Other paths (spec fixtures, a single template
      # directory) only get the ECR checks.
      def self.check_layout_references(views_root : String) : Array(Issue)
        root = views_root.rstrip('/')
        root = "/" if root.empty?
        return [] of Issue unless File.basename(root) == "views"

        controllers = File.join(File.dirname(root), "controllers")
        return [] of Issue unless Dir.exists?(controllers)

        issues = [] of Issue
        Dir.glob(File.join(controllers, "**", "*.cr")).sort.each do |file|
          code = strip_code_comments(File.read(file))
          code.scan(LAYOUT_CALL) do |match|
            next unless layout_render_call?(match[0])
            next if inside_string?(code, match.begin(0))

            reference = match[1]
            next if reference.empty? || dynamic_reference?(reference)

            expected = layout_path(root, reference)
            next if expected && File.file?(expected)

            offset = match.begin(0) + (match[0].byte_index("layout:") || 0)
            issues << Issue.new(file, line_for(code, 1, offset),
              "layout '#{reference}' not found (expected #{expected || reference})")
          end
        end
        issues
      end

      # `render partial: ..., layout:` ignores the layout; only template/action
      # renders (and the `render_template`/`render_to_string` macros) use it.
      def self.layout_render_call?(call : String) : Bool
        return true if call.starts_with?("render_template") || call.starts_with?("render_to_string")

        head = call.byte_slice(0, call.byte_index("layout:") || 0)
        head.includes?("template:") || head.includes?("action:")
      end

      # Removes Crystal `#` comments while leaving string literals and newlines
      # intact, so line numbers still match the file and `#` inside a string is
      # not treated as a comment.
      def self.strip_code_comments(code : String) : String
        String.build do |io|
          quote = nil
          escaped = false
          in_comment = false

          code.each_char do |char|
            if in_comment
              if char == '\n'
                in_comment = false
                io << char
              end
            elsif quote
              io << char
              if escaped
                escaped = false
              elsif char == '\\'
                escaped = true
              elsif char == quote
                quote = nil
              end
            elsif char == '"' || char == '\''
              quote = char
              io << char
            elsif char == '#'
              in_comment = true
            else
              io << char
            end
          end
        end
      end

      # Whether a byte offset in Crystal source falls inside a double-quoted
      # string. Used to ignore examples in string literals; the opening quote
      # itself counts as outside.
      def self.inside_string?(source : String, byte_position : Int32) : Bool
        bytes = source.to_slice
        in_string = false
        in_char = false
        escaped = false
        index = 0
        limit = Math.min(byte_position, bytes.size)

        while index < limit
          byte = bytes[index]
          if in_string
            if escaped
              escaped = false
            elsif byte == '\\'.ord
              escaped = true
            elsif byte == '"'.ord
              in_string = false
            end
          elsif in_char
            if escaped
              escaped = false
            elsif byte == '\\'.ord
              escaped = true
            elsif byte == '\''.ord
              in_char = false
            end
          elsif byte == '"'.ord
            in_string = true
          elsif byte == '\''.ord
            in_char = true
          end
          index += 1
        end

        in_string
      end

      def self.line_for(text : String, base_line : Int32, byte_offset : Int32) : Int32
        base_line + text.byte_slice(0, byte_offset).count('\n')
      end

      def self.unclosed_tag_line(source : String, fallback : Int32) : Int32
        index = source.rindex("<%")
        return fallback unless index
        byte_index = source.char_index_to_byte_index(index)
        return fallback unless byte_index
        line_for(source, 1, byte_index)
      end

      def self.dynamic_reference?(reference : String) : Bool
        reference.includes?("\#{")
      end

      # `render_partial("shared/row")` resolves to `src/views/shared/row.ecr`;
      # dynamic paths (`"#{...}"`) are skipped by `partial_issues`.
      def self.partial_path(views_root : String, reference : String) : String?
        return nil if dynamic_reference?(reference)
        relative = reference.lchop('/')
        relative += ".ecr" unless relative.ends_with?(".ecr")
        File.join(views_root, relative)
      end

      # `layout: "admin"` resolves to `src/views/layouts/admin.ecr`, exactly
      # like `render_template`'s macro expansion.
      def self.layout_path(views_root : String, reference : String) : String?
        return nil if dynamic_reference?(reference)
        File.join(views_root, "layouts", "#{reference.lchop('/')}.ecr")
      end
    end
  end
end
