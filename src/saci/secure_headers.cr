module Saci
  # Secure response headers, applied to every controller response unless
  # already set (so actions can override). Configure globally:
  #
  # ```
  # Saci::SecureHeaders.configure do |headers|
  #   headers["Content-Security-Policy"] = "default-src 'self'"
  #   headers.delete("X-Frame-Options")
  # end
  # ```
  module SecureHeaders
    DEFAULTS = {
      "X-Frame-Options"        => "SAMEORIGIN",
      "X-Content-Type-Options" => "nosniff",
      "Referrer-Policy"        => "strict-origin-when-cross-origin",
    }

    @@headers : Hash(String, String) = DEFAULTS.dup
    @@mutex = Mutex.new

    def self.configure(& : Hash(String, String) ->) : Nil
      @@mutex.synchronize { yield @@headers }
    end

    def self.headers : Hash(String, String)
      @@mutex.synchronize { @@headers.dup }
    end

    def self.reset! : Nil
      @@mutex.synchronize { @@headers = DEFAULTS.dup }
    end

    def self.apply!(response : HTTP::Server::Response) : Nil
      headers.each do |name, value|
        response.headers[name] = value unless response.headers.has_key?(name)
      end
    end
  end
end
