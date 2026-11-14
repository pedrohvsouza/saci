require "uri"

module Saci
  # Development-time check for markup the response's own
  # Content-Security-Policy will block. Browsers only report CSP violations
  # in their console, so a page with an inline `<style>`, a `style="..."`
  # attribute or a Google Fonts stylesheet renders without any server-side
  # sign that something is off. Each problem is logged once per path:
  #
  # ```text
  # CSP: GET / has an inline <style> without a nonce, blocked by style-src 'self'. ...
  # ```
  #
  # On by default in development only; `Saci::SecureHeaders.csp_warnings = true/false`
  # forces it. The scan is heuristic (regular expressions over the HTML
  # body), so it may miss markup built at runtime by JavaScript.
  module SecureHeaders
    @@csp_warnings : Bool? = nil
    @@csp_warned = Set(String).new
    @@csp_warned_mutex = Mutex.new
    CSP_WARNED_LIMIT = 1000

    STYLE_ELEMENT_RE     = /<style\b([^>]*)>/i
    SCRIPT_ELEMENT_RE    = /<script\b([^>]*)>/i
    LINK_ELEMENT_RE      = /<link\b([^>]*)>/i
    IMG_ELEMENT_RE       = /<img\b([^>]*)>/i
    STYLE_ATTRIBUTE_RE   = /<[a-z][a-z0-9-]*\b[^>]*?\sstyle\s*=/i
    HANDLER_ATTRIBUTE_RE = /<[a-z][a-z0-9-]*\b[^>]*?\son[a-z]+\s*=/i

    # nil = automatic (development only).
    def self.csp_warnings? : Bool
      value = @@csp_warnings
      value.nil? ? Saci.development? : value
    end

    def self.csp_warnings=(value : Bool?) : Nil
      @@csp_warnings = value
    end

    # Forgets which warnings were already logged (spec isolation).
    def self.reset_csp_warnings! : Nil
      @@csp_warned_mutex.synchronize { @@csp_warned.clear }
    end

    # Logs (once per path and problem) what *policy* would block in *html*.
    def self.warn_csp_violations(request : HTTP::Request, response : HTTP::Server::Response, html : String) : Nil
      return unless csp_warnings?
      policy = response.headers[CSP_HEADER]?
      return if policy.nil? || policy.strip.empty?
      label = "#{request.method} #{request.path}"
      csp_violations(policy, html, request.headers["Host"]?).each do |problem|
        key = "#{label}|#{problem}"
        fresh = @@csp_warned_mutex.synchronize do
          next false if @@csp_warned.includes?(key)
          @@csp_warned.clear if @@csp_warned.size >= CSP_WARNED_LIMIT
          @@csp_warned << key
          true
        end
        Saci.logger.warn { "CSP: #{label} #{problem}" } if fresh
      end
    rescue
      # A heuristic warning must never break a response.
    end

    # Problems *policy* causes for *html*, as human-readable sentences.
    # `host` (the request's `Host`) lets absolute same-origin URLs count as
    # `'self'`.
    def self.csp_violations(policy : String, html : String, host : String? = nil) : Array(String)
      directives = parse_csp(policy)
      problems = [] of String

      if sources = csp_directive(directives, "style-src-elem", "style-src", "default-src")
        html.scan(STYLE_ELEMENT_RE) do |match|
          next if csp_inline_allowed?(sources, csp_attribute(match[1], "nonce"))
          problems << "has an inline <style> without a nonce, blocked by #{csp_describe(directives, "style-src-elem", "style-src", "default-src")}. " \
                      "Move it to a stylesheet, or add 'nonce' to style-src and nonce=\"<%= csp_nonce %>\" to the tag."
          break
        end
        html.scan(LINK_ELEMENT_RE) do |match|
          attrs = match[1]
          next unless (csp_attribute(attrs, "rel") || "").downcase.split.includes?("stylesheet")
          next unless href = csp_attribute(attrs, "href")
          next unless url = csp_external_url(href, host)
          next if csp_url_allowed?(sources, url)
          problems << "loads the stylesheet #{href} from #{csp_origin(url)}, blocked by #{csp_describe(directives, "style-src-elem", "style-src", "default-src")}. " \
                      "Add #{csp_origin(url)} to style-src."
          if url.host.try(&.downcase) == "fonts.googleapis.com"
            fonts = csp_directive(directives, "font-src", "default-src")
            gstatic = URI.parse("https://fonts.gstatic.com/")
            if fonts && !csp_url_allowed?(fonts, gstatic)
              problems << "uses Google Fonts; the font files come from https://fonts.gstatic.com, which #{csp_describe(directives, "font-src", "default-src")} blocks. " \
                          "Add https://fonts.gstatic.com to font-src."
            end
          end
        end
      end

      if sources = csp_directive(directives, "style-src-attr", "style-src", "default-src")
        if html.matches?(STYLE_ATTRIBUTE_RE) && !csp_inline_allowed?(sources, nil)
          problems << "has style=\"...\" attributes, which #{csp_describe(directives, "style-src-attr", "style-src", "default-src")} blocks (nonces do not cover attributes). " \
                      "Move the rules into a stylesheet (CSS classes or custom properties set there)."
        end
      end

      if sources = csp_directive(directives, "script-src-elem", "script-src", "default-src")
        reported_inline = false
        html.scan(SCRIPT_ELEMENT_RE) do |match|
          attrs = match[1]
          if src = csp_attribute(attrs, "src")
            next unless url = csp_external_url(src, host)
            next if csp_url_allowed?(sources, url)
            problems << "loads the script #{src} from #{csp_origin(url)}, blocked by #{csp_describe(directives, "script-src-elem", "script-src", "default-src")}. " \
                        "Add #{csp_origin(url)} to script-src."
          else
            next if reported_inline
            type = (csp_attribute(attrs, "type") || "").downcase
            # Data blocks (JSON, import maps are scripts though) never execute.
            next if type == "application/json" || type == "application/ld+json" || type == "text/template"
            next if csp_inline_allowed?(sources, csp_attribute(attrs, "nonce"))
            reported_inline = true
            problems << "has an inline <script> without a nonce, blocked by #{csp_describe(directives, "script-src-elem", "script-src", "default-src")}. " \
                        "Move it to a file, or add 'nonce' to script-src and nonce=\"<%= csp_nonce %>\" to the tag."
          end
        end
      end

      if sources = csp_directive(directives, "script-src-attr", "script-src", "default-src")
        if html.matches?(HANDLER_ATTRIBUTE_RE) && !csp_inline_allowed?(sources, nil)
          problems << "has inline event handlers (onclick=...), which #{csp_describe(directives, "script-src-attr", "script-src", "default-src")} blocks. " \
                      "Attach the handlers from a script file instead."
        end
      end

      if sources = csp_directive(directives, "img-src", "default-src")
        html.scan(IMG_ELEMENT_RE) do |match|
          next unless src = csp_attribute(match[1], "src")
          next unless url = csp_external_url(src, host)
          next if csp_url_allowed?(sources, url)
          problems << "loads the image #{src} from #{csp_origin(url)}, blocked by #{csp_describe(directives, "img-src", "default-src")}. " \
                      "Add #{csp_origin(url)} to img-src."
        end
      end

      problems.uniq
    end

    # `"default-src 'self'; style-src 'self' https:"` -> directive => sources.
    def self.parse_csp(policy : String) : Hash(String, Array(String))
      directives = {} of String => Array(String)
      policy.split(';').each do |part|
        tokens = part.strip.split(/\s+/).reject(&.empty?)
        next if tokens.empty?
        name = tokens.shift.downcase
        directives[name] = tokens unless directives.has_key?(name)
      end
      directives
    end

    private def self.csp_directive(directives : Hash(String, Array(String)), *names : String) : Array(String)?
      names.each { |name| return directives[name] if directives.has_key?(name) }
      nil
    end

    private def self.csp_describe(directives : Hash(String, Array(String)), *names : String) : String
      names.each do |name|
        if sources = directives[name]?
          return sources.empty? ? name : "#{name} #{sources.join(' ')}"
        end
      end
      names.last
    end

    # Inline content runs only with `'unsafe-inline'` and no nonce/hash
    # source (their presence disables `'unsafe-inline'`), or with a nonce
    # that matches the element's.
    private def self.csp_inline_allowed?(sources : Array(String), nonce : String?) : Bool
      lowered = sources.map(&.downcase)
      if nonce && !nonce.empty?
        return true if sources.includes?("'nonce-#{nonce}'")
      end
      has_nonce_or_hash = lowered.any? { |s| s.starts_with?("'nonce-") || s.starts_with?("'sha256-") || s.starts_with?("'sha384-") || s.starts_with?("'sha512-") }
      lowered.includes?("'unsafe-inline'") && !has_nonce_or_hash
    end

    private def self.csp_url_allowed?(sources : Array(String), url : URI) : Bool
      scheme = (url.scheme || "https").downcase
      host = (url.host || "").downcase
      sources.any? do |raw|
        source = raw.downcase
        case source
        when "*"
          {"http", "https", "ws", "wss"}.includes?(scheme)
        when "'none'", "'self'", "'unsafe-inline'", "'unsafe-eval'", "'strict-dynamic'", "'unsafe-hashes'", "'report-sample'", "'wasm-unsafe-eval'"
          false
        else
          if source.ends_with?(':') && !source.includes?('/')
            source.rchop == scheme || (source == "http:" && scheme == "https")
          elsif source.starts_with?('\'')
            false
          else
            csp_host_source_matches?(source, scheme, host)
          end
        end
      end
    end

    private def self.csp_host_source_matches?(source : String, scheme : String, host : String) : Bool
      rest = source
      if idx = rest.index("://")
        source_scheme = rest[0, idx]
        rest = rest[(idx + 3)..]
        return false unless source_scheme == scheme || (source_scheme == "http" && scheme == "https")
      end
      source_host = rest.split('/', 2).first.split(':', 2).first
      return false if source_host.empty?
      if source_host.starts_with?("*.")
        host.ends_with?(source_host[1..])
      else
        host == source_host
      end
    end

    # Absolute URL for *value* when it points at another origin; nil for
    # relative and same-origin URLs (both covered by `'self'`).
    private def self.csp_external_url(value : String, host : String?) : URI?
      candidate = value.strip
      candidate = "https:#{candidate}" if candidate.starts_with?("//")
      return nil unless candidate.starts_with?("http://") || candidate.starts_with?("https://")
      url = URI.parse(candidate)
      url_host = url.host
      return nil if url_host.nil?
      if request_host = host
        return nil if request_host.downcase == url_host.downcase || request_host.downcase.split(':').first == url_host.downcase
      end
      url
    rescue URI::Error
      nil
    end

    private def self.csp_origin(url : URI) : String
      "#{url.scheme}://#{url.host}#{url.port ? ":#{url.port}" : ""}"
    end

    private def self.csp_attribute(attrs : String, name : String) : String?
      if match = attrs.match(/(?:\A|\s)#{name}\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/i)
        match[1]? || match[2]? || match[3]?
      end
    end
  end
end
