require "./watch"

module Saci
  module CLI
    # `saci test` — runs the app's spec suite.
    #
    # The whole suite is compiled once into `tmp/.saci-test/specs` and that
    # binary is reused until a source file changes, so picking specs
    # (`saci test spec/models`, `spec/post_spec.cr:12`) only changes the
    # filters the binary runs with and needs no compile. `--watch` reruns
    # the same selection after every change; `--rebuild` forces a compile.
    # Spec runner options (`--fail-fast`, `-e NAME`, `--order random`, ...)
    # go to the binary; other options and everything after `--` go to
    # `crystal build`.
    module Test
      BUILD_DIR = File.join("tmp", ".saci-test")
      RUNNER    = File.join(BUILD_DIR, "runner.cr")
      BINARY    = File.join(BUILD_DIR, "specs")
      STAMP     = File.join(BUILD_DIR, "specs.stamp")

      # Options of Crystal's spec runner, passed to the binary at run time;
      # the ones in `RUNTIME_WITH_VALUE` take the next argument.
      RUNTIME_FLAGS      = %w(--fail-fast -v --verbose -p --profile --tap --dry-run --list-tags --color --no-color)
      RUNTIME_WITH_VALUE = %w(-e --example -l --line --location --tag --order --junit_output)

      def self.run(args : Array(String)) : Int32
        Util.shard_name(Dir.current)
        raise Error.new("No spec/ directory found. Is this a Saci app?") unless Dir.exists?("spec")
        script_args, crystal_flags = split_args(args)
        watch = !!script_args.delete("--watch")
        rebuild = !!script_args.delete("--rebuild")
        selection, locations, options = select_specs(script_args)
        raise Error.new("No spec files found.") if selection.empty?
        runtime_opts, compiler_opts = split_options(options)
        selected = script_args.any? { |a| spec_argument?(a) }
        flags = compiler_opts + crystal_flags

        status = run_once(selection, locations, selected, flags, runtime_opts, rebuild)
        return status unless watch

        STDERR.puts "Watching for changes (Ctrl-C to stop)..."
        baseline = Watch.snapshot(watch_roots)
        loop do
          sleep Watch::DEFAULT_INTERVAL.seconds
          next unless Watch.changed?(baseline, Watch.snapshot(watch_roots))
          sleep Watch::DEBOUNCE_QUIET.seconds
          baseline = Watch.snapshot(watch_roots)
          begin
            run_once(selection, locations, selected, flags, runtime_opts, false)
          rescue ex : Error
            # A selected file was deleted or renamed: report and keep watching.
            STDERR.puts "error: #{ex.message}"
          end
          STDERR.puts "Watching for changes (Ctrl-C to stop)..."
        end
      end

      # Builds the suite when it is stale, then runs it with the filters
      # for the selection. Returns the exit status (1 when the build failed).
      def self.run_once(selection : Array(String), locations : Array(Tuple(String, String)), selected : Bool,
                        flags : Array(String), runtime_opts : Array(String), rebuild : Bool) : Int32
        files = suite_files(selection)
        stamp = fingerprint(files, flags)
        if rebuild || !fresh?(stamp)
          return 1 unless build(files, flags, stamp)
        else
          STDERR.puts "Specs are up to date, reusing #{BINARY}."
        end
        filters = selected ? filter_options(selection, locations) : [] of String
        status = Process.run(BINARY, args: filters + runtime_opts, input: Process::Redirect::Inherit,
          output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
        status.success? ? 0 : 1
      end

      # Compiles to a temporary name and renames it into place, so a
      # concurrent `saci test` never runs a half-written binary. The runner
      # keeps one path, which lets the compiler reuse its object cache.
      def self.build(files : Array(String), flags : Array(String), stamp : String) : Bool
        Dir.mkdir_p(BUILD_DIR)
        File.write(RUNNER, runner_source(files, BUILD_DIR))
        partial = "#{BINARY}.#{Process.pid}"
        noun = files.size == 1 ? "spec file" : "spec files"
        unless Compile.build(flags + ["-o", partial, RUNNER], "#{files.size} #{noun}")
          Compile.remove_binary(partial)
          File.delete(STAMP) if File.exists?(STAMP)
          return false
        end
        File.rename(partial, BINARY)
        File.rename("#{partial}.dwarf", "#{BINARY}.dwarf") if File.exists?("#{partial}.dwarf")
        File.write(STAMP, stamp)
        true
      end

      def self.fresh?(stamp : String) : Bool
        File.exists?(BINARY) && File.exists?(STAMP) && File.read(STAMP) == stamp
      end

      # What the binary was built from, hashed (FNV-1a 64): the compiler,
      # its flags, the spec files and every watched file with its mtime.
      def self.fingerprint(files : Array(String), flags : Array(String)) : String
        parts = [] of String
        if crystal = Process.find_executable("crystal")
          parts << crystal << File.info(crystal).modification_time.to_unix_ms.to_s
        end
        parts.concat(flags)
        parts << "--"
        parts.concat(files)
        parts << "--"
        Watch.snapshot(watch_roots).to_a.sort_by!(&.[0]).each do |(path, mtime)|
          parts << "#{path}\t#{mtime.to_unix_ns}"
        end
        hash = 0xcbf29ce484222325_u64
        parts.each do |part|
          part.each_byte { |byte| hash = (hash ^ byte) &* 0x100000001b3_u64 }
          hash = (hash ^ 0x0a_u64) &* 0x100000001b3_u64
        end
        hash.to_s(16).rjust(16, '0')
      end

      def self.watch_roots : Array(String)
        Watch.roots + ["spec"]
      end

      # Every spec file of the suite, plus selected files that live outside
      # `spec/**/*_spec.cr`, so one binary serves every selection.
      def self.suite_files(selection : Array(String)) : Array(String)
        (Dir["spec/**/*_spec.cr"].sort + selection).uniq
      end

      def self.spec_argument?(arg : String) : Bool
        !!(arg =~ /\.cr(:\d+)?\z/) || Dir.exists?(arg)
      end

      # Selected spec files, `file:line` locations, and the remaining
      # options, the way `crystal spec` reads its arguments.
      def self.select_specs(args : Array(String)) : Tuple(Array(String), Array(Tuple(String, String)), Array(String))
        selected = args.select { |a| spec_argument?(a) }
        options = args.reject { |a| selected.includes?(a) }
        locations = [] of Tuple(String, String)
        files = [] of String
        if selected.empty?
          files = Dir["spec/**/*_spec.cr"].sort
        else
          selected.each do |name|
            if name =~ /\A(.+?):(\d+)\z/
              file, line = $1, $2
              raise Error.new("'#{file}' is not a file") unless File.file?(file)
              files << file
              locations << {file, line}
            elsif Dir.exists?(name)
              files.concat Dir["#{::Path[name].to_posix}/**/*_spec.cr"].sort
            elsif File.file?(name)
              files << name
            else
              raise Error.new("'#{name}' is not a file")
            end
          end
        end
        {files.uniq, locations, options}
      end

      # Splits leftover options into spec runner options (run time) and
      # compiler options (build time).
      def self.split_options(options : Array(String)) : Tuple(Array(String), Array(String))
        runtime = [] of String
        compiler = [] of String
        i = 0
        while i < options.size
          opt = options[i]
          if RUNTIME_FLAGS.includes?(opt)
            runtime << opt
          elsif RUNTIME_WITH_VALUE.includes?(opt.split('=', 2).first)
            runtime << opt
            if !opt.includes?('=') && (value = options[i + 1]?)
              runtime << value
              i += 1
            end
          else
            compiler << opt
          end
          i += 1
        end
        {runtime, compiler}
      end

      # `--location` filters for the selection. `file:line` keeps its line;
      # a whole file runs through the first line of each top-level group,
      # since a group selected by its first line runs everything inside.
      def self.filter_options(files : Array(String), locations : Array(Tuple(String, String))) : Array(String)
        opts = locations.flat_map { |(file, line)| ["--location", "#{file}:#{line}"] }
        with_line = locations.map(&.[0])
        (files - with_line).each do |file|
          lines = top_level_lines(file)
          # Specs defined by macros or loops: select every line of the file.
          lines = (1..File.read_lines(file).size).to_a if lines.empty?
          lines.each { |line| opts << "--location" << "#{file}:#{line}" }
        end
        opts
      end

      def self.top_level_lines(file : String) : Array(Int32)
        lines = [] of Int32
        File.read_lines(file).each_with_index do |text, index|
          lines << index + 1 if text =~ /\A(?:::)?(?:Spec\.)?(?:describe|context|it|pending)\b/
        end
        lines
      end

      # `require` lines relative to `dir`, where the runner file lives.
      def self.runner_source(files : Array(String), dir : String) : String
        base = ::Path[File.expand_path(dir)]
        files.join('\n') do |file|
          relative = ::Path[File.expand_path(file)].relative_to(base).to_posix.to_s
          relative = "./#{relative}" unless relative.starts_with?("../")
          %(require "#{relative.inspect_unquoted}")
        end + "\n"
      end

      def self.split_args(args : Array(String)) : Tuple(Array(String), Array(String))
        script_args = [] of String
        crystal_flags = [] of String
        forward = false
        args.each do |a|
          if forward
            crystal_flags << a
          elsif a == "--"
            forward = true
          else
            script_args << a
          end
        end
        {script_args, crystal_flags}
      end
    end
  end
end
