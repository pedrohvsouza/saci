module Saci
  module CLI
    # `saci views:check [PATH]` — lints ECR templates for mistakes that
    # otherwise only show up when the page renders:
    #
    # - a block helper written as `<%= helper do %>` (ECR does not capture
    #   the block; use `<% helper do %> ... <% end %>`);
    # - an ECR tag inside a Crystal string literal (`"<%= @post.title %>"`);
    # - a `render_partial` / `render partial:` target that does not exist.
    #
    # The default path is `src/views`; a missing directory is an error and
    # any issue makes the command exit 1, so it can gate CI.
    module ViewsCheck
      record Issue, path : String, line : Int32, message : String

      ECR_TAG          = /<%(=?|#)?(.*?)%>/m
      ECR_COMMENT      = /<%#.*?%>/m
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

        Exits 1 when it finds issues, 0 when the templates are clean.
        HELP
      end

      def self.check(dir : String) : Array(Issue)
        files = Dir.glob(File.join(dir, "**", "*.ecr")).sort
        issues = [] of Issue
        files.each { |file| issues.concat(check_file(file, dir)) }
        issues
      end

      def self.check_file(file : String, views_root : String) : Array(Issue)
        source = File.read(file)
        issues = [] of Issue

        source.scan(ECR_TAG) do |match|
          mode = match[1]? || ""
          code = match[2]
          line = 1 + source[0...match.begin(0)].count('\n')
          next if mode == "#"

          if mode == "=" && block_helper?(code)
            issues << Issue.new(file, line, "block helper in `<%= %>`; use `<% ... do %> ... <% end %>`")
          end
          if nested_tag_in_string?(code)
            issues << Issue.new(file, line, "ECR tag inside a string literal; render it outside the quotes")
          end
        end

        partials(source).each do |(reference, line)|
          expected = partial_path(views_root, reference)
          next if expected && File.file?(expected)
          issues << Issue.new(file, line,
            "partial '#{reference}' not found (expected #{expected || reference})")
        end

        issues
      end

      # `do` and `do |args|` at the end of an expression tag. ECR writes the
      # block body to the template buffer, so wrapping the helper in `<%= %>`
      # either prints the helper's own return value or nothing useful.
      def self.block_helper?(code : String) : Bool
        cleaned = code.sub(/\s*#.*\z/m, "").strip
        cleaned = cleaned.rchop.rstrip if cleaned.ends_with?("-")
        !!cleaned.match(/\bdo\s*(?:\|[^|]*\|)?\z/)
      end

      # Finds an ECR opening tag inside Crystal double/single-quoted strings.
      # Backslash escapes are skipped so `"a \"<%= x %>\""` is still caught.
      def self.nested_tag_in_string?(code : String) : Bool
        quote = nil
        escaped = false
        code.each_char.with_index do |char, index|
          if quote
            if escaped
              escaped = false
            elsif char == '\\'
              escaped = true
            elsif char == quote
              quote = nil
            elsif char == '<' && code[index + 1]? == '%'
              return true
            end
          elsif char == '"' || char == '\''
            quote = char
          end
        end
        false
      end

      # Literal partial references and the line they appear on. ECR
      # comments are blanked first so examples in them do not count.
      def self.partials(source : String) : Array(Tuple(String, Int32))
        clean = source.gsub(ECR_COMMENT) { |comment| "\n" * comment.count('\n') }
        found = [] of Tuple(String, Int32)
        PARTIAL_PATTERNS.each do |pattern|
          clean.scan(pattern) do |match|
            reference = match[1]
            next if reference.empty? || reference.includes?("\#{")
            line = 1 + clean[0...match.begin(0)].count('\n')
            entry = {reference, line}
            found << entry unless found.includes?(entry)
          end
        end
        found
      end

      # `render_partial("shared/row")` resolves to `src/views/shared/row.ecr`;
      # dynamic paths (`"#{...}"`) are skipped by `partials`.
      def self.partial_path(views_root : String, reference : String) : String?
        return nil if reference.includes?("\#{")
        relative = reference.lchop('/')
        relative += ".ecr" unless relative.ends_with?(".ecr")
        File.join(views_root, relative)
      end
    end
  end
end
