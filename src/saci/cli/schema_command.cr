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
    # one the same way. With `--database=NAME`, only that named database
    # (whose migrations live in `db/<name>_migrate/`) is dumped, into its
    # own `db/<name>_schema.cr` (Rails' `<name>_schema.rb`), and
    # `db:schema:load --database=NAME` replays that file.
    module Schema
      RUNNER_PATH = File.join("tmp", ".saci-schema-dump.cr")

      def self.run(args : Array(String), action : String) : Int32
        case action
        when "dump" then dump(args)
        when "load" then load(args)
        else             raise Error.new("Unknown schema action #{action.inspect} (expected dump|load)")
        end
      end

      # `--database NAME` is normalized to `database: NAME`
      # (`"primary"` means the default db/schema.cr, so it maps to nil).
      def self.parse(args : Array(String)) : NamedTuple(all: Bool, database: String?, script_args: Array(String), crystal_flags: Array(String))
        script_args = [] of String
        crystal_flags = [] of String
        forward = false
        all = false
        database : String? = nil
        i = 0
        while i < args.size
          a = args[i]
          if forward
            crystal_flags << a
          elsif a == "--"
            forward = true
          elsif a == "--all"
            all = true
            script_args << a
          elsif a == "--database" || a.starts_with?("--database=")
            name = a == "--database" ? (i += 1; args[i]?) : a.lchop("--database=")
            raise Error.new("--database needs a name (e.g. --database=analytics)") if name.nil? || name.empty?
            database = Generate.validate_database_name!(name)
          else
            script_args << a
          end
          i += 1
        end
        database = nil if database == "primary"
        raise Error.new("Use either --all or --database=NAME, not both.") if all && database
        {all: all, database: database, script_args: script_args, crystal_flags: crystal_flags}
      end

      # Snapshot file per database: `db/schema.cr` for primary (and the
      # `--all` multi-database dump), `db/<name>_schema.cr` for a named one.
      def self.schema_path(database : String? = nil) : String
        database.nil? || database == "primary" ? "db/schema.cr" : "db/#{database}_schema.cr"
      end

      def self.dump(args : Array(String)) : Int32
        app = Util.shard_name(Dir.current)
        raise Error.new("db/migrate.cr not found. Is this a Saci app?") unless File.exists?("db/migrate.cr")
        parsed = parse(args)
        extra = parsed[:script_args].reject { |a| a == "--all" }
        raise Error.new("Usage: saci db:schema:dump [--all|--database=NAME] [-- crystal flags]") unless extra.empty?
        database = parsed[:database]
        template = if database
                     named_url_default(app, database)
                   else
                     migrate_url_default || "sqlite3://./db/#{app}_\#{env_name}.db"
                   end
        path = schema_path(database)
        Dir.mkdir_p("tmp")
        File.write(RUNNER_PATH, dump_runner_source(template, database))
        puts "Dumping schema to #{path}#{" (all databases)" if parsed[:all]}#{" (database #{database})" if database}"
        code = Compile.run(RUNNER_PATH, parsed[:crystal_flags], parsed[:all] ? ["--all"] : [] of String, name: "schema dumper")
        File.delete(RUNNER_PATH) if File.exists?(RUNNER_PATH)
        code
      end

      def self.load(args : Array(String)) : Int32
        Util.shard_name(Dir.current)
        parsed = parse(args)
        database = parsed[:database]
        raise Error.new("Usage: saci db:schema:load [--database=NAME] [-- crystal flags]") unless parsed[:script_args].empty?
        path = schema_path(database)
        unless File.exists?(path)
          raise Error.new("#{path} not found. Run `saci db:schema:dump#{" --database=#{database}" if database}` first.")
        end
        Compile.run(path, parsed[:crystal_flags], name: path)
      end

      # Default URL of a named database (`DATABASE_URL_<NAME>` fallback):
      # the `<app>_<name>_<env>` convention db/migrate.cr suggests, with a
      # literal `#{env_name}` interpolation for the generated files.
      def self.named_url_default(app : String, database : String) : String
        New.db_url_default(app, Util.db_kind(app), "#{database}_\#{env_name}")
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
      # `#` + `{`, spelled out: `crystal tool format` rewrites the escaped
      # literal for it into a real interpolation, which breaks the build.
      INTERPOLATION_OPEN = "#" + "{"

      def self.dump_runner_source(url_template : String, database : String? = nil) : String
        escaped = url_template.gsub("\\", "\\\\").gsub("\"", "\\\"").gsub(INTERPOLATION_OPEN, "\\" + INTERPOLATION_OPEN)
        return named_dump_runner_source(url_template, escaped, database) if database && database != "primary"
        <<-CRYSTAL
        # Temporary runner written by `saci db:schema:dump` (removed afterwards).
        # Connects exactly like db/migrate.cr, then writes db/schema.cr.
        require "saci"
        require "file_utils"

        FileUtils.mkdir_p("db")
        env_name = ENV.fetch("APP_ENV", "development")
        db_url = Saci::ConfigFile.database_url(env_name) || ENV.fetch("DATABASE_URL", "#{url_template}")
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

      # Runner for `--database=NAME`: connects that database alone
      # (DATABASE_URL_<NAME>, else the naming convention) and writes
      # db/<name>_schema.cr.
      private def self.named_dump_runner_source(url_template : String, escaped : String, database : String) : String
        path = schema_path(database)
        env_key = "DATABASE_URL_#{database.upcase}"
        <<-CRYSTAL
        # Temporary runner written by `saci db:schema:dump --database=#{database}` (removed afterwards).
        # Connects the named database #{database.inspect}, then writes #{path}.
        require "saci"
        require "file_utils"

        FileUtils.mkdir_p("db")
        env_name = ENV.fetch("APP_ENV", "development")
        db_url = ENV.fetch(#{env_key.inspect}, "#{url_template}")
        Saci::Record.establish_connection(#{database.inspect}, db_url)
        url_embed = "#{escaped}"
        content = Saci::Record::Schema.dump(Saci::Record.database(#{database.inspect}), url_embed, database: #{database.inspect})
        File.write(#{path.inspect}, content)
        puts "Wrote #{path} (#{database})"
        CRYSTAL
      end
    end
  end
end
