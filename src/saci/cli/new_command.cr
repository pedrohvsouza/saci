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
        when "sqlite", "sqlite3"      then "sqlite"
        when "postgres", "postgresql" then "postgres"
        when "mysql"                  then "mysql"
        else                               raise Error.new("Unknown --db '#{db}'. Expected sqlite|postgres|mysql.")
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
        write(File.join(dir, ".tool-versions"), "crystal #{Crystal::VERSION}\n")
        write(File.join(dir, "README.md"), readme(name))
        write(File.join(dir, "src", "#{name}.cr"), entrypoint(name, db))
        write(File.join(dir, "src", "controllers", "application_controller.cr"), application_controller)
        write(File.join(dir, "src", "controllers", "home_controller.cr"), home_controller)
        write(File.join(dir, "src", "controllers", "health_controller.cr"), health_controller)
        write(File.join(dir, "src", "channels", ".gitkeep"), "")
        write(File.join(dir, "src", "jobs", ".gitkeep"), "")
        write(File.join(dir, "src", "mailers", ".gitkeep"), "")
        write(File.join(dir, "src", "views", "layouts", "application.ecr"), layout_view)
        write(File.join(dir, "src", "views", "home", "index.ecr"), home_view)
        write(File.join(dir, "src", "models", "application_record.cr"), application_record)
        write(File.join(dir, "db", "migrations.cr"), Generate.manifest_source([] of String, [] of String))
        write(File.join(dir, "db", "migrate.cr"), migrate_runner(name, db))
        write(File.join(dir, "db", "seed.cr"), seed_file)
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
        write(File.join(dir, "config", "environments", "staging.cr"), env_staging)
        write(File.join(dir, "config", "locales", "en.yml"), locales_en)
        write(File.join(dir, "config", "locales", "es.yml"), locales_es)
        write(File.join(dir, "config", "initializers", "filter_parameter_logging.cr"), initializer_filter_parameter_logging)
        write(File.join(dir, "config", "initializers", "cors.cr"), initializer_cors)
        write(File.join(dir, "config", "initializers", "assets.cr"), initializer_assets)
        write(File.join(dir, "spec", "spec_helper.cr"), spec_helper(name, db))
        write(File.join(dir, "spec", "app_spec.cr"), app_spec(name))
        write(File.join(dir, "spec", "controllers", ".gitkeep"), "")
        write(File.join(dir, "spec", "models", ".gitkeep"), "")
        write(File.join(dir, "spec", "mailers", ".gitkeep"), "")
        write(File.join(dir, "spec", "integration", ".gitkeep"), "")
        write(File.join(dir, "spec", "fixtures", ".gitkeep"), "")

        # Rails-like operating surface. Tests are Crystal specs, not minitest:
        # the directories above mirror test/{controllers,models,...}.
        write(File.join(dir, "public", "400.html"), public_error_page(400, "Bad Request"))
        write(File.join(dir, "public", "404.html"), public_error_page(404, "Not Found"))
        write(File.join(dir, "public", "422.html"), public_error_page(422, "Unprocessable Content"))
        write(File.join(dir, "public", "500.html"), public_error_page(500, "Internal Server Error"))
        write(File.join(dir, "public", "robots.txt"), robots_txt)
        write(File.join(dir, "storage", ".gitkeep"), "")
        write(File.join(dir, "log", ".gitkeep"), "")
        write(File.join(dir, "tmp", "pids", ".gitkeep"), "")
        write(File.join(dir, "vendor", ".gitkeep"), "")
        write(File.join(dir, "script", ".gitkeep"), "")

        write_executable(File.join(dir, "bin", "saci"), bin_saci)
        write_executable(File.join(dir, "bin", "setup"), bin_setup)
        write_executable(File.join(dir, "bin", "dev"), bin_dev)
        write_executable(File.join(dir, "bin", "ci"), bin_ci)
        write_executable(File.join(dir, "bin", "docker-entrypoint"), bin_docker_entrypoint)
        write_executable(File.join(dir, "bin", "thrust"), bin_thrust)
        write(File.join(dir, "Dockerfile"), dockerfile(name))
        write(File.join(dir, ".dockerignore"), dockerignore)
        write(File.join(dir, ".github", "workflows", "ci.yml"), ci_workflow)

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
        # POSIX text convention: generated files end with a newline. This
        # also keeps `crystal tool format --check` (see the generated CI
        # workflow) clean for fresh apps.
        content += "\n" unless content.empty? || content.ends_with?('\n')
        File.write(path, content)
        puts "  create #{path}"
      end

      # Heredocs drop the final newline. `write` adds it, so the one template
      # a spec compares byte-for-byte with its file (env_staging) does too.
      private def self.ensure_newline(content : String) : String
        content.ends_with?('\n') ? content : content + "\n"
      end

      # Binstubs must survive a checkout with their executable bit intact.
      # Git records the mode, so chmod at generation time (Crystal has no
      # portable `install -m` equivalent worth shelling out for).
      private def self.write_executable(path : String, content : String) : Nil
        write(path, content)
        File.chmod(path, 0o755)
      end

      # Builds `shard.yml` line-by-line rather than interpolating a block into
      # a heredoc: heredoc indentation stripping turned the driver block into
      # `pg:` *under* `saci.path`, which made every Postgres/MySQL app fail
      # `shards install` (RAILS_GAP_ANALYSIS D1). A flat list keeps every
      # dependency key at the same two-space level.
      def self.shard_yml(name : String, saci_path : String, db : String = "sqlite") : String
        lines = [
          "name: #{name}",
          "version: 0.1.0",
          "",
          "description: #{Util.class_name(name)} app built with Saci.",
          "",
          "authors:",
          "  - you",
          "",
          "crystal: \">= 1.0.0\"",
          "",
          "dependencies:",
          "  saci:",
          "    path: #{saci_path}",
        ]
        case normalize_db(db)
        when "postgres"
          lines << "  pg:"
          lines << "    github: will/crystal-pg"
          lines << "    version: \"~> 0.30.0\""
        when "mysql"
          lines << "  mysql:"
          lines << "    github: crystal-lang/crystal-mysql"
          lines << "    version: \"~> 0.17.0\""
        else
          lines << "  # PostgreSQL / MySQL need an app-level driver (the framework stays"
          lines << "  # driver-free so SQLite apps link anywhere):"
          lines << "  # pg:"
          lines << "  #   github: will/crystal-pg"
          lines << "  #   version: \"~> 0.30.0\""
          lines << "  # mysql:"
          lines << "  #   github: crystal-lang/crystal-mysql"
          lines << "  #   version: \"~> 0.17.0\""
        end
        lines << ""
        lines << "targets:"
        lines << "  #{name}:"
        lines << "    main: src/#{name}.cr"
        lines << ""
        lines << "license: MIT"
        lines << ""
        lines.join('\n')
      end

      # `/bin/*` ignores release binaries but re-includes the project
      # binstubs, which are part of the scaffold and must be committed.
      def self.gitignore : String
        <<-IGNORE
        /.crystal/
        /.shards/
        /lib/
        /bin/*
        !/bin/saci
        !/bin/setup
        !/bin/dev
        !/bin/ci
        !/bin/docker-entrypoint
        !/bin/thrust
        /tmp/*
        !/tmp/.gitkeep
        !/tmp/pids/
        /tmp/pids/*
        !/tmp/pids/.gitkeep
        /log/*
        !/log/.gitkeep
        /storage/*
        !/storage/.gitkeep
        /vendor/*
        !/vendor/.gitkeep
        *.dwarf
        /db/*.db
        /db/*.db-*
        /config/master.key
        .DS_Store
        IGNORE
      end

      def self.readme(name : String) : String
        app = Util.class_name(name)
        <<-MD
        # #{app}

        Built with [Saci](https://github.com/rails-crystal/saci) — a
        Rails-compatible web framework for Crystal.

        ## Quick start

        ```sh
        bin/setup          # shards install + db:migrate + db:seed
        bin/dev            # saci serve --watch on http://127.0.0.1:3000
        ```

        The health endpoint answers `GET /up` with `200 OK`; point container
        and load-balancer probes at it.

        ## Everyday commands

        | Command | What it does |
        | --- | --- |
        | `bin/saci ...` | Project-local wrapper around the global `saci` binary (args pass through, including `--`). |
        | `bin/setup` | Installs shards, runs migrations, then seeds. `SKIP_SEED=1 bin/setup` skips seeding. |
        | `bin/dev` | `saci serve --watch`; extra args go to `saci serve` (e.g. `bin/dev --port 4000`). |
        | `bin/ci` | `crystal spec`. Set `SACI_EXECUTION_CONTEXT=1` (or pass `--execution-context`) to add `-Dexecution_context`. |
        | `bin/docker-entrypoint` | Prepares the database (`saci db:migrate` or the release `bin/saci-migrate`) and then execs its arguments. |
        | `bin/thrust` | Documentation only: Saci has no bundled proxy. Put Caddy/nginx/Thruster in front of `saci serve`. |

        Direct framework commands still work:

        ```sh
        shards install
        saci generate model Post title:string
        saci db:migrate
        saci db:seed
        saci test
        saci serve
        ```

        ## Layout

        - `src/<app>.cr` — boot file. There is deliberately **no `config.ru`**:
          Saci is not Rack-based. This file (and `bin/saci`) is the entrypoint.
        - `config/environments/*.cr` — per-environment settings, loaded by a
          require glob.
        - `config/initializers/*.cr` — app initializers, also loaded by glob
          (`require "../config/initializers/*"`). The generated files are
          comment-only examples so a fresh app always compiles.
        - `config/locales/*.yml` — I18n dictionaries.
        - `public/` — static error pages and `robots.txt`. Serve this directory
          with Saci's static middleware when the framework build provides it;
          otherwise mount it behind your reverse proxy. The `/up` route is
          dynamic and lives in `src/controllers/health_controller.cr`.
        - `spec/{controllers,models,mailers,integration,fixtures}/` — the
          Crystal equivalent of Rails' `test/` tree (`crystal spec` runs it).
        - `db/migrate/` + `db/migrations.cr` — migrations and their manifest.
        - `storage/`, `log/`, `tmp/pids/`, `vendor/`, `script/` — runtime and
          auxiliary directories. `.gitkeep` keeps empty ones in Git.
        - `bin/` — project binstubs (executable).
        - `Dockerfile`, `.dockerignore`, `.github/workflows/ci.yml` — deployment
          and CI defaults. `.tool-versions` pins the Crystal version.

        ## Docker

        ```sh
        docker build -t #{name} .
        docker run --rm -p 3000:3000 \\
          -e SECRET_KEY_BASE="$(saci secret)" \\
          -e DATABASE_URL="postgres://..." \\
          #{name}
        ```

        The image is multi-stage (Crystal build stage + slim Debian runtime),
        runs as the non-root `saci` user, prepares the database in the
        entrypoint, and exposes port 3000. `SKIP_DB_PREPARE=1` skips the
        migrate step. The generated `shard.yml` points at your local Saci
        checkout; update that path (or vendor/publish Saci) before building in
        CI or on another machine.

        ## Notes

        - There is no `Rakefile`: use the documented `saci` tasks
          (`saci db:migrate`, `saci db:seed`, `saci routes`, `saci test`, ...).
        - Set `SECRET_KEY_BASE` in production. `config/credentials.yml.enc`
          plus the gitignored `config/master.key` is the local alternative.
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

      # Saci boots from this Crystal file; there is intentionally no
      # `config.ru` (Saci is not Rack) and no generated `Rakefile` (tasks are
      # `saci db:migrate`, `saci db:seed`, ...). Keep the comment so new
      # contributors do not hunt for either.
      def self.entrypoint(name : String, db : String = "sqlite") : String
        ndb = normalize_db(db)
        url_default = db_url_default(name, ndb, "\#{env_name}")
        driver = db_driver_require(ndb)
        <<-CRYSTAL
        # Boot file for #{Util.class_name(name)}. There is no config.ru:
        # Saci is a Crystal framework, not a Rack app.
        #{driver}require "saci"
        require "file_utils"
        # Globs so every env file and initializer (including files added
        # later) loads without editing this boot file.
        require "../config/environments/*"
        require "../config/initializers/*"
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
          r.get "/up", HealthController, :show
          r.root HomeController, :index
        end

        port = ENV.fetch("PORT", "3000").to_i
        host = ENV.fetch("HOST", "127.0.0.1")
        Saci::Application.new(router).listen(port, host)
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

      # Dependency-free liveness/readiness endpoint (Rails' `GET /up`).
      # Kept as an explicit route so it works even when the framework build
      # has no health middleware.
      def self.health_controller : String
        <<-CRYSTAL
        class HealthController < ApplicationController
          # GET /up — 200 when the app can serve requests. No database query:
          # container probes should stay cheap and not fail during migrations.
          def show
            render plain: "OK", status: 200
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

      def self.env_staging : String
        content = <<-CRYSTAL
        # Staging mirrors production (real secrets, SSL, encrypted sessions)
        # but stays distinct: `log_level = :info` (production uses `:warn`)
        # plus request logging, so pre-release issues are debuggable.
        # Boot with: APP_ENV=staging saci serve
        # (Staging vs production: same hardening, more visibility. Staging
        # data is production-like — treat dumps, logs and secrets with
        # equal care. Framework-generic: no app-specific defaults here.)

        # `Saci.staging?` mirrors `Saci.production?`/`Saci.test?` (defined
        # here, outside the guard, so every scaffolded app has it in any env
        # — this file always compiles in via the environments glob).
        module Saci
          def self.staging? : Bool
            env == "staging"
          end
        end

        if Saci.env == "staging"
          Saci.log_level = :info
          Saci.log_requests = true
          Saci.force_ssl = true
          Saci.show_detailed_exceptions = false
          # Opaque sessions (no downgrade: enable before launch, since
          # previously signed sessions stop being accepted).
          Saci::Session.encrypt = true
          # Staging uses real secrets, like production: refuse to boot
          # without one (the framework only enforces this for production,
          # so staging enforces it here).
          has_secret = !ENV.fetch("SECRET_KEY_BASE", "").empty? ||
                       !(begin
                         Saci::Credentials.dig("secret_key_base") rescue nil
                       end).to_s.empty?
          unless has_secret
            raise Saci::Secrets::MissingSecretInProduction.new(
              "SECRET_KEY_BASE is not set (and no secret_key_base in credentials). " +
              "Refusing to boot in staging with a generated dev secret. " +
              "Set SECRET_KEY_BASE (e.g. from `saci secret`) and restart.")
          end
        end
        CRYSTAL
        ensure_newline(content)
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

      # Conventional seed starter (kept in sync with CLI::Inspect::Seed.template).
      # Run with: saci db:seed
      def self.seed_file : String
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

      def self.spec_helper(name : String, db : String = "sqlite") : String
        ndb = normalize_db(db)
        url_default = db_url_default(name, ndb, "test")
        driver = db_driver_require(ndb)
        <<-CRYSTAL
        require "spec"
        #{driver}require "saci"
        require "file_utils"
        # Globs so every env file (including staging) and initializer loads
        # without editing this (each env file guards on `Saci.env` itself).
        require "../config/environments/*"
        require "../config/initializers/*"
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

          it "answers the health check at /up" do
            router = Saci::Router.new.draw do |r|
              r.get "/up", HealthController, :show
            end
            Saci::TestSession.serve(router) do |app|
              resp = app.get("/up")
              resp.status_code.should eq(200)
              resp.body.should eq("OK")
            end
          end
        end
        CRYSTAL
      end

      # -- project binstubs ---------------------------------------------------

      # A thin project-local wrapper. It deliberately does not duplicate CLI
      # logic: every argument (including `--` and everything after it) is
      # forwarded verbatim to the global `saci` binary. Set SACI_BIN to point
      # at a specific build (e.g. a checkout's `bin/saci`).
      def self.bin_saci : String
        <<-SH
        #!/usr/bin/env bash
        # Project-local Saci binstub. Forwards all arguments (including `--`).
        set -euo pipefail
        exec "${SACI_BIN:-saci}" "$@"
        SH
      end

      def self.bin_setup : String
        <<-SH
        #!/usr/bin/env bash
        # First-run setup: dependencies, schema, seed data.
        set -euo pipefail
        cd "$(dirname "$0")/.."

        if ! command -v shards >/dev/null 2>&1; then
          echo "error: shards is required to set up this app." >&2
          exit 1
        fi

        shards install
        "${SACI_BIN:-saci}" db:migrate

        if [ "${SKIP_SEED:-0}" != "1" ]; then
          "${SACI_BIN:-saci}" db:seed
        fi

        echo "Setup complete. Start the app with: bin/dev"
        SH
      end

      def self.bin_dev : String
        <<-SH
        #!/usr/bin/env bash
        # Development server with hot reload.
        set -euo pipefail
        exec "${SACI_BIN:-saci}" serve --watch "$@"
        SH
      end

      # Mirrors `bin/ci` in Rails 8: specs are the default; opt into
      # multithreaded execution with SACI_EXECUTION_CONTEXT=1 or
      # `bin/ci --execution-context`.
      def self.bin_ci : String
        <<-SH
        #!/usr/bin/env bash
        set -euo pipefail
        cd "$(dirname "$0")/.."

        CRYSTAL="${CRYSTAL_BIN:-crystal}"
        MT="${SACI_EXECUTION_CONTEXT:-0}"
        if [ "${1:-}" = "--execution-context" ]; then
          MT=1
          shift
        fi

        if [ "$MT" = "1" ]; then
          exec "$CRYSTAL" spec -Dexecution_context "$@"
        fi
        exec "$CRYSTAL" spec "$@"
        SH
      end

      # Container entrypoint: prepare the schema, then exec the server (or
      # whatever command was passed). In the release image `saci` is not
      # installed, so prefer the prebuilt `bin/saci-migrate`.
      def self.bin_docker_entrypoint : String
        <<-SH
        #!/usr/bin/env bash
        set -euo pipefail
        cd "$(dirname "$0")/.."

        if [ "${SKIP_DB_PREPARE:-0}" != "1" ]; then
          if [ -x "./bin/saci-migrate" ]; then
            ./bin/saci-migrate up
          elif command -v saci >/dev/null 2>&1; then
            saci db:migrate
          else
            echo "warning: no migrator found; set SKIP_DB_PREPARE=1 if this is intentional." >&2
          fi
        fi

        if [ "$#" -eq 0 ]; then
          echo "usage: bin/docker-entrypoint COMMAND [ARGS...]" >&2
          exit 1
        fi
        exec "$@"
        SH
      end

      # Saci does not bundle an HTTP/2 proxy (Rails' Thruster). Do not pretend
      # otherwise: this script only documents the supported topology.
      def self.bin_thrust : String
        <<-SH
        #!/usr/bin/env bash
        set -euo pipefail

        cat <<'MSG'
        bin/thrust is a documentation placeholder, not a proxy.

        Saci serves HTTP directly (`saci serve`). For production, terminate
        TLS and compress/cache at a reverse proxy in front of it, for example:

          Caddy:   reverse_proxy 127.0.0.1:3000
          nginx:   proxy_pass http://127.0.0.1:3000;
          Thruster: run it separately and point it at 127.0.0.1:3000

        Keep the app bound to localhost (the default) when a proxy runs on the
        same host. In containers, bind HOST=0.0.0.0 and expose port 3000.
        MSG
        SH
      end

      # -- containers / CI ---------------------------------------------------

      def self.dockerfile(name : String) : String
        <<-DOCKER
        # Multi-stage build: compile with the official Crystal image, then
        # ship only the release binaries in a slim, non-root runtime.
        FROM crystallang/crystal:1.22.0 AS build
        WORKDIR /app

        # Dependencies first so source edits do not invalidate the cache.
        # NOTE: the generated shard.yml uses a local `path:` for saci. Make
        # that path available in the build context (or vendor/publish Saci)
        # before building the image.
        COPY shard.yml ./
        RUN shards install --production

        COPY . .
        RUN crystal build src/#{name}.cr --release --no-debug -o bin/#{name}
        RUN crystal build db/migrate.cr --release --no-debug -o bin/saci-migrate

        FROM debian:bookworm-slim AS runtime
        # Runtime libraries required by the release binary (verified with
        # `ldd`). crystal-pg/crystal-mysql speak the wire protocol in pure
        # Crystal, so no libpq/libmysqlclient is needed.
        RUN apt-get update \\
         && apt-get install -y --no-install-recommends \\
              ca-certificates curl libgcc-s1 libpcre2-8-0 libsqlite3-0 libssl3 \\
              libstdc++6 libyaml-0-2 libzstd1 tzdata zlib1g \\
         && rm -rf /var/lib/apt/lists/*

        RUN useradd --create-home --uid 1000 --shell /usr/sbin/nologin saci \\
         && mkdir -p /app/bin /app/config/locales /app/db /app/log /app/public \\
                     /app/storage /app/tmp/pids \\
         && chown -R saci:saci /app

        WORKDIR /app
        ENV APP_ENV=production \\
            HOST=0.0.0.0 \\
            PORT=3000

        COPY --from=build --chown=saci:saci /app/bin/#{name} /app/bin/#{name}
        COPY --from=build --chown=saci:saci /app/bin/saci-migrate /app/bin/saci-migrate
        COPY --from=build --chown=saci:saci /app/bin/docker-entrypoint /app/bin/docker-entrypoint
        COPY --from=build --chown=saci:saci /app/config/locales /app/config/locales
        COPY --from=build --chown=saci:saci /app/public /app/public

        USER saci
        EXPOSE 3000
        HEALTHCHECK --interval=30s --timeout=3s --start-period=10s \\
          CMD curl -fsS http://127.0.0.1:3000/up || exit 1

        ENTRYPOINT ["/app/bin/docker-entrypoint"]
        CMD ["/app/bin/#{name}"]
        DOCKER
      end

      def self.dockerignore : String
        <<-IGNORE
        .git
        .github
        .crystal
        .shards
        lib
        spec
        tmp
        log
        storage
        vendor
        db/*.db
        db/*.db-*
        config/master.key
        *.dwarf
        .DS_Store

        # Keep binstubs in the context (the entrypoint is copied into the
        # runtime image); ignore release binaries produced by local builds.
        bin/*
        !bin/docker-entrypoint
        !bin/saci
        !bin/setup
        !bin/dev
        !bin/ci
        !bin/thrust
        IGNORE
      end

      def self.ci_workflow : String
        <<-YAML
        name: CI

        on:
          push:
          pull_request:

        jobs:
          install:
            name: Install dependencies
            runs-on: ubuntu-latest
            steps:
              - uses: actions/checkout@v4
              - uses: crystal-lang/install-crystal@v1
                with:
                  crystal: 1.22.0
              - name: shards install
                # This app's shard.yml points at a local Saci checkout. Publish
                # Saci (or vendor it and rewrite the path) before enabling CI.
                run: shards install

          format:
            name: Format
            runs-on: ubuntu-latest
            steps:
              - uses: actions/checkout@v4
              - uses: crystal-lang/install-crystal@v1
                with:
                  crystal: 1.22.0
              - name: crystal tool format --check
                run: crystal tool format --check src spec db

          spec:
            name: Specs
            runs-on: ubuntu-latest
            steps:
              - uses: actions/checkout@v4
              - uses: crystal-lang/install-crystal@v1
                with:
                  crystal: 1.22.0
              - name: shards install
                run: shards install
              - name: crystal spec
                run: crystal spec
        YAML
      end

      # -- public/ -----------------------------------------------------------

      def self.public_error_page(code : Int32, title : String) : String
        <<-HTML
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>#{code} #{title}</title>
          <style>
            body { font-family: system-ui, sans-serif; margin: 4rem auto; max-width: 40rem; padding: 0 1rem; }
            h1 { font-size: 3rem; margin-bottom: 0.5rem; }
            p { color: #555; }
          </style>
        </head>
        <body>
          <h1>#{code}</h1>
          <p>#{title}. The application could not complete this request.</p>
          <p><a href="/">Return to the home page</a></p>
        </body>
        </html>
        HTML
      end

      def self.robots_txt : String
        <<-TXT
        User-agent: *
        Disallow:
        TXT
      end

      # -- initializers ------------------------------------------------------
      #
      # These are intentionally comment-only. Parallel framework work may add
      # CORS/assets/initializer APIs; a generated app must compile even when
      # those APIs are absent. Uncomment and adapt once the API is available.

      def self.initializer_filter_parameter_logging : String
        <<-CRYSTAL
        # Filter sensitive request parameters from logs.
        #
        # Saci filters password, password_confirmation, token and secret by
        # default (substring match, case-insensitive). Add app-specific keys
        # by uncommenting the line below:
        #
        #   Saci.filter_parameters = Saci.filter_parameters + ["ssn", "credit_card"]
        #
        # Keep this file comment-only unless the API above exists in your Saci
        # version; initializers are loaded by a require glob from the boot file.
        CRYSTAL
      end

      def self.initializer_cors : String
        <<-CRYSTAL
        # Cross-Origin Resource Sharing (CORS).
        #
        # Saci does not ship a CORS middleware in the core scaffold yet. If
        # your framework build provides `Saci::CORS`, configure it here:
        #
        #   Saci::CORS.allow_origins = ["https://example.com"]
        #   Saci::CORS.allow_methods = %w[GET POST PATCH DELETE OPTIONS]
        #   Saci::CORS.allow_headers = %w[Content-Type Authorization]
        #
        # Until then, set the headers from a custom HTTP::Handler or a
        # `before_action` in ApplicationController. This example stays
        # comment-only so a fresh app always compiles.
        CRYSTAL
      end

      def self.initializer_assets : String
        <<-CRYSTAL
        # Asset pipeline configuration.
        #
        # Saci has no digesting asset helper in the core scaffold yet. Static
        # files live in public/ and are served by the static middleware when
        # the framework build provides it; otherwise let your reverse proxy
        # serve public/. If an assets helper becomes available, configure it
        # here, for example:
        #
        #   Saci::Assets.manifest_path = "public/assets/.manifest.json"
        #   Saci::Assets.prefix = "/assets"
        #
        # Comment-only by design: generated apps must compile without the
        # optional assets API.
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
