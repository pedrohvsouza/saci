require "../assets"

module Saci
  module CLI
    # `saci assets:precompile` / `saci assets:clobber` — fingerprints
    # `src/assets/` into `public/assets/` for production (see
    # `Saci::Assets.precompile`). The generated Dockerfile runs the same
    # code during the image build.
    module AssetsCommand
      def self.help : String
        <<-HELP
        Usage: saci assets:precompile [--source DIR] [--output DIR]
               saci assets:clobber [--source DIR] [--output DIR]

        precompile copies every file under the source (default src/assets) into
        the output (default public/assets) twice: as name-<sha256>.ext, which
        asset_path/stylesheet_link_tag use once the manifest exists and which
        is served with `Cache-Control: immutable`, and under its plain name.
        It writes public/assets/.manifest.json and clears earlier output first.
        clobber removes that output again (only files precompile wrote).

        In development nothing needs compiling: /assets/* is served straight
        from src/assets. Keep public/assets out of Git; build it at deploy time.
        HELP
      end

      def self.run(args : Array(String), action : String) : Int32
        if args.includes?("-h") || args.includes?("--help")
          puts help
          return 0
        end
        source = Saci::Assets::DEFAULT_SOURCE
        output = Saci::Assets::DEFAULT_OUTPUT
        i = 0
        while i < args.size
          arg = args[i]
          case arg
          when "--source"
            source = args[i + 1]? || raise Error.new("Missing value for --source")
            i += 1
          when .starts_with?("--source=")
            source = arg.split("=", 2)[1]
          when "--output"
            output = args[i + 1]? || raise Error.new("Missing value for --output")
            i += 1
          when .starts_with?("--output=")
            output = arg.split("=", 2)[1]
          else
            raise Error.new("Unknown argument '#{arg}'. See `saci help assets:#{action}`.")
          end
          i += 1
        end

        case action
        when "precompile"
          manifest = begin
            Saci::Assets.precompile(source, output)
          rescue ex : ArgumentError
            raise Error.new(ex.message || "assets:precompile failed")
          end
          manifest.each { |logical, digested| puts "  #{logical} -> #{File.join(output, digested)}" }
          puts "Precompiled #{manifest.size} asset#{manifest.size == 1 ? "" : "s"} into #{output}."
        when "clobber"
          removed = Saci::Assets.clobber(output, source)
          puts removed.zero? ? "Nothing to clobber in #{output}." : "Removed #{removed} file#{removed == 1 ? "" : "s"} from #{output}."
        else
          raise Error.new("Unknown assets action '#{action}' (expected precompile|clobber)")
        end
        0
      end
    end
  end
end
