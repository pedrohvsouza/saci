require "./watch"

module Saci
  module CLI
    # `saci serve` — runs the app with `crystal run` (dev) or `--release`.
    # Everything after `--` is forwarded to `crystal run` (e.g. link flags).
    # With `--watch`, rebuilds + restarts on file changes (hot-reload).
    # With `--mt`, compiles with multithreading and enables it at boot.
    module Serve
      alias Options = NamedTuple(
        port: String,
        host: String,
        release: Bool,
        watch: Bool,
        interval: Float64,
        mt: Bool,
        workers: Int32?,
        crystal_extra: Array(String),
      )

      def self.parse(args : Array(String)) : Options
        port = ENV.fetch("PORT", "3000")
        host = ENV.fetch("HOST", "127.0.0.1")
        release = false
        watch = false
        interval = Watch::DEFAULT_INTERVAL
        mt = false
        workers = nil
        crystal_extra = [] of String
        forward = false

        i = 0
        while i < args.size
          a = args[i]
          if forward
            crystal_extra << a
          elsif a == "--"
            forward = true
          elsif a.starts_with?("--port=")
            port = a.split("=", 2)[1]
          elsif a == "--port"
            port = args[i + 1]? || raise Error.new("Missing value for --port")
            i += 1
          elsif a.starts_with?("--host=")
            host = a.split("=", 2)[1]
          elsif a == "--host"
            host = args[i + 1]? || raise Error.new("Missing value for --host")
            i += 1
          elsif a == "--release"
            release = true
          elsif a == "--watch" || a == "-w"
            watch = true
          elsif a.starts_with?("--watch-interval=")
            interval = a.split("=", 2)[1].to_f
          elsif a == "--mt"
            mt = true
          elsif a.starts_with?("--workers=")
            mt = true
            workers = a.split("=", 2)[1].to_i
          elsif a == "--workers"
            mt = true
            workers = (args[i + 1]? || raise Error.new("Missing value for --workers")).to_i
            i += 1
          else
            raise Error.new("Unknown option '#{a}'. See `saci help serve`.")
          end
          i += 1
        end

        {port: port, host: host, release: release, watch: watch,
         interval: interval, mt: mt, workers: workers, crystal_extra: crystal_extra}
      end

      def self.run(args : Array(String)) : Int32
        opts = parse(args)

        name = Util.shard_name(Dir.current)
        entry = File.join("src", "#{name}.cr")
        raise Error.new("Entrypoint #{entry} not found.") unless File.exists?(entry)

        crystal = Util.crystal_bin!
        # Compiler flags go BEFORE the entrypoint; program args after `--`.
        build_base = [crystal, "build"]
        build_base << "--release" if opts[:release]
        build_base << "-Dexecution_context" if opts[:mt]
        build_base = build_base + opts[:crystal_extra]
        env = {"PORT" => opts[:port], "HOST" => opts[:host]}
        env["SACI_MT"] = "1" if opts[:mt]
        if workers = opts[:workers]
          env["CRYSTAL_WORKERS"] = workers.to_s
        end

        if opts[:watch]
          puts "Serving #{name} with hot-reload (PORT=#{opts[:port]} HOST=#{opts[:host]}#{opts[:mt] ? " MT" : ""})"
          out_path = File.join("tmp", ".saci-serve-#{name}")
          Watch.serve(entry, out_path, env, build_base, opts[:interval])
        else
          run_cmd = [crystal, "run"]
          run_cmd << "--release" if opts[:release]
          run_cmd << "-Dexecution_context" if opts[:mt]
          run_cmd = run_cmd + opts[:crystal_extra] + [entry]
          puts "Serving #{name} (PORT=#{opts[:port]} HOST=#{opts[:host]}#{opts[:mt] ? " MT" : ""}) via: #{run_cmd.join(" ")}"
          Process.exec(run_cmd[0], args: run_cmd[1..], env: env)
        end
      end
    end

    # `saci db:migrate` / `saci db:rollback [STEPS]`.
    # Extra args before `--` are forwarded to the migrate script (e.g. STEPS,
    # `--all` to migrate primary + all named DBs); everything after `--` is
    # forwarded to `crystal` as compiler flags.
    module Db
      def self.parse(args : Array(String)) : NamedTuple(all: Bool, script_args: Array(String), crystal_flags: Array(String))
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
        {all: all, script_args: script_args, crystal_flags: crystal_flags}
      end

      def self.run(args : Array(String), action : String) : Int32
        Util.shard_name(Dir.current)
        raise Error.new("db/migrate.cr not found. Is this a Saci app?") unless File.exists?("db/migrate.cr")
        Generate.regenerate_manifest!

        parsed = parse(args)
        script_args = parsed[:script_args]
        crystal_flags = parsed[:crystal_flags]

        crystal = Util.crystal_bin!
        crystal_args = ["run"] + crystal_flags + ["db/migrate.cr", "--", action] + script_args
        puts "Running: #{crystal} #{crystal_args.join(" ")}#{" (all databases)" if parsed[:all]}"
        status = Process.run(crystal, args: crystal_args, output: STDOUT, error: STDERR)
        status.success? ? 0 : 1
      end
    end
  end
end
