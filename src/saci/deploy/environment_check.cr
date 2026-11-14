require "uri"
require "../config_file"
require "../credentials"
require "../deploy/server_config"

module Saci
  module Deploy
    # Raised by `check_environment!` when a required deployment check fails.
    class EnvironmentError < Exception
      getter checks : Array(Check)

      def initialize(@checks : Array(Check))
        failures = @checks.reject(&.ok?).map { |check| "#{check.name}: #{check.detail}" }
        super("Deployment environment check failed:\n  #{failures.join("\n  ")}")
      end
    end

    # One environment check result. `required` separates hard boot failures
    # from advisory warnings in development.
    struct Check
      getter name : String
      getter ok : Bool
      getter detail : String
      getter required : Bool

      def initialize(@name : String, @ok : Bool, @detail : String, @required : Bool = true)
      end

      def ok? : Bool
        @ok
      end

      def label : String
        return "OK" if ok?
        @required ? "FAIL" : "WARN"
      end

      def to_s(io : IO) : Nil
        io << '[' << label << "] " << name << ": " << detail
      end
    end

    # Pre-flight checks for deployment (G141/G142/G144): secret, database URL
    # shape, and writable runtime directories. No network or database
    # connection is attempted.
    def self.environment_checks(db_url : String? = nil, root : String = Saci.root) : Array(Check)
      checks = [] of Check

      checks << check_secret
      checks << check_database(db_url, root)
      {"storage", "log", "tmp"}.each do |dir|
        checks << check_directory(root, dir)
      end
      checks
    end

    # Like `environment_checks`, but raises `EnvironmentError` when any
    # required check fails. Call this from production boot scripts if you want
    # a hard failure instead of doctor output.
    def self.check_environment!(db_url : String? = nil, root : String = Saci.root) : Array(Check)
      checks = environment_checks(db_url, root)
      failures = checks.select { |check| check.required && !check.ok? }
      raise EnvironmentError.new(checks) unless failures.empty?
      checks
    end

    # Prints a doctor report. Returns 0 when all checks pass, 1 otherwise.
    def self.doctor(io : IO = STDOUT, db_url : String? = nil, root : String = Saci.root) : Int32
      checks = environment_checks(db_url, root)
      io.puts "Saci doctor — APP_ENV=#{Saci.env} root=#{root}"
      checks.each { |check| io.puts "  #{check}" }
      failed = checks.count { |check| !check.ok? }
      io.puts ""
      io.puts "#{checks.size} check#{checks.size == 1 ? "" : "s"}, #{failed} failure#{failed == 1 ? "" : "s"}"
      failed == 0 ? 0 : 1
    end

    # Structured boot summary (G141): one compact block instead of scattered
    # puts. Safe to call in every environment; the database URL password is
    # redacted.
    def self.boot_summary(io : IO = STDOUT, app : String? = nil, db_url : String? = nil, server : ServerConfig = ServerConfig.current) : String
      name = app || ENV["SACI_APP"]? || "app"
      database = db_url || configured_database_url
      text = String.build do |summary|
        summary << "Saci " << Saci::VERSION << " boot\n"
        summary << "  app:       " << name << " (" << Saci.env << ")\n"
        summary << "  crystal:   " << Crystal::VERSION << "\n"
        summary << "  root:      " << Saci.root << "\n"
        summary << "  server:    " << server.summary << "\n"
        summary << "  database:  " << (database ? redact_url(database) : "not configured") << "\n"
        summary << "  shutdown:  SIGTERM/SIGINT, " << server.shutdown_timeout.total_seconds.round(1) << "s deadline"
      end
      io.puts text
      text
    end

    # Hides the password in `scheme://user:password@host/...` URLs.
    def self.redact_url(url : String) : String
      url.gsub(/(\A[a-z0-9+.-]+:\/\/[^:\/@]+:)[^@\/]+(@)/i) do |_full, match|
        "#{match[1]}***#{match[2]}"
      end
    rescue
      url
    end

    private def self.check_secret : Check
      if secret = ENV["SECRET_KEY_BASE"]?
        return Check.new("SECRET_KEY_BASE", !secret.empty?, secret.empty? ? "set but empty" : "set (#{secret.size} chars)")
      end

      credentials_secret = begin
        Saci::Credentials.dig("secret_key_base")
      rescue
        nil
      end
      unless credentials_secret.nil? || credentials_secret.empty?
        return Check.new("SECRET_KEY_BASE", true, "read from config/credentials.yml.enc")
      end

      if Saci.env == "production" || Saci.env == "staging"
        Check.new("SECRET_KEY_BASE", false, "not set (required in #{Saci.env}; run `saci secret`)")
      else
        Check.new("SECRET_KEY_BASE", true, "not set; #{Saci.env} uses the generated tmp/.dev_secret fallback")
      end
    end

    private def self.check_database(db_url : String?, root : String) : Check
      url = db_url || configured_database_url
      if url.nil? || url.strip.empty?
        return Check.new("database", false, "DATABASE_URL is not set and config/database.yml has no URL")
      end

      if url.starts_with?("sqlite3://") || url.starts_with?("sqlite://")
        path = url.sub(/\Asqlite3?:\/\//, "")
        path = File.join(root, path) unless path.starts_with?("/")
        if File.exists?(path)
          Check.new("database", File::Info.writable?(path), "SQLite #{path} (#{File::Info.writable?(path) ? "writable" : "read-only"})")
        else
          parent = File.dirname(path)
          ok = Dir.exists?(parent) && File::Info.writable?(parent)
          Check.new("database", ok, "SQLite #{path} (#{ok ? "parent writable" : "parent missing or read-only"})")
        end
      else
        uri = URI.parse(url) rescue nil
        if uri && !uri.host.to_s.empty? && !uri.path.to_s.strip('/').empty?
          Check.new("database", true, "#{uri.scheme}://#{uri.host}#{uri.path} (not connected)")
        else
          Check.new("database", false, "DATABASE_URL is not a usable URL: #{redact_url(url)}")
        end
      end
    end

    private def self.check_directory(root : String, name : String) : Check
      path = File.join(root, name)
      if !Dir.exists?(path)
        Check.new(name, false, "#{path} is missing")
      else
        writable = File::Info.writable?(path)
        Check.new(name, writable, "#{path} (#{writable ? "writable" : "read-only"})")
      end
    end

    private def self.configured_database_url : String?
      ENV["DATABASE_URL"]? || ConfigFile.database_url
    rescue
      ENV["DATABASE_URL"]?
    end
  end
end
