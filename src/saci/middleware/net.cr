module Saci
  module Middleware
    # Small, dependency-free host/IP helpers shared by `HostAuthorization` and
    # `RemoteIp`. Crystal's `Socket::IPAddress` parses addresses but has no
    # CIDR or host-header helpers, so the prefix maths lives here.
    module Net
      LOOPBACK_HOSTS = {"localhost", "127.0.0.1", "::1", "0.0.0.0"}

      # Splits an HTTP `Host` value (or a configured host entry) into a
      # lower-cased host and an optional port. Bracketed IPv6 literals are
      # handled: `[::1]:3000` -> `{"::1", 3000}`.
      def self.split_host_port(value : String) : {String, Int32?}
        value = value.strip
        if value.starts_with?("[") && (close = value.index(']'))
          host = value[1...close].downcase
          rest = value[(close + 1)..]
          port = rest.starts_with?(":") ? rest[1..].to_i? : nil
          return {host, port}
        end

        # One colon means host:port. Multiple colons are an unbracketed IPv6
        # address, which cannot carry a port in a Host header.
        if value.count(':') == 1
          if index = value.rindex(':')
            host = value[0...index]
            port = value[(index + 1)..].to_i?
            if port
              return {host.downcase.rstrip('.'), port}
            end
          end
        end
        {value.downcase.rstrip('.'), nil}
      end

      # Matches a configured host entry against a request host/port.
      #
      # Supported entries:
      # * `example.com` (any port), `example.com:3000` (exact port)
      # * `*.example.com` (one or more subdomain labels, not the apex)
      # * `localhost` (also loopback IPs and `*.localhost`)
      # * IPv4 / bracketed IPv6 literals
      # * `*` (allow all)
      def self.host_entry_matches?(entry : String, host : String, port : Int32?) : Bool
        entry = entry.strip
        return false if entry.empty?

        if scheme_index = entry.index("://")
          entry = entry[(scheme_index + 3)..]
        end
        entry = entry.split('/', 2)[0]
        entry_host, entry_port = split_host_port(entry)
        return false if entry_port && entry_port != port
        return true if entry_host == "*"

        host = host.downcase.rstrip('.')
        if entry_host.starts_with?("*.")
          suffix = entry_host[1..] # ".example.com"
          return host.ends_with?(suffix) && host.size > suffix.size
        end

        if LOOPBACK_HOSTS.includes?(entry_host)
          return LOOPBACK_HOSTS.includes?(host) || host.ends_with?(".localhost")
        end

        entry_host == host
      end

      # Parses an IPv4 or IPv6 literal into its 4/16 network bytes. Returns nil
      # for hostnames, malformed addresses and values carrying a port.
      def self.ip_bytes(value : String) : Bytes?
        value = value.strip
        return nil if value.empty?
        value = value[1...-1] if value.starts_with?("[") && value.ends_with?("]")
        if zone = value.index('%')
          value = value[0...zone]
        end
        return nil if value.includes?('/')
        return nil if value.includes?(':') == false && value.includes?('.') == false

        bytes = value.includes?(':') ? parse_ipv6(value) : parse_ipv4(value)
        return nil unless bytes

        # Canonicalise IPv4-mapped IPv6 (`::ffff:127.0.0.1`) so trusted-proxy
        # comparisons work regardless of how a proxy formats the address.
        if bytes.size == 16 && bytes[0, 10].all?(&.zero?) && bytes[10] == 0xff_u8 && bytes[11] == 0xff_u8
          return bytes[12, 4]
        end
        bytes
      end

      # True when *ip* is one of the configured proxy entries (IP or CIDR).
      def self.trusted_proxy?(ip : String, entries : Array(String)) : Bool
        bytes = ip_bytes(ip)
        return false unless bytes
        entries.any? do |entry|
          entry = entry.strip
          next false if entry.empty?
          if entry.includes?('/')
            in_cidr?(bytes, entry)
          else
            other = ip_bytes(entry)
            other ? other == bytes : false
          end
        end
      end

      # Parses `10.0.0.0/8` / `2001:db8::/32` into `{bytes, prefix_bits}`.
      def self.parse_cidr(entry : String) : {Bytes, Int32}?
        parts = entry.strip.split('/', 2)
        return nil if parts.size > 2
        bytes = ip_bytes(parts[0])
        return nil unless bytes
        max_bits = bytes.size * 8
        bits = parts.size == 2 ? parts[1].to_i? : max_bits
        return nil unless bits
        return nil if bits < 0 || bits > max_bits
        {bytes, bits}
      end

      # Returns the canonical textual form of an IP literal, or nil if the
      # value is not an IP address. Used for `X-Forwarded-For` values.
      def self.normalize_ip(value : String) : String?
        bytes = ip_bytes(value)
        return nil unless bytes
        format_ip(bytes)
      end

      # Convenience used by `RemoteIp`: is *value* a valid IP with an optional
      # `:port` suffix (some proxies append one to X-Forwarded-For entries)?
      def self.normalize_forwarded_ip(value : String) : String?
        value = value.strip
        return nil if value.empty?
        return normalize_ip(value) if ip_bytes(value)

        # `203.0.113.7:41234` (IPv4) and `[2001:db8::1]:41234` (IPv6).
        if value.starts_with?("[") && (close = value.index(']'))
          return normalize_ip(value[1...close])
        end
        if value.count(':') == 1 && (index = value.rindex(':'))
          candidate = value[0...index]
          if candidate.includes?('.') && ip_bytes(candidate)
            return normalize_ip(candidate)
          end
        end
        nil
      end

      private def self.parse_ipv4(value : String) : Bytes?
        parts = value.split('.', remove_empty: false)
        return nil unless parts.size == 4
        bytes = Bytes.new(4)
        parts.each_with_index do |part, index|
          return nil unless part.matches?(/\A\d{1,3}\z/)
          number = part.to_i
          return nil if number > 255
          bytes[index] = number.to_u8
        end
        bytes
      end

      private def self.parse_ipv6(value : String) : Bytes?
        # An embedded IPv4 tail (`::ffff:192.0.2.1`) becomes two hex words.
        if value.includes?('.')
          last_colon = value.rindex(':')
          return nil unless last_colon
          v4 = parse_ipv4(value[(last_colon + 1)..])
          return nil unless v4
          high = ((v4[0].to_i << 8) | v4[1].to_i).to_s(16)
          low = ((v4[2].to_i << 8) | v4[3].to_i).to_s(16)
          value = "#{value[0..last_colon]}#{high}:#{low}"
        end

        if value.includes?("::")
          sides = value.split("::", remove_empty: false)
          return nil if sides.size > 2
          left = sides[0].empty? ? [] of String : sides[0].split(':', remove_empty: true)
          right = sides.size == 2 && !sides[1].empty? ? sides[1].split(':', remove_empty: true) : [] of String
        else
          left = value.split(':', remove_empty: true)
          right = [] of String
        end

        return nil if left.size + right.size > 8
        zeros = 8 - left.size - right.size
        if value.includes?("::")
          return nil if zeros < 1
        else
          return nil unless zeros == 0
        end

        words = [] of Int32
        (left + Array.new(zeros) { "0" } + right).each do |word|
          return nil unless word.matches?(/\A[0-9a-fA-F]{1,4}\z/)
          words << word.to_i(16)
        end
        return nil unless words.size == 8

        bytes = Bytes.new(16)
        words.each_with_index do |word, index|
          bytes[index * 2] = (word >> 8).to_u8
          bytes[index * 2 + 1] = (word & 0xff).to_u8
        end
        bytes
      end

      private def self.in_cidr?(bytes : Bytes, cidr : String) : Bool
        parsed = parse_cidr(cidr)
        return false unless parsed
        network, bits = parsed
        return false unless network.size == bytes.size

        full_bytes = bits // 8
        full_bytes.times do |index|
          return false unless bytes[index] == network[index]
        end
        remaining = bits % 8
        if remaining > 0
          mask = (0xff << (8 - remaining)) & 0xff
          return false unless (bytes[full_bytes].to_i & mask) == (network[full_bytes].to_i & mask)
        end
        true
      end

      private def self.format_ip(bytes : Bytes) : String
        if bytes.size == 4
          return "#{bytes[0]}.#{bytes[1]}.#{bytes[2]}.#{bytes[3]}"
        end

        words = [] of Int32
        (bytes.size // 2).times do |index|
          words << ((bytes[index * 2].to_i << 8) | bytes[index * 2 + 1].to_i)
        end

        # RFC 5952: compress the longest run of at least two zero words.
        best_start = -1
        best_length = 0
        index = 0
        while index < words.size
          if words[index] == 0
            run_start = index
            index += 1
            while index < words.size && words[index] == 0
              index += 1
            end
            run_length = index - run_start
            if run_length >= 2 && run_length > best_length
              best_start = run_start
              best_length = run_length
            end
          else
            index += 1
          end
        end

        String.build do |io|
          index = 0
          while index < words.size
            if index == best_start
              io << "::"
              index += best_length
              next
            end
            io << ':' if index > 0 && index != best_start + best_length
            io << words[index].to_s(16)
            index += 1
          end
        end
      end
    end
  end
end
