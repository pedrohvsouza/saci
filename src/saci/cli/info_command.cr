require "file_utils"

module Saci
  module CLI
    # `saci about|stats|notes|middleware|initializers|dbconsole|dev:cache|
    # log:clear|tmp:clear|time:zones|restart` (G119).
    #
    # All of these are static/introspective: they never boot the app (the
    # only exception is `initializers:run`, which uses the runner wrapper
    # so the initializer executes in app context).
    module Info
      # -- about -------------------------------------------------------------

      def self.about(args : Array(String)) : Int32
        reject_flags!(args, "about")
        puts "Saci #{Saci::VERSION}"
        puts "Crystal #{Crystal::VERSION}"
        if name = Util.app_name?
          kind = Util.db_kind(name)
          env = ENV.fetch("APP_ENV", "development")
          puts "App: #{name} (#{env}, #{kind})"
          url = ENV["DATABASE_URL"]? || New.db_url_default(name, kind, env)
          puts "Database: #{url}"
        else
          puts "App: (not a Saci app directory)"
        end
        puts "Working directory: #{Dir.current}"
        0
      end

      # -- stats -------------------------------------------------------------

      STATS_DIRS = [
        {"models", "src/models"},
        {"controllers", "src/controllers"},
        {"channels", "src/channels"},
        {"jobs", "src/jobs"},
        {"mailers", "src/mailers"},
        {"views", "src/views"},
        {"helpers", "src/helpers"},
        {"migrations", "db/migrate"},
        {"tasks", "lib/tasks"},
        {"specs", "spec"},
        {"config", "config"},
      ]

      def self.stats(args : Array(String)) : Int32
        reject_flags!(args, "stats")
        rows = [] of Tuple(String, Int32, Int32)
        STATS_DIRS.each do |(label, dir)|
          next unless Dir.exists?(dir)
          files = Dir.glob(File.join(dir, "**", "*")).select { |path| File.file?(path) }
          lines = files.sum { |path| File.read(path).lines.size }
          rows << {label, files.size, lines}
        end
        if rows.empty?
          puts "No source directories found. Run from a Saci app root."
          return 0
        end
        name_width = (rows.map(&.[0].size) + ["Total".size]).max
        puts "#{"Name".ljust(name_width)}  Files  Lines"
        puts "#{"-" * name_width}  -----  -----"
        rows.each { |(label, files, lines)| puts "#{label.ljust(name_width)}  #{files.to_s.rjust(5)}  #{lines.to_s.rjust(5)}" }
        total_files = rows.sum(&.[1])
        total_lines = rows.sum(&.[2])
        puts "#{"Total".ljust(name_width)}  #{total_files.to_s.rjust(5)}  #{total_lines.to_s.rjust(5)}"
        0
      end

      # -- notes -------------------------------------------------------------

      NOTE_TAGS = ["TODO", "FIXME", "OPTIMIZE"]
      NOTE_DIRS = ["src", "spec", "config", "db", "lib/tasks"]

      def self.notes(args : Array(String)) : Int32
        reject_flags!(args, "notes")
        found = {} of String => Array(String)
        NOTE_TAGS.each { |tag| found[tag] = [] of String }
        NOTE_DIRS.each do |dir|
          next unless Dir.exists?(dir)
          Dir.glob(File.join(dir, "**", "*.cr")).sort.each do |path|
            File.read(path).each_line.with_index(1) do |line, number|
              NOTE_TAGS.each do |tag|
                if line.matches?(/\b#{tag}\b/)
                  found[tag] << "#{path}:#{number}: #{line.strip}"
                  break
                end
              end
            end
          end
        end
        total = found.values.sum(&.size)
        if total == 0
          puts "No notes found (#{NOTE_TAGS.join(", ")})."
          return 0
        end
        found.each do |tag, entries|
          next if entries.empty?
          puts "#{tag}:"
          entries.each { |entry| puts "  #{entry}" }
        end
        puts ""
        puts "#{total} note#{total == 1 ? "" : "s"}."
        0
      end

      # -- middleware --------------------------------------------------------

      def self.middleware(args : Array(String)) : Int32
        reject_flags!(args, "middleware")
        handlers = Saci::Application.handlers(Saci::Router.new)
        puts "Handler chain (outermost first):"
        handlers.each_with_index do |handler, index|
          puts "  #{index + 1}. #{handler.class}"
        end
        puts ""
        puts "Controller-level concerns (before_action filters, CSRF, CSP, sessions, ...)"
        puts "are applied by Saci::Handler/Controller, not as separate handlers."
        0
      rescue ex : Exception
        # Tolerate a boot API that does not expose the handler list.
        puts "Handler chain introspection unavailable (#{ex.class}): #{ex.message}"
        puts "Saci::Application currently builds HTTP::WebSocketHandler + Saci::Handler."
        0
      end

      # -- initializers ------------------------------------------------------

      def self.initializers(args : Array(String)) : Int32
        reject_flags!(args, "initializers")
        entries = initializer_files
        if entries.empty?
          puts "No initializers in config/initializers/."
          puts "Create config/initializers/<name>.cr — it is required at boot time."
          return 0
        end
        puts "Initializers (config/initializers):"
        entries.each do |path|
          puts "  #{File.basename(path)}  (#{File.read(path).lines.size} lines)"
        end
        puts ""
        puts "Run one with: saci initializers:run NAME   (or `saci initializers:run all`)"
        0
      end

      def self.initializers_run(args : Array(String)) : Int32
        target = args.first? || "all"
        files = initializer_files
        if files.empty?
          raise Error.new("No initializers in config/initializers/.")
        end
        selected = if target == "all"
                     files
                   else
                     file = files.find { |path| File.basename(path, ".cr") == target || File.basename(path) == target }
                     raise Error.new("Unknown initializer '#{target}'. Available: #{files.map { |p| File.basename(p, ".cr") }.join(", ")}.") unless file
                     [file.not_nil!]
                   end

        name = Util.shard_name(Dir.current)
        source = String.build do |io|
          io << Inspect::Runner.framework_require_line << "\n"
          io << "require \"file_utils\"\n"
          io << Inspect::Runner.driver_require_line(name)
          io << "require \"../config/environments/*\"\n" if Dir.exists?("config/environments")
          ["models", "controllers", "channels", "jobs", "mailers"].each do |dir|
            io << "require \"../src/#{dir}/*\"\n" if Dir.exists?(File.join("src", dir))
          end
          io << "\nFileUtils.mkdir_p(\"db\")\n"
          io << "env_name = ENV.fetch(\"APP_ENV\", \"development\")\n"
          io << "db_url = ENV.fetch(\"DATABASE_URL\", \"#{Inspect::Runner.db_default(name)}\")\n"
          io << "Saci::Record.connect(db_url)\n"
          io << "Saci::I18n.reload!\n"
          selected.each do |path|
            io << "require \"#{Inspect::Runner.relative_from_tmp(path)}\"\n"
          end
        end
        puts "Running #{selected.size} initializer#{selected.size == 1 ? "" : "s"} in app context..."
        Inspect::Runner.with_wrapper do |path|
          File.write(path, source)
          Inspect::Runner.exec_wrapper(path, [] of String, [] of String)
        end
      end

      def self.initializer_files : Array(String)
        Dir.glob("config/initializers/*.cr").sort
      end

      # -- dbconsole ---------------------------------------------------------

      def self.dbconsole(args : Array(String)) : Int32
        open = false
        all = false
        args.each do |a|
          case a
          when "--open" then open = true
          when "--all"  then all = true
          else               raise Error.new("Unknown option '#{a}'. See `saci help dbconsole`.")
          end
        end
        name = Util.shard_name(Dir.current)
        kind = Util.db_kind(name)
        env = ENV.fetch("APP_ENV", "development")
        urls = [{"primary", ENV["DATABASE_URL"]? || New.db_url_default(name, kind, env)}]
        if all
          ENV.each do |key, value|
            next unless key.starts_with?("DATABASE_URL_") && !key.ends_with?("_TEST")
            urls << {key["DATABASE_URL_".size..].downcase, value}
          end
        end
        urls.each do |(db_name, url)|
          adapter = Saci::Record.adapter_for_url(url)
          puts "#{db_name}: #{url}"
          case adapter
          when :sqlite
            path = Saci::DBTasks.sqlite_path(url)
            puts "  sqlite3 #{path}"
            if open && db_name == "primary"
              exe = Process.find_executable("sqlite3")
              raise Error.new("sqlite3 executable not found in PATH.") unless exe
              Process.exec(exe, args: [path])
            end
          when :postgres
            puts "  psql #{url.inspect}"
          when :mysql
            puts "  mysql #{url.inspect}"
          end
        end
        0
      end

      # -- dev:cache / log:clear / tmp:clear ---------------------------------

      DEV_CACHE_FILE = File.join("tmp", "caching-dev.txt")

      def self.dev_cache(args : Array(String)) : Int32
        on = false
        off = false
        args.each do |a|
          case a
          when "--on"  then on = true
          when "--off" then off = true
          else              raise Error.new("Unknown option '#{a}'. See `saci help dev:cache`.")
          end
        end
        if on && off
          raise Error.new("Pass either --on or --off.")
        end
        Dir.mkdir_p("tmp")
        if on || (!off && !File.exists?(DEV_CACHE_FILE))
          File.write(DEV_CACHE_FILE, "enabled\n")
          puts "Development cache is enabled (#{DEV_CACHE_FILE})."
          puts "Read it at boot with: Saci::Cache.enabled = File.exists?(\"#{DEV_CACHE_FILE}\")"
        else
          File.delete(DEV_CACHE_FILE) if File.exists?(DEV_CACHE_FILE)
          puts "Development cache is disabled."
        end
        0
      end

      def self.log_clear(args : Array(String)) : Int32
        reject_flags!(args, "log:clear")
        files = Dir.glob("log/*.log")
        if files.empty?
          puts "No log files to clear."
          return 0
        end
        files.each { |path| File.write(path, "") }
        puts "Cleared #{files.size} log file#{files.size == 1 ? "" : "s"}."
        0
      end

      def self.tmp_clear(args : Array(String)) : Int32
        reject_flags!(args, "tmp:clear")
        unless Dir.exists?("tmp")
          puts "No tmp directory to clear."
          return 0
        end
        removed = 0
        ["cache", "pids", "sockets", "storage", "screenshots"].each do |sub|
          path = File.join("tmp", sub)
          if Dir.exists?(path)
            FileUtils.rm_rf(path)
            removed += 1
          end
        end
        Dir.glob("tmp/*").each do |path|
          base = File.basename(path)
          next unless File.file?(path)
          next unless base.ends_with?(".log") || base.ends_with?(".pid") ||
                      base.ends_with?(".tmp") || base.starts_with?(".saci-") || base == "restart.txt"
          File.delete(path)
          removed += 1
        end
        if removed == 0
          puts "tmp is already clear."
        else
          puts "Cleared #{removed} tmp entr#{removed == 1 ? "y" : "ies"}."
        end
        0
      end

      # -- time:zones / restart ----------------------------------------------

      def self.time_zones(args : Array(String)) : Int32
        if args == ["--local"]
          puts "Local time zone: #{Time::Location.local.name}"
          return 0
        end
        reject_flags!(args, "time:zones")
        zones = discover_time_zones
        zones.each { |zone| puts zone }
        puts ""
        puts "#{zones.size} time zones."
        0
      end

      # Walks the system tzdata when present; falls back to a compact
      # common-zone list (containers often have no /usr/share/zoneinfo).
      def self.discover_time_zones : Array(String)
        root = "/usr/share/zoneinfo"
        if Dir.exists?(root)
          skip_top = ["posix", "right", "zone.tab", "zone1970.tab", "iso3166.tab",
                      "leapseconds", "tzdata.zi", "localtime", "+VERSION"]
          zones = [] of String
          Dir.glob(File.join(root, "**", "*")).sort.each do |path|
            next unless File.file?(path)
            rel = path.sub(root + "/", "")
            next if rel.empty?
            next if skip_top.includes?(rel.split("/").first)
            next if rel.includes?(".tab") || rel.ends_with?(".zi") || rel == "leapseconds" || rel == "localtime"
            zones << rel
          end
          return zones unless zones.empty?
        end
        ["UTC", "America/New_York", "America/Chicago", "America/Denver",
         "America/Los_Angeles", "America/Sao_Paulo", "Europe/London",
         "Europe/Paris", "Europe/Berlin", "Europe/Lisbon", "Africa/Cairo",
         "Asia/Tokyo", "Asia/Shanghai", "Asia/Kolkata", "Asia/Dubai",
         "Australia/Sydney", "Pacific/Auckland"]
      end

      def self.restart(args : Array(String)) : Int32
        reject_flags!(args, "restart")
        Dir.mkdir_p("tmp")
        File.write(File.join("tmp", "restart.txt"), Time.utc.to_rfc3339 + "\n")
        puts "Restart requested (tmp/restart.txt touched)."
        puts "Process managers can watch this file. Note: `saci serve --watch` restarts on source"
        puts "changes only and ignores tmp/ today."
        0
      end

      private def self.reject_flags!(args : Array(String), command : String) : Nil
        if bad = args.find { |a| a.starts_with?("-") }
          raise Error.new("Unknown option '#{bad}'. See `saci help #{command}`.")
        end
        unless args.empty?
          raise Error.new("Unexpected argument '#{args.first}'. See `saci help #{command}`.")
        end
      end
    end
  end
end
