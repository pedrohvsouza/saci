module Saci
  module CLI
    # `saci task` / `saci task:list` / `saci task NAME` (G118/G229).
    #
    # Task files live in `lib/tasks/**/*.cr` and use the `task` DSL (or
    # `Saci::Task.define`). Listing is a static parse (no boot/compile);
    # running builds a temporary runner that requires every task file
    # plus the app's models and database connection — the same mechanism
    # as `saci runner`, so tasks run in full app context.
    module TaskCommand
      record Entry, name : String, description : String, path : String, line : Int32

      def self.run(args : Array(String)) : Int32
        if args.empty? || args[0] == "list" || args[0] == "--list" || args[0] == "-l"
          list(args[1..]? || [] of String)
          return 0
        end
        if args == ["-h"] || args == ["--help"] || args == ["help"]
          puts help
          return 0
        end

        rest = args.dup
        rest.shift if rest.first? == "run"
        name = rest.shift? || raise Error.new("Usage: saci task NAME | saci task:list")
        script_args = [] of String
        crystal_flags = [] of String
        forward = false
        rest.each do |a|
          if forward
            crystal_flags << a
          elsif a == "--"
            forward = true
          else
            script_args << a
          end
        end
        run_task(name, script_args, crystal_flags)
      end

      def self.help : String
        <<-HELP
        Usage:
          saci task:list [PATTERN]     list tasks from lib/tasks/**/*.cr
          saci task NAME [args] [-- crystal flags]
          saci task run NAME [args]

        Tasks use the `task "reports:daily" do ... end` DSL (or
        `Saci::Task.define`) and run in app context (models loaded, DB
        connected, server never booted). Arguments before `--` are passed
        to the task as ARGV; everything after `--` goes to the compiler.
        HELP
      end

      # Statically scans task files without compiling anything.
      def self.scan(dir : String = "lib/tasks") : Array(Entry)
        entries = [] of Entry
        Dir.glob(File.join(dir, "**", "*.cr")).sort.each do |path|
          File.read(path).each_line.with_index(1) do |line, number|
            stripped = line.lstrip
            next if stripped.starts_with?("#")
            next unless stripped.includes?("task") || stripped.includes?("Saci::Task.define")
            name = nil
            if m = stripped.match(/(?:^|\s)task\s*\(?\s*["']([^"']+)["']/)
              name = m[1]
            elsif m = stripped.match(/Saci::Task\.define\s*\(?\s*["']([^"']+)["']/)
              name = m[1]
            end
            next unless name
            description = ""
            if m = line.match(/,\s*["']([^"']*)["']\s*(?:do|\{|\z)/)
              description = m[1]
            elsif m = line.match(/(?:description|desc):\s*["']([^"']*)["']/)
              description = m[1]
            end
            entries << Entry.new(name, description, path, number)
          end
        end
        entries
      end

      def self.list(args : Array(String)) : Nil
        pattern = args.first?
        entries = scan
        entries = entries.select { |e| e.name.includes?(pattern) } if pattern
        if entries.empty?
          if Dir.exists?("lib/tasks") && !Dir.glob("lib/tasks/**/*.cr").empty?
            puts "No tasks matched#{pattern ? " '#{pattern}'" : ""}."
          else
            puts "No tasks found in lib/tasks/."
            puts "Generate one with: saci generate task reports:daily"
          end
          return
        end

        width = entries.map(&.name.size).max
        puts "Tasks (lib/tasks):"
        entries.each do |entry|
          desc = entry.description.empty? ? "" : "  #{entry.description}"
          puts "  #{entry.name.ljust(width)}#{desc}  (#{entry.path}:#{entry.line})"
        end
      end

      def self.run_task(name : String, script_args : Array(String), crystal_flags : Array(String)) : Int32
        Util.shard_name(Dir.current)
        unless Dir.exists?("lib/tasks") && !Dir.glob("lib/tasks/**/*.cr").empty?
          raise Error.new("No task files found. Create lib/tasks/<name>.cr (or run `saci generate task #{name}`).")
        end

        puts "Running task #{name}..."
        Inspect::Runner.with_wrapper do |path|
          File.write(path, runner_source(name))
          Inspect::Runner.exec_wrapper(path, script_args, crystal_flags)
        end
      end

      # Temporary runner: task definitions are required (compile-time)
      # before `Saci::Task.run` is called, in the same app context as
      # `saci runner` (models loaded, DB connected). `name` is escaped
      # into a Crystal string literal.
      def self.runner_source(name : String) : String
        app = Util.shard_name(Dir.current)
        escaped_name = name.gsub("\\", "\\\\").gsub("\"", "\\\"")
        String.build do |io|
          io << Inspect::Runner.framework_require_line << "\n"
          io << Util.internal_require("tasks") << "\n"
          io << "require \"file_utils\"\n"
          io << Inspect::Runner.driver_require_line(app)
          io << "require \"../config/environments/*\"\n" if Dir.exists?("config/environments")
          ["models", "controllers", "channels", "jobs", "mailers"].each do |dir|
            io << "require \"../src/#{dir}/*\"\n" if Dir.exists?(File.join("src", dir))
          end
          io << "require \"../lib/tasks/*\"\n"
          io << "\nFileUtils.mkdir_p(\"db\")\n"
          io << "env_name = ENV.fetch(\"APP_ENV\", \"development\")\n"
          io << "db_url = ENV.fetch(\"DATABASE_URL\", \"#{Inspect::Runner.db_default(app)}\")\n"
          io << "Saci::Record.connect(db_url)\n"
          io << "Saci::I18n.reload!\n"
          io << "Saci::Task.run(\"#{escaped_name}\")\n"
        end
      end
    end
  end
end
