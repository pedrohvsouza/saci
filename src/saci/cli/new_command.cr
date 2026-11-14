module Saci
  module CLI
    # `saci new blog` — generates a runnable app skeleton.
    module New
      # Absolute path of the framework source tree, baked in at compile time.
      # Used by the scaffold specs (and `--saci-path` users) to point an app
      # at a local checkout.
      SACI_ROOT = File.expand_path("../../../", __DIR__)

      # Where generated apps fetch Saci from (unless `--saci-path` is given).
      SACI_GITHUB = "pedrohvsouza/saci"

      # Build and runtime images for the generated Dockerfile. The runtime
      # must be the build image's distro (crystallang/crystal:1.22.0 is
      # Ubuntu 26.04): release binaries need the glibc they were linked
      # against, so an older base fails at start ("GLIBC_2.38 not found").
      CRYSTAL_IMAGE = "crystallang/crystal:1.22.0"
      RUNTIME_IMAGE = "ubuntu:26.04"

      # `~> X.Y.Z` for this framework version (pre-release suffix dropped).
      def self.saci_version_requirement : String
        "~> #{Saci::VERSION.split(/[-+]/).first}"
      end

      def self.run(args : Array(String)) : Int32
        name = args.find { |a| !a.starts_with?("-") } || raise Error.new("Usage: saci new APP_NAME [--db=sqlite|postgres|mysql] [--saci-path PATH] [--skip-shards] [--skip-git] [--devcontainer]")
        Util.check_app_name!(name)
        opts = parse_opts(args)
        create(name, saci_path: opts[:saci_path], skip_shards: opts[:skip_shards], skip_git: opts[:skip_git], db: opts[:db], devcontainer: opts[:devcontainer])
        0
      end

      def self.parse_opts(args : Array(String)) : NamedTuple(saci_path: String?, skip_shards: Bool, skip_git: Bool, db: String, devcontainer: Bool)
        saci_path = nil
        skip_shards = false
        skip_git = false
        db = "sqlite"
        devcontainer = false
        i = 0
        while i < args.size
          a = args[i]
          case a
          when "--skip-shards"  then skip_shards = true
          when "--skip-git"     then skip_git = true
          when "--devcontainer" then devcontainer = true
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
        {saci_path: saci_path, skip_shards: skip_shards, skip_git: skip_git, db: db, devcontainer: devcontainer}
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

      def self.create(name : String, dir : String = name, saci_path : String? = nil, skip_shards : Bool = false, skip_git : Bool = false, db : String = "sqlite", devcontainer : Bool = false) : Nil
        Util.check_app_name!(name)
        db = normalize_db(db)
        raise Error.new("Directory #{dir} already exists and is not empty.") if Dir.exists?(dir) && !Dir.empty?(dir)
        Dir.mkdir_p(dir)

        local_saci = !saci_path.nil?
        write(File.join(dir, "shard.yml"), shard_yml(name, saci_path, db))
        write(File.join(dir, ".gitignore"), gitignore)
        write(File.join(dir, ".tool-versions"), "crystal #{Crystal::VERSION}\n")
        write(File.join(dir, "README.md"), readme(name, devcontainer, local_saci))
        write(File.join(dir, "src", "#{name}.cr"), entrypoint(name, db))
        write(File.join(dir, "src", "controllers", "application_controller.cr"), application_controller)
        write(File.join(dir, "src", "controllers", "home_controller.cr"), home_controller)
        write(File.join(dir, "src", "controllers", "health_controller.cr"), health_controller)
        write(File.join(dir, "src", "channels", "application_channel.cr"), application_channel)
        write(File.join(dir, "src", "jobs", "application_job.cr"), application_job)
        write(File.join(dir, "src", "mailers", "application_mailer.cr"), application_mailer)
        write(File.join(dir, "src", "views", "layouts", "application.ecr"), layout_view)
        write(File.join(dir, "src", "views", "home", "index.ecr"), home_view)
        write(File.join(dir, "src", "models", "application_record.cr"), application_record)
        write(File.join(dir, "src", "assets", "application.css"), application_css)
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
        write(File.join(dir, "config", "initializers", "content_security_policy.cr"), initializer_content_security_policy)
        write(File.join(dir, "config", "initializers", "trusted_proxies.cr"), initializer_trusted_proxies)

        # Declarative per-environment YAML (G147/G148). Saci's env-var defaults
        # still work when these are deleted; the files document the supported
        # keys and are read with `Saci.config_for(:name)`.
        write(File.join(dir, "config", "database.yml"), database_yml(name, db))
        write(File.join(dir, "config", "cache.yml"), cache_yml(name))
        write(File.join(dir, "config", "queue.yml"), queue_yml)
        write(File.join(dir, "config", "cable.yml"), cable_yml(name))
        write(File.join(dir, "config", "recurring.yml"), recurring_yml)
        write(File.join(dir, "config", "storage.yml"), storage_yml)
        write(File.join(dir, "config", "server.yml"), server_yml)
        write(File.join(dir, "config", "server.cr"), server_cr)
        write(File.join(dir, "config", "ci.cr"), ci_config(name))
        write(File.join(dir, "config", "deploy.yml"), deploy_yml(name, db))
        write(File.join(dir, ".kamal", "secrets"), kamal_secrets(db))
        write(File.join(dir, "script", "doctor.cr"), doctor_script(name))
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
        write_executable(File.join(dir, "bin", "doctor"), bin_doctor)
        write_executable(File.join(dir, "bin", "kamal"), bin_kamal)
        write_executable(File.join(dir, "bin", "systemd"), bin_systemd(name))
        write(File.join(dir, "deploy", "#{name}.service"), systemd_unit(name))
        write(File.join(dir, "docs", "thruster.md"), thruster_doc(name))
        write(File.join(dir, "Dockerfile"), dockerfile(name, local_saci))
        write(File.join(dir, ".dockerignore"), dockerignore)
        write(File.join(dir, ".github", "workflows", "ci.yml"), ci_workflow(local_saci))

        if devcontainer
          write(File.join(dir, ".devcontainer", "devcontainer.json"), devcontainer_json(name))
          write(File.join(dir, ".devcontainer", "Dockerfile"), devcontainer_dockerfile)
        end

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
      # `shards install`. A flat list keeps every dependency key at the same
      # two-space level.
      #
      # Saci comes from GitHub at this framework's version, so the app builds
      # on any machine, in CI and in Docker. `--saci-path` (a local
      # checkout, for framework development) writes a `path:` dependency
      # instead.
      def self.shard_yml(name : String, saci_path : String? = nil, db : String = "sqlite") : String
        saci_dep = if path = saci_path
                     ["    path: #{path}"]
                   else
                     ["    github: #{SACI_GITHUB}", "    version: \"#{saci_version_requirement}\""]
                   end
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
        ] + saci_dep
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
        !/bin/doctor
        !/bin/kamal
        !/bin/systemd
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
        # Build output of `saci assets:precompile` (sources live in src/assets).
        /public/assets/
        /config/master.key
        # Keep Kamal secrets as env-var references, never literal values.
        .kamal/secrets.local
        .DS_Store
        IGNORE
      end

      def self.readme(name : String, devcontainer : Bool = false, local_saci : Bool = false) : String
        app = Util.class_name(name)
        container_note = if devcontainer
                           <<-MD

          ## Devcontainer

          This app was generated with `--devcontainer`. Open the folder in VS
          Code/Dev Containers (or GitHub Codespaces); `.devcontainer/` builds a
          Crystal 1.22 image with SQLite headers and runs `shards install` once.
          Forward port 3000 and use `bin/dev` inside the container.
          MD
                         else
                           ""
                         end
        <<-MD
        # #{app}

        Built with [Saci](https://github.com/#{SACI_GITHUB}) — a
        Rails-compatible web framework for Crystal.

        ## Quick start

        ```sh
        bin/setup          # shards install + db:migrate + db:seed
        bin/dev            # saci serve --watch on http://127.0.0.1:3000
        bin/doctor         # pre-flight deployment checks
        ```

        The health endpoint answers `GET /up` with `200 OK`; point container
        and load-balancer probes at it.

        ## Everyday commands

        | Command | What it does |
        | --- | --- |
        | `bin/saci ...` | Project-local wrapper around the global `saci` binary (args pass through, including `--`). |
        | `bin/setup` | Installs shards, runs migrations, then seeds. `SKIP_SEED=1 bin/setup` skips seeding. |
        | `bin/dev` | `saci serve --watch`; extra args go to `saci serve` (e.g. `bin/dev --port 4000`). |
        | `bin/ci` | Runs `config/ci.cr` through `saci ci` when available, else `crystal spec`. Set `SACI_EXECUTION_CONTEXT=1` (or pass `--execution-context`) to add `-Dexecution_context`. |
        | `bin/doctor` | Checks `SECRET_KEY_BASE`, the database URL and writable `storage/`, `log/`, `tmp/`. |
        | `bin/docker-entrypoint` | Prepares the database (`saci db:migrate` or the release `bin/saci-migrate`) and then execs its arguments. |
        | `bin/kamal` | Wrapper for Kamal 2 (`bin/kamal setup`, `bin/kamal deploy`); see `config/deploy.yml`. |
        | `bin/systemd` | Prints `deploy/#{name}.service`; `bin/systemd --install` copies it to `/etc/systemd/system`. |
        | `bin/thrust` | Documentation only: Saci has no bundled proxy. Put Caddy/nginx/Kamal's proxy (or a separately installed Thruster) in front of `saci serve`. |

        Direct framework commands still work:

        ```sh
        shards install
        saci generate model Post title:string
        saci db:migrate
        saci db:seed
        saci test
        saci serve
        ```

        ## Configuration files

        Saci keeps working with env vars and no YAML. The generated files are
        the declarative, per-`APP_ENV` surface (G147/G148):

        | File | Read with | Notes |
        | --- | --- | --- |
        | `config/database.yml` | `Saci.config_for(:database)` / `Saci::ConfigFile.database_url` | `development`/`test`/`staging`/`production`, pool, optional replicas/cache/queue/cable examples. |
        | `config/cache.yml` | `Saci.config_for(:cache)` | `memory` by default; Redis example in comments. |
        | `config/queue.yml` | `Saci.config_for(:queue)` | Maps to `Saci::Job.queue_adapter` (`:async`, `:test`, `:db`, ...). |
        | `config/cable.yml` | `Saci.config_for(:cable)` | In-process default; Redis example for multi-process. |
        | `config/recurring.yml` | `Saci.config_for(:recurring)` | Descriptive task list; register blocks with `Saci::Recurring`. |
        | `config/storage.yml` | `Saci.config_for(:storage)` | Local disk under `storage/`; S3 keys documented. |
        | `config/server.yml` | `Saci::Deploy::ServerConfig` | Host/port/threads/timeouts; `config/server.cr` applies `HOST`/`PORT` and `SACI_*` overrides at boot. |

        Example:

        ```crystal
        db = Saci.config_for(:database)
        db[:adapter].as_s                 # string and symbol keys both work
        Saci::ConfigFile.database_url     # URL assembled from the current section
        ```

        Files may use `<%= ENV["NAME"] %>` or
        `<%= ENV.fetch("NAME", "default") %>`; only those forms are
        interpolated (there is no runtime ERB). Delete any file and Saci falls
        back to its env-var defaults.

        ## Operations and deployment

        - **Graceful shutdown.** `src/#{name}.cr` calls
          `listen_gracefully`, which traps `SIGTERM`/`SIGINT`, stops accepting
          connections, waits for in-flight requests up to
          `SACI_SHUTDOWN_TIMEOUT` (default 10s), then runs shutdown hooks.
          Plain `Saci::Application#listen` keeps its original behaviour.
        - **Server model.** Crystal's stdlib HTTP server is single-process and
          has no Puma-style cluster/workers. `SACI_THREADS` maps to Crystal
          execution contexts and only takes effect when compiled with
          `-Dexecution_context` (`saci serve --mt`, `bin/dev --mt`). For more
          capacity run multiple processes behind a proxy or scale containers.
        - **Kamal 2.** `config/deploy.yml` uses the image built by the
          `Dockerfile`, exposes port 3000, and probes `/up`. `bin/kamal` is a
          thin wrapper; Kamal's proxy handles TLS/HTTP2 outside the app.
          Secrets belong in `.kamal/secrets` as env-var references (or your
          password manager's command), never literal values.
        - **systemd.** `deploy/#{name}.service` is a ready-to-edit unit;
          `bin/systemd` prints it and `bin/systemd --install` installs it.
          Keep `TimeoutStopSec` above the app's shutdown timeout.
        - **Docker restart policy.** For plain Docker, use
          `docker run --restart unless-stopped` so the process restarts after
          a crash; Kamal/systemd already restart failed units.
        - **Thruster.** Saci does not bundle a proxy. See
          `docs/thruster.md` for supported topologies and why `bin/thrust` is
          documentation, not an implementation.

        ## Layout

        - `src/<app>.cr` — boot file. There is deliberately **no `config.ru`**:
          Saci is not Rack-based. This file (and `bin/saci`) is the entrypoint.
        - `config/environments/*.cr` — per-environment settings, loaded by a
          require glob.
        - `config/server.cr` — server settings loaded explicitly by the boot
          file (it is not an initializer).
        - `config/initializers/*.cr` — app initializers, also loaded by glob
          (`require "../config/initializers/*"`).
          `content_security_policy.cr` spells out the Content-Security-Policy
          (the default blocks inline `<style>`/`<script>`, `style="..."` and
          external origins such as Google Fonts; development logs a warning
          for markup the policy blocks) and `trusted_proxies.cr` lists the
          proxies whose `X-Forwarded-For` is believed.
        - `config/locales/*.yml` — I18n dictionaries.
        - `config/*.yml` — declarative per-environment settings (see above).
        - `config/ci.cr` — local CI steps (`Saci::CI.step` / `Saci::CI.run`).
        - `src/assets/` — stylesheets, scripts and images. Reference them with
          `stylesheet_link_tag("application.css")`, `asset_path(...)` and
          friends. In development `/assets/*` is served straight from here
          (no caching, edits show on reload); `saci assets:precompile` (run by
          the Dockerfile) writes fingerprinted copies to `public/assets/`,
          which is build output and gitignored.
        - `public/` — static error pages (`404.html` also answers unknown
          routes for browsers) and `robots.txt`, served by Saci's static
          middleware. The `/up` route is dynamic and lives in
          `src/controllers/health_controller.cr`.
        - `spec/{controllers,models,mailers,integration,fixtures}/` — the
          Crystal equivalent of Rails' `test/` tree (`crystal spec` runs it).
        - `db/migrate/` + `db/migrations.cr` — migrations and their manifest.
        - `storage/`, `log/`, `tmp/pids/`, `vendor/`, `script/` — runtime and
          auxiliary directories. `.gitkeep` keeps empty ones in Git.
        - `bin/` — project binstubs (executable).
        - `deploy/`, `docs/`, `.kamal/` — systemd unit, deployment docs and
          Kamal secrets template.
        - `Dockerfile`, `.dockerignore`, `.github/workflows/ci.yml` — deployment
          and CI defaults. `.tool-versions` pins the Crystal version.
        #{container_note}
        ## Docker

        ```sh
        docker build -t #{name} .
        docker run --rm -p 3000:3000 --restart unless-stopped \\
          -e RAILS_MASTER_KEY="$(cat config/master.key)" \\
          -v #{name}_db:/app/db -v #{name}_storage:/app/storage \\
          #{name}
        ```

        The image is multi-stage (Crystal build stage + an Ubuntu runtime of
        the same release, so the binaries find the glibc they were linked
        against), runs as the non-root `saci` user, fingerprints
        `src/assets`, prepares the database in the entrypoint, and exposes
        port 3000. `RAILS_MASTER_KEY` decrypts `config/credentials.yml.enc`,
        which holds `secret_key_base`; a managed database also needs
        `DATABASE_URL`. Named volumes keep SQLite and uploads across
        restarts and are writable by the container user. `STOPSIGNAL SIGTERM`
        lets the app drain requests. `SKIP_DB_PREPARE=1` skips the migrate
        step. Commit `shard.lock`: the build installs exactly those versions.
        #{local_saci ? "This app's `shard.yml` points at a local Saci checkout (`--saci-path`), which the build context cannot reach; switch it to `github: #{SACI_GITHUB}` before building the image or running CI." : ""}

        ## Notes

        - There is no `Rakefile`: use the documented `saci` tasks
          (`saci db:migrate`, `saci db:seed`, `saci routes`, `saci test`, ...).
        - Production reads `secret_key_base` from `config/credentials.yml.enc`
          (decrypted with `config/master.key` or `RAILS_MASTER_KEY`), or from
          `SECRET_KEY_BASE`. Set other secrets with
          `saci credentials:set KEY VALUE` (`--stdin` keeps them out of shell
          history).
        - Run `bin/doctor` before the first deploy and after changing secrets,
          database URLs or volume mounts.
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
        # Server settings live in config/server.cr (not an initializer):
        # config/server.yml supplies defaults; HOST/PORT/SACI_* override them.
        require "../config/server"
        # Base classes first: globs load files alphabetically, and a subclass
        # such as admin_controller.cr must not load before its parent. `**`
        # also loads subdirectories (src/controllers/admin/ from
        # `saci generate admin`).
        require "./models/application_record"
        require "./controllers/application_controller"
        require "./channels/application_channel"
        require "./jobs/application_job"
        require "./mailers/application_mailer"
        require "./models/**"
        require "./controllers/**"
        require "./channels/**"
        require "./jobs/**"
        require "./mailers/**"

        env_name = ENV.fetch("APP_ENV", "development")
        FileUtils.mkdir_p("db")
        # config/database.yml (when present) assembles the URL per APP_ENV;
        # DATABASE_URL still wins, and the historic default is the fallback.
        db_url = ConfigFile.database_url(env_name) || ENV.fetch("DATABASE_URL", "#{url_default}")
        Record.connect(db_url)
        I18n.reload!

        server_config = Deploy::ServerConfig.current
        if server_config.threads > 1
          Saci.enable_multithreading!(server_config.threads)
        elsif ENV["SACI_MT"]? == "1"
          Saci.enable_multithreading!
        end

        router = Router.new.draw do |r|
          r.get "/up", HealthController, :show
          r.root HomeController, :index
        end

        Deploy.boot_summary(app: "#{name}", db_url: db_url, server: server_config)
        Application.new(router).listen_gracefully(server_config.port, server_config.host)
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

      # App-wide parents for jobs, mailers and channels (Rails' ApplicationJob
      # / ApplicationMailer / ApplicationCable::Channel). Generators subclass
      # these, so `Saci::` appears once per kind, as in ApplicationRecord.
      def self.application_job : String
        <<-CRYSTAL
        abstract class ApplicationJob < Saci::Job::Base
        end
        CRYSTAL
      end

      def self.application_mailer : String
        <<-CRYSTAL
        abstract class ApplicationMailer < Saci::Mailer::Base
        end
        CRYSTAL
      end

      def self.application_channel : String
        <<-CRYSTAL
        abstract class ApplicationChannel < Saci::Cable::Channel
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
          # public/assets is fingerprinted at image build, so the static file
          # server sends fingerprinted files with `immutable` caching and the
          # rest with `public, max-age=3600`. Tune with:
          # Saci.configure { |config| config.public_file_server.cache_control = "public, max-age=300" }
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
        require "../src/models/application_record"
        require "../src/models/**"
        require "./migrations"

        FileUtils.mkdir_p("db")
        env_name = ENV.fetch("APP_ENV", "development")
        db_url = Saci::ConfigFile.database_url(env_name) || ENV.fetch("DATABASE_URL", "#{url_default}")
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
        require "../src/models/application_record"
        require "../src/controllers/application_controller"
        require "../src/channels/application_channel"
        require "../src/jobs/application_job"
        require "../src/mailers/application_mailer"
        require "../src/models/**"
        require "../src/controllers/**"
        require "../src/channels/**"
        require "../src/jobs/**"
        require "../src/mailers/**"
        require "../db/migrations"

        # Isolated test database (never touch development data).
        # Multidb apps: establish named DBs here too and use
        # `Saci::Record.clean_all!` in specs to truncate all connections.
        FileUtils.mkdir_p("db")
        ENV["APP_ENV"] = "test"
        db_url = Saci::ConfigFile.database_url("test") || ENV.fetch("DATABASE_URL", "#{url_default}")
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
            Record.clean_database!
          end

          it "serves the home page as HTML" do
            router = Router.new.draw do |r|
              r.root HomeController, :index
            end
            TestSession.serve(router) do |app|
              resp = app.get("/")
              resp.status_code.should eq(200)
              resp.body.should contain("Welcome")
            end
          end

          it "answers the health check at /up" do
            router = Router.new.draw do |r|
              r.get "/up", HealthController, :show
            end
            TestSession.serve(router) do |app|
              resp = app.get("/up")
              resp.status_code.should eq(200)
              resp.body.should eq("OK")
            end
          end
        end
        CRYSTAL
      end

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

      # Mirrors `bin/ci` in Rails 8: `config/ci.cr` is the pipeline when the
      # global Saci binary is available; a plain `crystal spec` remains the
      # fallback so a fresh checkout still works without `saci` installed.
      # Opt into multithreaded specs with SACI_EXECUTION_CONTEXT=1 or
      # `bin/ci --execution-context`.
      def self.bin_ci : String
        <<-SH
        #!/usr/bin/env bash
        set -euo pipefail
        cd "$(dirname "$0")/.."

        CRYSTAL="${CRYSTAL_BIN:-crystal}"
        SACI="${SACI_BIN:-saci}"
        MT="${SACI_EXECUTION_CONTEXT:-0}"
        if [ "${1:-}" = "--execution-context" ]; then
          MT=1
          shift
        fi

        # config/ci.cr (Saci::CI DSL) takes precedence when `saci` is usable.
        if [ "$MT" != "1" ] && [ -f config/ci.cr ] && command -v "$SACI" >/dev/null 2>&1; then
          exec "$SACI" ci "$@"
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

      # Saci does not bundle an HTTP/2 proxy (Rails' Thruster) or Kamal's
      # proxy. Do not pretend otherwise: this script only documents the
      # supported topology and the generated deploy files.
      def self.bin_thrust : String
        <<-SH
        #!/usr/bin/env bash
        set -euo pipefail

        cat <<'MSG'
        bin/thrust is a documentation placeholder, not a proxy.

        Saci serves HTTP directly (`saci serve`). For production, terminate
        TLS and compress/cache at a reverse proxy in front of it:

          Kamal 2:  config/deploy.yml uses kamal-proxy (TLS + /up healthcheck)
          Caddy:    reverse_proxy 127.0.0.1:3000
          nginx:    proxy_pass http://127.0.0.1:3000;
          Thruster: install/run it separately and point it at 127.0.0.1:3000

        Thruster is a standalone Rails proxy, not a Saci component. The
        generated config/deploy.yml and docs/thruster.md show the supported
        topologies; no proxy is started by this script.

        Keep the app bound to localhost (the default) when a proxy runs on the
        same host. In containers, bind HOST=0.0.0.0 and expose port 3000.
        MSG
        SH
      end

      # Prebuilt in the Docker image (`bin/saci-doctor`); falls back to
      # `crystal run` for local checkouts and development.
      def self.bin_doctor : String
        <<-SH
        #!/usr/bin/env bash
        # Pre-flight deployment checks (secrets, database URL, writable dirs).
        set -euo pipefail
        cd "$(dirname "$0")/.."

        if [ -x ./bin/saci-doctor ]; then
          exec ./bin/saci-doctor "$@"
        fi
        exec "${CRYSTAL_BIN:-crystal}" run script/doctor.cr -- "$@"
        SH
      end

      # Kamal 2 is an external CLI (Ruby gem or container). Do not vendor or
      # reimplement it here; this wrapper only runs it from the app root so
      # config/deploy.yml and .kamal/secrets are picked up.
      def self.bin_kamal : String
        <<-SH
        #!/usr/bin/env bash
        # Kamal 2 wrapper. Install Kamal separately (`gem install kamal`).
        set -euo pipefail
        cd "$(dirname "$0")/.."
        exec "${KAMAL_BIN:-kamal}" "$@"
        SH
      end

      def self.bin_systemd(name : String) : String
        <<-SH
        #!/usr/bin/env bash
        # Print the generated systemd unit, or install it on this host.
        set -euo pipefail
        cd "$(dirname "$0")/.."

        service="#{name}"
        unit="deploy/${service}.service"
        case "${1:-}" in
          --install)
            sudo cp "$unit" "/etc/systemd/system/${service}.service"
            sudo systemctl daemon-reload
            sudo systemctl enable --now "$service"
            ;;
          *)
            cat "$unit"
            ;;
        esac
        SH
      end

      # `database.yml` follows Rails' shape but uses Saci adapter names
      # (`sqlite3`, `postgres`, `mysql`). The `default:` anchor keeps the four
      # env sections small; `Saci::ConfigFile` interpolates `<%= ENV[...] %>`
      # before YAML parsing.
      def self.database_yml(name : String, db : String = "sqlite") : String
        ndb = normalize_db(db)
        adapter = case ndb
                  when "postgres" then "postgres"
                  when "mysql"    then "mysql"
                  else                 "sqlite3"
                  end
        lines = [
          "# config/database.yml — per-environment database settings (G147).",
          "#",
          "# Saci connects from DATABASE_URL at boot. This file is the declarative",
          "# surface for apps that prefer YAML:",
          "#",
          "#   db = Saci.config_for(:database)      # current APP_ENV section",
          "#   db[:adapter]                         # string and symbol keys work",
          "#   Saci::ConfigFile.database_url        # URL assembled from this file",
          "#",
          "# Only <%= ENV[\"NAME\"] %> and <%= ENV.fetch(\"NAME\", \"default\") %> are",
          "# interpolated; there is no runtime ERB. Deleting this file is safe —",
          "# the boot file falls back to DATABASE_URL and its built-in default.",
          "default: &default",
          "  adapter: #{adapter}",
          "  pool: <%= ENV.fetch(\"DB_POOL\", \"5\") %>",
          "  timeout: 5000",
        ]
        case ndb
        when "postgres"
          lines << "  host: <%= ENV.fetch(\"DB_HOST\", \"localhost\") %>"
          lines << "  port: <%= ENV.fetch(\"DB_PORT\", \"5432\") %>"
          lines << "  username: <%= ENV.fetch(\"DB_USERNAME\", \"postgres\") %>"
          lines << "  password: <%= ENV[\"DB_PASSWORD\"] %>"
        when "mysql"
          lines << "  host: <%= ENV.fetch(\"DB_HOST\", \"localhost\") %>"
          lines << "  port: <%= ENV.fetch(\"DB_PORT\", \"3306\") %>"
          lines << "  username: <%= ENV.fetch(\"DB_USERNAME\", \"root\") %>"
          lines << "  password: <%= ENV[\"DB_PASSWORD\"] %>"
        end

        {"development", "test", "staging", "production"}.each do |env|
          lines << ""
          lines << "#{env}:"
          lines << "  <<: *default"
          lines << "  url: <%= ENV[\"DATABASE_URL\"] %>"
          lines << "  database: #{database_name(name, ndb, env)}"
        end

        lines << ""
        lines << "# Optional named databases / read replicas. Register them with"
        lines << "# `Saci::Record.establish_connection(name, url)`; Saci does not"
        lines << "# connect to these sections automatically."
        lines << "  # Add read replicas here and register each with establish_connection:"
        lines << "  replicas: []"
        lines << "  cache:"
        lines << "    <<: *default"
        lines << "    database: #{database_name(name, ndb, "production_cache")}"
        lines << "  queue:"
        lines << "    <<: *default"
        lines << "    database: #{database_name(name, ndb, "production_queue")}"
        lines << "  cable:"
        lines << "    <<: *default"
        lines << "    database: #{database_name(name, ndb, "production_cable")}"
        lines.join('\n')
      end

      def self.database_name(name : String, db : String, env : String) : String
        case normalize_db(db)
        when "postgres", "mysql" then "#{name}_#{env}"
        else                          "./db/#{name}_#{env}.db"
        end
      end

      def self.cache_yml(name : String) : String
        <<-YAML
        # config/cache.yml — cache store per environment (G148).
        #
        # Defaults to Saci's in-process MemoryStore. Read it with:
        #   Saci.config_for(:cache)["store"].as_s
        # For multi-process deployments, point every process at one Redis
        # (vendor-free RESP2 client) and uncomment:
        #   store: redis
        #   url: <%= ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379") %>
        development:
          store: memory
          namespace: #{name}_development

        test:
          store: memory
          namespace: #{name}_test

        staging:
          store: memory
          namespace: #{name}_staging
          # store: redis
          # url: <%= ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379") %>

        production:
          store: memory
          namespace: #{name}_production
          # store: redis
          # url: <%= ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379") %>
        YAML
      end

      def self.queue_yml : String
        <<-YAML
        # config/queue.yml — job queue adapter per environment (G148).
        #
        # Values map to `Saci::Job.queue_adapter`: inline, async, test, db.
        # `db` stores jobs in the database (see Saci::JobDB) and needs its
        # schema migrated; `async` is the in-process default and is lost on
        # restart. Read it with `Saci.config_for(:queue)["adapter"].as_s`.
        development:
          adapter: async
          concurrency: 2

        test:
          adapter: test

        staging:
          adapter: async
          concurrency: 4
          # adapter: db
          # poll_interval: 1

        production:
          adapter: async
          concurrency: 4
          # adapter: db
          # poll_interval: 1
        YAML
      end

      def self.cable_yml(name : String) : String
        <<-YAML
        # config/cable.yml — Action Cable pub/sub per environment (G148).
        #
        # The default server is in-process (single replica only). For multiple
        # replicas use the vendored Redis server:
        #   Saci::Cable.server = Saci::Cable::RedisServer.new(
        #     ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379"))
        # Read this section with `Saci.config_for(:cable)["adapter"].as_s`.
        development:
          adapter: memory
          namespace: #{name}_development

        test:
          adapter: memory
          namespace: #{name}_test

        staging:
          adapter: memory
          namespace: #{name}_staging
          # adapter: redis
          # url: <%= ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379") %>

        production:
          adapter: memory
          namespace: #{name}_production
          # adapter: redis
          # url: <%= ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379") %>
        YAML
      end

      def self.recurring_yml : String
        <<-YAML
        # config/recurring.yml — recurring tasks per environment (G148).
        #
        # This file is descriptive: register the matching block in code with
        # `Saci::Recurring.cron("0 3 * * *", "cleanup") { ... }`.
        # Read it with `Saci.config_for(:recurring)["tasks"]`.
        development:
          enabled: false
          tasks: []

        test:
          enabled: false
          tasks: []

        staging:
          enabled: false
          tasks: []
          # tasks:
          #   - name: sample_cleanup
          #     schedule: "0 3 * * *"
          #     class: CleanupJob

        production:
          enabled: false
          tasks: []
          # tasks:
          #   - name: sample_cleanup
          #     schedule: "0 3 * * *"
          #     class: CleanupJob
        YAML
      end

      def self.storage_yml : String
        <<-YAML
        # config/storage.yml — Active Storage-style service per environment
        # (G148). Defaults to local disk under storage/. Read it with
        # `Saci.config_for(:storage)["service"].as_s`.
        #
        # Cloud example (register the service before uploading):
        #   Saci::Storage.register_service("s3", Saci::Storage::S3Service.new(
        #     bucket: ENV.fetch("S3_BUCKET"), region: ENV.fetch("S3_REGION", "us-east-1")))
        development:
          service: local
          root: storage

        test:
          service: local
          root: storage

        staging:
          service: local
          root: storage
          # service: s3
          # bucket: <%= ENV["S3_BUCKET"] %>
          # region: <%= ENV.fetch("S3_REGION", "us-east-1") %>

        production:
          service: local
          root: storage
          # service: s3
          # bucket: <%= ENV["S3_BUCKET"] %>
          # region: <%= ENV.fetch("S3_REGION", "us-east-1") %>
        YAML
      end

      def self.server_yml : String
        <<-YAML
        # config/server.yml — HTTP server settings per environment (G138).
        #
        # Loaded by config/server.cr through Saci::Deploy::ServerConfig.
        # Durations are seconds (or "250ms"/"5s"/"2m" strings).
        #
        # Crystal's stdlib HTTP server has no Puma-style cluster/workers:
        # `threads` only takes effect when compiled with -Dexecution_context
        # (`saci serve --mt`). Run multiple processes for more capacity.
        development:
          host: 127.0.0.1
          port: 3000
          threads: 1
          reuse_port: false
          keep_alive_timeout: 5
          request_timeout: 30
          shutdown_timeout: 10

        test:
          host: 127.0.0.1
          port: 3000
          threads: 1
          reuse_port: false
          keep_alive_timeout: 5
          request_timeout: 30
          shutdown_timeout: 5

        staging:
          host: 0.0.0.0
          port: 3000
          threads: 2
          reuse_port: false
          keep_alive_timeout: 5
          request_timeout: 30
          shutdown_timeout: 15

        production:
          host: 0.0.0.0
          port: 3000
          threads: 4
          reuse_port: true
          keep_alive_timeout: 5
          request_timeout: 30
          shutdown_timeout: 15
        YAML
      end

      def self.server_cr : String
        <<-CRYSTAL
        # config/server.cr — HTTP server settings (G138). Required explicitly by
        # src/<app>.cr (this is not an initializer).
        #
        # There is no Puma cluster mode: Crystal's stdlib server is one process.
        # `threads` maps to execution contexts and only works in a binary built
        # with -Dexecution_context (`saci serve --mt`). Use systemd/Kamal/Docker
        # replicas behind a proxy when one process is not enough.
        #
        # Precedence: defaults < config/server.yml[APP_ENV] < these ENV vars.
        Saci::Deploy::ServerConfig.reload!("config/server.yml")

        Saci::Deploy::ServerConfig.configure do |server|
          server.host = ENV["HOST"] if ENV["HOST"]?
          server.port = ENV["PORT"].to_i if ENV["PORT"]?
          server.threads = ENV["SACI_THREADS"].to_i if ENV["SACI_THREADS"]?
          server.reuse_port = ENV["SACI_REUSE_PORT"] == "1" if ENV["SACI_REUSE_PORT"]?
          if value = ENV["SACI_KEEP_ALIVE_TIMEOUT"]?
            server.keep_alive_timeout = value.to_i.seconds
          end
          if value = ENV["SACI_REQUEST_TIMEOUT"]?
            server.request_timeout = value.to_i.seconds
          end
          if value = ENV["SACI_SHUTDOWN_TIMEOUT"]?
            server.shutdown_timeout = value.to_i.seconds
          end
          server.pid_file = ENV["SACI_PIDFILE"]? if ENV["SACI_PIDFILE"]?
        end
        CRYSTAL
      end

      def self.ci_config(name : String) : String
        <<-CRYSTAL
        # config/ci.cr — local CI pipeline (G121/G178), run with `bin/ci` or
        # `saci ci`. `Saci::CI.step` runs compiled Crystal in-process;
        # `Saci::CI.run` shells out and fails on a non-zero exit status.
        Saci::CI.step "Format" do
          status = Process.run("crystal", args: ["tool", "format", "--check", "src", "spec", "config", "db", "script"])
          Saci::CI.fail!("crystal tool format reported changes") unless status.success?
        end

        Saci::CI.run "Specs", "crystal spec --no-color"
        Saci::CI.run "Build", "crystal build src/#{name}.cr -o tmp/ci-build"
        CRYSTAL
      end

      def self.deploy_yml(name : String, db : String = "sqlite") : String
        ndb = normalize_db(db)
        lines = [
          "# config/deploy.yml — Kamal 2 deployment (G165).",
          "#",
          "# Kamal builds the image from ./Dockerfile and runs kamal-proxy in",
          "# front of the app (TLS/HTTP2, /up healthcheck). Saci does not bundle",
          "# a proxy; Kamal owns that layer. Install Kamal separately and run",
          "# `bin/kamal setup` once, then `bin/kamal deploy`.",
          "service: #{name}",
          "image: your-registry-user/#{name}",
          "",
          "servers:",
          "  web:",
          "    - 192.168.0.1",
          "",
          "# Named volumes keep data across deploys. Docker seeds them from the",
          "# image, so they belong to the container's non-root user (uid 1000);",
          "# a host bind mount (/var/lib/...:/app/db) is created root-owned and",
          "# the app cannot write to it. `volumes` sits at the top level (Kamal",
          "# rejects it under servers/web).",
          "volumes:",
          "  - #{name}_storage:/app/storage",
        ] + (ndb == "sqlite" ? ["  - #{name}_db:/app/db"] : [] of String) + [
          "",
          "proxy:",
          "  ssl: true",
          "  host: example.com",
          "  app_port: 3000",
          "  # Behind another proxy or CDN (e.g. Cloudflare), kamal-proxy with",
          "  # ssl: true replaces X-Forwarded-For with that proxy's address and the",
          "  # app loses the visitor's IP. Forward the header and list the CDN's",
          "  # ranges in config/initializers/trusted_proxies.cr:",
          "  # forward_headers: true",
          "  healthcheck:",
          "    path: /up",
          "    interval: 10",
          "    timeout: 5",
          "",
          "registry:",
          "  server: ghcr.io",
          "  username: your-registry-user",
          "  password:",
          "    - KAMAL_REGISTRY_PASSWORD",
          "",
          "builder:",
          "  arch: amd64",
          "",
          "env:",
          "  clear:",
          "    APP_ENV: production",
          "    HOST: 0.0.0.0",
          "    PORT: \"3000\"",
          "    SACI_THREADS: \"4\"",
          "    SACI_KEEP_ALIVE_TIMEOUT: \"5\"",
          "    SACI_SHUTDOWN_TIMEOUT: \"15\"",
          "  secret:",
          "    # Decrypts config/credentials.yml.enc (secret_key_base + app secrets).",
          "    - RAILS_MASTER_KEY",
        ] + (ndb == "sqlite" ? [] of String : ["    - DATABASE_URL"]) + [
          "",
          "ssh:",
          "  user: deploy",
          "",
          "# Kamal-side drain must exceed SACI_SHUTDOWN_TIMEOUT so SIGTERM can",
          "# finish in-flight requests before the container is killed.",
          "deploy_timeout: 30",
          "drain_timeout: 30",
        ]

        case ndb
        when "postgres"
          lines.concat([
            "",
            "accessories:",
            "  db:",
            "    image: postgres:16",
            "    host: 192.168.0.1",
            "    port: \"127.0.0.1:5432:5432\"",
            "    env:",
            "      clear:",
            "        POSTGRES_DB: #{name}_production",
            "        POSTGRES_USER: #{name}",
            "      secret:",
            "        - POSTGRES_PASSWORD",
            "    directories:",
            "      - data:/var/lib/postgresql/data",
            "  # redis:",
            "  #   image: redis:7",
            "  #   host: 192.168.0.1",
            "  #   port: \"127.0.0.1:6379:6379\"",
            "  #   directories:",
            "  #     - data:/data",
          ])
        when "mysql"
          lines.concat([
            "",
            "accessories:",
            "  db:",
            "    image: mysql:8.4",
            "    host: 192.168.0.1",
            "    port: \"127.0.0.1:3306:3306\"",
            "    env:",
            "      clear:",
            "        MYSQL_DATABASE: #{name}_production",
            "      secret:",
            "        - MYSQL_ROOT_PASSWORD",
            "    directories:",
            "      - data:/var/lib/mysql",
            "  # redis:",
            "  #   image: redis:7",
            "  #   host: 192.168.0.1",
            "  #   port: \"127.0.0.1:6379:6379\"",
            "  #   directories:",
            "  #     - data:/data",
          ])
        else
          lines.concat([
            "",
            "# No database accessory: SQLite lives in the #{name}_db volume above.",
            "# For a managed database, set DATABASE_URL in .kamal/secrets.",
            "# Optional accessories (Redis example):",
            "accessories: {}",
            "# accessories:",
            "#   redis:",
            "#     image: redis:7",
            "#     host: 192.168.0.1",
            "#     port: \"127.0.0.1:6379:6379\"",
            "#     directories:",
            "#       - data:/data",
          ])
        end
        lines.join('\n')
      end

      def self.kamal_secrets(db : String = "sqlite") : String
        lines = [
          "# .kamal/secrets — read by Kamal 2 at deploy time (shell syntax).",
          "# Keep only references here, never literal credentials. Export the",
          "# variables in your shell/password manager before `bin/kamal deploy`.",
          "KAMAL_REGISTRY_PASSWORD=$KAMAL_REGISTRY_PASSWORD",
          "",
          "# Required by config/deploy.yml env.secret. The master key decrypts",
          "# config/credentials.yml.enc, which holds secret_key_base, so no",
          "# separate SECRET_KEY_BASE is needed.",
          "RAILS_MASTER_KEY=$(cat config/master.key)",
        ]
        ndb = normalize_db(db)
        lines << "DATABASE_URL=$DATABASE_URL" unless ndb == "sqlite"
        case ndb
        when "postgres"
          lines << ""
          lines << "# Used by the generated db accessory:"
          lines << "POSTGRES_PASSWORD=$POSTGRES_PASSWORD"
        when "mysql"
          lines << ""
          lines << "# Used by the generated db accessory:"
          lines << "MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD"
        end
        lines.join('\n')
      end

      def self.doctor_script(name : String) : String
        <<-CRYSTAL
        # script/doctor.cr — pre-flight deployment checks (G141/G142/G144).
        # Run with `bin/doctor` (the Docker image prebuilds bin/saci-doctor).
        require "saci"
        require "../config/environments/*"

        env_name = ENV.fetch("APP_ENV", "development")
        db_url = Saci::ConfigFile.database_url(env_name) || ENV["DATABASE_URL"]?
        exit(Saci::Deploy.doctor(db_url: db_url))
        CRYSTAL
      end

      def self.systemd_unit(name : String) : String
        <<-UNIT
        [Unit]
        Description=#{name} (Saci)
        After=network-online.target
        Wants=network-online.target

        [Service]
        Type=simple
        # Create a dedicated user/group (`useradd --system --home /srv/#{name} saci`).
        User=saci
        Group=saci
        WorkingDirectory=/srv/#{name}
        Environment=APP_ENV=production
        Environment=HOST=127.0.0.1
        Environment=PORT=3000
        # Keep secrets out of this unit: mode 0600 EnvironmentFile.
        EnvironmentFile=-/etc/saci/#{name}.env
        ExecStart=/srv/#{name}/bin/#{name}
        KillSignal=SIGTERM
        # Must be greater than SACI_SHUTDOWN_TIMEOUT in config/server.yml.
        TimeoutStopSec=30
        Restart=on-failure
        RestartSec=5
        NoNewPrivileges=true
        PrivateTmp=true
        ProtectSystem=full
        ReadWritePaths=/srv/#{name}/storage /srv/#{name}/log /srv/#{name}/tmp

        [Install]
        WantedBy=multi-user.target
        UNIT
      end

      def self.thruster_doc(name : String) : String
        <<-MD
        # Thruster and reverse proxies

        Saci does **not** bundle Thruster (or any proxy). `bin/thrust` is a
        documentation placeholder, not a server. The generated app speaks
        plain HTTP/1.1 via Crystal's stdlib server; TLS, HTTP/2, compression
        and asset caching belong in a proxy in front of it.

        ## Supported topologies

        ### Kamal 2 (recommended for containers)

        `config/deploy.yml` runs kamal-proxy beside the `#{name}` container.
        It terminates TLS, exposes port 3000, and healthchecks `GET /up`:

        ```sh
        bin/kamal setup     # first deploy
        bin/kamal deploy    # subsequent deploys
        ```

        The app receives `SIGTERM`, drains for
        `SACI_SHUTDOWN_TIMEOUT` (15s in the generated deploy config), and
        Kamal waits `drain_timeout: 30` before killing it.

        ### systemd + Caddy/nginx

        `deploy/#{name}.service` runs the app on `127.0.0.1:3000`. Put Caddy
        or nginx on the same host and proxy to that address. Keep the app on
        loopback; the proxy owns public ports 80/443.

        ### Thruster as an external binary

        Thruster is the Rails 8 proxy (HTTP/2, compression, X-Sendfile). It is
        not a Saci dependency, but you may install it separately and point it
        at `127.0.0.1:3000`:

        ```sh
        thrust bin/#{name} --port 3000
        ```

        Verify `/up` through the proxy before switching traffic. Do not claim
        Thruster-specific features (X-Sendfile, asset caching) unless the
        external proxy actually provides them.

        ## Health and shutdown contract

        - `GET /up` returns `200 OK` without touching the database.
        - The Dockerfile declares `HEALTHCHECK` against `/up` and
          `STOPSIGNAL SIGTERM`.
        - Plain `docker run` should use `--restart unless-stopped`; Kamal and
          systemd already restart failed processes.

        ## Caveats

        - Crystal's stdlib server is single-process: there is no Puma cluster
          mode. Scale with containers/processes behind the proxy.
        - `SACI_THREADS` needs a binary compiled with `-Dexecution_context`
          (`saci serve --mt`); otherwise it is intentionally a no-op.
        MD
      end

      def self.devcontainer_json(name : String) : String
        <<-JSON
        {
          "name": "#{name}",
          "build": {
            "dockerfile": "Dockerfile",
            "context": ".."
          },
          "workspaceFolder": "/workspace",
          "postCreateCommand": "shards install",
          "forwardPorts": [3000],
          "remoteEnv": {
            "APP_ENV": "development"
          },
          "customizations": {
            "vscode": {
              "extensions": ["crystal-lang.crystal-lang"]
            }
          }
        }
        JSON
      end

      def self.devcontainer_dockerfile : String
        <<-DOCKER
        # Devcontainer image: Crystal + native headers used by the common
        # drivers. The app itself is bind-mounted at /workspace.
        FROM crystallang/crystal:1.22.0
        RUN apt-get update \\
         && apt-get install -y --no-install-recommends \\
              ca-certificates curl git libsqlite3-dev libssl-dev libyaml-dev \\
              pkg-config postgresql-client default-mysql-client \\
         && rm -rf /var/lib/apt/lists/*
        RUN useradd --create-home --uid 1000 --shell /bin/bash vscode \\
         && mkdir -p /workspace \\
         && chown vscode:vscode /workspace
        WORKDIR /workspace
        USER vscode
        DOCKER
      end

      def self.dockerfile(name : String, local_saci : Bool = false) : String
        saci_note = if local_saci
                      "# NOTE: shard.yml points at a local Saci checkout (--saci-path), which\n" \
                      "# is outside the build context. Switch it to `github: #{SACI_GITHUB}`\n" \
                      "# (or vendor Saci into the app) before building the image.\n"
                    else
                      "# Saci comes from GitHub at the version pinned in shard.lock.\n"
                    end
        <<-DOCKER
        # Multi-stage build: compile with the official Crystal image, then
        # ship only the release binaries in a slim, non-root runtime.
        FROM #{CRYSTAL_IMAGE} AS build
        WORKDIR /app

        # crystal-sqlite3 links against libsqlite3, which the Crystal image lacks.
        RUN apt-get update \\
         && apt-get install -y --no-install-recommends libsqlite3-dev \\
         && rm -rf /var/lib/apt/lists/*

        # Dependencies first so source edits do not invalidate the cache.
        # `--production` installs exactly what shard.lock pins: commit it.
        #{saci_note.chomp}
        COPY shard.yml shard.lock ./
        RUN shards install --production

        COPY . .
        # -Dexecution_context makes SACI_THREADS/config/server.yml `threads`
        # effective; without it Crystal stays single-threaded (a no-op).
        RUN crystal build src/#{name}.cr --release --no-debug -Dexecution_context -o bin/#{name}
        RUN crystal build db/migrate.cr --release --no-debug -o bin/saci-migrate
        RUN crystal build script/doctor.cr --release --no-debug -o bin/saci-doctor
        # Fingerprint src/assets into public/assets (`saci assets:precompile`):
        # every deploy gets new asset URLs, served with `immutable` caching.
        RUN if [ -d src/assets ]; then crystal eval 'require "saci/assets"; Saci::Assets.precompile'; fi

        # Same distro as #{CRYSTAL_IMAGE} (#{RUNTIME_IMAGE.sub(":", " ")}): the binaries need
        # the glibc they were linked against, so an older base cannot start them.
        FROM #{RUNTIME_IMAGE} AS runtime
        # Runtime libraries required by the release binaries (verified with
        # `ldd`). crystal-pg/crystal-mysql speak the wire protocol in pure
        # Crystal, so no libpq/libmysqlclient is needed.
        RUN apt-get update \\
         && apt-get install -y --no-install-recommends \\
              ca-certificates curl libgcc-s1 libgmp10 libpcre2-8-0 libsqlite3-0 libssl3t64 \\
              libstdc++6 libyaml-0-2 libzstd1 tzdata zlib1g \\
         && rm -rf /var/lib/apt/lists/*

        # Ubuntu images ship a default "ubuntu" user on uid 1000.
        RUN (userdel --remove ubuntu 2>/dev/null || true) \\
         && useradd --create-home --uid 1000 --shell /usr/sbin/nologin saci \\
         && mkdir -p /app/bin /app/config/locales /app/db /app/log /app/public \\
                     /app/storage /app/tmp/pids \\
         && chown -R saci:saci /app

        WORKDIR /app
        ENV APP_ENV=production \\
            HOST=0.0.0.0 \\
            PORT=3000

        COPY --from=build --chown=saci:saci /app/bin/#{name} /app/bin/#{name}
        COPY --from=build --chown=saci:saci /app/bin/saci-migrate /app/bin/saci-migrate
        COPY --from=build --chown=saci:saci /app/bin/saci-doctor /app/bin/saci-doctor
        COPY --from=build --chown=saci:saci /app/bin/docker-entrypoint /app/bin/docker-entrypoint
        COPY --from=build --chown=saci:saci /app/config/locales /app/config/locales
        COPY --from=build --chown=saci:saci /app/config/database.yml /app/config/database.yml
        COPY --from=build --chown=saci:saci /app/config/cache.yml /app/config/cache.yml
        COPY --from=build --chown=saci:saci /app/config/queue.yml /app/config/queue.yml
        COPY --from=build --chown=saci:saci /app/config/cable.yml /app/config/cable.yml
        COPY --from=build --chown=saci:saci /app/config/recurring.yml /app/config/recurring.yml
        COPY --from=build --chown=saci:saci /app/config/storage.yml /app/config/storage.yml
        COPY --from=build --chown=saci:saci /app/config/server.yml /app/config/server.yml
        # Encrypted (secret_key_base + app secrets); readable only with
        # RAILS_MASTER_KEY, passed at run time (a Kamal secret).
        COPY --from=build --chown=saci:saci /app/config/credentials.yml.enc /app/config/credentials.yml.enc
        COPY --from=build --chown=saci:saci /app/public /app/public

        USER saci
        EXPOSE 3000
        # SIGTERM triggers Saci::Deploy::GracefulShutdown (drain + hooks).
        STOPSIGNAL SIGTERM
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
        .devcontainer
        .kamal
        deploy
        docs
        lib
        spec
        tmp
        log
        storage
        vendor
        db/*.db
        db/*.db-*
        public/assets
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

      def self.ci_workflow(local_saci : Bool = false) : String
        # Indented for its place under `steps:` (interpolated lines keep their
        # own leading spaces; heredoc dedent only touches the literal ones).
        install_run = String.build do |io|
          if local_saci
            io << "        # shard.yml points at a local Saci checkout (--saci-path): switch it\n"
            io << "        # to `github: #{SACI_GITHUB}` before enabling CI.\n"
          end
          io << "        run: shards install"
        end
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
        #{install_run}

          format:
            name: Format
            runs-on: ubuntu-latest
            steps:
              - uses: actions/checkout@v4
              - uses: crystal-lang/install-crystal@v1
                with:
                  crystal: 1.22.0
              - name: crystal tool format --check
                run: crystal tool format --check src spec db config script

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

      # Initializers. `filter_parameter_logging.cr`, `cors.cr` and
      # `assets.cr` are comment-only examples; `content_security_policy.cr`
      # and `trusted_proxies.cr` hold active (default) settings.

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
        # Asset pipeline.
        #
        # Sources live in src/assets/. Views reference them by logical name:
        #
        #   <%= stylesheet_link_tag("application.css") %>
        #   <%= image_tag("logo.svg", alt: "Logo") %>
        #
        # Development serves /assets/* straight from src/assets/ with
        # `Cache-Control: no-cache`, so edits show on reload. For production,
        # `saci assets:precompile` (run by the Dockerfile) copies them into
        # public/assets/ under fingerprinted names (application-<sha256>.css)
        # plus a manifest, and the helpers above switch to those names, which
        # are cached as immutable. `saci assets:clobber` removes that output.
        #
        # Optional settings:
        #
        #   Saci.configure do |config|
        #     config.assets.source = "src/assets"   # development source
        #     config.assets.enabled = true          # also outside development/test
        #   end
        CRYSTAL
      end

      def self.initializer_content_security_policy : String
        <<-CRYSTAL
        # Content-Security-Policy sent with every controller response.
        #
        # This is Saci's default, written out so it is visible. It only allows
        # files from this app: inline <style> and <script> tags, style="..."
        # attributes and other origins (Google Fonts, CDNs, analytics) are all
        # blocked by the browser, and the page renders without them. In
        # development Saci logs a warning when a page contains markup the
        # policy blocks.
        #
        # Prefer stylesheets and scripts under src/assets. When you need more:
        #
        # * an external origin: add it to the matching directive, e.g. Google
        #   Fonts needs "style-src 'self' https://fonts.googleapis.com" and
        #   "font-src 'self' https://fonts.gstatic.com";
        # * an inline <style>/<script>: add 'nonce' to style-src/script-src
        #   (Saci replaces it with a per-request nonce) and render the tag as
        #   <style nonce="<%= csp_nonce %>">. A nonce changes on every request,
        #   so avoid it on pages served with ETag/stale? caching: a 304 brings
        #   a new nonce that no longer matches the cached body.
        #   style="..." attributes cannot use nonces (only 'unsafe-inline' in
        #   style-src-attr allows them); move them into a stylesheet;
        # * per controller: `csp "..."` or `skip_csp` (see Saci::SecureHeaders).
        Saci::SecureHeaders.configure do |headers|
          headers["Content-Security-Policy"] = [
            "default-src 'self'",
            # "style-src 'self' https://fonts.googleapis.com",
            # "font-src 'self' https://fonts.gstatic.com",
            # "script-src 'self' 'nonce'",
            # "img-src 'self' data:",
          ].join("; ")
        end
        CRYSTAL
      end

      def self.initializer_trusted_proxies : String
        <<-CRYSTAL
        # Proxies whose X-Forwarded-For Saci believes
        # (Saci::Middleware::RemoteIp). Behind kamal-proxy, nginx or another
        # reverse proxy the app's peer is the proxy, so without this every
        # request appears to come from the proxy's address, and
        # Saci::Throttle / `rate_limit` put all visitors in one bucket. A
        # forwarded address is only taken from these peers; anyone else's
        # header is ignored.
        #
        # Behind a CDN such as Cloudflare, also list its ranges
        # (https://www.cloudflare.com/ips/) and set `forward_headers: true`
        # under `proxy:` in config/deploy.yml.
        Saci.configure do |config|
          config.trusted_proxies = Saci::Middleware::RemoteIp::PRIVATE_NETWORKS.dup
        end
        CRYSTAL
      end

      def self.application_css : String
        <<-CSS
        /* Served from src/assets in development; fingerprinted into
           public/assets by `saci assets:precompile` for production. */
        body {
          font-family: system-ui, -apple-system, sans-serif;
          margin: 4rem auto;
          max-width: 42rem;
          padding: 0 1rem;
          line-height: 1.5;
        }
        CSS
      end

      def self.layout_view : String
        <<-ECR
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Saci app</title>
          <%= stylesheet_link_tag("application.css") %>
          <%= content_for(:head) %>
        </head>
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
