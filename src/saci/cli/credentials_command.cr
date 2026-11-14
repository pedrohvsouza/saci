module Saci
  module CLI
    # `saci credentials:show|edit|keygen|fetch|get|set|unset` — manages the encrypted
    # credentials file (`config/credentials.yml.enc` + `config/master.key`).
    module Credentials
      def self.run(args : Array(String), action : String) : Int32
        case action
        when "show"         then show
        when "edit"         then edit(args.first?)
        when "keygen"       then keygen
        when "fetch", "get" then return fetch(args)
        when "set"          then return set(args)
        when "unset"        then return unset(args)
        else                     raise Error.new("Unknown credentials action '#{action}' (expected show|edit|keygen|fetch|get|set|unset)")
        end
        0
      end

      def self.show : Nil
        puts decrypted_yaml
      end

      def self.edit(editor : String? = nil) : Nil
        editor ||= ENV["EDITOR"]? || "vi"
        path = File.tempname("saci-credentials", ".yml")
        begin
          File.write(path, decrypted_yaml)
          status = Process.run(editor, args: [path], input: STDIN, output: STDOUT, error: STDERR)
          raise Error.new("Editor exited with status #{status.exit_code}") unless status.success?
          Saci::Credentials.write(parse_yaml(File.read(path)))
          puts "Credentials updated."
        ensure
          File.delete(path) if File.exists?(path)
        end
      end

      def self.keygen : Nil
        path = Saci::Credentials.key_path
        if File.exists?(path)
          puts "#{path} already exists — not overwriting."
        else
          File.write(path, Saci::Credentials.generate_key + "\n")
          puts "Generated #{path} (gitignored — never commit it)."
        end
      end

      # `saci credentials:fetch KEY [--to PATH|--write PATH]` (G180/8.1).
      # Reads a (possibly dotted) key from encrypted credentials; prints
      # the value, or writes it verbatim to PATH. Exits 1 when missing.
      def self.fetch(args : Array(String)) : Int32
        key = nil
        to = nil
        i = 0
        while i < args.size
          a = args[i]
          case a
          when "--to", "--write", "-o"
            to = args[i + 1]? || raise Error.new("Missing value for #{a}")
            i += 1
          when .starts_with?("--to=")
            to = a.split("=", 2)[1]
          when .starts_with?("--write=")
            to = a.split("=", 2)[1]
          else
            if a.starts_with?("-")
              raise Error.new("Unknown option '#{a}'. See `saci help credentials:fetch`.")
            end
            if key
              raise Error.new("Unexpected argument '#{a}'. Usage: saci credentials:fetch KEY [--to PATH]")
            end
            key = a
          end
          i += 1
        end
        raise Error.new("Usage: saci credentials:fetch KEY [--to PATH]") unless key

        value = Saci::Credentials.dig(key.not_nil!)
        if value.nil?
          STDERR.puts "error: key '#{key}' not found in #{Saci::Credentials.file_path}."
          return 1
        end

        if path = to
          Dir.mkdir_p(File.dirname(path)) unless File.dirname(path) == "."
          File.write(path, value)
          puts "Wrote #{key} to #{path}"
        else
          puts value
        end
        0
      end

      # `saci credentials:set KEY VALUE` (or `KEY --stdin`, which keeps the
      # value out of shell history and process listings). Non-interactive
      # counterpart of `credentials:edit` for setup scripts, CI and deploys.
      def self.set(args : Array(String), input : IO = STDIN) : Int32
        from_stdin = args.includes?("--stdin")
        positional = args.reject { |a| a == "--stdin" }
        usage = "Usage: saci credentials:set KEY VALUE | saci credentials:set KEY --stdin"
        if bad = positional.find { |a| a.starts_with?("-") && a != "-" }
          raise Error.new("Unknown option '#{bad}'. #{usage}")
        end
        key = positional[0]? || raise Error.new(usage)
        value = if from_stdin || positional[1]? == "-"
                  raise Error.new(usage) if positional.size > 2
                  input.gets_to_end.chomp
                else
                  raise Error.new(usage) unless positional.size == 2
                  positional[1]
                end
        begin
          Saci::Credentials.set(key, value)
        rescue ex : ArgumentError
          raise Error.new(ex.message || "invalid key")
        end
        puts "Set #{key} in #{Saci::Credentials.file_path}."
        0
      end

      # `saci credentials:unset KEY`. Exits 1 when the key is missing.
      def self.unset(args : Array(String)) : Int32
        raise Error.new("Usage: saci credentials:unset KEY") unless args.size == 1 && !args[0].starts_with?("-")
        removed = begin
          Saci::Credentials.unset(args[0])
        rescue ex : ArgumentError
          raise Error.new(ex.message || "invalid key")
        end
        if removed
          puts "Removed #{args[0]} from #{Saci::Credentials.file_path}."
          0
        else
          STDERR.puts "error: key '#{args[0]}' not found in #{Saci::Credentials.file_path}."
          1
        end
      end

      # Decrypted YAML text (empty mapping when nothing stored yet).
      def self.decrypted_yaml : String
        data = Saci::Credentials.read
        data.empty? ? "{}\n" : data.to_yaml
      end

      def self.parse_yaml(text : String) : Hash(String, YAML::Any)
        (YAML.parse(text).as_h? || {} of YAML::Any => YAML::Any).transform_keys(&.to_s)
      end
    end
  end
end
