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
        else               raise Error.new("Unknown credentials action '#{action}' (expected show|edit|keygen)")
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
