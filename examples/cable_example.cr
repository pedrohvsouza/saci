require "../src/saci"

# Chat demo: two clients talking through a channel (single process).
#
# Run with: crystal run examples/cable_example.cr
# Then connect a real client to ws://127.0.0.1:4111/cable, e.g. with
# `websocat`:
#   websocat ws://127.0.0.1:4111/cable
#   {"command":"subscribe","identifier":"{\"channel\":\"DemoChatChannel\",\"room\":\"general\"}"}
#   {"command":"message","identifier":"{\"channel\":\"DemoChatChannel\",\"room\":\"general\"}","data":"{\"text\":\"hello\"}"}

class DemoChatChannel < Cable::Channel
  def subscribed
    stream_from "room:#{params["room"]?.try(&.as_s?) || "general"}"
  end

  def receive(data)
    Cable.broadcast("room:#{params["room"]?.try(&.as_s?) || "general"}", {
      from: params["user"]?.try(&.as_s?) || "anon",
      text: data["text"]? || data,
    })
  end
end

router = Router.new.draw do |r|
  r.cable "/cable", DemoChatChannel
  r.websocket("/ping") { |ws, _ctx, _params| ws.send("pong") }
end

TestSession.serve(router, port: 4111) do |app|
  alice = Cable::TestClient.new(app.host, app.port, "/cable")
  bob = Cable::TestClient.new(app.host, app.port, "/cable")

  alice.subscribe("DemoChatChannel", {"room" => "general", "user" => "alice"})
  bob.subscribe("DemoChatChannel", {"room" => "general", "user" => "bob"})

  alice.send_message(
    Cable.identifier_for("DemoChatChannel", {"room" => "general", "user" => "alice"}),
    {text: "hello room!"}
  )

  puts "alice got: #{alice.next_message["message"]}"
  puts "bob got:   #{bob.next_message["message"]}"

  alice.close
  bob.close
end
