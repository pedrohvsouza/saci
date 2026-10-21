require "uri"
require "yaml"

module Saci
  # Declarative, per-environment YAML configuration (G147/G148).
  #
  # Rails apps read `config/database.yml`, `config/cache.yml`, ... with
  # `Rails.application.config_for`. Saci keeps its env-var defaults, but apps
  # that want declarative files can opt in:
  #
  # ```
  # db = Saci.config_for(:database) # section for APP_ENV
  # db[:adapter]                    # string and symbol keys work
  # db["pool"].as_i?                # 5
  #
  # cache = Saci::ConfigFile.config_for(:cache, env: "production")
  # ```
  #
  # The files are ordinary YAML with optional `<%= ENV["NAME"] %>` and
  # `<%= ENV.fetch("NAME", "default") %>` interpolation. Only those two forms
  # are evaluated — Crystal has no runtime ERB, and arbitrary code in a config
  # file must never be executed. Missing files/sections return an empty
  # `Section`, so framework defaults keep working without any YAML file.
  module ConfigFile
    class Error < Exception
    end

    # Matches both `ENV["X"]` and `ENV.fetch("X", "default")` (the default is
    # optional). Quotes may be single or double.
    ENV_TAG = /<%=\s*ENV(?:\[\s*["']([^"']+)["']\s*\]|\.fetch\(\s*["']([^"']+)["']\s*(?:,\s*["']([^"']*)["']\s*)?\))\s*%>/

    # One environment section. Lookups accept strings and symbols; values stay
    # as `YAML::Any` so nested hashes/arrays keep their natural API.
    class Section
      include Enumerable({String, YAML::Any})

      getter env : String
      getter path : String?

      def initialize(@data : Hash(String, YAML::Any), @env : String = "", @path : String? = nil)
      end

      def [](key : String | Symbol) : YAML::Any
        @data[key.to_s]? || raise KeyError.new("Missing key #{key.inspect} in #{@path || "config"} (#{@env})")
      end

      def []?(key : String | Symbol) : YAML::Any?
        @data[key.to_s]?
      end

      def fetch(key : String | Symbol, default : YAML::Any) : YAML::Any
        @data.fetch(key.to_s, default)
      end

      def fetch(key : String | Symbol, & : String -> YAML::Any) : YAML::Any
        @data.fetch(key.to_s) { |missing| yield missing }
      end

      def has_key?(key : String | Symbol) : Bool
        @data.has_key?(key.to_s)
      end

      def includes?(key : String | Symbol) : Bool
        has_key?(key)
      end

      def each(& : {String, YAML::Any} ->) : Nil
        @data.each { |key, value| yield({key, value}) }
      end

      def size : Int32
        @data.size
      end

      def empty? : Bool
        @data.empty?
      end

      def keys : Array(String)
        @data.keys
      end

      def values : Array(YAML::Any)
        @data.values
      end

      def to_h : Hash(String, YAML::Any)
        @data.dup
      end

      # Nested lookup with symbol support: `section.dig(:replica, "url")`.
      def dig(*keys : String | Symbol) : YAML::Any?
        return nil if keys.empty?
        current = @data[keys.first.to_s]?
        return nil unless current
        keys[1..].each do |key|
          hash = current.as_h?
          return nil unless hash
          current = hash[key.to_s]?
          return nil unless current
        end
        current
      end

      def to_s(io : IO) : Nil
        io << "#<Saci::ConfigFile::Section env=#{@env.inspect} keys=#{@data.keys.inspect}>"
      end
    end

    # Loads a YAML file and returns its top-level mapping with string keys.
    # Raises `Error` for missing files, invalid YAML or a non-mapping root.
    def self.load(path : String) : Hash(String, YAML::Any)
      raise Error.new("Config file #{path} not found") unless File.exists?(path)
      parse(File.read(path), path)
    end

    # Like `load`, but returns nil when the file does not exist.
    def self.load?(path : String) : Hash(String, YAML::Any)?
      File.exists?(path) ? load(path) : nil
    end

    # Parses YAML source after ENV interpolation. `path` is used in error
    # messages only.
    def self.parse(source : String, path : String? = nil) : Hash(String, YAML::Any)
      parsed = YAML.parse(interpolate(source, path))
      mapping = parsed.as_h?
      unless mapping
        raise Error.new("Config #{path || "source"} must contain a YAML mapping at the top level")
      end
      result = {} of String => YAML::Any
      mapping.each do |key, value|
        result[key.as_s? || key.to_s] = value
      end
      result
    rescue ex : Error
      raise ex
    rescue ex : YAML::ParseException
      raise Error.new("Invalid YAML in #{path || "config source"}: #{ex.message}")
    end

    # Replaces the supported ERB-style ENV tags. A missing `ENV["X"]`
    # interpolates as an empty string (matching ERB); `ENV.fetch("X")`
    # without a default raises because that is the explicit strict form.
    def self.interpolate(source : String, path : String? = nil) : String
      source.gsub(ENV_TAG) do |_full, match|
        bracket_key = match[1]?
        fetch_key = match[2]?
        key = bracket_key || fetch_key
        next "" if key.nil?

        if bracket_key
          ENV[bracket_key]? || ""
        elsif value = ENV[fetch_key.not_nil!]?
          value
        elsif default = match[3]?
          default
        else
          raise Error.new("ENV[#{key.inspect}] is not set (used in #{path || "config"})")
        end
      end
    end

    # Returns the section for `env` (default `Saci.env`). A missing file or
    # section yields an empty section; pass `required: true` to raise instead.
    #
    # `path:` overrides the conventional `dir/name.yml` lookup, which is handy
    # for specs and for apps that keep deployment config elsewhere.
    def self.config_for(name : String | Symbol, env : String = Saci.env, dir : String = "config", path : String? = nil, required : Bool = false) : Section
      file = path || File.join(dir, "#{name}.yml")
      unless File.exists?(file)
        return empty_section(env, file) unless required
        raise Error.new("Config file #{file} not found")
      end

      data = load(file)
      section = data[env]?
      unless section
        return empty_section(env, file) unless required
        raise Error.new("Config file #{file} has no #{env.inspect} section")
      end

      mapping = section.as_h?
      unless mapping
        raise Error.new("Config section #{env.inspect} in #{file} must be a mapping")
      end

      Section.new(normalize_mapping(mapping), env, file)
    end

    # Strict variant: missing file or env section raises.
    def self.config_for!(name : String | Symbol, env : String = Saci.env, dir : String = "config", path : String? = nil) : Section
      config_for(name, env: env, dir: dir, path: path, required: true)
    end

    # Builds a database URL from `config/database.yml` for `env`.
    #
    # `url:` wins when present (normally `ENV["DATABASE_URL"]`); otherwise the
    # adapter/database/host/username/password keys are assembled. Returns nil
    # when the section is absent or incomplete, so callers can fall back to
    # their existing `DATABASE_URL` default.
    def self.database_url(env : String = Saci.env, config : Section? = nil, dir : String = "config", path : String? = nil) : String?
      section = config || config_for(:database, env: env, dir: dir, path: path)
      return nil if section.empty?

      if url_value = section["url"]?
        url = url_value.as_s?
        return url unless url.nil? || url.strip.empty?
      end

      adapter = section["adapter"]?.try(&.as_s?).try(&.downcase) || "sqlite3"
      database = section["database"]?.try(&.as_s?)
      return nil if database.nil? || database.empty?

      case adapter
      when "sqlite", "sqlite3"
        "sqlite3://#{database}"
      when "postgres", "postgresql", "postgis"
        user = section["username"]?.try(&.as_s?) || section["user"]?.try(&.as_s?)
        password = section["password"]?.try(&.as_s?)
        host = section["host"]?.try(&.as_s?) || "localhost"
        port = section["port"]?.try(&.as_i?) || 5432
        userinfo = build_userinfo(user, password)
        "postgres://#{userinfo}#{host}:#{port}/#{database}"
      when "mysql", "mysql2", "trilogy"
        user = section["username"]?.try(&.as_s?) || section["user"]?.try(&.as_s?) || "root"
        password = section["password"]?.try(&.as_s?)
        host = section["host"]?.try(&.as_s?) || "localhost"
        port = section["port"]?.try(&.as_i?) || 3306
        userinfo = build_userinfo(user, password)
        "mysql://#{userinfo}#{host}:#{port}/#{database}"
      else
        nil
      end
    end

    private def self.empty_section(env : String, path : String?) : Section
      Section.new({} of String => YAML::Any, env: env, path: path)
    end

    private def self.normalize_mapping(mapping : Hash(YAML::Any, YAML::Any)) : Hash(String, YAML::Any)
      result = {} of String => YAML::Any
      mapping.each do |key, value|
        result[key.as_s? || key.to_s] = value
      end
      result
    end

    private def self.build_userinfo(user : String?, password : String?) : String
      return "" unless user && !user.empty?
      encoded_user = URI.encode_path_segment(user)
      return "#{encoded_user}@" unless password && !password.empty?
      "#{encoded_user}:#{URI.encode_path_segment(password)}@"
    end
  end
end
