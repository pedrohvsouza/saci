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
  # NOTE: the underlying `HTTP::Client` is not shareable — drive
  # concurrent load with one client (or session) per fiber.
  class TestSession
    getter host : String
    getter port : Int32
    getter application : Application

    # `port: 0` picks an ephemeral port (see `port` afterwards).
    def initialize(router : Router, host : String = "127.0.0.1", port : Int32 = 0,
                   config : Configuration = Saci.config)
      @host = host
      @application = Application.new(router, config)
      @application.boot
      @server = HTTP::Server.new(@application.handler)
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
      @client.exec(method, path, headers, body)
    end

    def get(path : String, headers : HTTP::Headers? = nil) : HTTP::Client::Response
      @client.get(path, headers)
    end

    def head(path : String, headers : HTTP::Headers? = nil) : HTTP::Client::Response
      @client.head(path, headers)
    end

    def options(path : String, headers : HTTP::Headers? = nil, body : HTTP::Client::BodyType = nil) : HTTP::Client::Response
      @client.options(path, headers, body)
    end

    def post(path : String, headers : HTTP::Headers? = nil, body : HTTP::Client::BodyType = nil) : HTTP::Client::Response
      @client.post(path, headers, body)
    end

    def put(path : String, headers : HTTP::Headers? = nil, body : HTTP::Client::BodyType = nil) : HTTP::Client::Response
      @client.put(path, headers, body)
    end

    def patch(path : String, headers : HTTP::Headers? = nil, body : HTTP::Client::BodyType = nil) : HTTP::Client::Response
      @client.patch(path, headers, body)
    end

    def delete(path : String, headers : HTTP::Headers? = nil) : HTTP::Client::Response
      @client.delete(path, headers)
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
