require "./cable"
require "./test_session"

# Explicit TestSession integration for the cable test helpers (G97).
#
# `src/saci/cable.cr` already includes the helpers when it is loaded after
# `test_session` (the order used by `src/saci.cr`); requiring this file is
# idempotent and makes the dependency explicit for apps/specs that load
# cable in a different order.
class Saci::TestSession
  include Saci::Cable::TestHelpers

  # Server the session's cable endpoint uses (override by passing
  # `server:` to `Router#cable` and asserting against that server).
  def cable_server : Saci::Cable::Server
    Saci::Cable.server
  end

  def cable_client(path : String = "/cable", headers : HTTP::Headers = HTTP::Headers.new) : Saci::Cable::TestClient
    Saci::Cable::TestClient.new(host, port, path, headers)
  end
end
