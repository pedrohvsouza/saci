require "./util"

module Saci
  module CLI
    # Edits the app's router in place. `saci new` draws routes inline in
    # `src/<app>.cr`; apps that extract them may have a `src/routes.cr`
    # with `Router.new.draw` or `Routes.define`. Both are supported, and
    # the block variable (`|r|`) is preserved.
    #
    # Edits are line-based and stay "add if absent", so rerunning a
    # generator (including with `--force`) never duplicates a route. The
    # caller falls back to printing the old hint when no draw block is
    # found.
    module RouterEdit
      enum Result
        Updated
        Unchanged
        NotFound
      end

      record Block, open : Int32, close : Int32, indent : String, var : String

      DRAW     = /^(\s*)(?:[a-z_]\w*\s*=\s*)?(?:Saci::)?Router\.new\.draw\s+do\s+\|(\w+)\|/
      DEFINE   = /^(\s*)(?:Saci::)?Routes\.define\s+[\w:]+\s+do\s+\|(\w+)\|/
      END_LINE = /^(\s*)end\s*$/

      # Adds `routes` (full DSL lines) before the draw block's `end`, and
      # `requires` after the file's last require. Returns `NotFound` when
      # no draw block exists (the caller prints the copy-paste hint).
      def self.add(routes : Array(String), requires : Array(String) = [] of String,
                   pretend : Bool = false, io : IO = STDOUT) : Result
        located = locate_for_add
        return Result::NotFound unless located
        path, lines, draw = located

        missing = routes.reject { |route| present?(lines, route) }
        missing_requires = requires.reject { |req| present?(lines, req) }
        return Result::Unchanged if missing.empty? && missing_requires.empty?

        updated = lines.dup
        unless missing_requires.empty?
          at = last_require_index(updated)
          indent = at ? indent_of(updated[at]) : ""
          missing_requires.reverse_each do |req|
            updated.insert(at ? at + 1 : 0, "#{indent}#{req}")
          end
        end

        missing.each do |route|
          draw = find_draw(updated) || draw
          updated.insert(draw.close, "#{draw.indent}  #{with_var(route, draw.var)}")
        end

        report(io, path, missing_requires + missing, pretend, "add")
        write(path, updated) unless pretend
        Result::Updated
      end

      # Adds `resource` under `r.namespace(prefix)`, reusing an existing
      # namespace block or creating one at the end of the draw block.
      def self.add_namespace(prefix : String, resource : String, controller : String,
                             pretend : Bool = false, io : IO = STDOUT) : Result
        located = locate_for_add
        return Result::NotFound unless located
        path, lines, draw = located
        suffix = %(resources "#{resource}", #{controller})
        return Result::Unchanged if lines.any? { |line| normalized(line).ends_with?(suffix) }

        updated = lines.dup
        if namespace = find_namespace(updated, draw, prefix)
          line = "#{namespace.indent}  #{namespace.var}.#{suffix}"
          updated.insert(namespace.close, line)
          additions = [line.strip]
        else
          var = draw.var == "a" ? "admin" : "a"
          block = [
            "#{draw.indent}  #{draw.var}.namespace(\"#{prefix}\") do |#{var}|",
            "#{draw.indent}    #{var}.#{suffix}",
            "#{draw.indent}  end",
          ]
          block.each_with_index { |line, index| updated.insert(draw.close + index, line) }
          additions = block.map(&.strip)
        end

        report(io, path, additions, pretend, "add")
        write(path, updated) unless pretend
        Result::Updated
      end

      # Removes exact route/require lines (ignoring the receiver name).
      # Missing lines are ignored: the app has already been edited by hand.
      def self.remove(routes : Array(String), requires : Array(String) = [] of String,
                      pretend : Bool = false, io : IO = STDOUT) : Result
        targets = (routes + requires).map { |line| normalized(line) }
        candidates.each do |path|
          lines = read_lines(path)
          kept = lines.reject { |line| targets.includes?(normalized(line)) }
          next if kept.size == lines.size
          removed = lines.reject { |line| kept.includes?(line) }
          report(io, path, removed, pretend, "remove")
          write(path, kept) unless pretend
          return Result::Updated
        end
        Result::Unchanged
      end

      def self.candidates : Array(String)
        paths = [] of String
        paths << "src/routes.cr" if File.file?("src/routes.cr")
        if name = Util.app_name?
          entry = File.join("src", "#{name}.cr")
          paths << entry if File.file?(entry)
        end
        paths.uniq
      end

      def self.read_lines(path : String) : Array(String)
        File.read(path).lines
      end

      def self.write(path : String, lines : Array(String)) : Nil
        trailing = File.read(path).ends_with?('\n') ? "\n" : ""
        File.write(path, lines.join('\n') + trailing)
      end

      private def self.locate_for_add : Tuple(String, Array(String), Block)?
        candidates.each do |path|
          lines = read_lines(path)
          if draw = find_draw(lines)
            return {path, lines, draw}
          end
        end
        nil
      end

      private def self.find_draw(lines : Array(String)) : Block?
        lines.each_with_index do |line, index|
          match = line.match(DRAW) || line.match(DEFINE)
          next unless match
          close = find_close(lines, index, match[1].size)
          return Block.new(index, close, match[1], match[2]) if close
        end
        nil
      end

      private def self.find_namespace(lines : Array(String), draw : Block, prefix : String) : Block?
        pattern = /^(\s*)(\w+)\.namespace\(\s*["']#{Regex.escape(prefix)}["']\s*\)\s+do\s+\|(\w+)\|/
        (draw.open + 1...draw.close).each do |index|
          match = lines[index].match(pattern)
          next unless match
          close = find_close(lines, index, match[1].size)
          return Block.new(index, close, match[1], match[3]) if close
        end
        nil
      end

      # First `end` at or above the block's indentation. Router blocks are
      # formatter-clean, so nested `end`s are always more indented.
      private def self.find_close(lines : Array(String), open : Int32, indent : Int32) : Int32?
        (open + 1...lines.size).each do |index|
          match = lines[index].match(END_LINE)
          return index if match && match[1].size <= indent
        end
        nil
      end

      private def self.present?(lines : Array(String), line : String) : Bool
        wanted = normalized(line)
        lines.any? { |candidate| normalized(candidate) == wanted }
      end

      # Drops the receiver (`r.get` and `a.get` compare equal) and the
      # draw-variable argument (`Routes.draw_posts(r)`/`(router)`), so
      # edits survive a renamed block variable.
      private def self.normalized(line : String) : String
        line.strip.sub(/\A[A-Za-z_]\w*\./, "").sub(/\(\w+\)\z/, "(__draw__)")
      end

      private def self.with_var(line : String, var : String) : String
        return line if var == "r"
        line = line.sub(/\Ar\./, "#{var}.")
        line.sub(/\(r\)\z/, "(#{var})")
      end

      private def self.last_require_index(lines : Array(String)) : Int32?
        found = nil
        lines.each_with_index { |line, index| found = index if line =~ /^\s*require\s+/ }
        found
      end

      private def self.indent_of(line : String) : String
        line[/\A\s*/] || ""
      end

      private def self.report(io : IO, path : String, lines : Array(String), pretend : Bool, action : String) : Nil
        io.puts "  #{pretend ? "would update" : "update"} #{path} (#{action} routes)"
        lines.each { |line| io.puts "    #{action == "add" ? "+" : "-"} #{line.strip}" }
      end
    end
  end
end
