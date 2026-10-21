module Saci
  module Middleware
    # Trusted-proxy aware client-IP resolution (Rails `ActionDispatch::RemoteIp`).
    #
    # ```
    # Saci.configure do |config|
    #   config.trusted_proxies = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "::1/128"]
    # end
    # ```
    #
    # Only when the direct peer (`context.remote_address`) is a trusted proxy
    # is `X-Forwarded-For` consulted. The header is walked right-to-left: trusted
    # proxy hops are skipped and the first untrusted address becomes the client.
    # Malformed values are ignored as a whole, and for an untrusted peer the
    # header is never consulted — so a client cannot spoof its address by simply
    # sending `X-Forwarded-For`. `context.remote_address` keeps its original
    # value whenever no trusted resolution happens.
    class RemoteIp
      include HTTP::Handler
      include Conditional

      def initialize(@config : Configuration)
        @trusted_proxies = nil
      end

      def initialize(trusted_proxies : Array(String))
        @config = nil
        @trusted_proxies = trusted_proxies
      end

      def enabled? : Bool
        !trusted_proxies.empty?
      end

      def trusted_proxies : Array(String)
        @trusted_proxies || @config.not_nil!.trusted_proxies
      end

      def call(context : HTTP::Server::Context) : Nil
        return call_next(context) unless enabled?

        peer = context.remote_address
        peer_ip = case peer
                  when Socket::IPAddress then peer.address
                  when Nil                then nil
                  else                         peer.to_s
                  end
        return call_next(context) unless peer_ip
        return call_next(context) unless Net.trusted_proxy?(peer_ip, trusted_proxies)

        forwarded = context.request.headers["X-Forwarded-For"]?
        return call_next(context) unless forwarded && !forwarded.strip.empty?

        hops = forwarded.split(',').map(&.strip).reject(&.empty?)
        client : String? = nil

        hops.reverse_each do |hop|
          ip = Net.normalize_forwarded_ip(hop)
          # One malformed hop makes the whole chain untrustworthy. Falling
          # back to the socket address is safer than guessing.
          return call_next(context) unless ip
          if Net.trusted_proxy?(ip, trusted_proxies)
            next
          else
            client = ip
            break
          end
        end

        # Every hop was a trusted proxy: the left-most value is the client.
        client ||= Net.normalize_forwarded_ip(hops.first)
        if client
          context.remote_address = Socket::IPAddress.new(client, 0)
        end
        call_next(context)
      end
    end
  end
end
