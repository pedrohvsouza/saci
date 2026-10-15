module Saci
  module CLI
    # `saci db:schema:dump [--all]` / `saci db:schema:load`.
    # Rails `schema.rb` equivalent: dump writes a standalone runnable
    # `db/schema.cr` (adapter-aware data + loader call, portable across
    # SQLite / PostgreSQL / MySQL); load replays it with `crystal run`.
    #
    # Like `Db`, this shells out to committed/temp runner scripts rather
    # than booting the app: dump connects exactly like `db/migrate.cr`
    # (DATABASE_URL-or-default) via a temp runner requiring the app's
    # `saci` dependency, then deletes the runner; load runs the
    # committed `db/schema.cr` directly.
    #
    # Multidb: with `--all`, every database registered through
    # `DATABASE_URL_<NAME>` env vars (plus primary) is dumped into its
    # own section of `db/schema.cr`, and loading re-establishes each
    # one the same way.
    module Schema
      RUNNER_PATH = File.join("tmp", ".saci-schema-dump.cr")

      def self.run(args : Array(String), action : String) : Int32
        case action
        when "dump" then dump(args)
        when "load" then load(args)
        else             raise Error.new("Unknown schema action #{action.inspect} (expected dump|load)")
        end
      end

      def self.parse(args : Array(String)) : NamedTuple(all: Bool, script_args: Array(String), crystal_flags: Array(String))
        script_args = [] of String
        crystal_flags = [] of String
        forward = false
        all = false
        args.each do |a|
          if forward
            crystal_flags << a
          elsif a == "--"
            forward = true
          elsif a == "--all"
            all = true
            script_args << a
          else
            script_args << a
          end
        end
        {all: all, script_args: script_args, crystal_flags: crystal_flags}
      end

      def self.dump(args : Array(String)) : Int32
        Util.shard_name(Dir.current)
        raise Error.new("db/migrate.cr not found. Is this a Saci app?") unless File.exists?("db/migrate.cr")
        parsed = parse(args)
        extra = parsed[:script_args].reject { |a| a == "--all" }
        raise Error.new("Usage: saci db:schema:dump [--all] [-- crystal flags]") unless extra.empty?
        template = migrate_url_default || "sqlite3://./db/#{Util.shard_name(Dir.current)}_\#{env_name}.db"
        Dir.mkdir_p("tmp")
        File.write(RUNNER_PATH, dump_runner_source(template))
        crystal = Util.crystal_bin!
        crystal_args = ["run"] + parsed[:crystal_flags] + [RUNNER_PATH, "--"] + (parsed[:all] ? ["--all"] : [] of String)
        puts "Dumping schema to db/schema.cr#{" (all databases)" if parsed[:all]} via: #{crystal} #{crystal_args.join(" ")}"
        status = Process.run(crystal, args: crystal_args, output: STDOUT, error: STDERR)
        File.delete(RUNNER_PATH) if File.exists?(RUNNER_PATH)
        status.success? ? 0 : 1
      end

      def self.load(args : Array(String)) : Int32
        Util.shard_name(Dir.current)
        raise Error.new("db/schema.cr not found. Run `saci db:schema:dump` first.") unless File.exists?("db/schema.cr")
        parsed = parse(args)
        raise Error.new("Usage: saci db:schema:load [-- crystal flags]") unless parsed[:script_args].empty?
        crystal = Util.crystal_bin!
        crystal_args = ["run"] + parsed[:crystal_flags] + ["db/schema.cr"]
        puts "Loading db/schema.cr via: #{crystal} #{crystal_args.join(" ")}"
        status = Process.run(crystal, args: crystal_args, output: STDOUT, error: STDERR)
        status.success? ? 0 : 1
      end

      # Default `DATABASE_URL` expression from the app's migrate runner
      # (`ENV.fetch("DATABASE_URL", "<default>")`), so schema.cr connects
      # exactly like `db/migrate.cr`. Nil when the convention is absent.
      def self.migrate_url_default(dir : String = Dir.current) : String?
        path = File.join(dir, "db", "migrate.cr")
        return nil unless File.exists?(path)
        if m = File.read(path).match(/ENV\.fetch\("DATABASE_URL",\s*"((?:[^"\\]|\\.)*)"\)/)
          m[1]
        end
      end

      # Temp runner: connects like `db/migrate.cr` (primary via
      # DATABASE_URL-or-default, named DBs via DATABASE_URL_<NAME>),
      # then snapshots each target into `db/schema.cr`. `url_template`
      # carries a literal `#{env_name}` interpolation, resolved here for
      # connecting and preserved (escaped) for embedding in schema.cr.
      def self.dump_runner_source(url_template : String) : String
        escaped = url_template.gsub("\\", "\\\\").gsub("\"", "\\\"").gsub("#\{", "\\#\{")
        <<-CRYSTAL
        # Temporary runner written by `saci db:schema:dump` (removed afterwards).
        # Connects exactly like db/migrate.cr, then writes db/schema.cr.
        require "saci"
        require "file_utils"

        FileUtils.mkdir_p("db")
        env_name = ENV.fetch("APP_ENV", "development")
        db_url = ENV.fetch("DATABASE_URL", "#{url_template}")
        Saci::Record.connect(db_url)
        ENV.each do |key, value|
          if key.starts_with?("DATABASE_URL_") && key != "DATABASE_URL"
            Saci::Record.establish_connection(key["DATABASE_URL_".size..].downcase, value)
          end
        end
        dump_all = ARGV.includes?("--all")
        targets = dump_all ? Saci::Record.configuration_names : ["primary"]
        url_embed = "#{escaped}"
        others = targets.reject { |db_name| db_name == "primary" }.map do |db_name|
          Saci::Record::Schema::DatabaseDump.new(
            db_name,
            Saci::Record.database(db_name),
            ENV.fetch("DATABASE_URL_\#{db_name.upcase}", "")
          )
        end
        content = Saci::Record::Schema.dump(Saci::Record.database("primary"), url_embed, others)
        File.write("db/schema.cr", content)
        puts "Wrote db/schema.cr (\#{targets.join(", ")})"
        CRYSTAL
      end
    end
  end
end
