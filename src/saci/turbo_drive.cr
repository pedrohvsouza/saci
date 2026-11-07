require "html"
require "./configuration"

module Saci
  # Turbo Drive addition on top of `Saci::Turbo` (frames/streams).
  #
  # The vendored script is a dependency-free subset: same-origin link and
  # form interception, `<body>`/`<title>` swapping through `DOMParser`,
  # `pushState`/`replaceState` + `popstate`, per-entry scroll restoration,
  # and `turbo:before-fetch-request` / `turbo:before-render` / `turbo:render`
  # / `turbo:load` CustomEvents. Any failure (network, non-HTML response,
  # disabled support) falls back to ordinary browser navigation.
  #
  # ```
  # # in a layout (rendered only when enabled):
  # <%= turbo_drive_tags %>
  #
  # # config/application.cr
  # Saci.configure { |config| config.turbo_drive = false } # opt out globally
  # ```
  #
  # `data-turbo="false"` on a link/form (or any ancestor) opts that element
  # out. The script honours `data-turbo="false"` on `<html>` too.
  module TurboDrive
    JS = {{ read_file("#{__DIR__}/assets/turbo_drive.js") }}

    META_NAME = "turbo-drive"

    # True when the global config enables Turbo Drive. Calling
    # `turbo_drive_tags` also expresses intent, so the default is on.
    def self.enabled? : Bool
      Saci.config.turbo_drive?
    end

    def self.turbo_drive? : Bool
      enabled?
    end

    # Returns the meta marker plus an inline module script, or "" when
    # disabled. `enabled:` overrides the global config for one layout.
    def self.turbo_drive_tags(enabled : Bool? = nil) : String
      active = enabled.nil? ? enabled? : enabled.not_nil!
      return "" unless active

      String.build do |io|
        io << %(<meta name=") << META_NAME << %(" content="enabled">)
        io << %(\n<script type="module" data-turbo-drive>)
        io << JS
        io << %(</script>)
      end
    end
  end

  class Configuration
    property turbo_drive : Bool = true

    def turbo_drive? : Bool
      @turbo_drive
    end
  end

  def self.turbo_drive? : Bool
    config.turbo_drive?
  end

  def self.turbo_drive=(value : Bool) : Bool
    config.turbo_drive = value
  end
end
