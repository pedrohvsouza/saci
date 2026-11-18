require "http/client"
require "socket"

module Saci
  # Live-request test helper for request specs — exercises the full
  # router/controller/middleware stack over real HTTP without a deployment.
  #
  # A private `Saci::Configuration` can be passed so examples do not mutate the
  # process-wide configuration:
  #
  # ```
  # config = Saci::Configuration.new
  # config.public_file_server.root = "spec/fixtures/public"
  #
  # Saci::TestSession.serve(router, config: config) do |app|
  #   app.get("/assets/app.css")
  # end
  # ```
  #
  # `sign_in_as(user)` logs a user in for the following requests, the way
  # `Controller#login` would, without posting a login form:
  #
  # ```
  # Saci::TestSession.serve(router) do |app|
  #   app.sign_in_as(User.create!(email: "a@example.com", password: "secret123"))
  #   app.get("/posts").status_code.should eq(200)
  # end
  # ```
  #
  # Cookies in `cookies` are sent with every request. Once `track_cookies`
  # is on (`sign_in_as` turns it on), `Set-Cookie` responses update the
  # jar like a browser, so a logout or a session rotation sticks.
  #
  # NOTE: the underlying `HTTP::Client` is not shareable — drive
  # concurrent load with one client (or session) per fiber.
  class TestSession
    getter host : String
    getter port : Int32
    getter application : Application
    # Sent as the `Cookie` header of every request (unless the request
    # passes its own `Cookie` header).
    getter cookies : HTTP::Cookies = HTTP::Cookies.new
    # Stores `Set-Cookie` responses in `cookies`. Off by default, so specs
    # that do not use the jar see every request without a session.
    property? track_cookies : Bool = false

    # `port: 0` picks an ephemeral port (see `port` afterwards).
    def initialize(router : Router, host : String = "127.0.0.1", port : Int32 = 0,
                   config : Configuration = Saci.config)
      @host = host
      @application = Application.new(router, config)
      @application.boot
      @server = Saci::HTTPServer.new(@application.handler, Saci.config.socket_buffer_size)
      @port = @server.bind_tcp(host, port).port
      @client = HTTP::Client.new(host, @port)
      spawn { @server.listen }
      wait_until_ready!
    end

    def self.serve(router : Router, host : String = "127.0.0.1", port : Int32 = 0,
                   config : Configuration = Saci.config, & : TestSession ->) : Nil
      session = new(router, host, port, config)
      begin
        yield session
      ensure
        session.close
      end
    end

    # Generic escape hatch for methods without a dedicated helper.
    def request(method : String, path : String, headers : HTTP::Headers? = nil,
                body : HTTP::Client::BodyType = nil) : HTTP::Client::Response
      exec(method, path, headers, body)
    end

    def get(path : String, headers : HTTP::Headers? = nil) : HTTP::Client::Response
      exec("GET", path, headers)
    end

    def head(path : String, headers : HTTP::Headers? = nil) : HTTP::Client::Response
      exec("HEAD", path, headers)
    end

    def options(path : String, headers : HTTP::Headers? = nil, body : HTTP::Client::BodyType = nil) : HTTP::Client::Response
      exec("OPTIONS", path, headers, body)
    end

    def post(path : String, headers : HTTP::Headers? = nil, body : HTTP::Client::BodyType = nil) : HTTP::Client::Response
      exec("POST", path, headers, body)
    end

    def put(path : String, headers : HTTP::Headers? = nil, body : HTTP::Client::BodyType = nil) : HTTP::Client::Response
      exec("PUT", path, headers, body)
    end

    def patch(path : String, headers : HTTP::Headers? = nil, body : HTTP::Client::BodyType = nil) : HTTP::Client::Response
      exec("PATCH", path, headers, body)
    end

    def delete(path : String, headers : HTTP::Headers? = nil) : HTTP::Client::Response
      exec("DELETE", path, headers)
    end

    # Logs `user` in for the following requests: writes the session
    # `Controller#login` would (the id under `Saci::Auth.session_key`, plus
    # `session_token` when the record has one) through the active
    # `Session.store`, puts its cookie in `cookies` and turns on
    # `track_cookies`. Duck-typed like `login`: any object with `id` works.
    def sign_in_as(user) : self
      data = {} of String => JSON::Any
      data[Saci::Auth.session_key.to_s] = case raw = user.id
                                          when Int    then JSON::Any.new(raw.to_i64)
                                          when String then JSON::Any.new(raw)
                                          else             JSON::Any.new(raw.to_s)
                                          end
      if user.responds_to?(:session_token)
        data[Saci::Auth.token_key.to_s] = JSON::Any.new(user.session_token.to_s)
      end
      payload = Session.store.commit(Session.generate_id, data)
      @cookies << HTTP::Cookie.new(Session::COOKIE_KEY, payload, path: "/")
      @track_cookies = true
      self
    end

    # Forgets the session cookie (the next requests are anonymous).
    def sign_out : self
      @cookies.delete(Session::COOKIE_KEY)
      self
    end

    private def exec(method : String, path : String, headers : HTTP::Headers?, body : HTTP::Client::BodyType = nil) : HTTP::Client::Response
      unless @cookies.empty? || headers.try(&.has_key?("Cookie"))
        headers = headers ? headers.dup : HTTP::Headers.new
        @cookies.add_request_headers(headers)
      end
      response = @client.exec(method, path, headers, body)
      store_cookies(response) if @track_cookies
      response
    end

    private def store_cookies(response : HTTP::Client::Response) : Nil
      response.cookies.each do |cookie|
        if cookie.expired? || cookie.value.empty?
          @cookies.delete(cookie.name)
        else
          @cookies << HTTP::Cookie.new(cookie.name, cookie.value, path: cookie.path || "/")
        end
      end
    end

    def close : Nil
      @client.close
      @server.close
    rescue
      # Already closed — harmless in teardown paths.
    end

    private def wait_until_ready! : Nil
      deadline = Time.instant + 5.seconds
      loop do
        begin
          TCPSocket.new(@host, @port).close
          return
        rescue Socket::ConnectError
          raise "Saci::TestSession server did not boot in time" if Time.instant > deadline
          sleep 0.02.seconds
        end
      end
    end
  end
end
