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

    # Stores *value* under a (dotted) key, creating intermediate mappings
    # and replacing a scalar that sits in the way. Re-encrypts the file.
    def self.set(dot_path : String, value : String, path : String = file_path) : Nil
      keys = split_key!(dot_path)
      data = read(path)
      data[keys.first] = assign(data[keys.first]?, keys[1..], value)
      write(data, path)
    end

    # Removes a (dotted) key. Returns false when it was not present.
    def self.unset(dot_path : String, path : String = file_path) : Bool
      keys = split_key!(dot_path)
      data = read(path)
      if keys.size == 1
        return false unless data.delete(keys.first)
      else
        return false unless top = data[keys.first]?
        updated = remove(top, keys[1..])
        return false unless updated
        data[keys.first] = updated
      end
      write(data, path)
      true
    end

    private def self.split_key!(dot_path : String) : Array(String)
      keys = dot_path.split(".")
      if keys.empty? || keys.any?(&.empty?)
        raise ArgumentError.new("invalid credentials key #{dot_path.inspect}")
      end
      keys
    end

    private def self.assign(node : YAML::Any?, keys : Array(String), value : String) : YAML::Any
      return YAML::Any.new(value) if keys.empty?
      hash = node.try(&.as_h?).try(&.dup) || {} of YAML::Any => YAML::Any
      key = YAML::Any.new(keys.first)
      hash[key] = assign(hash[key]?, keys[1..], value)
      YAML::Any.new(hash)
    end

    # Copy of *node* without the nested key, or nil when it is absent.
    private def self.remove(node : YAML::Any, keys : Array(String)) : YAML::Any?
      hash = node.as_h?.try(&.dup)
      return nil unless hash
      key = YAML::Any.new(keys.first)
      if keys.size == 1
        return nil unless hash.has_key?(key)
        hash.delete(key)
      else
        return nil unless child = hash[key]?
        return nil unless updated = remove(child, keys[1..])
        hash[key] = updated
      end
      YAML::Any.new(hash)
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
