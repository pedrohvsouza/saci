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
      when "serve", "server", "s"
        Serve.run(args)
      when "test", "t"
        Test.run(args)
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
      when "secret"
        Secret.run(args)
      when "credentials:show"
        Credentials.run(args, "show")
      when "credentials:edit"
        Credentials.run(args, "edit")
      when "credentials:keygen"
        Credentials.run(args, "keygen")
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
        "Usage: saci new APP_NAME [--db=sqlite|postgres|mysql] [--saci-path PATH] [--skip-shards] [--skip-git]\n\nGenerates a runnable app skeleton in ./APP_NAME (--db picks driver deps + require lines + URL defaults)."
      when "generate", "g"
        <<-HELP
        Usage:
          saci generate model NAME [field:type ...]
          saci generate controller NAME [action ...]
          saci generate migration NAME [field:type ...] [--unique]
          saci generate channel NAME
          saci generate job NAME
          saci generate mailer NAME
          saci generate scaffold NAME [field:type ...]

        Field types: string, text, integer, bigint, float, boolean, datetime.
        Migration names: AddXToY emits add_column; AddIndex... (or --unique) emits add_index.
        Request specs use real verbs (create->POST, update->PATCH, destroy->DELETE).
        Examples:
          saci g model Post title:string views:integer published:boolean
          saci g controller Posts index show
          saci g migration AddBioToUsers bio:text
          saci g migration AddIndexToFollows follower_id --unique
          saci g channel Chat
          saci g job Welcome
          saci g mailer User
          saci g scaffold Post title:string
        HELP
      when "serve", "server", "s"
        "Usage: saci serve [--port N] [--host H] [--release] [--watch] [--watch-interval SECS] [--mt] [--workers N] [-- extra crystal args]\n\nRuns src/<app>.cr with crystal run (PORT/HOST env are set for the app). With --watch, rebuilds and restarts on file changes. With --mt, compiles with multithreading (-Dexecution_context) and enables it at boot via SACI_MT."
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
      when "credentials:show", "credentials:edit", "credentials:keygen"
        "Usage: saci credentials:show | credentials:edit [EDITOR] | credentials:keygen\n\nShows, edits ($EDITOR) or generates the key for the encrypted credentials file."
      when "test", "t"
        "Usage: saci test [spec files/options] [-- crystal compiler flags]\n\nRuns the app's spec suite (crystal spec). Uses the test database via APP_ENV=test."
      else
        <<-HELP
        Saci #{Saci::VERSION} — Rails-compatible web framework for Crystal.

        Usage: saci COMMAND [args]

          new APP_NAME              generate a new app skeleton (--db=sqlite|postgres|mysql)
          generate (g) KIND ...     generate a model, controller or migration
          serve (s)                 run the app (see `saci help serve`)
          test (t)                  run the spec suite (see `saci help test`)
          db:migrate [--all]        run pending migrations (all DBs with --all)
          db:rollback [STEPS] [--all] roll back migrations
          db:schema:dump [--all]      dump the schema to db/schema.cr (all DBs with --all)
          db:schema:load              load db/schema.cr (recreate tables + indexes)
          db:schema:check [--all] warn when DB and models disagree (exit 1 on drift)
          secret                    print a random SECRET_KEY_BASE
          credentials:show         decrypt and print credentials
          credentials:edit         edit credentials in $EDITOR
          credentials:keygen       generate config/master.key
          version                   print the version
          help [COMMAND]            show this help or command help
        HELP
      end
    end
  end
end
