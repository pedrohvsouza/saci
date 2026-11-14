module Saci
  module CLI
    # `saci db:schema:check [--all]` — warns when the database and the models
    # disagree (missing tables/columns on either side). Exits 1 when drift is
    # found, 0 when clean (CI-gateable).
    #
    # The check needs the app's MODELS, so — like `Db` (see
    # serve_command.cr) — this reuses the app's own `db/migrate.cr` runner
    # (models required, web server never booted) via its `schema:check`
    # action. Everything after `--` is forwarded to `crystal` as compiler
    # flags.
    module SchemaCheck
      def self.run(args : Array(String)) : Int32
        Util.shard_name(Dir.current)
        raise Error.new("db/migrate.cr not found. Is this a Saci app?") unless File.exists?("db/migrate.cr")
        Generate.regenerate_manifest!

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

        puts "Checking all databases" if all
        Compile.run("db/migrate.cr", crystal_flags, ["schema:check"] + script_args, name: "migrations")
      end
    end
  end
end
