module Saci
  module CLI
    # `saci db:prepare|setup|reset|version|migrate:status|fixtures:load|...`
    # (G39/G40/G113) — the rest of the Rails `db:*` surface, on top of the
    # existing `db:migrate|rollback|schema:*|seed` commands.
    #
    # SQLite targets run in-process (the framework already links the sqlite
    # driver). PostgreSQL/MySQL targets compile a temporary runner that
    # requires the app's driver and calls the same `Saci::DBTasks` methods,
    # so output and behavior stay identical across adapters.
    #
    # `--all` covers primary + every `DATABASE_URL_<NAME>` database, like
    # `db:migrate --all` / `db:schema:dump --all`.
    module Db
      # `db:version` / `db:migrate:status` etc. are dispatched here from
      # CLI.run; `Db.run` (serve_command.cr) stays the migrate/rollback path.
      def self.run_action(action : String, args : Array(String)) : Int32
        case action
        when "prepare"           then prepare(args)
        when "setup"             then setup(args)
        when "reset"             then reset(args)
        when "version"           then version(args)
        when "migrate:status"    then migrate_status(args)
        when "fixtures:load"     then fixtures_load(args)
        when "seed:replant"      then seed_replant(args)
        when "schema:cache:dump" then schema_cache_dump(args)
        when "test:prepare"      then test_prepare(args)
        when "create"            then create(args)
        when "drop"              then drop(args)
        else                          raise Error.new("Unknown db task '#{action}'. See `saci help db`.")
        end
      end

      alias ActionOptions = NamedTuple(
        all: Bool,
        force: Bool,
        pretend: Bool,
        seed: Bool?,
        dir: String?,
        flags: Array(String),
        positional: Array(String),
      )

      def self.parse_action_args(args : Array(String)) : ActionOptions
        all = false
        force = false
        pretend = false
        seed : Bool? = nil
        dir : String? = nil
        flags = [] of String
        positional = [] of String
        forward = false
        i = 0
        while i < args.size
          a = args[i]
          if forward
            flags << a
          else
            case a
            when "--"
              forward = true
            when "--all"
              all = true
            when "--force"
              force = true
            when "--pretend"
              pretend = true
            when "--seed"
              seed = true
            when "--no-seed"
              seed = false
            when .starts_with?("--dir=")
              dir = a.split("=", 2)[1]
            when "--dir"
              dir = args[i + 1]? || raise Error.new("Missing value for --dir")
              i += 1
            else
              if a.starts_with?("-")
                raise Error.new("Unknown option '#{a}'. See `saci help db`.")
              end
              positional << a
            end
          end
          i += 1
        end
        {all: all, force: force, pretend: pretend, seed: seed, dir: dir,
         flags: flags, positional: positional}
      end

      def self.app_context! : NamedTuple(name: String, kind: String, env: String)
        name = Util.shard_name(Dir.current)
        raise Error.new("db/migrate.cr not found. Is this a Saci app?") unless File.exists?("db/migrate.cr")
        {name: name, kind: Util.db_kind(name), env: ENV.fetch("APP_ENV", "development")}
      end

      # URL for an environment: explicit DATABASE_URL (or DATABASE_URL_TEST)
      # wins; otherwise the `saci new` convention.
      def self.url_for(name : String, kind : String, env : String, test : Bool = false) : String
        if test
          ENV["DATABASE_URL_TEST"]? || ENV["DATABASE_URL"]? || New.db_url_default(name, kind, "test")
        else
          ENV["DATABASE_URL"]? || New.db_url_default(name, kind, env)
        end
      end

      record Target, name : String, url : String, adapter : Symbol

      def self.targets(all : Bool, name : String, kind : String, env : String, test : Bool = false) : Array(Target)
        list = [Target.new("primary", url_for(name, kind, env, test), Saci::Record.adapter_for_url(url_for(name, kind, env, test)))]
        if all
          ENV.each do |key, value|
            next unless key.starts_with?("DATABASE_URL_") && !key.ends_with?("_TEST")
            db_name = key["DATABASE_URL_".size..].downcase
            list << Target.new(db_name, value, Saci::Record.adapter_for_url(value))
          end
        end
        list
      end

      def self.sqlite_only?(targets : Array(Target)) : Bool
        targets.all? { |t| t.adapter == :sqlite }
      end

      def self.prepare(args : Array(String)) : Int32
        ctx = app_context!
        opts = parse_action_args(args)
        if opts[:pretend]
          puts "Pretend: would create (if missing), migrate and seed #{ctx[:name]}."
          return 0
        end
        return run_prepare(ctx, opts, seed_when_created: true)
      end

      def self.setup(args : Array(String)) : Int32
        ctx = app_context!
        opts = parse_action_args(args)
        if opts[:pretend]
          puts "Pretend: would create, migrate/load schema and seed #{ctx[:name]}."
          return 0
        end
        run_prepare(ctx, opts, seed_when_created: true, seed_always: true)
      end

      def self.reset(args : Array(String)) : Int32
        ctx = app_context!
        opts = parse_action_args(args)
        if opts[:pretend]
          puts "Pretend: would drop and re-setup #{ctx[:name]}."
          return 0
        end
        check_production_guard!(ctx[:env], opts[:force])
        drop_result = drop_targets(ctx, opts)
        return drop_result if drop_result != 0
        run_prepare(ctx, opts, seed_when_created: true, seed_always: true)
      end

      def self.test_prepare(args : Array(String)) : Int32
        ctx = app_context!
        opts = parse_action_args(args)
        if opts[:pretend]
          puts "Pretend: would create and prepare the #{ctx[:name]} test database."
          return 0
        end
        test_url = targets(opts[:all], ctx[:name], ctx[:kind], "test", test: true).first.url
        with_env({"APP_ENV" => "test", "DATABASE_URL" => test_url}) do
          run_prepare(ctx, opts, seed_when_created: false, test: true)
        end
      end

      private def self.run_prepare(ctx, opts, seed_when_created : Bool, seed_always : Bool = false, test : Bool = false) : Int32
        targets = targets(opts[:all], ctx[:name], ctx[:kind], ctx[:env], test)
        created = create_targets(targets, quiet: false, kind: ctx[:kind], app_name: ctx[:name])
        created_primary = created[:primary]

        # A schema-only deploy (db/schema.cr present, no migration files)
        # loads the snapshot; otherwise run migrations.
        schema_only = File.exists?("db/schema.cr") && Dir.glob("db/migrate/*.cr").empty?
        want_seed = seed_always || (seed_when_created && created_primary)
        seed_path = Inspect::Seed.resolve
        want_seed = false if seed_path.nil?

        if schema_only
          puts "Loading db/schema.cr..."
          schema_args = opts[:flags].empty? ? [] of String : ["--"] + opts[:flags]
          code = Schema.load(schema_args)
          return code unless code == 0
          if want_seed
            if path = seed_path
              puts "Seeding from #{path}..."
              seed_args = opts[:flags].empty? ? [] of String : ["--"] + opts[:flags]
              code = Inspect::Seed.run(seed_args)
              return code unless code == 0
            end
          end
        else
          Generate.regenerate_manifest! unless Generate.pretend?
          code = run_prepare_runner(ctx, opts, seed_path, want_seed, test)
          return code unless code == 0
        end

        puts "Database prepared#{test ? " (test)" : ""}."
        0
      end

      # Migration runner for prepare/setup/test: one compile that migrates
      # every target and (optionally) runs the seed file afterwards.
      private def self.run_prepare_runner(ctx, opts, seed_path : String?, seed : Bool, test : Bool) : Int32
        name = ctx[:name]
        kind = ctx[:kind]
        default_url = New.db_url_default(name, kind, test ? "test" : "\#{env_name}")
        all = opts[:all]
        source = String.build do |io|
          io << Inspect::Runner.framework_require_line << "\n"
          io << "require \"file_utils\"\n"
          io << Inspect::Runner.driver_require_line(name)
          io << "require \"../src/models/*\"\n" if Dir.exists?("src/models")
          io << "require \"../db/migrations\"\n"
          io << "\nFileUtils.mkdir_p(\"db\")\n"
          io << "env_name = ENV.fetch(\"APP_ENV\", \"development\")\n"
          io << "db_url = ENV.fetch(\"DATABASE_URL\", \"#{default_url}\")\n"
          io << "Saci::Record.connect(db_url)\n"
          io << Util.internal_require("db_tasks") << "\n"
          io << "Saci::DBTasks.register_named_databases!\n"
          io << "targets = ARGV.includes?(\"--all\") ? Saci::Record.configuration_names : [\"primary\"]\n"
          io << "targets.each do |db_name|\n"
          io << "  db = Saci::Record.database(db_name)\n"
          io << "  ran = Saci::Record::Migrator.migrate(db, SACI_MIGRATIONS)\n"
          io << "  puts \"Migrated \#{db_name}: \#{ran.inspect}\"\n"
          io << "end\n"
          if seed && seed_path
            io << "puts \"Seeding from #{seed_path}...\"\n"
            io << "require \"#{Inspect::Runner.relative_from_tmp(seed_path)}\"\n"
          end
        end
        run_generated("db:prepare", source, ["--all"].select { |_| all }, opts[:flags], test_env(test))
      end

      def self.version(args : Array(String)) : Int32
        ctx = app_context!
        opts = parse_action_args(args)
        targets = targets(opts[:all], ctx[:name], ctx[:kind], ctx[:env])
        return external_run("version", ctx, opts) unless sqlite_only?(targets)
        entries = Saci::DBTasks.migration_entries
        multi = targets.size > 1
        targets.each do |target|
          applied = sqlite_applied(target.url)
          Saci::DBTasks.print_version(STDOUT, target.name, applied || [] of String, entries, multi)
          puts "(database does not exist)" if applied.nil?
        end
        0
      end

      def self.migrate_status(args : Array(String)) : Int32
        ctx = app_context!
        opts = parse_action_args(args)
        targets = targets(opts[:all], ctx[:name], ctx[:kind], ctx[:env])
        return external_run("status", ctx, opts) unless sqlite_only?(targets)
        entries = Saci::DBTasks.migration_entries
        multi = targets.size > 1
        if entries.empty?
          puts "No migrations found in db/migrate/."
        end
        targets.each do |target|
          applied = sqlite_applied(target.url)
          Saci::DBTasks.print_status(STDOUT, target.name, entries, applied || [] of String, multi)
          puts "(database does not exist)" if applied.nil?
        end
        0
      end

      # Applied migration names for a SQLite URL. Returns nil when the DB
      # file is missing (so callers can report "does not exist" without
      # creating it), [] when the bookkeeping table is absent.
      private def self.sqlite_applied(url : String) : Array(String)?
        path = Saci::DBTasks.sqlite_path(url)
        return nil unless File.exists?(path)
        db = Saci::Record.establish_connection("primary", url)
        begin
          has_table = db.scalar("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'schema_migrations'").as(Int64) > 0
          return [] of String unless has_table
          db.query_all("SELECT name FROM schema_migrations", as: String)
        ensure
          db.close
        end
      end

      def self.schema_cache_dump(args : Array(String)) : Int32
        ctx = app_context!
        opts = parse_action_args(args)
        if opts[:pretend]
          puts "Pretend: would write db/schema_cache.yml."
          return 0
        end
        targets = targets(opts[:all], ctx[:name], ctx[:kind], ctx[:env])
        return external_run("cache:dump", ctx, opts) unless sqlite_only?(targets)

        missing = targets.select do |target|
          path = Saci::DBTasks.sqlite_path(target.url)
          !File.exists?(path)
        end
        unless missing.empty?
          raise Error.new("Database #{missing.first.name} does not exist. Run `saci db:prepare` first.")
        end
        targets.each { |target| Saci::Record.establish_connection(target.name, target.url) }
        names = targets.map(&.name)
        begin
          Saci::DBTasks.write_schema_cache("db/schema_cache.yml", names)
          puts "Wrote db/schema_cache.yml (#{names.join(", ")})"
        ensure
          names.each do |db_name|
            Saci::Record.database(db_name).close
          rescue
          end
        end
        0
      end

      def self.fixtures_load(args : Array(String)) : Int32
        ctx = app_context!
        opts = parse_action_args(args)
        if opts[:pretend]
          puts "Pretend: would load fixtures into #{ctx[:name]}."
          return 0
        end
        check_production_guard!(ctx[:env], opts[:force])
        dir = opts[:dir] || default_fixtures_dir
        if dir.nil? || !Dir.exists?(dir)
          raise Error.new("No fixtures directory found (expected spec/fixtures or test/fixtures). Create one or pass --dir PATH.")
        end
        fixtures_dir = dir.not_nil!
        targets = targets(opts[:all], ctx[:name], ctx[:kind], ctx[:env])
        return external_run("fixtures:load", ctx, opts) unless sqlite_only?(targets)
        db = Saci::Record.establish_connection("primary", targets.first.url)
        begin
          count = Saci::DBTasks.load_fixtures(db, fixtures_dir, STDOUT)
          puts "Loaded #{count} fixture record#{count == 1 ? "" : "s"}."
        ensure
          db.close
        end
        0
      end

      def self.default_fixtures_dir : String?
        ["spec/fixtures", "test/fixtures"].find { |dir| Dir.exists?(dir) }
      end

      def self.seed_replant(args : Array(String)) : Int32
        ctx = app_context!
        opts = parse_action_args(args)
        if opts[:pretend]
          puts "Pretend: would truncate #{ctx[:name]} and run the seed file."
          return 0
        end
        check_production_guard!(ctx[:env], opts[:force])
        seed_path = Inspect::Seed.resolve
        raise Error.new("No db/seed.cr (or db/seeds.cr) found. Create one first.") unless seed_path
        name = ctx[:name]
        default_url = New.db_url_default(name, ctx[:kind], "\#{env_name}")
        source = String.build do |io|
          io << Inspect::Runner.framework_require_line << "\n"
          io << "require \"file_utils\"\n"
          io << Inspect::Runner.driver_require_line(name)
          io << "require \"../src/models/*\"\n" if Dir.exists?("src/models")
          io << Util.internal_require("db_tasks") << "\n"
          io << "\nFileUtils.mkdir_p(\"db\")\n"
          io << "env_name = ENV.fetch(\"APP_ENV\", \"development\")\n"
          io << "db_url = ENV.fetch(\"DATABASE_URL\", \"#{default_url}\")\n"
          io << "Saci::Record.connect(db_url)\n"
          io << "Saci::DBTasks.register_named_databases!\n"
          io << "count = Saci::DBTasks.clean_databases!(ARGV.includes?(\"--all\"))\n"
          io << "puts \"Truncated \#{count} table(s).\"\n"
          io << "require \"#{Inspect::Runner.relative_from_tmp(seed_path.not_nil!)}\"\n"
        end
        run_generated("db:seed:replant", source, ["--all"].select { |_| opts[:all] }, opts[:flags])
      end

      def self.create(args : Array(String)) : Int32
        ctx = app_context!
        opts = parse_action_args(args)
        if opts[:pretend]
          puts "Pretend: would create the configured database(s)."
          return 0
        end
        targets = targets(opts[:all], ctx[:name], ctx[:kind], ctx[:env])
        unless sqlite_only?(targets)
          return run_external_source("create", create_drop_source("create", ctx[:kind], ctx[:name]),
            args: ["--all"].select { |_| opts[:all] }, flags: opts[:flags])
        end
        create_targets(targets, quiet: false, kind: ctx[:kind], app_name: ctx[:name])
        0
      end

      def self.drop(args : Array(String)) : Int32
        ctx = app_context!
        opts = parse_action_args(args)
        if opts[:pretend]
          puts "Pretend: would drop the configured database(s)."
          return 0
        end
        check_production_guard!(ctx[:env], opts[:force])
        drop_targets(ctx, opts)
      end

      private def self.drop_targets(ctx, opts) : Int32
        targets = targets(opts[:all], ctx[:name], ctx[:kind], ctx[:env])
        unless sqlite_only?(targets)
          return run_external_source("drop", create_drop_source("drop", ctx[:kind], ctx[:name]),
            args: ["--all"].select { |_| opts[:all] }, flags: opts[:flags])
        end
        targets.each do |target|
          if Saci::DBTasks.drop_database(target.url)
            puts "Dropped #{target.name} (#{target.url})"
          else
            puts "Database #{target.name} does not exist (#{target.url})"
          end
        end
        0
      end

      # `db:create` returns whether the primary database was newly created
      # (used by prepare/setup to decide on seeding). Non-SQLite targets
      # run through a small runner whose output is captured.
      private def self.create_targets(targets : Array(Target), quiet : Bool, kind : String, app_name : String) : NamedTuple(primary: Bool)
        primary_created = false
        targets.each do |target|
          if target.adapter == :sqlite
            created = Saci::DBTasks.create_database(target.url)
            primary_created = created if target.name == "primary"
            unless quiet
              puts created ? "Created #{target.name} (#{target.url})" : "Database #{target.name} already exists (#{target.url})"
            end
          else
            output = IO::Memory.new
            code = run_external_source("create", create_drop_source("create", kind, app_name), output: output)
            text = output.to_s
            primary_created = text.includes?("Created primary")
            print text
            return {primary: primary_created} unless code == 0
          end
        end
        {primary: primary_created}
      end

      private def self.external_run(action : String, ctx, opts) : Int32
        source = external_source(action, ctx[:name], ctx[:kind], opts)
        run_generated("db:#{action}", source, ["--all"].select { |_| opts[:all] } + opts[:positional], opts[:flags])
      end

      # Generates the tiny PG/MySQL runner for read-only actions. It uses
      # the same Saci::DBTasks methods as the in-process SQLite path.
      def self.external_source(action : String, name : String, kind : String, opts) : String
        default_url = New.db_url_default(name, kind, "\#{env_name}")
        String.build do |io|
          io << Inspect::Runner.framework_require_line << "\n"
          io << "require \"file_utils\"\n"
          io << Inspect::Runner.driver_require_line(name)
          io << Util.internal_require("db_tasks") << "\n"
          io << "\nFileUtils.mkdir_p(\"db\")\n"
          io << "env_name = ENV.fetch(\"APP_ENV\", \"development\")\n"
          io << "db_url = ENV.fetch(\"DATABASE_URL\", \"#{default_url}\")\n"
          io << "Saci::Record.connect(db_url)\n"
          io << "Saci::DBTasks.register_named_databases!\n"
          io << "all = ARGV.includes?(\"--all\")\n"
          case action
          when "version"
            io << "entries = Saci::DBTasks.migration_entries\n"
            io << "names = Saci::DBTasks.target_names(all)\n"
            io << "multi = names.size > 1\n"
            io << "names.each do |db_name|\n"
            io << "  applied = Saci::DBTasks.applied_names(Saci::Record.database(db_name))\n"
            io << "  Saci::DBTasks.print_version(STDOUT, db_name, applied, entries, multi)\n"
            io << "end\n"
          when "status"
            io << "entries = Saci::DBTasks.migration_entries\n"
            io << "names = Saci::DBTasks.target_names(all)\n"
            io << "multi = names.size > 1\n"
            io << "names.each do |db_name|\n"
            io << "  applied = Saci::DBTasks.applied_names(Saci::Record.database(db_name))\n"
            io << "  Saci::DBTasks.print_status(STDOUT, db_name, entries, applied, multi)\n"
            io << "end\n"
          when "cache:dump"
            io << "names = Saci::DBTasks.target_names(all)\n"
            io << "Saci::DBTasks.write_schema_cache(\"db/schema_cache.yml\", names)\n"
            io << "puts \"Wrote db/schema_cache.yml (\#{names.join(\", \")})\"\n"
          when "fixtures:load"
            dir = opts[:dir] || default_fixtures_dir || "spec/fixtures"
            io << "dir = ARGV[0]? || #{dir.inspect}\n"
            io << "count = Saci::DBTasks.load_fixtures(Saci::Record.database(\"primary\"), dir, STDOUT)\n"
            io << "puts \"Loaded \#{count} fixture record(s).\"\n"
          else
            raise Error.new("No external runner for db action '#{action}'.")
          end
        end
      end

      # Source for `db:create` / `db:drop` runners (SQLite handled
      # in-process; this path is PG/MySQL). URLs come from ENV, never from
      # the generated file, so credentials are not written to tmp/.
      def self.create_drop_source(action : String, kind : String, app_name : String) : String
        default_url = New.db_url_default(app_name, kind, "\#{env_name}")
        String.build do |io|
          io << Inspect::Runner.framework_require_line << "\n"
          io << "require \"file_utils\"\n"
          io << New.db_driver_require(kind)
          io << Util.internal_require("db_tasks") << "\n"
          io << "\nenv_name = ENV.fetch(\"APP_ENV\", \"development\")\n"
          io << "urls = [{\"primary\", ENV.fetch(\"DATABASE_URL\", \"#{default_url}\")}]\n"
          io << "if ARGV.includes?(\"--all\")\n"
          io << "  ENV.each do |key, value|\n"
          io << "    urls << {key[\"DATABASE_URL_\".size..].downcase, value} if key.starts_with?(\"DATABASE_URL_\") && !key.ends_with?(\"_TEST\")\n"
          io << "  end\n"
          io << "end\n"
          io << "urls.each do |(db_name, url)|\n"
          io << "  next if url.empty?\n"
          if action == "create"
            io << "  created = Saci::DBTasks.create_database(url)\n"
            io << "  puts created ? \"Created \#{db_name}\" : \"Already exists \#{db_name}\"\n"
          else
            io << "  existed = Saci::DBTasks.drop_database(url)\n"
            io << "  puts existed ? \"Dropped \#{db_name}\" : \"Does not exist \#{db_name}\"\n"
          end
          io << "end\n"
        end
      end

      private def self.run_external_source(label : String, source : String, args : Array(String) = [] of String, output : IO = STDOUT, flags : Array(String) = [] of String) : Int32
        path = File.join("tmp", ".saci-db-#{label.gsub(":", "-")}-#{Process.pid}.cr")
        Dir.mkdir_p("tmp")
        File.write(path, source)
        begin
          crystal = Util.crystal_bin!
          crystal_args = ["run"] + flags + [path, "--"] + args
          puts "Running: #{crystal} #{crystal_args.join(" ")}" if output == STDOUT
          status = Process.run(crystal, args: crystal_args, output: output, error: STDERR)
          status.success? ? 0 : 1
        ensure
          File.delete(path) if File.exists?(path)
        end
      end

      private def self.run_generated(label : String, source : String, args : Array(String), flags : Array(String), env : Hash(String, String)? = nil) : Int32
        path = File.join("tmp", ".saci-db-#{label.gsub(":", "-")}-#{Process.pid}.cr")
        Dir.mkdir_p("tmp")
        File.write(path, source)
        begin
          crystal = Util.crystal_bin!
          crystal_args = ["run"] + flags + [path, "--"] + args
          puts "Running: #{crystal} #{crystal_args.join(" ")}"
          status = Process.run(crystal, args: crystal_args, output: STDOUT, error: STDERR, env: env)
          status.success? ? 0 : 1
        ensure
          File.delete(path) if File.exists?(path)
        end
      end

      private def self.test_env(test : Bool) : Hash(String, String)?
        test ? {"APP_ENV" => "test"} : nil
      end

      private def self.with_env(vars : Hash(String, String), & : -> T) : T forall T
        previous = {} of String => String?
        vars.each do |key, value|
          previous[key] = ENV[key]?
          ENV[key] = value
        end
        begin
          yield
        ensure
          previous.each do |key, value|
            if value
              ENV[key] = value
            else
              ENV.delete(key)
            end
          end
        end
      end

      private def self.check_production_guard!(env : String, force : Bool) : Nil
        return unless env == "production"
        return if force || ENV["SACI_ALLOW_PRODUCTION_DB"]? == "1"
        raise Error.new("Refusing to drop the production database. Set SACI_ALLOW_PRODUCTION_DB=1 or pass --force if you really mean it.")
      end

      def self.help : String
        <<-HELP
        Usage: saci db:ACTION [--all] [--force] [-- crystal flags]

          db:prepare            create if missing, migrate (or load schema), seed on create
          db:setup              create + schema/migrate + seed
          db:reset              drop + setup
          db:version            print the current schema version
          db:migrate:status     list migrations as up/down
          db:fixtures:load      load YAML fixtures (spec/fixtures or test/fixtures)
          db:seed:replant       truncate every table, then run db/seed.cr
          db:schema:cache:dump  write db/schema_cache.yml (portable YAML snapshot)
          db:test:prepare       create + prepare the test database (no seed)
          db:create             create the database(s)
          db:drop               drop the database(s) (refuses in production unless --force)
          db:migrate|rollback|schema:dump|schema:load|schema:check|seed are separate commands.

        With --all, primary + every DATABASE_URL_<NAME> database is targeted.
        HELP
      end
    end
  end
end
