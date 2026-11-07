require "socket"

# The "Local / Network" banner printed when the server starts, in the
# spirit of Vite's dev server:
#
# ```text
# Saci listening on:
#   Local:   http://localhost:3000/
#   Network: http://192.168.15.10:3000/
# ```
#
# Bound to every interface (`0.0.0.0` / `::`, e.g. `saci serve --host`), it
# lists this machine's IPv4 addresses, so another device on the local network
# can open the app. Bound to loopback, it says how to expose it.
module Saci::ServerUrls
  {% unless flag?(:win32) %}
    lib LibSaciIfaddrs
      # struct ifaddrs (same field order on Linux, macOS and the BSDs).
      struct Ifaddrs
        ifa_next : Ifaddrs*
        ifa_name : LibC::Char*
        ifa_flags : LibC::UInt
        ifa_addr : LibC::Sockaddr*
        ifa_netmask : LibC::Sockaddr*
        ifa_dstaddr : LibC::Sockaddr*
        ifa_data : Void*
      end

      fun getifaddrs(ifap : Ifaddrs**) : LibC::Int
      fun freeifaddrs(ifa : Ifaddrs*) : Void
    end
  {% end %}

  IFF_UP       = 0x1_u32
  IFF_LOOPBACK = 0x8_u32

  # Interfaces that only reach containers or VMs on this machine (Docker,
  # libvirt, Podman, CNI plugins), left out of the banner by default.
  VIRTUAL_PREFIXES = {"docker", "br-", "veth", "virbr", "vnet", "cni", "flannel", "cali", "podman", "lxc", "tun", "tap"}

  WILDCARD_HOSTS = {"0.0.0.0", "::", "[::]", ""}

  # {interface name, IPv4 address} of every interface that is up and not
  # loopback. Empty where interfaces cannot be listed.
  def self.interfaces : Array({String, String})
    found = [] of {String, String}
    {% unless flag?(:win32) %}
      head = Pointer(LibSaciIfaddrs::Ifaddrs).null
      return found unless LibSaciIfaddrs.getifaddrs(pointerof(head)) == 0
      begin
        node = head
        until node.null?
          ifa = node.value
          addr = ifa.ifa_addr
          if !addr.null? && addr.value.sa_family == LibC::AF_INET &&
             ifa.ifa_flags & IFF_UP != 0 && ifa.ifa_flags & IFF_LOOPBACK == 0
            ip = Socket::IPAddress.from(addr, sizeof(LibC::SockaddrIn))
            found << {String.new(ifa.ifa_name), ip.address}
          end
          node = ifa.ifa_next
        end
      ensure
        LibSaciIfaddrs.freeifaddrs(head)
      end
    {% end %}
    found
  end

  # IPv4 addresses other devices can reach this machine at: physical and
  # Wi-Fi interfaces first; virtual bridges only when nothing else exists.
  def self.network_addresses(interfaces = self.interfaces) : Array(String)
    real = interfaces.reject { |(name, _)| VIRTUAL_PREFIXES.any? { |p| name.starts_with?(p) } }
    (real.empty? ? interfaces : real).map(&.[1]).uniq
  end

  def self.wildcard?(host : String) : Bool
    WILDCARD_HOSTS.includes?(host)
  end

  def self.loopback?(host : String) : Bool
    host == "localhost" || host == "::1" || host == "[::1]" || host.starts_with?("127.")
  end

  def self.banner(host : String, port : Int32, addresses : Array(String)? = nil, scheme : String = "http") : String
    local = "#{scheme}://localhost:#{port}/"
    String.build do |io|
      io << "Saci listening on:\n"
      if wildcard?(host)
        io << "  Local:   " << local << '\n'
        list = addresses || network_addresses
        if list.empty?
          io << "  Network: no network interface found\n"
        else
          list.each { |ip| io << "  Network: " << scheme << "://" << ip << ':' << port << "/\n" }
        end
      elsif loopback?(host)
        io << "  Local:   " << local << '\n'
        io << "  Network: not exposed (use `saci serve --host` or HOST=0.0.0.0)\n"
      else
        shown = host.includes?(':') && !host.starts_with?('[') ? "[#{host}]" : host
        io << "  Network: " << scheme << "://" << shown << ':' << port << "/\n"
      end
    end
  end
end
