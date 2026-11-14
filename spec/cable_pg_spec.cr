require "spec"
require "../src/saci"

# Live PostgreSQL LISTEN/NOTIFY specs for `Saci::Cable::PostgresServer`.
# They compile only with PG_URL set, because requiring the pg driver breaks
# linking on systems where the suite otherwise builds (see the driver note
# in `src/saci/record.cr`):
#
#   docker compose -f docker-compose.live.yml up -d saci-pg
#   PG_URL=postgres://saci:saci@127.0.0.1:55432/saci_test crystal spec spec/cable_pg_spec.cr
{% if env("PG_URL") %}
  require "pg"
  require "../src/saci/cable_pg"

  class CablePgProbeChannel < Saci::Cable::Channel
    @@received = [] of String
    @@mutex = Mutex.new

    def self.received : Array(String)
      @@mutex.synchronize { @@received.dup }
    end

    def self.reset! : Nil
      @@mutex.synchronize { @@received.clear }
    end

    def subscribed
      stream_from "pg:probe"
    end

    def deliver(identifier : String, payload) : Nil
      @@mutex.synchronize { @@received << payload.to_json }
    end
  end

  def cable_pg_url : String
    ENV["PG_URL"]
  end

  def cable_pg_wait_until(desc : String, timeout : Time::Span = 5.seconds, &) : Nil
    deadline = Time.instant + timeout
    until yield
      raise "timed out waiting for #{desc}" if Time.instant > deadline
      sleep 10.milliseconds
    end
  end

  def cable_pg_server(db : DB::Database, listen_heartbeat : Time::Span = 10.seconds) : Saci::Cable::PostgresServer
    # An hour-long poll interval leaves NOTIFY as the only fast path.
    Saci::Cable::PostgresServer.new(db, listen_notify: true, listen_url: cable_pg_url,
      listen_heartbeat: listen_heartbeat, poll_interval: 1.hour, cleanup_interval: 0)
  end

  def cable_pg_listener(server : Saci::Cable::PostgresServer) : Saci::Cable::PgListener
    server.listener.as(Saci::Cable::PgListener)
  end

  def cable_pg_subscriber(server : Saci::Cable::Server) : Saci::Cable::Connection
    connection = Saci::Cable::Connection.new(HTTP::WebSocket.new(IO::Memory.new), Saci::Params.new, server)
    server.register(connection)
    server.subscribe(CablePgProbeChannel, connection, Saci::Cable.identifier_for("CablePgProbeChannel"),
      {} of String => JSON::Any)
    connection
  end

  describe "Saci::Cable::PostgresServer LISTEN/NOTIFY (live PostgreSQL)" do
    it "registers the listener factory" do
      Saci::Cable::PostgresServer.listen_notify_supported?.should be_true
    end

    it "keeps polling mode when listen_notify is off" do
      db = DB.open(cable_pg_url)
      server = Saci::Cable::PostgresServer.new(db, start_polling: false)
      begin
        server.listen_notify?.should be_false
        server.listener.should be_nil
        server.poll_interval.should eq(250.milliseconds)
      ensure
        server.close
        db.close
      end
    end

    it "delivers a peer's broadcast through NOTIFY instead of the poll interval" do
      CablePgProbeChannel.reset!
      db = DB.open(cable_pg_url)
      publisher = cable_pg_server(db)
      subscriber = cable_pg_server(db)
      begin
        publisher.listen_notify?.should be_true
        publisher.poll_interval.should eq(1.hour)
        cable_pg_wait_until("listeners connected") do
          cable_pg_listener(publisher).connected? && cable_pg_listener(subscriber).connected?
        end
        connection = cable_pg_subscriber(subscriber)
        # The subscriber's first poll ran at boot; only a wake-up can
        # deliver the next row within the hour.
        sleep 100.milliseconds

        publisher.broadcast("pg:probe", {"n" => 1})
        cable_pg_wait_until("notified delivery", 3.seconds) { CablePgProbeChannel.received.size == 1 }
        publisher.broadcast("pg:probe", {"n" => 2})
        cable_pg_wait_until("second delivery", 3.seconds) { CablePgProbeChannel.received.size == 2 }
        CablePgProbeChannel.received.should eq([%({"n":1}), %({"n":2})])
        connection.close
      ensure
        publisher.close
        subscriber.close
        db.close
      end
    end

    it "reconnects after the LISTEN backend is terminated" do
      CablePgProbeChannel.reset!
      db = DB.open(cable_pg_url)
      publisher = cable_pg_server(db)
      subscriber = cable_pg_server(db, listen_heartbeat: 100.milliseconds)
      begin
        listener = cable_pg_listener(subscriber)
        cable_pg_wait_until("listener connected") { listener.connected? }
        listener.connects.should eq(1)
        connection = cable_pg_subscriber(subscriber)

        terminated = db.scalar(<<-SQL, "%#{listener.ping_channel}%").as(Int64)
          SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity
          WHERE query LIKE $1 AND pid <> pg_backend_pid()
          SQL
        terminated.should eq(1)

        cable_pg_wait_until("reconnect", 5.seconds) { listener.connects >= 2 && listener.connected? }
        publisher.broadcast("pg:probe", {"after" => "reconnect"})
        cable_pg_wait_until("delivery after reconnect", 3.seconds) { !CablePgProbeChannel.received.empty? }
        CablePgProbeChannel.received.should eq([%({"after":"reconnect"})])
        connection.close
      ensure
        publisher.close
        subscriber.close
        db.close
      end
    end

    it "closes its LISTEN connection on close" do
      db = DB.open(cable_pg_url)
      server = cable_pg_server(db)
      listener = cable_pg_listener(server)
      begin
        cable_pg_wait_until("listener connected") { listener.connected? }
      ensure
        server.close
      end
      listener.closed?.should be_true
      cable_pg_wait_until("listener disconnected") { !listener.connected? }
      cable_pg_wait_until("backend gone") do
        db.scalar("SELECT count(*) FROM pg_stat_activity WHERE query LIKE $1 AND pid <> pg_backend_pid()",
          "%#{listener.ping_channel}%").as(Int64) == 0
      end
      db.close
    end
  end
{% else %}
  describe "Saci::Cable::PostgresServer LISTEN/NOTIFY (live PostgreSQL)" do
    pending "set PG_URL at compile time, e.g. postgres://saci:saci@127.0.0.1:55432/saci_test" do
    end
  end
{% end %}
