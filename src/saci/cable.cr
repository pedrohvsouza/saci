require "json"
require "mutex"
require "random"
require "socket"
require "uri"

module Saci
  # ActionCable-style WebSocket support (in-process pub/sub by default,
  # Redis fan-out across processes with `Cable::RedisServer`).
  #
  # ```
  # class ChatChannel < Saci::Cable::Channel
  #   def subscribed
  #     stream_from "room:#{params["room"]}"
  #   end
  #
  #   def receive(data)
  #     Saci::Cable.broadcast("room:#{params["room"]}", {from: params["user"], text: data["text"]})
  #   end
  # end
  #
  # router = Saci::Router.new.draw do |r|
  #   r.cable "/cable", ChatChannel
  # end
  #
  # # Multi-process deploys (kills the sticky-session caveat):
  # Saci::Cable.server = Saci::Cable::RedisServer.new(ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379"))
  # ```
  #
  # Wire protocol (ActionCable-compatible subset, JSON frames):
  # * client → `{"command":"subscribe","identifier":"{\"channel\":\"ChatChannel\",...}"}`
  # * client → `{"command":"message","identifier":"...","data":"{...}"}`
  #   (`data` may be a JSON-encoded string or a raw object)
  # * client → `{"command":"unsubscribe","identifier":"..."}`
  # * server → `{"type":"welcome"}`,
  #   `{"type":"confirm_subscription","identifier":"..."}`,
  #   `{"type":"reject_subscription","identifier":"..."}`,
  #   `{"identifier":"...","message":{...}}`
  module Cable
    # Global default server. Lazily created under a lock so concurrent
    # first touches never build two registries.
    @@server : Server? = nil
    @@server_mutex = Mutex.new

    def self.server : Server
      @@server || @@server_mutex.synchronize { @@server ||= Server.new }
    end

    def self.server=(server : Server) : Nil
      @@server = server
    end

    def self.broadcast(stream : String, payload) : Nil
      server.broadcast(stream, payload)
    end

    # Builds the identifier JSON clients send (`{"channel":"X",...}`).
    def self.identifier_for(channel : String, params : Hash(String, String) = {} of String => String) : String
      {"channel" => channel}.merge(params).to_json
    end

    # Raised by `Channel#reject`; aborts the subscription (client gets
    # `reject_subscription`).
    class RejectedError < Exception
    end

    # One per websocket connection. Owns the send lock and tracks the
    # connection's subscriptions for cleanup on close.
    class Connection
      getter socket : HTTP::WebSocket
      getter params : Saci::Params
      getter server : Server

      @send_mutex = Mutex.new
      @track_mutex = Mutex.new
      @subscriptions : Array(Subscription) = [] of Subscription

      def initialize(@socket : HTTP::WebSocket, @params : Saci::Params, @server : Server)
      end

      def send_json(payload) : Nil
        text = payload.to_json
        @send_mutex.synchronize { @socket.send(text) }
      rescue IO::Error
        # Peer is gone; `on_close` performs cleanup.
      end

      def close : Nil
        @socket.close
      rescue IO::Error
      end

      def track(sub : Subscription) : Nil
        @track_mutex.synchronize { @subscriptions << sub }
      end

      def untrack(sub : Subscription) : Nil
        @track_mutex.synchronize { @subscriptions.delete(sub) }
      end

      def find_subscription(identifier : String) : Subscription?
        @track_mutex.synchronize { @subscriptions.find { |s| s.identifier == identifier } }
      end

      def drain_subscriptions : Array(Subscription)
        @track_mutex.synchronize do
          drained = @subscriptions.dup
          @subscriptions.clear
          drained
        end
      end
    end

    struct Subscription
      getter stream : String
      getter identifier : String
      getter channel : Channel

      def initialize(@stream : String, @identifier : String, @channel : Channel)
      end
    end

    # Raised when the Redis hop is unreachable. Broadcast/publish paths
    # never propagate it (they degrade to local-only delivery with a
    # STDERR warning); it surfaces from direct client calls and is
    # translated by `Throttle::RedisStore` into `Throttle::RedisDown`.
    class RedisDown < Exception
    end

    # Minimal pure-socket Redis wire client (RESP2, no shard dependency,
    # no OpenSSL linkage — plain `TCPSocket` only, so default SQLite builds
    # link exactly as before). Shared by `Cable::RedisServer` and
    # `Throttle::RedisStore` (`throttle.cr` reuses it as
    # `Saci::Cable::RedisWire` since `saci.cr` requires cable first).
    module RedisWire
      alias RedisValue = String | Int64 | Array(RedisValue) | Nil

      struct Info
        getter host : String
        getter port : Int32
        getter user : String?
        getter password : String?
        getter db : Int32?

        def initialize(@host : String, @port : Int32, @user : String? = nil, @password : String? = nil, @db : Int32? = nil)
        end
      end

      # Parses `redis://[:password@]host:port/db` (`REDIS_URL` shape).
      # Username (`redis://user:pass@...`, for ACLs) is honored via AUTH.
      def self.parse_url(url : String) : Info
        uri = URI.parse(url)
        unless uri.scheme == "redis"
          raise RedisDown.new("redis: unsupported URL scheme #{uri.scheme.inspect} (want redis://host:port/db)")
        end
        raw_host = uri.host
        host = (raw_host.nil? || raw_host.empty?) ? "127.0.0.1" : raw_host
        port = uri.port || 6379
        db = nil
        if (path = uri.path) && !path.empty? && path != "/"
          stripped = path.lstrip("/")
          if stripped.empty?
            db = nil
          elsif n = stripped.to_i?
            db = n
          else
            raise RedisDown.new("redis: bad database in URL path #{path.inspect}")
          end
        end
        Info.new(host, port, uri.user, uri.password, db)
      end

      # Encodes a command in RESP2 framing (unit-specced without a server).
      def self.encode(args : Array(String)) : String
        String.build do |io|
          io << "*" << args.size << "\r\n"
          args.each do |a|
            io << "$" << a.bytesize << "\r\n"
            io << a << "\r\n"
          end
        end
      end

      # Parses one RESP2 reply from `io` (unit-specced via `IO::Memory`).
      # Error replies (`-...`) raise `RedisDown`.
      def self.read_reply(io : IO) : RedisValue
        line = io.gets
        raise RedisDown.new("redis: connection closed") if line.nil?
        line = line.chomp
        raise RedisDown.new("redis: empty reply") if line.empty?
        case line[0]
        when '+'
          line[1..]
        when '-'
          raise RedisDown.new("redis error: #{line[1..]}")
        when ':'
          line[1..].to_i64? || raise RedisDown.new("redis: bad integer reply #{line.inspect}")
        when '$'
          len = line[1..].to_i? || raise RedisDown.new("redis: bad bulk length #{line.inspect}")
          return nil if len < 0
          buf = Bytes.new(len + 2)
          io.read_fully(buf)
          String.new(buf[0, len])
        when '*'
          n = line[1..].to_i? || raise RedisDown.new("redis: bad array length #{line.inspect}")
          return nil if n < 0
          arr = [] of RedisValue
          n.times { arr << read_reply(io) }
          arr
        else
          raise RedisDown.new("redis: bad reply type #{line.inspect}")
        end
      rescue ex : RedisDown
        raise ex
      rescue ex : IO::Error
        raise RedisDown.new("redis: io error (#{ex.message})")
      end

      # One synchronous connection. Command connections are mutex-guarded
      # and fail fast (`timeout`); subscriber connections block forever in
      # `#subscribe` and must be dedicated (never shared with `#call`).
      class Conn
        def initialize(@info : Info, @timeout : Time::Span = 2.seconds, subscriber : Bool = false)
          @mutex = Mutex.new
          @sock = uninitialized TCPSocket
          @subscriber = subscriber
          connect!
        end

        def call(*args : String) : RedisValue
          call(args.to_a)
        end

        def call(args : Array(String)) : RedisValue
          @mutex.synchronize do
            write_cmd(args)
            RedisWire.read_reply(@sock)
          end
        end

        # SUBSCRIBEs and yields each published payload until the connection
        # breaks (raises `RedisDown`). `on_subscribed` fires once the
        # server confirms the subscription (lets owners reset backoff).
        def subscribe(channel : String, on_subscribed : -> Nil = -> { }, & : String -> Nil) : Nil
          write_cmd(["SUBSCRIBE", channel])
          RedisWire.read_reply(@sock)
          on_subscribed.call
          loop do
            msg = RedisWire.read_reply(@sock)
            if arr = msg.as?(Array(RedisValue))
              next unless arr.size == 3
              next unless arr[0] == "message"
              if payload = arr[2].as?(String)
                yield payload
              end
            end
          end
        end

        def close : Nil
          begin
            @sock.close
          rescue
          end
        end

        private def connect! : Nil
          begin
            sock = TCPSocket.new(@info.host, @info.port, connect_timeout: @timeout)
            unless @subscriber
              sock.read_timeout = @timeout
              sock.write_timeout = @timeout
            end
            @sock = sock
            if pw = @info.password
              if user = @info.user
                RedisWire.read_reply_expect_ok(@sock, ["AUTH", user, pw])
              else
                RedisWire.read_reply_expect_ok(@sock, ["AUTH", pw])
              end
            end
            if db = @info.db
              RedisWire.read_reply_expect_ok(@sock, ["SELECT", db.to_s])
            end
          rescue ex : RedisDown
            raise ex
          rescue ex : IO::Error
            raise RedisDown.new("redis: cannot connect to #{@info.host}:#{@info.port} (#{ex.message})")
          end
        end

        private def write_cmd(args : Array(String)) : Nil
          @sock.write(RedisWire.encode(args).to_slice)
        rescue ex : IO::Error
          raise RedisDown.new("redis: write failed (#{ex.message})")
        end
      end

      # Sends a command and discards the reply unless it is an error
      # (errors raise `RedisDown` via `read_reply`).
      protected def self.read_reply_expect_ok(sock : TCPSocket, args : Array(String)) : Nil
        sock.write(encode(args).to_slice)
        read_reply(sock)
        nil
      end
    end

    # In-process pub/sub registry. One instance serves any number of
    # connections/channels; all mutations are mutex-guarded.
    class Server
      def initialize
        @streams = Hash(String, Array(Subscription)).new { |h, k| h[k] = [] of Subscription }
        @mutex = Mutex.new
      end

      # Instantiates the channel and runs `#subscribed`. Returns nil when
      # the subscription was rejected or failed (client already notified).
      def subscribe(channel_class : Channel.class, connection : Connection, identifier : String, params : Hash(String, JSON::Any)) : Channel?
        channel = channel_class.new(connection, identifier, params)
        begin
          channel.subscribed
        rescue RejectedError
          connection.send_json({type: "reject_subscription", identifier: identifier})
          return nil
        rescue
          connection.close
          return nil
        end
        connection.send_json({type: "confirm_subscription", identifier: identifier})
        channel
      end

      # Removes one subscription (client `unsubscribe`), running the
      # channel's `#unsubscribed` hook.
      def unsubscribe(connection : Connection, identifier : String) : Nil
        if sub = connection.find_subscription(identifier)
          remove_subscription(connection, sub, run_hook: true)
        end
      end

      # Removes every subscription of a closing connection.
      def unsubscribe_connection(connection : Connection) : Nil
        connection.drain_subscriptions.each do |sub|
          remove_subscription(connection, sub, run_hook: true)
        end
      end

      # Delivers `payload` to every subscriber of `stream` on this
      # process. (`RedisServer` overrides this to fan out remotely too;
      # remote arrivals re-enter through `#deliver_local`.)
      def broadcast(stream : String, payload) : Nil
        deliver_local(stream, payload)
      end

      # Fan-out to this process's subscribers only (no Redis hop).
      def deliver_local(stream : String, payload) : Nil
        subs = @mutex.synchronize { @streams[stream].dup }
        subs.each do |sub|
          begin
            sub.channel.deliver(sub.identifier, payload)
          rescue
            remove_subscription(sub.channel.connection, sub, run_hook: false)
          end
        end
      end

      def add_stream(connection : Connection, stream : String, identifier : String, channel : Channel) : Nil
        sub = Subscription.new(stream, identifier, channel)
        @mutex.synchronize { @streams[stream] << sub }
        connection.track(sub)
      end

      def remove_stream(stream : String, channel : Channel) : Nil
        sub = nil
        @mutex.synchronize do
          if found = @streams[stream].find { |s| s.channel.same?(channel) }
            @streams[stream].delete(found)
            sub = found
          end
        end
        channel.connection.untrack(sub) if sub
      end

      def remove_channel(channel : Channel) : Nil
        leftovers = [] of Subscription
        @mutex.synchronize do
          @streams.each_value do |subs|
            subs.reject! do |s|
              if s.channel.same?(channel)
                leftovers << s
                true
              else
                false
              end
            end
          end
        end
        leftovers.each { |s| channel.connection.untrack(s) }
      end

      private def remove_subscription(connection : Connection, sub : Subscription, run_hook : Bool) : Nil
        @mutex.synchronize { @streams[sub.stream].delete(sub) }
        connection.untrack(sub)
        if run_hook
          begin
            sub.channel.unsubscribed
          rescue
          end
        end
      end
    end

    # Redis-backed pub/sub: same local registry as `Server`, plus a
    # PUBLISH/SUBSCRIBE hop so any number of processes on one Redis fan
    # out to each other (no sticky sessions).
    #
    # ```
    # Saci::Cable.server = Saci::Cable::RedisServer.new(ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379"))
    # ```
    #
    # Design:
    # * one Redis channel (`redis_channel`, default `"saci:cable"`)
    #   multiplexes every stream via a JSON envelope
    #   `{"sender": <server id>, "stream": ..., "message": ...}`;
    # * `#broadcast` delivers locally, then publishes; the sender's own
    #   echo is skipped by id (already delivered);
    # * a background fiber holds the SUBSCRIBE connection and reconnects
    #   with backoff (0.1s doubling to 5s), resubscribing automatically;
    # * degradation is fail-open per broadcast: Redis down means the
    #   remote hop is dropped with a STDERR warning while local delivery
    #   still happens — broadcasts never raise. The constructor never
    #   touches the network either (both connections are lazy), so
    #   misconfigured URLs fail at first broadcast, not at boot.
    class RedisServer < Server
      getter url : String
      getter redis_channel : String
      getter id : String

      @info : RedisWire::Info
      @pub_conn : RedisWire::Conn?
      @sub_conn : RedisWire::Conn?
      @closed : Atomic(Bool)
      @subscribed : Atomic(Bool)

      def initialize(@url : String = ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379"), @redis_channel : String = "saci:cable")
        super()
        @info = RedisWire.parse_url(@url)
        @id = Random::Secure.hex(8)
        @pub_mutex = Mutex.new
        @pub_conn = nil
        @sub_mutex = Mutex.new
        @sub_conn = nil
        @closed = Atomic(Bool).new(false)
        @subscribed = Atomic(Bool).new(false)
        spawn { subscriber_loop }
      end

      # Local fan-out first (remote failures must never lose local
      # delivery), then the Redis hop (fail-open with a warning).
      def broadcast(stream : String, payload) : Nil
        deliver_local(stream, payload)
        begin
          publish_envelope({"sender" => @id, "stream" => stream, "message" => payload}.to_json)
        rescue ex : Exception
          STDERR.puts("warning: saci cable redis unreachable (#{ex.message}); broadcast delivered locally only")
        end
      end

      # True once the background fiber holds a confirmed SUBSCRIBE
      # (useful to wait out races in specs before publishing).
      def subscribed? : Bool
        @subscribed.get
      end

      # Drops the subscriber connection (the loop reconnects with
      # backoff). Test hook for the resubscribe path; harmless in
      # production (a transient blip).
      def disconnect! : Nil
        @sub_mutex.synchronize do
          begin
            @sub_conn.try(&.close)
          rescue
          end
        end
      end

      # Stops the background subscriber. Servers are otherwise
      # fire-and-forget (specs should close what they create).
      def close : Nil
        @closed.set(true)
        disconnect!
      end

      private def publish_envelope(envelope : String) : Nil
        @pub_mutex.synchronize do
          begin
            conn = @pub_conn ||= RedisWire::Conn.new(@info)
            conn.call("PUBLISH", @redis_channel, envelope)
          rescue ex : RedisDown
            begin
              @pub_conn.try(&.close)
            rescue
            end
            @pub_conn = nil
            # One immediate retry: covers publish-right-after-restart
            # without waiting for the next broadcast.
            conn2 = RedisWire::Conn.new(@info)
            @pub_conn = conn2
            conn2.call("PUBLISH", @redis_channel, envelope)
          end
        end
      end

      private def subscriber_loop : Nil
        backoff = 0.1
        loop do
          break if @closed.get
          begin
            conn = RedisWire::Conn.new(@info, subscriber: true)
            @sub_mutex.synchronize { @sub_conn = conn }
            begin
              conn.subscribe(@redis_channel, on_subscribed: -> { backoff = 0.1; @subscribed.set(true); nil }) do |payload|
                handle_remote(payload)
              end
            ensure
              @subscribed.set(false)
              @sub_mutex.synchronize { @sub_conn = nil if @sub_conn.same?(conn) }
              begin
                conn.close
              rescue
              end
            end
          rescue
            # Broken pipe / refused / timeout: back off and retry.
          end
          break if @closed.get
          sleep backoff.seconds
          backoff = Math.min(backoff * 2.0, 5.0)
        end
      end

      private def handle_remote(payload : String) : Nil
        begin
          env = JSON.parse(payload)
          return if env["sender"]?.try(&.as_s?) == @id
          stream = env["stream"]?.try(&.as_s?)
          return if stream.nil?
          message = env["message"]?
          deliver_local(stream.as(String), message)
        rescue
          # One corrupt envelope must never kill the subscriber pump.
        end
      end
    end

    # Base class for channels. Subclass and override `subscribed`,
    # `unsubscribed` and `receive`.
    class Channel
      getter connection : Connection
      getter identifier : String
      getter params : Hash(String, JSON::Any)

      def initialize(@connection : Connection, @identifier : String, @params : Hash(String, JSON::Any))
      end

      # Called after subscribe. Open streams here (`stream_from`) or call
      # `reject` to refuse the subscription.
      def subscribed : Nil
      end

      # Called on `unsubscribe` and on connection close.
      def unsubscribed : Nil
      end

      # Called for each client `message` command on this subscription.
      def receive(data : JSON::Any) : Nil
      end

      # Refuses the subscription (client gets `reject_subscription`).
      def reject : NoReturn
        raise RejectedError.new
      end

      # Sends `payload` to this subscription only.
      def transmit(payload) : Nil
        connection.send_json({"identifier" => identifier, "message" => payload})
      end

      # Broadcast delivery (invoked by `Server#broadcast`).
      def deliver(identifier : String, payload) : Nil
        connection.send_json({"identifier" => identifier, "message" => payload})
      end

      # Subscribes this subscription to a named stream.
      def stream_from(stream : String) : Nil
        connection.server.add_stream(connection, stream, identifier, self)
      end

      def stop_stream(stream : String) : Nil
        connection.server.remove_stream(stream, self)
      end

      def stop_all_streams : Nil
        connection.server.remove_channel(self)
      end

      # Broadcasts to a stream via the default server (override `server:`
      # for multi-server setups).
      def self.broadcast_to(stream : String, payload, server : Server = Cable.server) : Nil
        server.broadcast(stream, payload)
      end
    end

    # Runs the JSON protocol for one socket. Registered channels map
    # channel names (class names) to channel classes.
    def self.handle(socket : HTTP::WebSocket, params : Saci::Params, channels : Hash(String, Channel.class), server : Server) : Nil
      connection = Connection.new(socket, params, server)
      socket.send({type: "welcome"}.to_json)
      socket.on_message do |raw|
        begin
          handle_frame(server, connection, channels, raw)
        rescue
          # One malformed frame must never kill the pump.
        end
      end
      socket.on_close do |_code, _message|
        server.unsubscribe_connection(connection)
      end
    end

    private def self.handle_frame(server : Server, connection : Connection, channels : Hash(String, Channel.class), raw : String) : Nil
      frame = JSON.parse(raw).as_h
      command = frame["command"]?.try(&.as_s?)
      identifier = frame["identifier"]?.try(&.as_s?)
      case command
      when "subscribe"
        name = identifier.try { |id| channel_name(id) }
        klass = name ? channels[name]? : nil
        if identifier.nil? || klass.nil?
          connection.send_json({type: "reject_subscription", identifier: identifier})
          return
        end
        server.subscribe(klass, connection, identifier, identifier_params(identifier))
      when "unsubscribe"
        server.unsubscribe(connection, identifier) if identifier
      when "message"
        if identifier && (sub = connection.find_subscription(identifier))
          sub.channel.receive(message_payload(frame["data"]?))
        end
      end
    end

    private def self.channel_name(identifier : String) : String?
      JSON.parse(identifier).as_h["channel"]?.try(&.as_s?)
    rescue
      nil
    end

    private def self.identifier_params(identifier : String) : Hash(String, JSON::Any)
      obj = JSON.parse(identifier).as_h
      obj.reject { |key, _| key == "channel" }
    rescue
      {} of String => JSON::Any
    end

    private def self.message_payload(data : JSON::Any?) : JSON::Any
      return JSON::Any.new(nil) if data.nil?
      if str = data.as_s?
        JSON.parse(str)
      else
        data
      end
    rescue
      JSON::Any.new(nil)
    end

    # Synchronous test client for channel specs (see `saci generate channel`).
    # All incoming frames are buffered, so broadcasts that arrive early
    # (e.g. while `subscribe` waits for confirmation) are never lost.
    class TestClient
      def initialize(host : String, port : Int32, path : String = "/cable")
        @buffer = [] of String
        @buffer_mutex = Mutex.new
        @wake = ::Channel(Nil).new
        @ws = HTTP::WebSocket.new(host, path, port)
        @ws.on_message do |msg|
          @buffer_mutex.synchronize { @buffer << msg }
          @wake.send(nil)
        end
        spawn { @ws.run }
      end

      def subscribe(channel : String, params : Hash(String, String) = {} of String => String, timeout : Time::Span = 5.seconds) : String
        identifier = Cable.identifier_for(channel, params)
        @ws.send({"command" => "subscribe", "identifier" => identifier}.to_json)
        # Skip over non-subscription frames (e.g. the `welcome` greeting).
        loop do
          msg = next_message(timeout)
          case msg["type"]?.try(&.as_s?)
          when "confirm_subscription"
            return identifier
          when "reject_subscription"
            raise "Subscription rejected for #{identifier}"
          end
        end
      end

      def send_message(identifier : String, data, timeout : Time::Span = 5.seconds) : Nil
        @ws.send({"command" => "message", "identifier" => identifier, "data" => data.to_json}.to_json)
      end

      def unsubscribe(identifier : String) : Nil
        @ws.send({"command" => "unsubscribe", "identifier" => identifier}.to_json)
      end

      def next_message(timeout : Time::Span = 5.seconds) : JSON::Any
        loop do
          if raw = @buffer_mutex.synchronize { @buffer.shift? }
            return JSON.parse(raw)
          end
          select
          when @wake.receive
          when timeout(timeout)
            raise "Timed out waiting for websocket message"
          end
        end
      end

      def close : Nil
        @ws.close
      rescue IO::Error
      end
    end
  end
end
