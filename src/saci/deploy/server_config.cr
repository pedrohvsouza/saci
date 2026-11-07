require "yaml"
require "../config_file"

module Saci
  module Deploy
    # HTTP server settings (G138). Saci runs on Crystal's stdlib
    # `HTTP::Server`, which is deliberately simpler than Puma:
    #
    # * there is **no cluster/worker mode** — one OS process owns one server;
    # * `threads` maps to Crystal execution contexts and only takes effect when
    #   the binary was compiled with `-Dexecution_context` (`saci serve --mt`);
    # * keep-alive/request timeouts are recorded for the proxy/process manager
    #   and used by the graceful-shutdown helper. Crystal 1.22's HTTP server
    #   does not expose idle/read timeout setters.
    #
    # The generated `config/server.cr` loads `config/server.yml` for the
    # current `APP_ENV` and then applies env-var overrides:
    #
    # ```
    # Saci::Deploy::ServerConfig.reload!("config/server.yml")
    # server = Saci::Deploy::ServerConfig.current
    # server.host # => "0.0.0.0"
    # ```
    class ServerConfig
      property host : String = "127.0.0.1"
      property port : Int32 = 3000
      property threads : Int32 = 1
      property reuse_port : Bool = false
      property keep_alive_timeout : Time::Span? = 5.seconds
      property request_timeout : Time::Span? = 30.seconds
      property shutdown_timeout : Time::Span = 10.seconds
      property pid_file : String? = nil

      @@current : ServerConfig = ServerConfig.new
      @@mutex = Mutex.new

      # Process-wide settings used by `Application#listen_gracefully`.
      def self.current : ServerConfig
        @@mutex.synchronize { @@current }
      end

      def self.current=(config : ServerConfig) : ServerConfig
        @@mutex.synchronize { @@current = config }
      end

      def self.configure(& : ServerConfig ->) : ServerConfig
        config = current
        yield config
        config
      end

      def self.reset! : ServerConfig
        self.current = ServerConfig.new
      end

      # Reads `path` for `env` and returns a fresh config. A missing file is
      # not an error: every setting keeps its default.
      def self.load(path : String = "config/server.yml", env : String = Saci.env) : ServerConfig
        config = ServerConfig.new
        config.apply_file(path, env)
        config
      end

      # Replaces the process-wide config with the values from `path`.
      def self.reload!(path : String = "config/server.yml", env : String = Saci.env) : ServerConfig
        self.current = load(path, env)
      end

      # Applies a section on top of the current values. Unknown keys are
      # ignored so a newer config file does not break an older framework.
      def apply(section : ConfigFile::Section) : self
        @host = section["host"]?.try(&.as_s?) || @host
        @port = section["port"]?.try(&.as_i?) || @port
        @threads = section["threads"]?.try(&.as_i?) || @threads
        if value = section["reuse_port"]?
          if parsed = value.as_bool?
            @reuse_port = parsed
          end
        end
        if value = section["keep_alive_timeout"]?
          @keep_alive_timeout = parse_duration(value) || @keep_alive_timeout
        end
        if value = section["request_timeout"]?
          @request_timeout = parse_duration(value) || @request_timeout
        end
        if value = section["shutdown_timeout"]?
          @shutdown_timeout = parse_duration(value) || @shutdown_timeout
        end
        @pid_file = section["pid_file"]?.try(&.as_s?) || @pid_file
        self
      end

      def apply_file(path : String, env : String = Saci.env) : self
        return self unless File.exists?(path)
        apply(ConfigFile.config_for(:server, env: env, path: path))
      end

      # True when the binary can actually run `threads` execution contexts.
      # `Saci.enable_multithreading!` is a no-op without the compile flag.
      def compile_time_threads? : Bool
        {% if flag?(:execution_context) || flag?(:preview_mt) %}
          true
        {% else %}
          false
        {% end %}
      end

      # Human-readable one-liner used by the boot summary.
      def summary : String
        String.build do |io|
          io << host << ':' << port
          io << " (threads=" << threads
          io << ", mt=" << (compile_time_threads? ? "compiled" : "single-threaded")
          io << ", reuse_port=" << reuse_port
          io << ", keep_alive=" << format_duration(@keep_alive_timeout)
          io << ", request_timeout=" << format_duration(@request_timeout)
          io << ", shutdown=" << format_duration(@shutdown_timeout) << ')'
        end
      end

      def to_s(io : IO) : Nil
        io << summary
      end

      private def parse_duration(value : YAML::Any) : Time::Span?
        if seconds = value.as_i?
          return seconds.seconds
        end
        if seconds = value.as_f?
          return seconds.seconds
        end
        raw = value.as_s?
        return nil unless raw
        raw = raw.strip
        return nil if raw.empty?
        if raw.ends_with?("ms")
          raw[0...-2].to_f?.try(&.milliseconds)
        elsif raw.ends_with?("s")
          raw[0...-1].to_f?.try(&.seconds)
        elsif raw.ends_with?("m")
          raw[0...-1].to_f?.try(&.minutes)
        else
          raw.to_f?.try(&.seconds)
        end
      end

      private def format_duration(value : Time::Span?) : String
        return "off" unless value
        "#{value.total_seconds.round(1)}s"
      end
    end
  end
end
