module Saci
  module CLI
    # `saci ci` — runs the app's local CI script (G121).
    #
    # `config/ci.cr` (or `config/ci.rb`, copied to a temp `.cr` because
    # Crystal only requires `.cr`) registers steps with `Saci::CI.step` /
    # `Saci::CI.run`; this command compiles a tiny runner that requires
    # the config and calls `Saci::CI.run_all`, reporting per-step timing
    # and a failure summary.
    module CICommand
      def self.run(args : Array(String)) : Int32
        if args == ["-h"] || args == ["--help"] || args == ["help"]
          puts help
          return 0
        end
        flags = [] of String
        forward = false
        args.each do |a|
          if forward
            flags << a
          elsif a == "--"
            forward = true
          else
            raise Error.new("Unknown option '#{a}'. See `saci help ci`.")
          end
        end

        path = locate
        unless path
          puts template
          STDERR.puts "No config/ci.cr found. Create it from the template above, then run `saci ci`."
          return 1
        end

        require_path = path
        temp_copy : String? = nil
        if path.ends_with?(".rb")
          Dir.mkdir_p("tmp")
          temp_copy = File.join("tmp", ".saci-ci-#{Process.pid}.cr")
          File.write(temp_copy, File.read(path))
          require_path = temp_copy
        end

        source = String.build do |io|
          io << Inspect::Runner.framework_require_line << "\n"
          io << Util.internal_require("ci") << "\n"
          io << "require \"#{Inspect::Runner.relative_from_tmp(require_path)}\"\n"
          io << "\nstatus = Saci::CI.run_all\n"
          io << "exit(status)\n"
        end

        puts "Running CI (#{path})..."
        code = Inspect::Runner.with_wrapper do |wrapper|
          File.write(wrapper, source)
          Inspect::Runner.exec_wrapper(wrapper, [] of String, flags)
        end
        code
      ensure
        if temp_copy && File.exists?(temp_copy)
          File.delete(temp_copy)
        end
      end

      def self.help : String
        "Usage: saci ci [-- crystal flags]\n\nRuns config/ci.cr (Saci::CI.step / Saci::CI.run) with timing and a failure summary.\nExits 1 when any step fails."
      end

      # `config/ci.cr` wins over `config/ci.rb`.
      def self.locate : String?
        ["config/ci.cr", "config/ci.rb"].find { |path| File.exists?(path) }
      end

      # Conventional starter (also printed when no config exists).
      def self.template : String
        <<-CRYSTAL
        # config/ci.cr — local CI steps, run with `saci ci`.
        # `Saci::CI.step` runs compiled Crystal in-process; `Saci::CI.run`
        # shells out and fails on a non-zero exit status.

        Saci::CI.step "Format" do
          status = Process.run("crystal", args: ["tool", "format", "--check", "src", "spec"])
          Saci::CI.fail!("crystal tool format reported changes") unless status.success?
        end

        Saci::CI.run "Specs", "crystal spec --no-color"
        Saci::CI.run "Build", "crystal build src/#{Util.app_name? || "app"}.cr -o tmp/ci-build"
        CRYSTAL
      end
    end
  end
end
