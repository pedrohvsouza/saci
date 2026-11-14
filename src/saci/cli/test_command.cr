module Saci
  module CLI
    # `saci test` — runs the app's spec suite via `crystal spec`.
    # Args before `--` select specs / spec options (`saci test spec/models`);
    # everything after `--` is forwarded to `crystal` as compiler flags.
    module Test
      def self.run(args : Array(String)) : Int32
        Util.shard_name(Dir.current)
        raise Error.new("No spec/ directory found. Is this a Saci app?") unless Dir.exists?("spec")
        script_args, crystal_flags = split_args(args)
        files, locations, compiler_opts = select_specs(script_args)
        raise Error.new("No spec files found.") if files.empty?
        runtime_opts = location_options(files, locations)

        # What `crystal spec` does, split in two so the compile gets a
        # progress line: one program requiring every spec file, built,
        # then run with the location filters.
        Dir.mkdir_p("tmp")
        runner = File.join("tmp", ".saci-spec-#{Process.pid}.cr")
        File.write(runner, runner_source(files, File.dirname(runner)))
        begin
          noun = files.size == 1 ? "spec file" : "spec files"
          Compile.run(runner, compiler_opts + crystal_flags, runtime_opts, name: "#{files.size} #{noun}")
        ensure
          File.delete(runner) if File.exists?(runner)
        end
      end

      # Spec files to compile, `file:line` locations, and the remaining
      # (compiler) options, the way `crystal spec` reads its arguments.
      def self.select_specs(args : Array(String)) : Tuple(Array(String), Array(Tuple(String, String)), Array(String))
        selected = args.select { |a| a =~ /\.cr(:\d+)?\z/ || Dir.exists?(a) }
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

      def self.location_options(files : Array(String), locations : Array(Tuple(String, String))) : Array(String)
        if files.size == 1 && locations.size == 1
          ["-l", locations.first[1]]
        else
          locations.flat_map { |(file, line)| ["--location", "#{file}:#{line}"] }
        end
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
