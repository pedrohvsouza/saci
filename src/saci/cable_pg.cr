# PostgreSQL LISTEN/NOTIFY for `Saci::Cable::PostgresServer`.
#
# Opt-in: this file requires the `pg` driver, which the framework never
# links on its own (see the driver note in `src/saci/record.cr`). Apps on
# PostgreSQL add it next to their driver require:
#
# ```
# require "pg"
# require "saci/cable_pg"
# ```
#
# and then pass `listen_notify: true` to `PostgresServer.new`.
require "pg"
require "./cable"

# :nodoc:
# crystal-pg only exposes its notification read loop through
# `PG.connect_listen`, which runs it in a fiber of its own: a dropped
# socket then surfaces as an unhandled exception that the caller never
# sees. This exposes the same protected loop so `PgListener` can run it in
# its own fiber, rescue the error and reconnect.
class PG::Connection
  # :nodoc:
  def saci_cable_listen(channels : Enumerable(String)) : Nil
    listen(channels, blocking: true)
  end
end

module Saci
  module Cable
    # Holds the LISTEN connection for one `PostgresServer`. Peer
    # notifications wake the server's poller; the server's own are
    # ignored.
    #
    # Liveness: a closed or reset socket ends the read loop and the
    # listener reconnects with backoff (`RECONNECT_INITIAL` doubling to
    # `RECONNECT_MAX`). A connection that stays open but stops delivering
    # (a half-open TCP connection, say) is caught by a heartbeat: the
    # listener pings itself on a private channel every `heartbeat` and
    # drops the connection after `MISSED_HEARTBEATS` heartbeats without
    # any notification. Each new connection wakes the poller, which picks
    # up anything published while the listener was away.
    class PgListener < PostgresServer::Listener
      RECONNECT_INITIAL = 100.milliseconds
      RECONNECT_MAX     = 5.seconds
      MISSED_HEARTBEATS = 3
      PING_PREFIX       = "saci_cable_ping_"

      getter url : String
      getter channel : String
      getter ping_channel : String
      getter heartbeat : Time::Span

      @conn : PG::Connection?

      def initialize(@server : PostgresServer, @url : String,
                     @channel : String = server.notify_channel,
                     @heartbeat : Time::Span = server.listen_heartbeat)
        @ping_channel = "#{PING_PREFIX}#{server.id}"
        @closed = Atomic(Bool).new(false)
        @connected = Atomic(Bool).new(false)
        @connects = Atomic(Int32).new(0)
        @stop = ::Channel(Nil).new(1)
        @conn_mutex = Mutex.new
        @conn = nil
        @heard_mutex = Mutex.new
        @last_heard = Time.instant
        spawn { supervise }
      end

      def connected? : Bool
        @connected.get
      end

      # Number of LISTEN connections opened so far (1 + reconnects).
      def connects : Int32
        @connects.get
      end

      def closed? : Bool
        @closed.get
      end

      # Stops the listener and closes its connection (idempotent).
      def close : Nil
        return if @closed.swap(true)
        @conn_mutex.synchronize { @conn.try { |conn| close_quietly(conn) } }
        select
        when @stop.send(nil)
        else
        end
      end

      private def supervise : Nil
        backoff = RECONNECT_INITIAL
        until @closed.get
          conn = nil
          begin
            live = conn = DB.connect(@url).as(PG::Connection)
            live.on_notification { |notification| handle(notification) }
            closed_meanwhile = @conn_mutex.synchronize do
              @conn = live
              @closed.get
            end
            break if closed_meanwhile
            touch
            spawn { watch(live) }
            listen(live) { backoff = RECONNECT_INITIAL }
          rescue ex
            Cable.report_error(ex, "pg listen") unless @closed.get
          ensure
            @connected.set(false)
            @conn_mutex.synchronize { @conn = nil }
            conn.try { |c| close_quietly(c) }
          end
          break if @closed.get
          select
          when @stop.receive
            break
          when timeout(backoff)
          end
          backoff = {backoff * 2, RECONNECT_MAX}.min
        end
      end

      # Runs LISTEN, marks the listener connected and blocks in the read
      # loop until the socket closes (returns) or fails (raises).
      private def listen(conn : PG::Connection, &) : Nil
        conn.exec_all("LISTEN #{conn.escape_identifier(@channel)}")
        conn.exec_all("LISTEN #{conn.escape_identifier(@ping_channel)}")
        @connected.set(true)
        @connects.add(1)
        yield
        @server.wake
        conn.saci_cable_listen([] of String)
      end

      # Pings every heartbeat while `conn` is open, and closes it once it
      # has gone silent so `supervise` reconnects.
      private def watch(conn : PG::Connection) : Nil
        loop do
          sleep @heartbeat
          return if @closed.get || conn.closed?
          silent = @heard_mutex.synchronize { Time.instant - @last_heard }
          if silent > @heartbeat * MISSED_HEARTBEATS
            Cable.report_error(
              IO::TimeoutError.new("no notification on #{@ping_channel} for #{silent.total_seconds.round(1)}s; reconnecting"),
              "pg listen")
            close_quietly(conn)
            return
          end
          begin
            @server.notify("ping", @ping_channel)
          rescue ex
            Cable.report_error(ex, "pg listen ping")
          end
        end
      end

      private def handle(notification : PQ::Notification) : Nil
        touch
        return if notification.channel == @ping_channel
        return if notification.payload == @server.id
        @server.wake
      end

      private def touch : Nil
        @heard_mutex.synchronize { @last_heard = Time.instant }
      end

      private def close_quietly(conn : PG::Connection) : Nil
        conn.close
      rescue
      end
    end
  end
end

Saci::Cable::PostgresServer.listener_factory = ->(server : Saci::Cable::PostgresServer, url : String) do
  Saci::Cable::PgListener.new(server, url).as(Saci::Cable::PostgresServer::Listener)
end
