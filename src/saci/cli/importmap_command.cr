require "../importmap"
require "./util"

module Saci
  module CLI
    # `saci importmap:install` / `saci importmap:json` (G72).
    #
    # The coordinator wires dispatch in `src/saci/cli.cr`; this file contains
    # the implementation only, so it can be required independently by specs.
    #
    # ```
    # saci importmap:install                 # write config/importmap.json
    # saci importmap:json                    # print the current manifest JSON
    # saci importmap:pin application --to=application.js --preload
    # saci importmap:pin_all_from app/javascript/controllers --under=controllers
    # ```
    module ImportmapCommand
      DEFAULT_PATH     = "config/importmap.json"
      APPLICATION_PATH = "app/javascript/application.js"

      def self.run(args : Array(String), output : IO = STDOUT) : Int32
        command = args.first? || "install"
        rest = args[1..]? || [] of String

        case command
        when "install"
          install(rest, output)
        when "json"
          json(rest, output)
        when "pin"
          pin(rest, output)
        when "pin_all_from", "pin-all-from"
          pin_all_from(rest, output)
        when "-h", "--help", "help"
          output.puts help
          0
        else
          raise Error.new("Unknown importmap task '#{command}'. See `saci help importmap`.")
        end
      end

      def self.install(args : Array(String), output : IO = STDOUT) : Int32
        options = parse_options(args, allow_positionals: false)
        path = options["path"]? || DEFAULT_PATH

        manifest = Importmap.default
        if manifest.empty?
          # A useful first install even when the app has not drawn a map yet.
          manifest.pin("application", to: "application.js", preload: true)
        end
        Importmap.write(path, manifest)
        output.puts "Wrote #{path}"

        unless options.has_key?("no-application")
          app_file = options["application"]? || APPLICATION_PATH
          unless File.exists?(app_file)
            dir = File.dirname(app_file)
            Dir.mkdir_p(dir) unless dir == "." || dir.empty?
            File.write(app_file, application_template)
            output.puts "Created #{app_file}"
          end
        end

        output.puts %(Add `<%= importmap_tags %>` inside your layout <head>.)
        0
      end

      def self.json(args : Array(String), output : IO = STDOUT) : Int32
        options = parse_options(args, allow_positionals: true)
        path = options["path"]? || DEFAULT_PATH
        json = File.file?(path) ? File.read(path).strip : Importmap.default.to_json

        if output_path = options["output"]?
          dir = File.dirname(output_path)
          Dir.mkdir_p(dir) unless dir == "." || dir.empty?
          File.write(output_path, "#{json}\n")
          output.puts "Wrote #{output_path}"
        else
          output.puts json
        end
        0
      end

      def self.pin(args : Array(String), output : IO = STDOUT) : Int32
        options = parse_options(args, allow_positionals: true)
        name = options["name"]? || options["_positionals"]?.try(&.split.first?)
        raise Error.new("Usage: saci importmap:pin NAME [--to=PATH] [--preload] [--path=config/importmap.json]") unless name

        to = options["to"]?
        preload = options.has_key?("preload")
        Importmap.pin(name, to: to, preload: preload)
        path = options["path"]? || DEFAULT_PATH
        Importmap.write(path, Importmap.default)
        output.puts "Pinned #{name} in #{path}"
        0
      end

      def self.pin_all_from(args : Array(String), output : IO = STDOUT) : Int32
        options = parse_options(args, allow_positionals: true)
        dir = options["dir"]? || options["_positionals"]?.try(&.split.first?)
        raise Error.new("Usage: saci importmap:pin_all_from DIR [--under=NAME] [--path=config/importmap.json]") unless dir

        Importmap.pin_all_from(dir, under: options["under"]?, to: options["to"]?)
        path = options["path"]? || DEFAULT_PATH
        Importmap.write(path, Importmap.default)
        output.puts "Pinned files from #{dir} in #{path}"
        0
      end

      def self.help : String
        <<-HELP
        Usage:
          saci importmap:install [--path=config/importmap.json] [--no-application]
          saci importmap:json [--path=config/importmap.json] [--output=PATH]
          saci importmap:pin NAME [--to=PATH] [--preload] [--path=PATH]
          saci importmap:pin_all_from DIR [--under=NAME] [--to=PATH] [--path=PATH]

        Pins resolve through Saci::Assets (fingerprinted /assets/... URLs when
        a manifest exists). Add <%= importmap_tags %> to the layout head.
        HELP
      end

      private def self.application_template : String
        <<-JS
        // Entry point for the browser import map (see config/importmap.json).
        // import "controllers/application"
        JS
      end

      # Tiny flag parser: `--flag`, `--flag=value`, `--flag value`, and
      # positionals. Flags are returned without leading dashes.
      private def self.parse_options(args : Array(String), allow_positionals : Bool = true) : Hash(String, String)
        options = {} of String => String
        positionals = [] of String
        index = 0
        while index < args.size
          arg = args[index]
          if arg.starts_with?("--")
            key_value = arg[2..]
            if eq = key_value.index('=')
              options[key_value[0...eq]] = key_value[(eq + 1)..]
              index += 1
            elsif index + 1 < args.size && !args[index + 1].starts_with?("--")
              options[key_value] = args[index + 1]
              index += 2
            else
              options[key_value] = "true"
              index += 1
            end
          elsif allow_positionals
            positionals << arg
            index += 1
          else
            raise Error.new("Unexpected argument '#{arg}'.")
          end
        end
        options["_positionals"] = positionals.join(" ") unless positionals.empty?
        options
      end
    end
  end
end
