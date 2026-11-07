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

    # Connection identification hook (G203). Runs once per websocket
    # connection, before the `welcome` frame and before any subscription.
    # Call `connection.reject_unauthorized_connection` (or raise
    # `RejectedError`) to close the socket.
    @@identify_hook : Proc(Connection, Nil)? = nil
    @@identify_mutex = Mutex.new

    # Optional error sink for timer / writer / identification failures.
    # Defaults to STDERR; override in tests or route into your logger.
    @@error_handler : Proc(Exception, Nil)? = nil
    @@error_mutex = Mutex.new

    def self.server : Server
      @@server || @@server_mutex.synchronize { @@server ||= Server.new }
    end

    def self.server=(server : Server) : Nil
      @@server = server
    end

    def self.broadcast(stream : String, payload) : Nil
      server.broadcast(stream, payload)
    end

    # Process-local remote-connection registry (G96).
    def self.remote_connections : RemoteConnections
      server.remote_connections
    end

    # Registers the per-connection identification hook. The block receives
    # the `Connection` (with query/path `params`) and may set identifiers
    # (`connection.set_identifier`, `connection.current_user = ...`).
    #
    # ```
    # Saci::Cable.identify do |connection|
    #   token = connection.params["token"]?
    #   user = token.try { |t| User.find_by(token: t) }
    #   connection.reject_unauthorized_connection if user.nil?
    #   connection.current_user = user
    # end
    # ```
    def self.identify(&block : Connection -> Nil) : Nil
      @@identify_mutex.synchronize { @@identify_hook = block }
    end

    # Alias for `identify` (connection-level `connect` hook).
    def self.on_connect(&block : Connection -> Nil) : Nil
      identify(&block)
    end

    def self.reset_identify_hook! : Nil
      @@identify_mutex.synchronize { @@identify_hook = nil }
    end

    # Installs the process-wide cable error handler (periodic timers,
    # outbound writer, identification). Returning normally keeps the
    # connection/timer alive where applicable.
    def self.on_error(&block : Exception -> Nil) : Nil
      @@error_mutex.synchronize { @@error_handler = block }
    end

    def self.reset_error_handler! : Nil
      @@error_mutex.synchronize { @@error_handler = nil }
    end

    def self.report_error(ex : Exception, context : String? = nil) : Nil
      handler = @@error_mutex.synchronize { @@error_handler }
      if handler
        begin
          handler.call(ex)
        rescue handler_ex
          STDERR.puts("saci cable error handler raised: #{handler_ex.class}: #{handler_ex.message}")
        end
      else
        prefix = context ? "saci cable #{context}" : "saci cable"
        STDERR.puts("#{prefix} error: #{ex.class}: #{ex.message}")
      end
    end

    # Runs the identification hook. Returns false when the connection was
    # rejected (the socket is already closed); other exceptions are reported
    # and treated as rejection so an unauthenticated socket never proceeds.
    def self.run_identify(connection : Connection) : Bool
      hook = @@identify_mutex.synchronize { @@identify_hook }
      hook.try(&.call(connection))
      true
    rescue RejectedError
      false
    rescue ex
      report_error(ex, "identification")
      false
    end

    # Builds the identifier JSON clients send (`{"channel":"X",...}`).
    def self.identifier_for(channel : String, params : Hash(String, String) = {} of String => String) : String
      {"channel" => channel}.merge(params).to_json
    end

    # Builds the ActionCable message frame for one subscription from an
    # already-encoded message. Byte-identical to
    # `{"identifier" => identifier, "message" => payload}.to_json` when
    # `message_json == payload.to_json`; `identifier` (itself a JSON
    # document) is escaped as a JSON string value.
    def self.broadcast_frame(identifier : String, message_json : String) : String
      String.build(identifier.bytesize + message_json.bytesize + 32) do |io|
        io << %({"identifier":)
        identifier.to_json(io)
        io << %(,"message":)
        io << message_json
        io << '}'
      end
    end

    # :nodoc:
    # Serialises a broadcast payload once. Returns nil when it cannot be
    # encoded (e.g. NaN): callers then fall back to the per-subscriber
    # `Channel#deliver` path so failure behaviour is unchanged.
    def self.encode_payload(payload) : String?
      payload.to_json
    rescue
      nil
    end

    # Raised by `Channel#reject`; aborts the subscription (client gets
    # `reject_subscription`).
    class RejectedError < Exception
    end

    # Values storable as connection identifiers (G203). Deliberately a
    # closed union: Crystal cannot store `Object` in collections, and these
    # cover wire scalars plus the dominant `current_user` model case.
    # `Saci::Record::Base` is resolved at semantic-analysis time; the ORM is
    # always part of a full Saci build.
    alias IdentifierValue = String | Int32 | Int64 | Float64 | Bool | Time | JSON::Any | Saci::Record::Base | Nil

    # One per websocket connection. Owns the outbound message buffer and
    # tracks the connection's subscriptions for cleanup on close.
    #
    # Concurrency model (G281): each connection has one reader (the
    # `HTTP::WebSocket` pump that calls `#handle_frame`) and one dedicated
    # writer fiber draining a *bounded* queue. Producers (broadcasts) only
    # enqueue; a slow client whose queue fills is disconnected instead of
    # blocking the publisher. Periodic channel timers add one fiber per
    # timer while subscribed. There is no shared worker pool — the bound is
    # the per-connection buffer plus `Server#max_connections`.
    class Connection
      # Frames a slow peer may lag behind before it is disconnected. The
      # queue is preallocated per connection (8 bytes a slot), so it is kept
      # modest; raise it per server for bursty streams.
      DEFAULT_MESSAGE_BUFFER_SIZE = 256

      getter socket : HTTP::WebSocket
      getter params : Saci::Params
      getter server : Server
      # Stable per-socket id (used by `remote_connections.where(identifier:)`).
      getter identifier : String
      getter message_buffer_size : Int32
      # The HTTP upgrade request/context (nil for connections built outside
      # a router, e.g. unit specs). Lets `Cable.identify` read cookies,
      # the session and the `Origin` header like Rails' `request`/`cookies`.
      getter request : HTTP::Request?
      getter context : HTTP::Server::Context?

      @track_mutex = Mutex.new
      @subscriptions : Array(Subscription) = [] of Subscription
      @identifiers_mutex = Mutex.new
      @identifiers = Hash(String, IdentifierValue).new

      @outbound : ::Channel(String?)
      @pending = Atomic(Int32).new(0)
      @closed = Atomic(Bool).new(false)
      @closing = Atomic(Bool).new(false)
      @rejected = Atomic(Bool).new(false)
      @overflowed = Atomic(Bool).new(false)
      # The writer fiber only exists while frames are queued (see
      # `#ensure_writer`): an idle socket costs no extra fiber stack.
      @writer_active = Atomic(Bool).new(false)

      def initialize(@socket : HTTP::WebSocket, @params : Saci::Params, @server : Server,
                     @message_buffer_size : Int32 = DEFAULT_MESSAGE_BUFFER_SIZE,
                     @identifier : String = Random::Secure.hex(16),
                     @context : HTTP::Server::Context? = nil)
        @request = @context.try(&.request)
        # A zero/negative buffer would make every send overflow; clamp to 1.
        @outbound = ::Channel(String?).new(@message_buffer_size < 1 ? 1 : @message_buffer_size)
      end

      # Upgrade request headers (`Origin`, `Cookie`, ...), nil without a request.
      def headers : HTTP::Headers?
        @request.try(&.headers)
      end

      # Cookie jar over the upgrade request (signed/encrypted readers work as
      # in controllers). Nil when the connection has no HTTP context.
      def cookies : Saci::CookieJar?
        ctx = @context
        req = @request
        return nil if ctx.nil? || req.nil?
        @cookies ||= Saci::CookieJar.new(req, ctx.response)
      end

      @cookies : Saci::CookieJar? = nil

      # The Saci session carried by the upgrade request's cookie (read-only
      # in practice: nothing writes Set-Cookie on a websocket).
      def session : Saci::Session?
        cookies.try { |jar| Saci::Session.new(jar) }
      end

      # Queues one JSON frame. Never blocks: when the bounded buffer is full
      # the peer is considered dead/slow and is disconnected (backpressure
      # policy documented on the class).
      def send_json(payload) : Nil
        return if closed?
        send_raw(payload.to_json)
      end

      # Queues one already-encoded frame (same bounded-queue/backpressure
      # semantics as `#send_json`). Broadcast fan-out uses it so a payload
      # is serialised once per broadcast instead of once per socket; the
      # String is immutable, so one instance may be queued on any number
      # of connections concurrently.
      def send_raw(text : String) : Nil
        return if closed?
        @pending.add(1)
        select
        when @outbound.send(text)
          ensure_writer
        else
          @pending.sub(1)
          @overflowed.set(true)
          force_close
        end
      rescue ::Channel::ClosedError
        @pending.sub(1)
      end

      # Waits (bounded) until all currently queued frames have been written.
      # Useful in timer/unit specs; never call from the writer fiber.
      def flush(timeout : Time::Span = 1.second) : Nil
        deadline = Time.instant + timeout
        while @pending.get > 0 && Time.instant < deadline
          sleep 1.millisecond
        end
      end

      def closed? : Bool
        @closed.get || @closing.get
      end

      def rejected? : Bool
        @rejected.get
      end

      # :nodoc:
      # True while a writer fiber exists (it only does while frames are queued).
      def writer_running? : Bool
        @writer_active.get
      end

      # True when the last outbound enqueue hit a full buffer.
      def overflowed? : Bool
        @overflowed.get
      end

      # Graceful close: flush already-queued frames, then close the socket.
      # Safe to call from any fiber and idempotent.
      def close : Nil
        return if @closing.swap(true)
        # The close sentinel counts as pending so an idling writer cannot
        # exit while it is still queued.
        @pending.add(1)
        select
        when @outbound.send(nil)
          ensure_writer
        else
          @pending.sub(1)
          force_close
        end
      rescue ::Channel::ClosedError
        @pending.sub(1)
        force_close
      end

      # Closes the connection and removes it from the server registry.
      def disconnect : Nil
        close
        @server.unregister(self)
      end

      # Rails connection API (G203). Marks the connection unauthorized,
      # closes it, and aborts the current hook/subscription.
      def reject_unauthorized_connection : NoReturn
        @rejected.set(true)
        disconnect
        raise RejectedError.new
      end

      # -- identifiers ------------------------------------------------------
      #
      # Identifiers are connection-scoped values resolved once by the
      # `Cable.identify` hook (or by a channel `connect` hook) and readable
      # from every channel on the connection. `IdentifierValue` is a closed
      # union (see the alias comment); the `identified_by :current_user,
      # User` macro casts at the channel edge.

      def set_identifier(name : String | Symbol, value : IdentifierValue) : Nil
        @identifiers_mutex.synchronize { @identifiers[name.to_s] = value }
      end

      def identifier_value(name : String | Symbol) : IdentifierValue
        @identifiers_mutex.synchronize { @identifiers[name.to_s]? }
      end

      # Snapshot (safe to iterate outside the lock).
      def identifiers : Hash(String, IdentifierValue)
        @identifiers_mutex.synchronize { @identifiers.dup }
      end

      def current_user : IdentifierValue
        identifier_value("current_user")
      end

      def current_user=(value : IdentifierValue) : Nil
        set_identifier("current_user", value)
      end

      def connection_identifier : String
        @identifier
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

      # Hands the connection to the process-wide writer pool unless it is
      # already scheduled. At most one pool worker drains a connection at a
      # time (CAS), which keeps its frames in order.
      private def ensure_writer : Nil
        _, won = @writer_active.compare_and_set(false, true)
        Cable.writer_pool.schedule(self) if won
      end

      # :nodoc:
      # Called by a `WriterPool` worker: drains the queue and returns once it
      # is empty (the connection keeps no fiber while idle). A close
      # sentinel, a closed queue or a socket error (including a write
      # timeout from a peer that stopped reading) ends the connection.
      def drain : Nil
        finished = false
        loop do
          select
          when text = @outbound.receive?
            if text.nil? # close sentinel or queue closed
              @pending.sub(1) unless @outbound.closed?
              finished = true
              break
            end
            begin
              @socket.send(text)
            rescue IO::Error
              finished = true
              break
            rescue ex
              Cable.report_error(ex, "writer")
              finished = true
              break
            ensure
              @pending.sub(1)
            end
          else
            # Queue looks empty: go idle, unless a producer counted a frame
            # it has not finished queueing (or queued it after our check
            # but before we stood down) and we win the writer role back.
            @writer_active.set(false)
            break if @pending.get <= 0
            _, won = @writer_active.compare_and_set(false, true)
            break unless won
            Fiber.yield
          end
        end
      ensure
        if finished
          begin
            @socket.close
          rescue
          end
          @closed.set(true)
          @writer_active.set(false)
        end
      end

      # Hard close used by overflow/close races; drops queued frames.
      private def force_close : Nil
        return if @closed.swap(true)
        begin
          @outbound.close
        rescue
        end
        begin
          @socket.close
        rescue
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
    #
    # It also owns the live connection registry used by
    # `remote_connections` (G96) and the optional broadcast recorder used by
    # the test helpers (G97).
    class Server
      getter max_connections : Int32
      getter message_buffer_size : Int32

      def initialize(max_connections : Int32 = 0, message_buffer_size : Int32 = Connection::DEFAULT_MESSAGE_BUFFER_SIZE)
        @streams = Hash(String, Array(Subscription)).new { |h, k| h[k] = [] of Subscription }
        @mutex = Mutex.new
        @max_connections = max_connections
        @message_buffer_size = message_buffer_size < 1 ? 1 : message_buffer_size
        @connections = Hash(String, Connection).new
        @connections_mutex = Mutex.new
        @record_broadcasts = Atomic(Bool).new(false)
        @broadcasts = Hash(String, Array(JSON::Any)).new { |h, k| h[k] = [] of JSON::Any }
        @broadcasts_mutex = Mutex.new
      end

      # -- live connection registry (G96) ---------------------------------

      # Registers a connection. Returns false when `max_connections` is
      # reached (the caller closes the socket with a clear log line).
      def register(connection : Connection) : Bool
        @connections_mutex.synchronize do
          if @max_connections > 0 && @connections.size >= @max_connections && !@connections.has_key?(connection.identifier)
            return false
          end
          @connections[connection.identifier] = connection
          true
        end
      end

      def unregister(connection : Connection) : Nil
        @connections_mutex.synchronize do
          if found = @connections[connection.identifier]?
            @connections.delete(connection.identifier) if found.same?(connection)
          end
        end
      end

      def open_connections : Array(Connection)
        @connections_mutex.synchronize { @connections.values.dup }
      end

      # Alias matching Rails' `server.connections`.
      def connections : Array(Connection)
        open_connections
      end

      def open_connections_count : Int32
        @connections_mutex.synchronize { @connections.size }
      end

      def remote_connections : RemoteConnections
        RemoteConnections.new(self)
      end

      # Closes every live connection on this server. Returns the number of
      # connections targeted (0 when none).
      def disconnect_all : Int32
        remote_connections.disconnect
      end

      # -- subscriptions ----------------------------------------------------

      # Instantiates the channel and runs the optional `#connect` hook plus
      # `#subscribed`. Returns nil when the subscription was rejected or
      # failed (client already notified).
      def subscribe(channel_class : Channel.class, connection : Connection, identifier : String, params : Hash(String, JSON::Any)) : Channel?
        channel = channel_class.new(connection, identifier, params)
        begin
          channel.connect
          channel.subscribed
        rescue RejectedError
          channel.stop_periodic_timers
          remove_channel(channel)
          connection.send_json({type: "reject_subscription", identifier: identifier})
          return nil
        rescue ex
          Cable.report_error(ex, "subscription")
          channel.stop_periodic_timers
          remove_channel(channel)
          connection.close
          return nil
        end
        connection.send_json({type: "confirm_subscription", identifier: identifier})
        channel.start_periodic_timers
        channel
      end

      # Removes one subscription (client `unsubscribe`), running the
      # channel's `#unsubscribed` hook and cancelling its timers.
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
        message_json = Cable.encode_payload(payload)
        record_broadcast(stream, payload, message_json)
        deliver_local(stream, payload, message_json)
      end

      # Fan-out to this process's subscribers only (no Redis hop).
      #
      # The payload is serialised once per call (not once per subscriber);
      # each frame is then spliced from the subscription identifier and
      # that shared, immutable String (see `Channel#deliver_encoded`).
      def deliver_local(stream : String, payload) : Nil
        subs = subscribers_snapshot(stream)
        return if subs.empty?
        deliver_to(subs, payload, Cable.encode_payload(payload))
      end

      # Same as `#deliver_local(stream, payload)` with the payload already
      # encoded by the caller (`message_json == payload.to_json`, or nil
      # when encoding failed).
      def deliver_local(stream : String, payload, message_json : String?) : Nil
        subs = subscribers_snapshot(stream)
        return if subs.empty?
        deliver_to(subs, payload, message_json)
      end

      # Fan-out of a message that only exists as JSON text (e.g. carried by
      # a Redis envelope): no parse/re-serialise round trip. It is parsed
      # (once, lazily) only for channels that override `Channel#deliver`,
      # which receive the same `JSON::Any` they always did.
      def deliver_local_encoded(stream : String, message_json : String) : Nil
        subs = subscribers_snapshot(stream)
        return if subs.empty?
        decoded : JSON::Any? = nil
        fan_out_encoded(subs, message_json) { decoded ||= JSON.parse(message_json) }
      end

      private def subscribers_snapshot(stream : String) : Array(Subscription)
        @mutex.synchronize { @streams[stream]?.try(&.dup) || [] of Subscription }
      end

      private def deliver_to(subs : Array(Subscription), payload, message_json : String?) : Nil
        if json = message_json
          fan_out_encoded(subs, json) { payload }
        else
          # Unencodable payload: legacy per-subscriber path (each `deliver`
          # raises and the subscription is dropped, exactly as before).
          subs.each do |sub|
            begin
              sub.channel.deliver(sub.identifier, payload)
            rescue
              remove_subscription(sub.channel.connection, sub, run_hook: false)
            end
          end
        end
      end

      # Channels that override `#deliver` keep getting the payload object
      # through it; every other subscription gets a spliced frame. Frames
      # are memoised per identifier (subscribers of one room usually share
      # the same identifier), so a fan-out to N sockets costs one payload
      # encode plus one frame per distinct identifier.
      private def fan_out_encoded(subs : Array(Subscription), message_json : String, &) : Nil
        frames = {} of String => String
        subs.each do |sub|
          begin
            channel = sub.channel
            if channel.deliver_overridden?
              payload = yield
              channel.deliver(sub.identifier, payload)
            else
              frame = frames[sub.identifier] ||= Cable.broadcast_frame(sub.identifier, message_json)
              channel.deliver_encoded(sub.identifier, message_json, frame)
            end
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
          if found = @streams[stream]?.try { |subs| subs.find { |s| s.channel.same?(channel) } }
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

      # -- introspection (test helpers) -------------------------------------

      def stream_names : Array(String)
        @mutex.synchronize do
          @streams.select { |_, subs| !subs.empty? }.keys.sort
        end
      end

      def has_stream?(stream : String) : Bool
        @mutex.synchronize do
          subs = @streams[stream]?
          subs.nil? ? false : !subs.empty?
        end
      end

      def stream_subscriber_count(stream : String) : Int32
        @mutex.synchronize { @streams[stream]?.try(&.size) || 0 }
      end

      # -- broadcast recording (test helpers) --------------------------------

      def record_broadcasts=(enabled : Bool) : Nil
        @record_broadcasts.set(enabled)
      end

      def record_broadcasts? : Bool
        @record_broadcasts.get
      end

      # All recorded payloads for `stream` (or every stream, in hash order)
      # since the last `clear_broadcasts`.
      def broadcasts(stream : String? = nil) : Array(JSON::Any)
        @broadcasts_mutex.synchronize do
          if s = stream
            (@broadcasts[s]? || [] of JSON::Any).dup
          else
            @broadcasts.values.flat_map { |values| values.dup }
          end
        end
      end

      def broadcast_count(stream : String? = nil) : Int32
        broadcasts(stream).size
      end

      def clear_broadcasts : Nil
        @broadcasts_mutex.synchronize { @broadcasts.clear }
      end

      protected def record_broadcast(stream : String, payload) : Nil
        record_broadcast(stream, payload, nil)
      end

      # `message_json`, when given, is `payload.to_json` already computed by
      # the caller (avoids a second encode while recording).
      protected def record_broadcast(stream : String, payload, message_json : String?) : Nil
        return unless @record_broadcasts.get
        any = payload.is_a?(JSON::Any) ? payload : JSON.parse(message_json || payload.to_json)
        @broadcasts_mutex.synchronize { @broadcasts[stream] << any }
      rescue ex
        Cable.report_error(ex, "broadcast recording")
      end

      private def remove_subscription(connection : Connection, sub : Subscription, run_hook : Bool) : Nil
        @mutex.synchronize { @streams[sub.stream]?.try(&.delete(sub)) }
        connection.untrack(sub)
        begin
          sub.channel.unsubscribed if run_hook
        rescue
          # A broken user hook must not block cleanup.
        ensure
          sub.channel.stop_periodic_timers
        end
      end
    end

    # A filtered view over one server's live connections (G96).
    #
    # ```
    # Saci::Cable.server.remote_connections
    #   .where(current_user: user)
    #   .disconnect
    # Saci::Cable.server.remote_connections.where(identifier: sid).disconnect
    # ```
    #
    # Matching is by connection identifier (`identifier` / `id`) or by any
    # value stored through `Connection#set_identifier`. The registry is
    # process-local (same as the default adapter); Redis/DB adapters fan out
    # messages but do not propagate disconnects across processes.
    class RemoteConnections
      def initialize(@server : Server, @criteria : Hash(String, IdentifierValue) = {} of String => IdentifierValue)
      end

      def where(**criteria) : RemoteConnections
        merged = @criteria.dup
        criteria.each { |key, value| merged[key.to_s] = value }
        RemoteConnections.new(@server, merged)
      end

      def where(criteria : Hash(K, V)) : RemoteConnections forall K, V
        merged = @criteria.dup
        criteria.each { |key, value| merged[key.to_s] = value.as(IdentifierValue) }
        RemoteConnections.new(@server, merged)
      end

      def to_a : Array(Connection)
        @server.open_connections.select { |connection| matches?(connection) }
      end

      def each(& : Connection ->) : Nil
        to_a.each { |connection| yield connection }
      end

      # Disconnects every matching connection. Returns the count.
      def disconnect : Int32
        targets = to_a
        targets.each do |connection|
          connection.disconnect
          @server.unregister(connection)
        end
        targets.size
      end

      def disconnect_all : Int32
        disconnect
      end

      private def matches?(connection : Connection) : Bool
        @criteria.all? do |key, expected|
          if key == "identifier" || key == "id"
            next true if cable_values_equal?(connection.identifier, expected)
          end
          cable_values_equal?(connection.identifier_value(key), expected)
        end
      end

      private def cable_values_equal?(actual : IdentifierValue, expected : IdentifierValue) : Bool
        return true if actual.nil? && expected.nil?
        return false if actual.nil? || expected.nil?
        return true if actual == expected
        if record = actual.as?(Saci::Record::Base)
          # Same model + primary key, or an id passed as the criterion.
          if other = expected.as?(Saci::Record::Base)
            return record.class == other.class &&
              record[record.class.primary_key_name].to_s == other[other.class.primary_key_name].to_s
          end
          return record[record.class.primary_key_name].to_s == expected.to_s
        end
        if any = actual.as?(JSON::Any)
          return true if any.raw == expected
          return any.to_json == expected.to_s
        end
        actual.to_s == expected.to_s
      rescue
        false
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
        message_json = Cable.encode_payload(payload)
        record_broadcast(stream, payload, message_json)
        deliver_local(stream, payload, message_json)
        begin
          publish_envelope(envelope_json(stream, payload, message_json))
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

      # Byte-identical to
      # `{"sender" => @id, "stream" => stream, "message" => payload}.to_json`,
      # reusing the already-encoded message when available.
      private def envelope_json(stream : String, payload, message_json : String?) : String
        if json = message_json
          String.build(json.bytesize + stream.bytesize + 64) do |io|
            io << %({"sender":)
            @id.to_json(io)
            io << %(,"stream":)
            stream.to_json(io)
            io << %(,"message":)
            io << json
            io << '}'
          end
        else
          {"sender" => @id, "stream" => stream, "message" => payload}.to_json
        end
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

      # Scans the envelope with a pull parser and keeps `message` as raw
      # JSON text (`read_raw`), so a remote broadcast is not materialised as
      # `JSON::Any` and re-serialised (unless a local channel overrides
      # `Channel#deliver`; see `Server#deliver_local_encoded`).
      private def handle_remote(payload : String) : Nil
        begin
          sender : String? = nil
          stream : String? = nil
          message_json : String? = nil
          pull = JSON::PullParser.new(payload)
          skipped = false
          pull.read_object do |key|
            case key
            when "sender"
              sender = remote_string(pull)
            when "stream"
              stream = remote_string(pull)
            when "message"
              # Envelopes carry sender and stream first: when this process
              # sent it or has nobody on that stream, skip decoding the
              # message at all (every replica receives every broadcast).
              if sender == @id || ((s = stream) && !local_subscribers?(s))
                skipped = true
                pull.skip
              else
                message_json = pull.read_raw
              end
            else
              pull.skip
            end
          end
          return if skipped
          return unless pull.kind.eof? # trailing garbage: rejected, like JSON.parse
          return if sender == @id
          target = stream
          return if target.nil?
          if json = message_json
            deliver_local_encoded(target, json)
          else
            deliver_local(target, nil) # no "message" key: null, as before
          end
        rescue
          # One corrupt envelope must never kill the subscriber pump.
        end
      end

      private def local_subscribers?(stream : String) : Bool
        @mutex.synchronize do
          subs = @streams[stream]?
          !subs.nil? && !subs.empty?
        end
      end

      # String value of an envelope field; non-strings are skipped (nil),
      # matching the old `env[key]?.try(&.as_s?)`.
      private def remote_string(pull : JSON::PullParser) : String?
        if pull.kind.string?
          pull.read_string
        else
          pull.skip
          nil
        end
      end
    end

    # One `periodically` declaration. The macro accumulates specs with
    # `previous_def`/`super`, so a class (and its parents) may declare any
    # number of independent timers.
    struct PeriodicSpec
      getter interval : Time::Span
      getter handler : Proc(Nil)

      def initialize(@interval : Time::Span, @handler : Proc(Nil))
      end
    end

    # Per-subscription timer fiber (G95). Wakes on `interval`, invokes the
    # handler, and isolates handler exceptions (reported, timer continues).
    # `stop` closes the wake channel and waits briefly for the fiber to
    # finish; calling `stop` from the timer's own handler never deadlocks.
    class PeriodicTimer
      getter interval : Time::Span

      @fiber : Fiber

      def initialize(@interval : Time::Span, @handler : Proc(Nil), @on_error : Proc(Exception, Nil)? = nil)
        raise ArgumentError.new("periodically interval must be positive (got #{@interval})") if @interval <= Time::Span.zero
        @stop = ::Channel(Nil).new(1)
        @stopped = Atomic(Bool).new(false)
        @fiber = spawn { run }
      end

      def stopped? : Bool
        @stopped.get
      end

      def stop : Nil
        return if @stopped.swap(true)
        begin
          # Buffered wake signal; never blocks and never closes the channel
          # (receiving from a closed channel raises in Crystal 1.22).
          @stop.send(nil)
        rescue ::Channel::ClosedError
        end
        # Do not wait for ourselves when a handler calls `disconnect`.
        return if Fiber.current.same?(@fiber)
        deadline = Time.instant + 1.second
        while !@fiber.dead? && Time.instant < deadline
          sleep 1.millisecond
        end
      end

      private def run : Nil
        loop do
          select
          when @stop.receive
            break
          when timeout(@interval)
            begin
              @handler.call
            rescue ex
              if handler = @on_error
                begin
                  handler.call(ex)
                rescue
                  Cable.report_error(ex, "periodic timer")
                end
              else
                Cable.report_error(ex, "periodic timer")
              end
            end
          end
        end
      end
    end

    # Base class for channels. Subclass and override `subscribed`,
    # `unsubscribed` and `receive`.
    class Channel
      getter connection : Connection
      getter identifier : String
      getter params : Hash(String, JSON::Any)

      @periodic_mutex = Mutex.new
      @periodic_timers = [] of PeriodicTimer
      @periodic_started = false

      def initialize(@connection : Connection, @identifier : String, @params : Hash(String, JSON::Any))
      end

      # Detects subclasses that define their own `#deliver`. Those keep
      # receiving the payload object through `#deliver` on broadcasts; all
      # other channels get pre-encoded frames via `#deliver_encoded`.
      # Descendants inherit the flag from their parent class.
      macro inherited
        macro finished
          \{% if @type.methods.any? { |m| m.name.stringify == "deliver" } %}
            # :nodoc:
            def deliver_overridden? : Bool
              true
            end
          \{% end %}
        end
      end

      # :nodoc:
      # True when this class (or an ancestor below `Channel`) defines its
      # own `#deliver` (see the `inherited` hook above).
      def deliver_overridden? : Bool
        false
      end

      # Optional per-subscription authentication hook, called before
      # `#subscribed`. For a connection-wide hook use `Cable.identify`.
      def connect : Nil
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

      # Closes the whole websocket connection (and cancels this channel's
      # timers). Other channels on the same connection are unsubscribed by
      # the server's close cleanup.
      def disconnect : Nil
        stop_periodic_timers
        connection.disconnect
      end

      # Rails connection API, available from channels for convenience.
      def reject_unauthorized_connection : NoReturn
        stop_periodic_timers
        connection.reject_unauthorized_connection
      end

      # Sends `payload` to this subscription only.
      def transmit(payload) : Nil
        connection.send_json({"identifier" => identifier, "message" => payload})
      end

      # Broadcast delivery of a payload object. `Server#deliver_local` calls
      # it only for subclasses that override it (see `#deliver_overridden?`);
      # otherwise the server uses `#deliver_encoded`. Kept for code that
      # calls or overrides it.
      def deliver(identifier : String, payload) : Nil
        connection.send_json({"identifier" => identifier, "message" => payload})
      end

      # Broadcast delivery of an already-encoded message (`payload.to_json`,
      # computed once per broadcast). `frame` lets the server share one
      # spliced frame between subscriptions with the same identifier.
      def deliver_encoded(identifier : String, message_json : String,
                          frame : String = Cable.broadcast_frame(identifier, message_json)) : Nil
        connection.send_raw(frame)
      end

      # Subscribes this subscription to a named stream.
      def stream_from(stream : String) : Nil
        connection.server.add_stream(connection, stream, identifier, self)
      end

      # Subscribes to the record-derived stream (G94). The default name is
      # `saci:<Model>:<id>`; a model declaring `broadcasts_for :posts`
      # (or an explicit `prefix:`) yields Rails-like `posts:<id>`.
      # Collections sort their constituent names and join with `:`.
      def stream_for(broadcastable, prefix : String? = nil) : String
        stream = Cable.broadcasting_for(broadcastable, prefix)
        stream_from(stream)
        stream
      end

      def stop_stream_for(broadcastable, prefix : String? = nil) : Nil
        stop_stream(Cable.broadcasting_for(broadcastable, prefix))
      end

      # `stream_for` when present, otherwise reject (Rails'
      # `stream_or_reject_for`).
      def stream_or_reject_for(broadcastable, prefix : String? = nil)
        if broadcastable
          stream_for(broadcastable, prefix)
        else
          reject
        end
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

      # Broadcasts to a record/collection-derived stream. Class-level so
      # publishers do not need a channel instance:
      #
      # ```
      # PostsChannel.broadcast_to(post, {title: "hi"})
      # PostsChannel.broadcasts_for(post) # => "saci:Post:1"
      # ```
      def self.broadcast_to(broadcastable, payload, prefix : String? = nil, server : Server = Cable.server) : Nil
        server.broadcast(Cable.broadcasting_for(broadcastable, prefix), payload)
      end

      # Class-level stream-name derivation used by `stream_for` (G94).
      def self.broadcasts_for(broadcastable, prefix : String? = nil) : String
        Cable.broadcasting_for(broadcastable, prefix)
      end

      # Rails-compatible alias.
      def self.broadcasting_for(broadcastable, prefix : String? = nil) : String
        Cable.broadcasting_for(broadcastable, prefix)
      end

      # Instance convenience: broadcast to a record through *this*
      # connection's server (useful in `receive`).
      def broadcast_to(broadcastable, payload, prefix : String? = nil) : Nil
        connection.server.broadcast(Cable.broadcasting_for(broadcastable, prefix), payload)
      end

      # -- identifiers (G203) ----------------------------------------------

      # Declares a connection identifier exposed on every channel:
      #
      # ```
      # class ApplicationCable::Channel < Saci::Cable::Channel
      #   identified_by :current_user, User
      # end
      # ```
      #
      # The connection-wide value is set by `Cable.identify` (or a channel
      # `connect` hook) via `connection.set_identifier`. The two-argument
      # form returns the declared type; the one-argument form returns
      # `JSON::Any?` for wire-provided values.
      macro identified_by(name, type)
        def {{name.id}} : {{type}}?
          connection.identifier_value({{name.id.stringify}}).as?({{type}})
        end

        def {{name.id}}=(value : {{type}}?) : Nil
          connection.set_identifier({{name.id.stringify}}, value)
        end
      end

      macro identified_by(name)
        def {{name.id}} : ::Saci::Cable::IdentifierValue
          connection.identifier_value({{name.id.stringify}})
        end

        def {{name.id}}=(value : ::Saci::Cable::IdentifierValue) : Nil
          connection.set_identifier({{name.id.stringify}}, value)
        end
      end

      # -- periodic timers (G95) -------------------------------------------

      # Runs the block every `interval` while the subscription is active.
      # The timer is cancelled by `unsubscribe`, connection close, and
      # `Channel#disconnect`; handler exceptions are reported and do not
      # stop the timer.
      #
      # ```
      # periodically(5.seconds) { transmit({type: "tick"}) }
      # ```
      macro periodically(interval, &block)
        def __saci_periodic_handlers : Array(::Saci::Cable::PeriodicSpec)
          {% if @type.methods.any? { |m| m.name == "__saci_periodic_handlers" } %}
            previous_def + [::Saci::Cable::PeriodicSpec.new({{interval}}, -> : Nil do
              {{block.body}}
              nil
            end)]
          {% else %}
            super + [::Saci::Cable::PeriodicSpec.new({{interval}}, -> : Nil do
              {{block.body}}
              nil
            end)]
          {% end %}
        end
      end

      # Overridden by `periodically` macros (accumulated with
      # `previous_def`/`super`).
      def __saci_periodic_handlers : Array(PeriodicSpec)
        [] of PeriodicSpec
      end

      # Starts one fiber per declared timer. Called by the server after
      # `subscribed` succeeds; idempotent.
      def start_periodic_timers : Nil
        specs = __saci_periodic_handlers
        return if specs.empty?
        started = [] of PeriodicTimer
        specs.each do |spec|
          begin
            started << PeriodicTimer.new(spec.interval, spec.handler,
              ->(ex : Exception) { Cable.report_error(ex, "periodic timer") })
          rescue ex
            Cable.report_error(ex, "periodic timer")
          end
        end
        @periodic_mutex.synchronize do
          return if @periodic_started
          @periodic_started = true
          @periodic_timers.concat(started)
        end
      end

      # Cancels every timer for this subscription. Safe/idempotent.
      def stop_periodic_timers : Nil
        timers = @periodic_mutex.synchronize do
          drained = @periodic_timers.dup
          @periodic_timers.clear
          @periodic_started = false
          drained
        end
        timers.each(&.stop)
      end

      def periodic_timers : Array(PeriodicTimer)
        @periodic_mutex.synchronize { @periodic_timers.dup }
      end
    end

    # Runs the JSON protocol for one socket. Registered channels map
    # channel names (class names) to channel classes.
    def self.handle(socket : HTTP::WebSocket, params : Saci::Params, channels : Hash(String, Channel.class), server : Server,
                    context : HTTP::Server::Context? = nil) : Nil
      connection = Connection.new(socket, params, server, message_buffer_size: server.message_buffer_size, context: context)

      unless server.register(connection)
        Cable.report_error(Exception.new("cable connection limit reached (#{server.max_connections})"), "connections")
        connection.close
        return
      end

      # Authentication/origin hook runs before the welcome frame and before
      # any subscribe frame can be processed (G203). Rejection closes the
      # socket; no welcome is sent.
      if (timeout = Cable.write_timeout) && (raw_io = socket.@ws.@io) && raw_io.responds_to?(:write_timeout=)
        raw_io.write_timeout = timeout
      end

      # Identification (cookie crypto, DB lookups) runs on a short-lived
      # fiber: the connection fiber lives as long as the socket and keeps
      # every stack page it ever touched resident.
      identified = false
      Cable.run_detached { identified = Cable.run_identify(connection) }
      unless identified
        server.unregister(connection)
        connection.close
        return
      end

      connection.send_json({type: "welcome"})
      socket.on_message do |raw|
        begin
          # Channel callbacks (subscribed/receive) may go deep (DB, crypto);
          # keep that off the long-lived connection fiber's stack.
          Cable.run_detached { handle_frame(server, connection, channels, raw) }
        rescue RejectedError
          connection.close
        rescue
          # One malformed frame must never kill the pump.
        end
      end
      socket.on_close do |_code, _message|
        begin
          Cable.run_detached { server.unsubscribe_connection(connection) }
        rescue
        end
        connection.close
        server.unregister(connection)
      end
      # The socket now idles in the read loop: release the stack pages the
      # HTTP request and upgrade path touched on the way here.
      trim_fiber_stack
    end

    # Returns to the kernel the stack pages of the current fiber that lie
    # below the stack pointer (minus `margin`). Those pages belong to calls
    # that have already returned, so dropping them is safe; the next deep
    # call simply faults fresh zero pages in. A WebSocket connection's fiber
    # touches its stack deeply once (HTTP parsing, upgrade, handshake) and
    # then idles in the read loop for hours: without this, every such page
    # stays resident per socket. Returns the bytes released (0 when the
    # fiber's stack is not a pooled 8 MiB stack, e.g. the main fiber).
    def self.trim_fiber_stack(margin : Int32 = 4 * 1024) : Int64
      {% if flag?(:linux) || flag?(:darwin) || flag?(:freebsd) %}
        stack = Fiber.current.@stack
        return 0_i64 unless stack.reusable?
        low = stack.pointer.address
        marker = 0_u8
        sp = pointerof(marker).address
        return 0_i64 unless low < sp && sp <= stack.bottom.address
        page = 4096_u64
        top = (sp - margin.to_u64) & ~(page - 1)
        start = (low + page - 1) & ~(page - 1)
        return 0_i64 if top <= start
        len = top - start
        LibC.madvise(Pointer(Void).new(start), len, LibC::MADV_DONTNEED)
        len.to_i64
      {% else %}
        0_i64
      {% end %}
    end

    # Fixed set of fibers that write queued frames to sockets. Connections
    # with pending frames are scheduled here instead of owning a writer
    # fiber each: a broadcast to N idle sockets then costs no N fibers (and
    # N stacks), only queue entries. A peer that stops reading cannot pin a
    # worker for long: sockets get `Cable.write_timeout`.
    class WriterPool
      getter size : Int32

      def initialize(@size : Int32)
        @queue = Deque(Connection).new
        @mutex = Mutex.new
        # Buffered wake-ups: a signal sent while every worker is busy is not
        # lost, and workers re-check the queue before waiting again.
        @wake = ::Channel(Nil).new(@size)
        @size.times { |i| spawn(name: "saci-cable-writer-#{i}") { work } }
      end

      def schedule(connection : Connection) : Nil
        @mutex.synchronize { @queue.push(connection) }
        select
        when @wake.send(nil)
        else
          # Every worker already has a pending wake-up.
        end
      end

      private def work : Nil
        loop do
          if connection = @mutex.synchronize { @queue.shift? }
            begin
              connection.drain
            rescue ex
              Cable.report_error(ex, "writer")
            end
          else
            @wake.receive
          end
        end
      end
    end

    @@writer_pool : WriterPool? = nil
    @@writer_pool_mutex = Mutex.new
    class_property writer_pool_size : Int32 = 32
    # Max time one frame write may block before the peer is dropped.
    class_property write_timeout : Time::Span? = 10.seconds

    def self.writer_pool : WriterPool
      @@writer_pool || @@writer_pool_mutex.synchronize { @@writer_pool ||= WriterPool.new(writer_pool_size) }
    end

    # Runs `block` on a fresh short-lived fiber and waits for it, re-raising
    # its exception. Used for per-frame work on WebSocket connections: a
    # connection's own fiber lives as long as the socket, and every stack
    # page it touches once (deep handlers, DB drivers, crypto) stays resident
    # for that whole time. A detached fiber's stack goes back to the pool.
    def self.run_detached(&block : -> _) : Nil
      done = ::Channel(Exception?).new(1)
      spawn(name: "saci-cable-work") do
        failure = nil.as(Exception?)
        begin
          block.call
        rescue ex
          failure = ex
        end
        done.send(failure)
      end
      if failure = done.receive
        raise failure
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
      # `headers` are sent with the upgrade request (e.g. `Cookie` from an
      # HTTP login, `Origin` for allowlist specs).
      def initialize(host : String, port : Int32, path : String = "/cable", headers : HTTP::Headers = HTTP::Headers.new)
        @buffer = [] of String
        @buffer_mutex = Mutex.new
        @wake = ::Channel(Nil).new
        @ws = HTTP::WebSocket.new(host, path, port, headers: headers)
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
            raise RejectedError.new("Subscription rejected for #{identifier}")
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

    # Test adapter (G97): a normal `Server` that records every published
    # payload in memory. Use it in place of the default server:
    #
    # ```
    # server = Saci::Cable::TestServer.new
    # router = Saci::Router.new.draw { |r| r.cable "/cable", ChatChannel, server: server }
    # # ...
    # server.broadcasts("chat:1").size.should eq(1)
    # server.clear_broadcasts
    # ```
    class TestServer < Server
      def initialize(*, max_connections : Int32 = 0,
                     message_buffer_size : Int32 = Connection::DEFAULT_MESSAGE_BUFFER_SIZE)
        super(max_connections: max_connections, message_buffer_size: message_buffer_size)
        self.record_broadcasts = true
      end

      # Convenience for spec teardown (`server.clear!`).
      def clear! : Nil
        clear_broadcasts
      end
    end

    alias TestAdapter = TestServer

    # Assertions for cable specs, included into `Saci::TestSession` (see
    # `src/saci/cable_testing.cr`). They operate on a server (default:
    # `Cable.server`) and therefore also work with a `TestServer` passed
    # explicitly to `Router#cable`.
    module TestHelpers
      # Recorded payloads for `stream` (newest last).
      def broadcasts(stream : String, server : ::Saci::Cable::Server = ::Saci::Cable.server) : Array(JSON::Any)
        server.broadcasts(stream)
      end

      def assert_broadcasts(stream : String, count : Int32,
                            server : ::Saci::Cable::Server = ::Saci::Cable.server) : Nil
        actual = server.broadcasts(stream).size
        unless actual == count
          raise "Expected #{count} broadcast(s) on #{stream.inspect}, got #{actual}: #{server.broadcasts(stream).map(&.to_json)}"
        end
      end

      def assert_no_broadcasts(stream : String,
                               server : ::Saci::Cable::Server = ::Saci::Cable.server) : Nil
        assert_broadcasts(stream, 0, server)
      end

      def assert_has_stream(stream : String,
                            server : ::Saci::Cable::Server = ::Saci::Cable.server) : Nil
        unless server.has_stream?(stream)
          raise "Expected an open subscription on stream #{stream.inspect}; active streams: #{server.stream_names}"
        end
      end

      def assert_has_stream_for(broadcastable, prefix : String? = nil,
                                server : ::Saci::Cable::Server = ::Saci::Cable.server) : Nil
        assert_has_stream(::Saci::Cable.broadcasting_for(broadcastable, prefix), server)
      end

      # Accepts a block that either raises `Cable::RejectedError`, returns
      # false/nil, or returns a closed/rejected `Connection`.
      def assert_reject_connection(&block : -> T) : Nil forall T
        rejected = false
        begin
          result = block.call
          if result.is_a?(::Saci::Cable::Connection)
            rejected = result.rejected? || result.closed?
          else
            rejected = (result == false)
          end
        rescue ::Saci::Cable::RejectedError
          rejected = true
        end
        raise "Expected the connection to be rejected but it was accepted" unless rejected
      end

      def assert_reject_connection(connection : ::Saci::Cable::Connection) : Nil
        unless connection.rejected? || connection.closed?
          raise "Expected the connection to be rejected but it is still open"
        end
      end

      def open_connections(server : ::Saci::Cable::Server = ::Saci::Cable.server) : Array(::Saci::Cable::Connection)
        server.open_connections
      end

      def open_connections_count(server : ::Saci::Cable::Server = ::Saci::Cable.server) : Int32
        server.open_connections_count
      end

      def assert_no_open_connections(server : ::Saci::Cable::Server = ::Saci::Cable.server) : Nil
        count = server.open_connections_count
        raise "Expected no open cable connections, got #{count}" if count > 0
      end
    end
  end
end

# Record-derived stream names (G94) and the model-level `broadcasts_for`
# macro are kept in a separate file so the core cable implementation stays
# usable without the ORM.
require "./cable_record"

# DB-backed pub/sub (G93/G164) + PostgreSQL adapter entry point (G282).
require "./cable_solid"

# Existing `TestSession` users get the assertions automatically when cable
# is loaded after test_session (the order in `src/saci.cr`); standalone
# `require "saci/cable"` simply skips this. `cable_testing` provides the
# same integration explicitly.
{% if @top_level.has_constant?("Saci") && @top_level.constant("Saci").has_constant?("TestSession") %}
  class ::Saci::TestSession
    include ::Saci::Cable::TestHelpers
  end
{% end %}
