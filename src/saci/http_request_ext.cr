require "http/server"
require "uri"

# Rails-style request host helpers (`request.host`, `request.domain`,
# `request.subdomain`, `request.port`, `request.host_with_port`,
# `request.ssl?`). Crystal's `HTTP::Request` only exposes `uri`; server
# requests carry the authority in the `Host` header, with the scheme
# possibly overridden by a reverse proxy's `X-Forwarded-Proto`.
#
# Only the common cases are modeled: the public-suffix list is not bundled,
# so `domain`/`subdomain` use the Rails `tld_length:` approximation
# (`example.co.uk` needs `tld_length: 2`).
class HTTP::Request
  # Authority without a port (`Host` header, else the request URI).
  def host : String
    raw = saci_host_header
    return "localhost" if raw.nil? || raw.empty?
    if raw.starts_with?("[")
      close = raw.index(']') || raw.size
      return raw[1...close]
    end
    raw.split(':', 2).first
  end

  # `Host` header as sent (includes a non-default port when present).
  def host_with_port : String
    raw = saci_host_header
    return host if raw.nil? || raw.empty?
    raw
  end

  # Explicit port from `Host`, else the URI, else the scheme default.
  def port : Int32
    raw = saci_host_header
    if raw
      if raw.starts_with?("[")
        if close = raw.index(']')
          rest = raw[(close + 1)..]?
          if rest && rest.starts_with?(":") && !rest[1..].empty?
            return rest[1..].to_i? || saci_default_port
          end
        end
      elsif raw.count(':') == 1
        port_part = raw.split(':', 2)[1]
        return port_part.to_i? || saci_default_port unless port_part.empty?
      end
    end
    uri.port || saci_default_port
  rescue
    saci_default_port
  end

  # `www.example.com` -> `example.com`; IP literals are returned unchanged.
  # Pass `tld_length: 2` for `example.co.uk`.
  def domain(tld_length : Int32 = 1) : String
    h = host
    return h if saci_ip_address?(h)
    labels = h.split('.')
    return h if labels.size <= tld_length + 1
    labels[(labels.size - tld_length - 1)..].join('.')
  end

  # All labels before the registrable domain (`dev.api.example.com` ->
  # `dev.api`); empty for a bare domain or IP literal.
  def subdomain(tld_length : Int32 = 1) : String
    h = host
    return "" if saci_ip_address?(h)
    labels = h.split('.')
    return "" if labels.size <= tld_length + 1
    labels[0...(labels.size - tld_length - 1)].join('.')
  end

  # True when the request reached us over TLS, including reverse-proxy
  # termination signalled through `X-Forwarded-Proto`.
  def ssl? : Bool
    if proto = headers["X-Forwarded-Proto"]?
      first = proto.split(',').first.strip.downcase
      return true if first == "https"
      return false if first == "http"
    end
    return true if uri.scheme.try(&.downcase) == "https"
    uri.to_s.starts_with?("https://")
  end

  def protocol : String
    ssl? ? "https" : "http"
  end

  private def saci_host_header : String?
    headers["Host"]?.try(&.strip)
  end

  private def saci_default_port : Int32
    uri.scheme.try(&.downcase) == "https" ? 443 : 80
  end

  private def saci_ip_address?(value : String) : Bool
    return true if value.includes?(':') # IPv6
    value.matches?(/\A\d{1,3}(\.\d{1,3}){3}\z/)
  end
end
