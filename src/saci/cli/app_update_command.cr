module Saci
  module CLI
    # `saci app:update` — re-applies the `saci new` scaffold without
    # clobbering user files (G122).
    #
    # Every stock file is written through the generator writer, so:
    # * missing files are created;
    # * identical files are skipped quietly;
    # * files that differ are skipped with a warning unless `--force`
    #   (or an interactive `y`) is given;
    # * `--pretend` previews everything and writes nothing.
    #
    # `--template`-style custom app templates for `saci new` are out of
    # scope; use `saci new` then `saci app:update` for existing apps.
    module AppUpdate
      def self.run(args : Array(String)) : Int32
        pretend = false
        force = false
        args.each do |a|
          case a
          when "--pretend", "--dry-run" then pretend = true
          when "--force"                then force = true
          when "-h", "--help"           then puts help; return 0
          else                               raise Error.new("Unknown option '#{a}'. See `saci help app:update`.")
          end
        end

        name = Util.shard_name(Dir.current)
        kind = Util.db_kind(name)
        Generate.pretend = pretend
        Generate.force = force

        counts = Hash(Symbol, Int32).new(0)
        manifest(name, kind).each do |(path, content)|
          result = Generate.write_file(path, content)
          counts[result] += 1
        end

        if File.exists?("db/migrations.cr") || pretend
          counts[:identical] += 1
        else
          Generate.regenerate_manifest!
          counts[:created] += 1
        end

        total = counts.values.sum
        puts ""
        puts "App update (#{name}, #{kind}): #{total} file#{total == 1 ? "" : "s"} checked"
        puts "  created:   #{counts[:created] + counts[:pretend_create]}"
        puts "  identical: #{counts[:identical] + counts[:pretend_identical]}"
        puts "  updated:   #{counts[:overwritten] + counts[:pretend_overwrite]}"
        skipped = counts[:skipped]
        puts "  skipped:   #{skipped} (existing files kept; use --force to overwrite)" if skipped > 0
        0
      ensure
        Generate.reset_flags!
      end

      def self.help : String
        "Usage: saci app:update [--pretend] [--force]\n\nCopies missing scaffold files (entrypoint, controllers, models, views, config environments, locales, specs, db runners) without overwriting user files. --force overwrites differing files; --pretend previews."
      end

      # path -> stock content, using the same `New` templates as `saci new`.
      def self.manifest(name : String, kind : String) : Array(Tuple(String, String))
        [
          {"src/#{name}.cr", New.entrypoint(name, kind)},
          {"src/controllers/application_controller.cr", New.application_controller},
          {"src/controllers/home_controller.cr", New.home_controller},
          {"src/models/application_record.cr", New.application_record},
          {"src/views/layouts/application.ecr", New.layout_view},
          {"src/views/home/index.ecr", New.home_view},
          {"config/environments/development.cr", New.env_development},
          {"config/environments/test.cr", New.env_test},
          {"config/environments/production.cr", New.env_production},
          {"config/environments/staging.cr", New.env_staging},
          {"config/locales/en.yml", New.locales_en},
          {"config/locales/es.yml", New.locales_es},
          {"spec/spec_helper.cr", New.spec_helper(name, kind)},
          {"spec/app_spec.cr", New.app_spec(name)},
          {"db/migrate.cr", New.migrate_runner(name, kind)},
          {"db/seed.cr", New.seed_file},
        ]
      end
    end
  end
end
