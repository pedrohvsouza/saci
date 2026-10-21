module Saci
  module Middleware
    # Host allowlist (Rails `ActionDispatch::HostAuthorization`).
    #
    # ```
    # Saci.configure do |config|
    #   config.hosts = ["example.com", "www.example.com", "10.0.0.0/8"]
    # end
    # ```
    #
    # An empty list disables the check (the historical Saci behaviour). Entries
    # may include a port and support `*` (any host) and `*.example.com`
    # (subdomains). `localhost` also permits loopback IPv4/IPv6 and
    # `*.localhost`. A missing `Host` header is allowed for HTTP/1.0 clients;
    # present-but-disallowed hosts receive `403`.
    class HostAuthorization
      include HTTP::Handler
      include Conditional

      def initialize(@config : Configuration)
        @hosts = nil
      end

      # Standalone constructor useful in specs or when the middleware is built
      # manually instead of through `Saci.configure`.
      def initialize(hosts : Array(String))
        @config = nil
        @hosts = hosts
      end

      def enabled? : Bool
        if config = @config
          return false unless config.host_authorization
        end
        !hosts.empty?
      end

      def hosts : Array(String)
        @hosts || @config.not_nil!.hosts
      end

      def allowed?(host_header : String?) : Bool
        return true unless host_header
        return true if hosts.empty?
        host, port = Net.split_host_port(host_header)
        return false if host.empty?
        hosts.any? { |entry| Net.host_entry_matches?(entry, host, port) }
      end

      def call(context : HTTP::Server::Context) : Nil
        return call_next(context) unless enabled?
        host_header = context.request.headers["Host"]?
        if allowed?(host_header)
          call_next(context)
        else
          host = host_header || "(missing)"
          Middleware.respond_text(context.response, 403, "Blocked host: #{host}")
        end
      end
    end
  end
end
