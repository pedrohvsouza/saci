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
        "Usage: saci new APP_NAME [--saci-path PATH] [--skip-shards] [--skip-git]\n\nGenerates a runnable app skeleton in ./APP_NAME."
      when "generate", "g"
        <<-HELP
        Usage:
          saci generate model NAME [field:type ...]
          saci generate controller NAME [action ...]
          saci generate migration NAME [field:type ...]
          saci generate channel NAME
          saci generate job NAME
          saci generate mailer NAME
          saci generate scaffold NAME [field:type ...]

        Field types: string, text, integer, bigint, float, boolean, datetime.
        Examples:
          saci g model Post title:string views:integer published:boolean
          saci g controller Posts index show
          saci g migration AddBioToUsers bio:text
          saci g channel Chat
          saci g job Welcome
          saci g mailer User
          saci g scaffold Post title:string
        HELP
      when "serve", "server", "s"
        "Usage: saci serve [--port N] [--host H] [--release] [--watch] [--watch-interval SECS] [--mt] [--workers N] [-- extra crystal args]\n\nRuns src/<app>.cr with crystal run (PORT/HOST env are set for the app). With --watch, rebuilds and restarts on file changes. With --mt, compiles with multithreading (-Dexecution_context) and enables it at boot via SACI_MT."
      when "db:migrate"
        "Usage: saci db:migrate\n\nRuns pending migrations in db/migrate/ (keeps db/migrations.cr in sync first)."
      when "db:rollback"
        "Usage: saci db:rollback [STEPS]\n\nRolls back the last STEPS migrations (default 1)."
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

          new APP_NAME              generate a new app skeleton
          generate (g) KIND ...     generate a model, controller or migration
          serve (s)                 run the app (see `saci help serve`)
          test (t)                  run the spec suite (see `saci help test`)
          db:migrate                run pending migrations
          db:rollback [STEPS]       roll back migrations
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
