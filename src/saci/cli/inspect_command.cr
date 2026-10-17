module Saci
  module CLI
    # `saci routes` / `runner` / `console` / `db:seed` (Task D: CLI gaps).
    #
    # All four share one rule: the web server is never booted. `routes` is
    # a static parse (no compile at all); `runner`/`console`/`db:seed`
    # compile a temp wrapper under `tmp/` (deleted after, Db.run pattern)
    # that loads models + connects the DB, then runs code — the Rails
    # runner/seeds equivalent and the only way to run ops scripts.
    module Inspect
      # `saci routes` — prints `VERB PATH -> Controller#action` WITHOUT
      # booting the server (or compiling anything).
      #
      # Static, best-effort parse of the route DSL. Reads `src/routes.cr`
      # when it exists (extracted route-builder convention), otherwise the
      # app entrypoint `src/<app>.cr` (`saci new` draws routes inline
      # there). Plain block routes show as `(block)`, redirects as
      # `redirect -> <to>`, websocket/cable endpoints as `WS`. A
      # per-route `constraints:` shows as a `[constraints]` suffix when
      # trivially visible on the same line. Namespace/scope prefixes are
      # applied via best-effort `do`/`end` depth tracking (documented
      # limitation: highly dynamic route code may misparse — the server
      # itself is the source of truth at runtime).
      module Routes
        record Row, verb : String, path : String, target : String

        def self.run(args : Array(String)) : Int32
          if args == ["-h"] || args == ["--help"] || args == ["help"]
            puts help
            return 0
          end
          if bad = args.find(&.starts_with?("-"))
            raise Error.new("Unknown option '#{bad}'. See `saci help routes`.")
          end
          name = Util.shard_name(Dir.current)
          source = locate!(name)
          rows = parse(File.read(source))
          if rows.empty?
            puts "(no routes found in #{source})"
          else
            width = rows.map(&.path.size).max
            rows.each do |r|
              puts "#{r.verb.ljust(6)} #{r.path.ljust(width)} #{r.target}"
            end
          end
          0
        end

        def self.help : String
          "Usage: saci routes\n\nPrints VERB PATH -> Controller#action for the app without booting the server.\nReads src/routes.cr when present, otherwise src/<app>.cr."
        end

        def self.locate!(name : String) : String
          return "src/routes.cr" if File.exists?("src/routes.cr")
          entry = File.join("src", "#{name}.cr")
          return entry if File.exists?(entry)
          raise Error.new("No routes found: expected src/routes.cr or #{entry}. Extract your routes into src/routes.cr or run from your app directory.")
        end

        def self.parse(source : String) : Array(Row)
          rows = [] of Row
          prefixes = [] of String
          pushed_at = [] of Int32
          depth = 0
          source.each_line do |line|
            stripped = line.lstrip
            next if stripped.starts_with?("#")
            if m = line.match(/[A-Za-z_]\w*\.(?:namespace|scope)\(\s*["']([^"']+)["']/)
              if line.includes?(" do")
                prefixes << clean_prefix(m[1])
                pushed_at << depth
              end
            elsif m = line.match(/[A-Za-z_]\w*\.root\s+([\w:]+)\s*,\s*:(\w+)/)
              rows << Row.new("GET", full_path(prefixes, "/"), "#{m[1]}##{m[2]}")
            elsif m = line.match(/[A-Za-z_]\w*\.resources\s+["']([^"']+)["']\s*,\s*([\w:]+)(.*)/)
              rows.concat(expand_resources(prefixes, m[1], m[2], m[3]))
            elsif m = line.match(/[A-Za-z_]\w*\.redirect\(\s*["']([^"']+)["']\s*,\s*to:\s*["']([^"']+)["']/)
              rows << Row.new("GET", full_path(prefixes, m[1]), "redirect -> #{m[2]}")
            elsif m = line.match(/[A-Za-z_]\w*\.websocket\(\s*["']([^"']+)["']/)
              rows << Row.new("WS", full_path(prefixes, m[1]), "(socket)")
            elsif m = line.match(/[A-Za-z_]\w*\.cable\s+["']([^"']+)["']\s*,\s*(.+)/)
              rows << Row.new("WS", full_path(prefixes, m[1]), "cable -> #{m[2].strip}")
            elsif m = line.match(/[A-Za-z_]\w*\.fallback\s+([\w:]+)\s*,\s*:(\w+)/)
              rows << Row.new("*", "*", "#{m[1]}##{m[2]} (fallback)")
            elsif m = line.match(/[A-Za-z_]\w*\.(get|post|put|patch|delete)\s*\(?\s*["']([^"']+)["'](.*)/)
              verb = m[1].upcase
              path = full_path(prefixes, m[2])
              rest = m[3]
              if cm = rest.match(/,\s*([\w:]+)\s*,\s*:(\w+)/)
                target = "#{cm[1]}##{cm[2]}"
                target += " [constraints]" if rest.includes?("constraints:")
                rows << Row.new(verb, path, target)
              else
                rows << Row.new(verb, path, "(block)")
              end
            end
            depth += line.scan(/\bdo\b/).size - line.scan(/\bend\b/).size
            while !pushed_at.empty? && pushed_at.last >= depth
              pushed_at.pop
              prefixes.pop
            end
          end
          rows
        end

        private def self.clean_prefix(raw : String) : String
          p = raw.starts_with?("/") ? raw : "/#{raw}"
          p.ends_with?("/") ? p[0...-1] : p
        end

        private def self.full_path(prefixes : Array(String), path : String) : String
          p = path.starts_with?("/") ? path : "/#{path}"
          (prefixes.join("") + p).gsub(/\/+/, "/")
        end

        # Mirrors Router registration order (index, new, show, create,
        # update x2, destroy, edit) honoring trivially parseable
        # only:/except: symbol lists.
        private def self.expand_resources(prefixes : Array(String), name : String, controller : String, rest : String) : Array(Row)
          actions = ["index", "new", "show", "create", "update", "destroy", "edit"]
          if m = rest.match(/only:\s*\[([^\]]*)\]/)
            only = m[1].scan(/:(\w+)/).map { |s| s[1] }
            actions = actions & only
          end
          if m = rest.match(/except:\s*\[([^\]]*)\]/)
            except = m[1].scan(/:(\w+)/).map { |s| s[1] }
            actions = actions - except
          end
          base = full_path(prefixes, name.starts_with?("/") ? name : "/#{name}")
          rows = [] of Row
          rows << Row.new("GET", base, "#{controller}#index") if actions.includes?("index")
          rows << Row.new("GET", "#{base}/new", "#{controller}#new") if actions.includes?("new")
          rows << Row.new("GET", "#{base}/:id", "#{controller}#show") if actions.includes?("show")
          rows << Row.new("POST", base, "#{controller}#create") if actions.includes?("create")
          if actions.includes?("update")
            rows << Row.new("PUT", "#{base}/:id", "#{controller}#update")
            rows << Row.new("PATCH", "#{base}/:id", "#{controller}#update")
          end
          rows << Row.new("DELETE", "#{base}/:id", "#{controller}#destroy") if actions.includes?("destroy")
          rows << Row.new("GET", "#{base}/:id/edit", "#{controller}#edit") if actions.includes?("edit")
          rows
        end
      end

      # `saci runner -e CODE` / `saci runner FILE [args] [-- crystal flags]`
      # — runs code/file in app context (models loaded, DB connected, server
      # never booted). The Rails runner equivalent; this is how apps run
      # seeds and ops scripts. Compiles a temp wrapper under `tmp/`
      # (deleted after, Db.run pattern). Args after the file are passed
      # through as ARGV; everything after `--` is forwarded to `crystal`
      # as compiler flags.
      module Runner
        def self.run(args : Array(String)) : Int32
          if args == ["-h"] || args == ["--help"] || args == ["help"]
            puts help
            return 0
          end
          code = nil
          file = nil
          script_args = [] of String
          crystal_flags = [] of String
          forward = false
          i = 0
          while i < args.size
            a = args[i]
            if forward
              crystal_flags << a
            elsif a == "--"
              forward = true
            elsif a == "-e" || a == "--eval"
              raise Error.new("Pass either -e CODE or a file, not both.") if file
              code = args[i + 1]? || raise Error.new("Missing value for -e. See `saci help runner`.")
              i += 1
            elsif a.starts_with?("-")
              raise Error.new("Unknown option '#{a}'. See `saci help runner`.")
            elsif file.nil?
              file = a
            else
              script_args << a
            end
            i += 1
          end
          if c = code
            raise Error.new("Pass either -e CODE or a file, not both.") if file
            run_code(c, script_args, crystal_flags)
          elsif f = file
            run_file(f, script_args, crystal_flags)
          else
            raise Error.new("Usage: saci runner -e CODE | saci runner FILE [args] [-- crystal flags]")
          end
        end

        def self.help : String
          "Usage: saci runner -e CODE | saci runner FILE [args] [-- crystal flags]\n\nRuns code/file in app context (models loaded, DB connected, server never booted)."
        end

        def self.run_code(code : String, script_args : Array(String) = [] of String, crystal_flags : Array(String) = [] of String) : Int32
          with_wrapper do |path|
            File.write(path, wrapper_source(code_body: code))
            exec_wrapper(path, script_args, crystal_flags)
          end
        end

        def self.run_file(file : String, script_args : Array(String) = [] of String, crystal_flags : Array(String) = [] of String) : Int32
          raise Error.new("File #{file} not found.") unless File.exists?(file)
          with_wrapper do |path|
            File.write(path, wrapper_source(require_file: file))
            exec_wrapper(path, script_args, crystal_flags)
          end
        end

        def self.with_wrapper(& : String -> Int32) : Int32
          Dir.mkdir_p("tmp")
          path = File.join("tmp", ".saci-runner-#{Process.pid}-#{Random.rand(1_000_000)}.cr")
          begin
            yield path
          ensure
            File.delete(path) if File.exists?(path)
          end
        end

        # Builds the wrapper source. The payload is appended verbatim
        # (never interpolated), so user code containing `#{}` is safe.
        def self.wrapper_source(code_body : String? = nil, require_file : String? = nil) : String
          name = Util.shard_name(Dir.current)
          String.build do |io|
            io << framework_require_line << "\n"
            io << "require \"file_utils\"\n"
            io << driver_require_line(name)
            ["models", "controllers", "channels", "jobs", "mailers"].each do |d|
              io << "require \"../src/#{d}/*\"\n" if Dir.exists?(File.join("src", d))
            end
            io << "\nFileUtils.mkdir_p(\"db\")\n"
            io << "env_name = ENV.fetch(\"APP_ENV\", \"development\")\n"
            io << "db_url = ENV.fetch(\"DATABASE_URL\", \"#{db_default(name)}\")\n"
            io << "Saci::Record.connect(db_url)\n"
            io << "Saci::I18n.reload!\n"
            if rf = require_file
              io << "require \"#{relative_from_tmp(rf)}\"\n"
            elsif cb = code_body
              io << "\n" << cb << "\n"
            end
          end
        end

        # Bare `require "saci"` when the app has its dependency installed
        # (the db/migrate.cr convention); otherwise a file-relative require
        # back to this CLI's own source tree (spec fixtures skip shards).
        def self.framework_require_line : String
          return "require \"saci\"" if Dir.exists?("lib/saci")
          tmpdir = File.expand_path("tmp")
          target = File.join(New::SACI_ROOT, "src", "saci")
          rel = relativize(tmpdir, target)
          "require \"#{rel}\""
        end

        def self.db_kind(name : String) : String
          entry = File.join("src", "#{name}.cr")
          return "sqlite" unless File.exists?(entry)
          src = File.read(entry)
          return "postgres" if src.includes?("require \"pg\"")
          return "mysql" if src.includes?("require \"mysql\"")
          "sqlite"
        end

        def self.db_default(name : String) : String
          # Literal `#{env_name}` in the OUTPUT (same trick as
          # New.migrate_runner): the wrapper resolves it at runtime.
          New.db_url_default(name, db_kind(name), "\#{env_name}")
        end

        def self.driver_require_line(name : String) : String
          New.db_driver_require(db_kind(name))
        end

        # File-relative require from tmp/ to the user file (Crystal has no
        # absolute-path requires, so relativize; `..` chains are fine).
        def self.relative_from_tmp(file : String) : String
          expanded = File.expand_path(file)
          expanded = expanded[0...-3] if expanded.ends_with?(".cr")
          rel = relativize(File.expand_path("tmp"), expanded)
          rel.starts_with?(".") ? rel : "./#{rel}"
        end

        def self.relativize(from_dir : String, to_path : String) : String
          from = from_dir.split("/").reject(&.empty?)
          to = to_path.split("/").reject(&.empty?)
          common = 0
          while common < from.size && common < to.size && from[common] == to[common]
            common += 1
          end
          ups = (from.size - common).times.map { ".." }.to_a
          ((ups + to[common..]).join("/"))
        end

        def self.exec_wrapper(path : String, script_args : Array(String), crystal_flags : Array(String)) : Int32
          crystal = Util.crystal_bin!
          crystal_args = ["run"] + crystal_flags + [path, "--"] + script_args
          puts "Running: #{crystal} #{crystal_args.join(" ")}"
          status = Process.run(crystal, args: crystal_args, output: STDOUT, error: STDERR)
          status.success? ? 0 : 1
        end
      end

      # `saci console` — honest minimal console. With `-e CODE` (or a file)
      # it is exactly `runner`. With no args it loops on stdin, compiling
      # and running each line in app context (`exit` quits). Crystal has no
      # runtime eval, so per-line compilation is slow but real; multi-line
      # definitions do not work in loop mode (put them in a file and pass
      # it, or use `-e`). Documented limitation, kept simple on purpose.
      module Console
        def self.run(args : Array(String), input : IO = STDIN) : Int32
          if args == ["-h"] || args == ["--help"] || args == ["help"]
            puts help
            return 0
          end
          return repl(input) if args.empty?
          Runner.run(args)
        end

        def self.help : String
          "Usage: saci console [-e CODE | FILE [args] [-- crystal flags]]\n\nNo args starts a minimal line loop (each line is compiled+run in app context; `exit` quits).\nCrystal has no runtime eval, so loop mode recompiles per line (slow but real)."
        end

        def self.repl(input : IO) : Int32
          puts "Saci console (each line is compiled and run in app context; Crystal has no runtime eval, so this is slow but real. Type `exit` to quit.)"
          loop do
            print "saci> "
            line = input.gets
            break if line.nil?
            line = line.strip
            next if line.empty?
            break if line == "exit" || line == "quit"
            Runner.run_code(line)
          end
          0
        end
      end

      # `saci db:seed` — runs `db/seed.cr` if present, else `db/seeds.cr`,
      # else prints the conventional template and exits 1 with guidance.
      # Execution shares the Runner mechanism (app context, no boot).
      module Seed
        def self.run(args : Array(String)) : Int32
          if args == ["-h"] || args == ["--help"] || args == ["help"]
            puts help
            return 0
          end
          script_args = [] of String
          crystal_flags = [] of String
          forward = false
          args.each do |a|
            if forward
              crystal_flags << a
            elsif a == "--"
              forward = true
            elsif a.starts_with?("-")
              raise Error.new("Unknown option '#{a}'. See `saci help db:seed`.")
            else
              script_args << a
            end
          end
          path = resolve
          unless path
            puts template
            STDERR.puts "No db/seed.cr (or db/seeds.cr) found. Create db/seed.cr from the template above, then run `saci db:seed`."
            return 1
          end
          Runner.run_file(path, script_args, crystal_flags)
        end

        # `db/seed.cr` wins over `db/seeds.cr`.
        def self.resolve : String?
          ["db/seed.cr", "db/seeds.cr"].find { |p| File.exists?(p) }
        end

        def self.help : String
          "Usage: saci db:seed [args] [-- crystal flags]\n\nRuns db/seed.cr (or db/seeds.cr) in app context via the runner mechanism (server never booted)."
        end

        # Conventional seed file (also printed when none exists; kept in
        # sync with New.seed_file).
        def self.template : String
          <<-CRYSTAL
          # db/seed.cr — conventional seed file.
          # Run with: saci db:seed
          # (Same app context as `saci runner`: models are loaded and the
          # database is connected; the web server is never booted.)
          #
          # Example:
          # post = Post.create!(title: "Hello")
          # puts "Seeded: \#{post.inspect}"
          puts "No seeds defined yet — edit db/seed.cr."
          CRYSTAL
        end
      end
    end
  end
end
