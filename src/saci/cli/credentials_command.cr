module Saci
  module CLI
    # `saci credentials:show|edit|keygen` — manages the encrypted
    # credentials file (`config/credentials.yml.enc` + `config/master.key`).
    module Credentials
      def self.run(args : Array(String), action : String) : Int32
        case action
        when "show"   then show
        when "edit"   then edit(args.first?)
        when "keygen" then keygen
        when "fetch"  then return fetch(args)
        else               raise Error.new("Unknown credentials action '#{action}' (expected show|edit|keygen|fetch)")
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
