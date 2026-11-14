require "./tasks"
require "./ci"
require "./db_tasks"
require "./cli/util"
require "./cli/new_command"
require "./cli/generate_command"
require "./cli/destroy_command"
require "./cli/serve_command"
require "./cli/schema_command"
require "./cli/schema_check_command"
require "./cli/test_command"
require "./cli/secret_command"
require "./cli/credentials_command"
require "./cli/inspect_command"
require "./cli/task_command"
require "./cli/db_task_command"
require "./cli/info_command"
require "./cli/ci_command"
require "./cli/app_update_command"
require "./cli/watch"

require "./cli/util"
require "./cli/new_command"
require "./cli/generate_command"
require "./cli/destroy_command"
require "./cli/serve_command"
require "./cli/schema_command"
require "./cli/schema_check_command"
require "./cli/test_command"
require "./cli/secret_command"
require "./cli/credentials_command"
require "./cli/inspect_command"
require "./cli/task_command"
require "./cli/db_task_command"
require "./cli/info_command"
require "./cli/ci_command"
require "./cli/app_update_command"
require "./cli/importmap_command"
require "./cli/assets_command"
require "./cli/watch"

module Saci
  # Command-line interface (`saci new/generate/serve/db:migrate/...`).
  module CLI
    def self.run(argv : Array(String)) : Int32
      args = argv.dup
      cmd = args.shift?
      case cmd
      when nil, "-h", "--help", "help"
        puts help_text(args.first?)
        0
      when "-v", "--version", "version"
        puts "saci #{Saci::VERSION}"
        0
      when "new"
        New.run(args)
      when "generate", "g"
        Generate.run(args)
      when "destroy"
        Destroy.run(args)
      when "serve", "server", "s"
        Serve.run(args)
      when "test", "t"
        Test.run(args)
      when "db"
        if args.empty? || args == ["-h"] || args == ["--help"]
          puts Db.help
          0
        else
          raise Error.new("Unknown db task '#{args.first}'. See `saci help db`.")
        end
      when "db:migrate", "db:migrate:up"
        Db.run(args, "up")
      when "db:rollback", "db:migrate:down"
        Db.run(args, "down")
      when "db:schema:dump"
        Schema.run(args, "dump")
      when "db:schema:load"
        Schema.run(args, "load")
      when "db:schema:check"
        SchemaCheck.run(args)
      when "db:prepare", "db:setup", "db:reset", "db:version", "db:migrate:status",
           "db:fixtures:load", "db:seed:replant", "db:schema:cache:dump",
           "db:test:prepare", "db:create", "db:drop"
        Db.run_action(cmd.not_nil!.sub("db:", ""), args)
      when "secret"
        Secret.run(args)
      when "routes"
        Inspect::Routes.run(args)
      when "runner"
        Inspect::Runner.run(args)
      when "console"
        Inspect::Console.run(args)
      when "db:seed"
        Inspect::Seed.run(args)
      when "task", "tasks", "rake"
        TaskCommand.run(args)
      when "task:list"
        TaskCommand.run(["list"] + args)
      when "task:run"
        TaskCommand.run(["run"] + args)
      when "importmap", "importmap:help"
        puts ImportmapCommand.help
        0
      when "importmap:install"
        ImportmapCommand.run(["install"] + args)
      when "importmap:json"
        ImportmapCommand.run(["json"] + args)
      when "importmap:pin"
        ImportmapCommand.run(["pin"] + args)
      when "importmap:pin_all_from"
        ImportmapCommand.run(["pin_all_from"] + args)
      when "assets:precompile"
        AssetsCommand.run(args, "precompile")
      when "assets:clobber"
        AssetsCommand.run(args, "clobber")
      when "ci"
        CICommand.run(args)
      when "app:update"
        AppUpdate.run(args)
      when "about"
        Info.about(args)
      when "stats"
        Info.stats(args)
      when "notes"
        Info.notes(args)
      when "middleware"
        Info.middleware(args)
      when "initializers"
        Info.initializers(args)
      when "initializers:run"
        Info.initializers_run(args)
      when "dbconsole"
        Info.dbconsole(args)
      when "dev:cache"
        Info.dev_cache(args)
      when "log:clear"
        Info.log_clear(args)
      when "tmp:clear"
        Info.tmp_clear(args)
      when "time:zones", "time:zones:all"
        Info.time_zones(args)
      when "restart"
        Info.restart(args)
      when "credentials:show"
        Credentials.run(args, "show")
      when "credentials:edit"
        Credentials.run(args, "edit")
      when "credentials:keygen"
        Credentials.run(args, "keygen")
      when "credentials:fetch"
        Credentials.run(args, "fetch")
      when "credentials:get"
        Credentials.run(args, "get")
      when "credentials:set"
        Credentials.run(args, "set")
      when "credentials:unset"
        Credentials.run(args, "unset")
      else
        STDERR.puts "Unknown command '#{cmd}'.\n"
        puts help_text(nil)
        1
      end
    rescue ex : Error
      STDERR.puts "error: #{ex.message}"
      1
    end

    def self.help_text(topic : String?) : String
      case topic
      when "new"
        "Usage: saci new APP_NAME [--db=sqlite|postgres|mysql] [--saci-path PATH] [--skip-shards] [--skip-git]\n\nGenerates a runnable app skeleton in ./APP_NAME (--db picks driver deps + require lines + URL defaults).\nCustom app templates (`--template`) are not supported; use `saci new` then `saci app:update` for existing apps."
      when "generate", "g"
        <<-HELP
        Usage:
          saci generate KIND NAME [args...] [--pretend] [--force] [--no-spec]

        Kinds:
          model NAME [field:type ...]          model + migration + spec
          controller NAME [action ...]         controller + request spec
          migration NAME [field:type ...]      migration (AddXToY, AddIndex...)
          scaffold NAME [field:type ...]       model + controller + migration + specs
          scaffold_controller NAME [field:type ...] controller + ECR views (existing model)
          resource NAME [field:type ...]       model + migration + JSON controller + route helper
          admin NAME [field:type ...]          namespaced admin scaffold (search/sort/pages)
          channel NAME                         cable channel (+ spec)
          job NAME                             job (+ spec)
          mailer NAME                          mailer (+ spec)
          authentication [USER]                sessions + password reset + User model/migration
          task NAME                            lib/tasks/<name>.cr (reports:daily -> subdirs)
          helper NAME                          src/helpers/<name>_helper.cr
          test NAME                            spec/models/<name>_test.cr skeleton
          integration_test NAME                spec/integration/<name>_test.cr skeleton
          benchmark NAME                       benchmarks/<name>_benchmark.cr
          application_record                   src/models/application_record.cr

        Field types: string, text, integer, bigint, float, boolean, datetime.
        Migration names: AddXToY emits add_column; AddIndex... (or --unique) emits add_index.
        Flags: --pretend prints would-be writes; --force overwrites without prompting;
        --no-spec/--no-test, --no-migration, --no-model, --no-controller, --no-views,
        --no-route, --no-mailer skip those artifacts.
        Examples:
          saci g model Post title:string views:integer published:boolean
          saci g scaffold Post title:string
          saci g resource Post title:string
          saci g authentication
          saci g task reports:daily
        HELP
      when "serve", "server", "s"
        "Usage: saci serve [--port N] [--host [H]] [--release] [--watch] [--watch-interval SECS] [--mt] [--workers N] [-- extra crystal args]\n\nRuns src/<app>.cr with crystal run (PORT/HOST env are set for the app). --host alone binds every interface (0.0.0.0) and prints the Network URLs other devices on the local network can open. With --watch, rebuilds and restarts on file changes. With --mt, compiles with multithreading (-Dexecution_context) and enables it at boot via SACI_MT."
      when "db:migrate"
        "Usage: saci db:migrate [--all]\n\nRuns pending migrations in db/migrate/ (keeps db/migrations.cr in sync first). With --all, migrates primary + all named DBs."
      when "db:rollback"
        "Usage: saci db:rollback [STEPS] [--all]\n\nRolls back the last STEPS migrations (default 1). With --all, rolls back on all databases."
      when "db:schema:dump"
        "Usage: saci db:schema:dump [--all] [-- crystal flags]\n\nDumps the schema to db/schema.cr (standalone runnable, portable across SQLite/PostgreSQL/MySQL). With --all, dumps primary + named DBs (registered via DATABASE_URL_<NAME> env vars) into per-database sections."
      when "db:schema:load"
        "Usage: saci db:schema:load [-- crystal flags]\n\nLoads db/schema.cr (runs it with crystal run), recreating tables + indexes. Repeatable on a fresh database."
      when "db:schema:check"
        "Usage: saci db:schema:check [--all]\n\nWarns when the database and the models disagree (missing tables/columns on either side). Exits 1 when drift is found, 0 when clean. With --all, checks primary + all named DBs."
      when "secret"
        "Usage: saci secret\n\nPrints a random secret for SECRET_KEY_BASE."
      when "routes"
        Inspect::Routes.help
      when "runner"
        Inspect::Runner.help
      when "console"
        Inspect::Console.help
      when "db:seed"
        Inspect::Seed.help
      when "credentials:show", "credentials:edit", "credentials:keygen"
        "Usage: saci credentials:show | credentials:edit [EDITOR] | credentials:keygen\n\nShows, edits ($EDITOR) or generates the key for the encrypted credentials file."
      when "credentials:fetch", "credentials:get"
        "Usage: saci credentials:fetch KEY [--to PATH|--write PATH]\n\nPrints (or writes) a (dotted) key from encrypted credentials. Exits 1 when the key is missing. `credentials:get` is an alias."
      when "credentials:set", "credentials:unset"
        "Usage: saci credentials:set KEY VALUE | credentials:set KEY --stdin | credentials:unset KEY\n\nWrites or removes a (dotted) key in the encrypted credentials without an editor (`moderation.password`). --stdin reads the value from standard input, keeping it out of shell history."
      when "destroy"
        <<-HELP
        Usage: saci destroy KIND NAME [--pretend] [--force]

        Removes the files a generator created:
          destroy model Post            destroy controller Posts
          destroy migration AddBioToUsers
          destroy scaffold Post         destroy resource Post
          destroy scaffold_controller Posts
          destroy channel Chat          destroy job Welcome
          destroy mailer User           destroy authentication
          destroy helper Posts          destroy task reports:daily
          destroy test Post             destroy integration_test Posts
          destroy benchmark Post        destroy application_record

        Modified files prompt before removal; --force removes without prompting;
        --pretend prints the plan only. Empty component directories are pruned,
        directories with unrelated files are kept, and db/migrations.cr is rebuilt.
        HELP
      when "task", "tasks", "task:list", "task:run", "rake"
        TaskCommand.help
      when "assets:precompile", "assets:clobber", "assets"
        AssetsCommand.help
      when "ci"
        CICommand.help
      when "app:update"
        AppUpdate.help
      when "db", "db:prepare", "db:setup", "db:reset", "db:version", "db:migrate:status",
           "db:fixtures:load", "db:seed:replant", "db:schema:cache:dump",
           "db:test:prepare", "db:create", "db:drop"
        Db.help
      when "about"
        "Usage: saci about\n\nPrints Saci/Crystal versions plus the app name, environment and database URL."
      when "stats"
        "Usage: saci stats\n\nPrints file/line counts per source directory (Rails `stats` equivalent)."
      when "notes"
        "Usage: saci notes\n\nLists TODO/FIXME/OPTIMIZE notes in src/, spec/, config/, db/ and lib/."
      when "middleware"
        "Usage: saci middleware\n\nLists the HTTP handler chain (websocket handler + Saci::Handler)."
      when "initializers", "initializers:run"
        "Usage: saci initializers | saci initializers:run NAME|all\n\nLists config/initializers/*.cr, or runs them in app context."
      when "dbconsole"
        "Usage: saci dbconsole [--open] [--all]\n\nPrints the database connection URL; --open launches sqlite3 for SQLite databases."
      when "dev:cache"
        "Usage: saci dev:cache [--on|--off]\n\nToggles tmp/caching-dev.txt (development cache flag)."
      when "log:clear"
        "Usage: saci log:clear\n\nTruncates every log/*.log file."
      when "tmp:clear"
        "Usage: saci tmp:clear\n\nClears tmp/cache, tmp/pids, tmp/sockets and stale tmp files."
      when "time:zones", "time:zones:all"
        "Usage: saci time:zones [--local]\n\nLists available time zones (from tzdata, or a compact fallback list)."
      when "restart"
        "Usage: saci restart\n\nTouches tmp/restart.txt so watchers/process managers restart the app."
      when "test", "t"
        "Usage: saci test [spec files/options] [-- crystal compiler flags]\n\nRuns the app's spec suite (crystal spec). Uses the test database via APP_ENV=test."
      else
        <<-HELP
        Saci #{Saci::VERSION} — Rails-compatible web framework for Crystal.

        Usage: saci COMMAND [args]

          new APP_NAME              generate a new app skeleton (--db=sqlite|postgres|mysql)
          generate (g) KIND ...     generate models, controllers, scaffolds, tasks, ...
          destroy KIND NAME ...     remove generator output (see `saci help destroy`)
          serve (s)                 run the app (see `saci help serve`)
          test (t)                  run the spec suite (see `saci help test`)
          task:list / task NAME     list/run lib/tasks/*.cr user tasks
          runner -e CODE|FILE       run code/file in app context (no boot)
          console [-e CODE]         minimal console (per-line compile; `exit` quits)
          db:migrate|rollback       run/roll back migrations (--all for every DB)
          db:prepare|setup|reset    create/migrate/seed/reset databases
          db:version|migrate:status migration bookkeeping
          db:fixtures:load          load spec/fixtures or test/fixtures YAML
          db:seed:replant           truncate tables, then run db/seed.cr
          db:schema:dump|load|check db/schema.cr snapshot commands
          db:schema:load            load the db/schema.cr snapshot
          db:schema:cache:dump      write db/schema_cache.yml
          db:test:prepare           create + prepare the test database
          db:create|drop            create/drop databases (drop refuses production)
          db:seed                   run db/seed.cr (or db/seeds.cr) in app context
          ci                        run config/ci.cr local CI steps
          importmap:install|json    write/inspect the import map (pin, pin_all_from)
          assets:precompile|clobber fingerprint src/assets into public/assets (production)
          app:update                copy missing scaffold files (--force to overwrite)
          routes [--boot] [--expanded] [--grep PATTERN]
          about|stats|notes|middleware|initializers|dbconsole
          dev:cache|log:clear|tmp:clear|time:zones|restart
          secret                    print a random SECRET_KEY_BASE
          credentials:show|edit|keygen|fetch|get|set|unset KEY
          version                   print the version
          help [COMMAND]            show this help or command help
        HELP
      end
    end
  end
end
