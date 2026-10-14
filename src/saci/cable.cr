require "json"
require "mutex"

module Saci
  # ActionCable-style WebSocket support (single-process pub/sub).
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

      # Delivers `payload` to every subscriber of `stream`.
      def broadcast(stream : String, payload) : Nil
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
