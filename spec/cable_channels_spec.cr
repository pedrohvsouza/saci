require "spec"
require "../src/saci"
require "../src/saci/cable_testing"

# Channels are tracked by identifier, independently of their streams.
class CableTrackingLog
  class_getter events = [] of String
end

class CableNoStreamChannel < Saci::Cable::Channel
  def receive(data)
    transmit({echo: data["n"].as_i})
  end
end

class CableManyStreamsChannel < Saci::Cable::Channel
  def subscribed
    stream_from "tracking:a"
    stream_from "tracking:b"
    stream_from "tracking:c"
  end

  def unsubscribed
    CableTrackingLog.events << "unsubscribed"
  end
end

private def tracking_wait(timeout = 2.seconds, &) : Nil
  deadline = Time.instant + timeout
  until yield
    raise "timed out" if Time.instant > deadline
    sleep 5.milliseconds
  end
end

private def tracking_next(client, timeout = 500.milliseconds) : JSON::Any?
  client.next_message(timeout)
rescue
  nil
end

describe "Saci::Cable channel tracking" do
  it "delivers client messages to a channel that streams nothing" do
    router = Saci::Router.new.draw { |r| r.cable "/cable", CableNoStreamChannel }
    Saci::TestSession.serve(router) do |app|
      client = app.cable_client
      begin
        identifier = client.subscribe("CableNoStreamChannel")
        client.send_message(identifier, {n: 7})
        reply = client.next_message
        until reply["message"]?
          reply = client.next_message
        end
        reply["message"]["echo"].as_i.should eq(7)
      ensure
        client.close
      end
    end
  end

  it "unsubscribes from every stream of a channel and runs the hook once" do
    CableTrackingLog.events.clear
    server = Saci::Cable::Server.new
    router = Saci::Router.new.draw { |r| r.cable "/cable", CableManyStreamsChannel, server: server }
    Saci::TestSession.serve(router) do |app|
      client = app.cable_client
      begin
        identifier = client.subscribe("CableManyStreamsChannel")
        tracking_wait { server.subscriber_count("tracking:c") == 1 }
        client.unsubscribe(identifier)
        tracking_wait { CableTrackingLog.events.size == 1 }
        {"tracking:a", "tracking:b", "tracking:c"}.each { |s| server.subscriber_count(s).should eq(0) }
        server.broadcast("tracking:b", {late: true})
        tracking_next(client).should be_nil
        sleep 50.milliseconds
        CableTrackingLog.events.should eq(["unsubscribed"])
      ensure
        client.close
      end
    end
  end

  it "runs the unsubscribed hook once when a multi-stream connection closes" do
    CableTrackingLog.events.clear
    server = Saci::Cable::Server.new
    router = Saci::Router.new.draw { |r| r.cable "/cable", CableManyStreamsChannel, server: server }
    Saci::TestSession.serve(router) do |app|
      client = app.cable_client
      client.subscribe("CableManyStreamsChannel")
      tracking_wait { server.subscriber_count("tracking:a") == 1 }
      client.close
      tracking_wait { CableTrackingLog.events.size >= 1 && server.subscriber_count("tracking:a") == 0 }
      sleep 50.milliseconds
      CableTrackingLog.events.should eq(["unsubscribed"])
    end
  end

  it "keeps one channel when the same identifier subscribes twice" do
    server = Saci::Cable::Server.new
    router = Saci::Router.new.draw { |r| r.cable "/cable", CableManyStreamsChannel, server: server }
    Saci::TestSession.serve(router) do |app|
      client = app.cable_client
      begin
        client.subscribe("CableManyStreamsChannel")
        client.subscribe("CableManyStreamsChannel")
        tracking_wait { server.subscriber_count("tracking:a") >= 1 }
        sleep 50.milliseconds
        server.subscriber_count("tracking:a").should eq(1)
      ensure
        client.close
      end
    end
  end
end
