require "http/client"
require "socket"

module Saci
  # Live-request test helper for request specs — exercises the full
  # router/controller stack over real HTTP without a deployment.
  #
  # NOTE: the underlying `HTTP::Client` is not shareable — drive
  # concurrent load with one client (or session) per fiber.
  #
  # ```
  # router = Saci::Router.new.draw do |r|
  #   r.root HomeController, :index
  # end
  #
  # Saci::TestSession.serve(router) do |app|
  #   resp = app.get("/")
  #   resp.status_code.should eq(200)
  # end
  # ```
  class TestSession
    getter host : String
    getter port : Int32

    # `port: 0` picks an ephemeral port (see `port` afterwards).
    def initialize(router : Router, host : String = "127.0.0.1", port : Int32 = 0)
      @host = host
      @server = HTTP::Server.new(Application.handlers(router))
      @port = @server.bind_tcp(host, port).port
      @client = HTTP::Client.new(host, @port)
      spawn { @server.listen }
      wait_until_ready!
    end

    def self.serve(router : Router, host : String = "127.0.0.1", port : Int32 = 0, & : TestSession ->) : Nil
      session = new(router, host, port)
      begin
        yield session
      ensure
        session.close
      end
    end

    def get(path : String, headers : HTTP::Headers? = nil) : HTTP::Client::Response
      @client.get(path, headers)
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
