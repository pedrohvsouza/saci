require "yaml"

module Saci
  # Encrypted credentials (`config/credentials.yml.enc` + `config/master.key`),
  # Rails-style. Values are nested YAML; `dig` reads dot paths:
  #
  # ```
  # Saci::Credentials.dig("aws.access_key") # => "AKIA..." or nil
  # ```
  #
  # Manage with `saci credentials:show|edit` (and `credentials:keygen` for
  # existing apps). The master key comes from `RAILS_MASTER_KEY` or
  # `config/master.key` (gitignored — never commit it).
  module Credentials
    @@file_path : String = "config/credentials.yml.enc"
    @@key_path : String = "config/master.key"
    @@mutex = Mutex.new

    def self.file_path : String
      @@mutex.synchronize { @@file_path }
    end

    def self.file_path=(path : String) : Nil
      @@mutex.synchronize { @@file_path = path }
    end

    def self.key_path : String
      @@mutex.synchronize { @@key_path }
    end

    def self.key_path=(path : String) : Nil
      @@mutex.synchronize { @@key_path = path }
    end

    # 32 raw bytes from hex. Raises on missing/malformed keys.
    def self.master_key : Bytes
      hex = ENV["RAILS_MASTER_KEY"]? || begin
        path = key_path
        raise "Master key not found: set RAILS_MASTER_KEY or create #{path} (`saci credentials:keygen`)" unless File.exists?(path)
        File.read(path).strip
      end
      raise "Master key must be 64 hex chars (32 bytes)" unless hex.size == 64
      hex.hexbytes
    rescue ArgumentError
      raise "Master key must be valid hex (64 chars)"
    end

    def self.generate_key : String
      bytes = Bytes.new(32)
      Random::Secure.random_bytes(bytes)
      bytes.hexstring
    end

    def self.read(path : String = file_path) : Hash(String, YAML::Any)
      return {} of String => YAML::Any unless File.exists?(path)
      plain = String.new(MessageEncryptor.decrypt_and_verify(master_key, File.read(path).strip))
      (YAML.parse(plain).as_h? || {} of YAML::Any => YAML::Any).transform_keys(&.to_s)
    end

    def self.write(data : Hash(String, YAML::Any), path : String = file_path) : Nil
      File.write(path, MessageEncryptor.encrypt_and_sign(master_key, data.to_yaml.to_slice))
    end

    def self.dig(dot_path : String, path : String = file_path) : String?
      keys = dot_path.split(".")
      hash = read(path)
      keys.each_with_index do |key, index|
        found = hash[key]?
        return nil if found.nil?
        return found.as_s? || found.to_s if index == keys.size - 1
        hash = found.as_h?.try(&.transform_keys(&.to_s)) || return nil
      end
      nil
    end
  end
end
