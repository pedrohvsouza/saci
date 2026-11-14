require "./config_file"
require "./server_urls"
require "./deploy/server_config"
require "./deploy/graceful_shutdown"
require "./deploy/environment_check"

module Saci
  # Deployment helpers for the generated scaffold (G138/G139/G141/G142/G144).
  #
  # * `ServerConfig` loads `config/server.yml` (host/port/threads/timeouts).
  # * `GracefulShutdown` drains in-flight requests on SIGTERM/SIGINT.
  # * `environment_checks` / `doctor` validate secrets, the database URL and
  #   writable runtime directories without connecting anywhere.
  # * `boot_summary` prints one structured block at startup.
  #
  # Crystal's stdlib server has no Puma-style cluster/workers; process
  # management is delegated to systemd, Kamal or the container runtime.
  module Deploy
  end

  class Application
    # Like `listen`, but installs SIGTERM/SIGINT handlers and waits for
    # in-flight requests before returning. `listen` is intentionally unchanged
    # for callers that want the raw stdlib behaviour.
    #
    # ```
    # shutdown = Saci::Deploy::GracefulShutdown.new(timeout: 10.seconds)
    # shutdown.on_shutdown { Saci::Job.stop }
    # app.listen_gracefully(3000, "0.0.0.0", shutdown: shutdown)
    # ```
    def listen_gracefully(port : Int32 = 3000, host : String = "127.0.0.1", shutdown : Deploy::GracefulShutdown? = nil, reuse_port : Bool? = nil) : Nil
      boot
      Saci::GCTuner.start_from_env
      settings = Deploy::ServerConfig.current
      graceful = shutdown || Deploy::GracefulShutdown.new(timeout: settings.shutdown_timeout)

      server = Saci::HTTPServer.new(graceful.handler(handler), @config.socket_buffer_size)
      if size = @config.max_headers_size
        server.max_headers_size = size
      end
      if size = @config.max_request_line_size
        server.max_request_line_size = size
      end

      dump_routes_if_requested
      port = Application.bind!(server, host, port, reuse_port.nil? ? settings.reuse_port : reuse_port)
      print Saci::ServerUrls.banner(host, port)
      puts (@router.routes_table + @router.ws_routes_table).join("\n")
      graceful.run(server)
    end
  end
end
