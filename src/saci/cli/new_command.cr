module Saci
  module CLI
    # `saci new blog` — generates a runnable app skeleton.
    module New
      # Absolute path of the framework source tree, baked in at compile time.
      # Used as the default `path:` dependency so generated apps work immediately.
      SACI_ROOT = File.expand_path("../../../", __DIR__)

      def self.run(args : Array(String)) : Int32
        name = args.find { |a| !a.starts_with?("-") } || raise Error.new("Usage: saci new APP_NAME [--db=sqlite|postgres|mysql] [--saci-path PATH] [--skip-shards] [--skip-git]")
        Util.check_app_name!(name)
        opts = parse_opts(args)
        create(name, saci_path: opts[:saci_path], skip_shards: opts[:skip_shards], skip_git: opts[:skip_git], db: opts[:db])
        0
      end

      def self.parse_opts(args : Array(String)) : NamedTuple(saci_path: String?, skip_shards: Bool, skip_git: Bool, db: String)
        saci_path = nil
        skip_shards = false
        skip_git = false
        db = "sqlite"
        i = 0
        while i < args.size
          a = args[i]
          case a
          when "--skip-shards" then skip_shards = true
          when "--skip-git"    then skip_git = true
          when .starts_with?("--saci-path=")
            saci_path = a.split("=", 2)[1]
          when "--saci-path"
            saci_path = args[i + 1]? || raise Error.new("Missing value for --saci-path")
            i += 1
          when .starts_with?("--db=")
            db = normalize_db(a.split("=", 2)[1])
          when "--db"
            db = normalize_db(args[i + 1]? || raise Error.new("Missing value for --db (expected sqlite|postgres|mysql)"))
            i += 1
          end
          i += 1
        end
        {saci_path: saci_path, skip_shards: skip_shards, skip_git: skip_git, db: db}
      end

      # Normalizes `--db` values (accepts common aliases, fails fast).
      def self.normalize_db(db : String) : String
        case db.downcase
        when "sqlite", "sqlite3"       then "sqlite"
        when "postgres", "postgresql"  then "postgres"
        when "mysql"                   then "mysql"
        else                                raise Error.new("Unknown --db '#{db}'. Expected sqlite|postgres|mysql.")
        end
      end

      def self.create(name : String, dir : String = name, saci_path : String? = nil, skip_shards : Bool = false, skip_git : Bool = false, db : String = "sqlite") : Nil
        Util.check_app_name!(name)
        db = normalize_db(db)
        raise Error.new("Directory #{dir} already exists and is not empty.") if Dir.exists?(dir) && !Dir.empty?(dir)
        Dir.mkdir_p(dir)

        dep = saci_path || SACI_ROOT
        write(File.join(dir, "shard.yml"), shard_yml(name, dep, db))
        write(File.join(dir, ".gitignore"), gitignore)
        write(File.join(dir, "README.md"), readme(name))
        write(File.join(dir, "src", "#{name}.cr"), entrypoint(name, db))
        write(File.join(dir, "src", "controllers", "application_controller.cr"), application_controller)
        write(File.join(dir, "src", "controllers", "home_controller.cr"), home_controller)
        write(File.join(dir, "src", "channels", ".gitkeep"), "")
        write(File.join(dir, "src", "jobs", ".gitkeep"), "")
        write(File.join(dir, "src", "mailers", ".gitkeep"), "")
        write(File.join(dir, "src", "views", "layouts", "application.ecr"), layout_view)
        write(File.join(dir, "src", "views", "home", "index.ecr"), home_view)
        write(File.join(dir, "src", "models", "application_record.cr"), application_record)
        write(File.join(dir, "db", "migrations.cr"), Generate.manifest_source([] of String, [] of String))
        write(File.join(dir, "db", "migrate.cr"), migrate_runner(name, db))
        Dir.mkdir_p(File.join(dir, "config"))
        Dir.cd(dir) do
          File.write("config/master.key", Saci::Credentials.generate_key + "\n")
          puts "  create #{dir}/config/master.key (gitignored — never commit it)"
          Saci::Credentials.write({"secret_key_base" => YAML::Any.new(Saci::Secrets.generate_secret)})
          puts "  create #{dir}/config/credentials.yml.enc (seeds secret_key_base)"
        end
        write(File.join(dir, "db", "migrate", ".gitkeep"), "")
        write(File.join(dir, "config", "environments", "development.cr"), env_development)
        write(File.join(dir, "config", "environments", "test.cr"), env_test)
        write(File.join(dir, "config", "environments", "production.cr"), env_production)
        write(File.join(dir, "config", "locales", "en.yml"), locales_en)
        write(File.join(dir, "config", "locales", "es.yml"), locales_es)
        write(File.join(dir, "spec", "spec_helper.cr"), spec_helper(name, db))
        write(File.join(dir, "spec", "app_spec.cr"), app_spec(name))

        unless skip_shards
          puts "Installing dependencies (shards install)..."
          status = Process.run("shards", args: ["install"], chdir: dir, output: STDOUT, error: STDERR)
          puts "warning: `shards install` failed — run it manually in #{dir}." unless status.success?
        end

        unless skip_git
          if Process.find_executable("git")
            Process.run("git", args: ["init", "-q"], chdir: dir, output: Process::Redirect::Close, error: Process::Redirect::Close)
          end
        end

        puts "Created #{name}/ — next steps:"
        puts "  cd #{dir}"
        puts "  saci generate model Post title:string"
        puts "  saci db:migrate"
        puts "  saci test"
        puts "  saci serve"
      end

      private def self.write(path : String, content : String) : Nil
        Dir.mkdir_p(File.dirname(path))
        File.write(path, content)
        puts "  create #{path}"
      end

      def self.shard_yml(name : String, saci_path : String, db : String = "sqlite") : String
        deps = case normalize_db(db)
               when "postgres"
                 "          pg:\n            github: will/crystal-pg\n            version: \"~> 0.30.0\""
               when "mysql"
                 "          mysql:\n            github: crystal-lang/crystal-mysql\n            version: \"~> 0.17.0\""
               else
                 "          # PostgreSQL / MySQL need an app-level driver (the framework stays\n          # driver-free so SQLite apps link anywhere):\n          # pg:\n          #   github: will/crystal-pg\n          #   version: \"~> 0.30.0\"\n          # mysql:\n          #   github: crystal-lang/crystal-mysql\n          #   version: \"~> 0.17.0\""
               end
        <<-YAML
        name: #{name}
        version: 0.1.0

        description: #{Util.class_name(name)} app built with Saci.

        authors:
          - you

        crystal: ">= 1.0.0"

        dependencies:
          saci:
            path: #{saci_path}
        #{deps}

        license: MIT
        YAML
      end

      def self.gitignore : String
        "/.crystal/\n/.shards/\n/lib/\n/bin/\n/tmp/\n*.dwarf\n/db/*.db\n/config/master.key\n.DS_Store\n"
      end

      def self.readme(name : String) : String
        <<-MD
        # #{Util.class_name(name)}

        Built with [Saci](https://github.com/rails-crystal/saci) (Rails-compatible web framework for Crystal).

        ```sh
        shards install
        saci generate model Post title:string
        saci db:migrate
        saci test
        saci serve
        ```
        MD
      end

      # Default DATABASE_URL per `--db` picker (template-level only; no live
      # servers needed). SQLite uses a file per APP_ENV; Postgres/MySQL use
      # `localhost` with the app + env in the DB name.
      def self.db_url_default(name : String, db : String, env_suffix : String) : String
        case normalize_db(db)
        when "postgres" then "postgres://localhost/#{name}_#{env_suffix}"
        when "mysql"    then "mysql://root@localhost/#{name}_#{env_suffix}"
        else                 "sqlite3://./db/#{name}_#{env_suffix}.db"
        end
      end

      def self.db_driver_require(db : String) : String
        case normalize_db(db)
        when "postgres" then "require \"pg\"\n"
        when "mysql"    then "require \"mysql\"\n"
        else                 ""
        end
      end

      def self.entrypoint(name : String, db : String = "sqlite") : String
        ndb = normalize_db(db)
        url_default = db_url_default(name, ndb, "\#{env_name}")
        driver = db_driver_require(ndb)
        <<-CRYSTAL
        #{driver}require "saci"
        require "file_utils"
        require "../config/environments/development"
        require "../config/environments/test"
        require "../config/environments/production"
        require "./models/*"
        require "./controllers/*"
        require "./channels/*"
        require "./jobs/*"
        require "./mailers/*"

        env_name = ENV.fetch("APP_ENV", "development")
        FileUtils.mkdir_p("db")
        db_url = ENV.fetch("DATABASE_URL", "#{url_default}")
        Saci::Record.connect(db_url)
        Saci::I18n.reload!
        Saci.enable_multithreading! if ENV["SACI_MT"]? == "1"

        router = Saci::Router.new.draw do |r|
          r.root HomeController, :index
        end

        port = ENV.fetch("PORT", "3000").to_i
        Saci::Application.new(router).listen(port)
        CRYSTAL
      end

      def self.application_controller : String
        <<-CRYSTAL
        class ApplicationController < Saci::Controller
        end
        CRYSTAL
      end

      def self.home_controller : String
        <<-CRYSTAL
        class HomeController < ApplicationController
          def index
            @app_name = "Saci"
            render_template(:index)
          end
        end
        CRYSTAL
      end

      def self.application_record : String
        <<-CRYSTAL
        class ApplicationRecord < Saci::Record::Base
        end
        CRYSTAL
      end

      def self.env_development : String
        <<-CRYSTAL
        # Development defaults (Saci ships safe dev defaults; tune here).
        if Saci.env == "development"
          Saci.log_level = :debug
          Saci.log_requests = true
          Saci.show_detailed_exceptions = true
        end
        CRYSTAL
      end

      def self.env_test : String
        <<-CRYSTAL
        if Saci.env == "test"
          Saci.log_level = :warn
          Saci.log_requests = false
          Saci.show_detailed_exceptions = false
          Saci::Record.bcrypt_min_cost = true
        end
        CRYSTAL
      end

      def self.env_production : String
        <<-CRYSTAL
        if Saci.env == "production"
          Saci.log_level = :warn
          Saci.force_ssl = true
          Saci.show_detailed_exceptions = false
          # Opaque sessions (no downgrade: enable before launch, since
          # previously signed sessions stop being accepted).
          Saci::Session.encrypt = true
          # Multi-replica deploys: point Cable pub/sub and throttle counters
          # at one Redis instead of per-process memory (both fail open when
          # Redis is down — see README). Zero new dependencies (vendored RESP2).
          # Saci::Cable.server = Saci::Cable::RedisServer.new(ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379"))
          # Saci::Throttle.store = Saci::Throttle::RedisStore.new(ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379"))
        end
        CRYSTAL
      end

      def self.locales_en : String
        <<-YAML
        en:
          hello: "Hello from Saci"
          items:
            one: "%{count} item"
            other: "%{count} items"
        YAML
      end

      def self.locales_es : String
        <<-YAML
        es:
          hello: "Hola desde Saci"
          items:
            one: "%{count} artículo"
            other: "%{count} artículos"
        YAML
      end

      # Standalone runner: loads models + migrations WITHOUT booting the
      # web server (the app entrypoint calls `listen`, so it must NOT be
      # required here).
      def self.migrate_runner(name : String, db : String = "sqlite") : String
        ndb = normalize_db(db)
        url_default = db_url_default(name, ndb, "\#{env_name}")
        driver = db_driver_require(ndb)
        <<-CRYSTAL
        # Run with: saci db:migrate [--all] | saci db:rollback [STEPS] [--all] | saci db:schema:check [--all]
        # (`--all` migrates primary + all named DBs; without it only primary.)
        # (Do not edit by hand — `saci generate migration` keeps db/migrations.cr in sync.)
        #{driver}require "saci"
        require "file_utils"
        require "../src/models/*"
        require "./migrations"

        FileUtils.mkdir_p("db")
        env_name = ENV.fetch("APP_ENV", "development")
        db_url = ENV.fetch("DATABASE_URL", "#{url_default}")
        Saci::Record.connect(db_url)
        # Named databases (multidb): register yours here, e.g.
        # Saci::Record.establish_connection("analytics", ENV.fetch("DATABASE_URL_ANALYTICS", "#{db_url_default(name, ndb, "analytics_\#{env_name}")}"))

        # Warns on STDERR when the database and the models disagree (tables
        # or columns missing on either side). Never fails the migrate itself.
        def print_schema_drift!(db_name : String) : Nil
          db = Saci::Record.database(db_name)
          Saci::Record.check_schema!(db).each do |warning|
            STDERR.puts "warning: schema drift (\#{db_name}): \#{warning}"
          end
        end

        action = ARGV[0]? || "up"
        rest = (ARGV[1..]? || [] of String)
        migrate_all = rest.includes?("--all") || ARGV.includes?("--all")
        steps = (rest.reject { |a| a == "--all" }.first? || "1").to_i
        targets = migrate_all ? Saci::Record.configuration_names : ["primary"]
        case action
        when "up"
          targets.each do |db_name|
            db = Saci::Record.database(db_name)
            ran = Saci::Record::Migrator.migrate(db, SACI_MIGRATIONS)
            puts "Migrated \#{db_name}: \#{ran.inspect}"
          end
          targets.each { |db_name| print_schema_drift!(db_name) }
        when "down"
          targets.reverse.each do |db_name|
            db = Saci::Record.database(db_name)
            undone = Saci::Record::Migrator.rollback(db, SACI_MIGRATIONS, steps)
            puts "Rolled back \#{db_name}: \#{undone.inspect}"
          end
          targets.each { |db_name| print_schema_drift!(db_name) }
        when "schema:check"
          drift = 0
          targets.each do |db_name|
            db = Saci::Record.database(db_name)
            Saci::Record.check_schema!(db).each do |warning|
              puts "drift (\#{db_name}): \#{warning}"
              drift += 1
            end
          end
          if drift == 0
            puts "Schema check: no drift (\#{targets.size} database(s), \#{Saci::Record.models.size} model(s))."
          end
          exit(drift == 0 ? 0 : 1)
        else
          abort "Unknown action \#{action} (expected up|down|schema:check)"
        end
        CRYSTAL
      end

      def self.spec_helper(name : String, db : String = "sqlite") : String
        ndb = normalize_db(db)
        url_default = db_url_default(name, ndb, "test")
        driver = db_driver_require(ndb)
        <<-CRYSTAL
        require "spec"
        #{driver}require "saci"
        require "file_utils"
        require "../src/models/*"
        require "../src/controllers/*"
        require "../src/channels/*"
        require "../src/jobs/*"
        require "../src/mailers/*"
        require "../db/migrations"

        # Isolated test database (never touch development data).
        # Multidb apps: establish named DBs here too and use
        # `Saci::Record.clean_all!` in specs to truncate all connections.
        FileUtils.mkdir_p("db")
        ENV["APP_ENV"] = "test"
        db_url = ENV.fetch("DATABASE_URL", "#{url_default}")
        Saci::Record.connect(db_url)
        Saci::I18n.reload!
        Saci::Record::Migrator.migrate(Saci::Record.connection.as(DB::Database), SACI_MIGRATIONS)
        Saci::Job.queue_adapter = :test
        Saci::Mailer.delivery_adapter = :test
        CRYSTAL
      end

      def self.app_spec(name : String) : String
        <<-CRYSTAL
        require "./spec_helper"

        describe "#{Util.class_name(name)} requests" do
          before_each do
            Saci::Record.clean_database!
          end

          it "serves the home page as HTML" do
            router = Saci::Router.new.draw do |r|
              r.root HomeController, :index
            end
            Saci::TestSession.serve(router) do |app|
              resp = app.get("/")
              resp.status_code.should eq(200)
              resp.body.should contain("Welcome")
            end
          end
        end
        CRYSTAL
      end

      def self.layout_view : String
        <<-ECR
        <html>
        <head><title>Saci app</title></head>
        <body><%= content %></body>
        </html>
        ECR
      end

      def self.home_view : String
        <<-ECR
        <h1>Welcome to <%= h(@app_name) %></h1>
        <p>Built with Saci, the Rails-compatible Crystal framework.</p>
        ECR
      end
    end
  end
end
