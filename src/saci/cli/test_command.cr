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
        crystal = Util.crystal_bin!
        crystal_args = ["spec"] + crystal_flags + script_args
        puts "Running: #{crystal} #{crystal_args.join(" ")}"
        status = Process.run(crystal, args: crystal_args, output: STDOUT, error: STDERR)
        status.success? ? 0 : 1
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
