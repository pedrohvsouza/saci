require "json"
require "html"

module Saci
  # Minimal Stimulus-compatible controller layer (G71), vendored without npm.
  #
  # ```
  # Saci::Stimulus.draw do |map|
  #   map.controller "hello", path: "controllers/hello_controller"
  # end
  #
  # # layout
  # <%= stimulus_tags %>
  # # data-controller="hello"
  # # data-action="click->hello#greet"
  # # data-hello-target="name"
  # # data-hello-url-value="/greet"
  # ```
  #
  # The loader resolves unregistered identifiers through
  # `window.__SACI_STIMULUS_MODULES__` using dynamic `import()` (so it works
  # with `Saci::Importmap`), or explicit classes registered with
  # `window.SaciStimulus.register("hello", class extends SaciStimulus.Controller {...})`.
  #
  # Implemented subset: `data-controller` scanning, `data-action` event
  # binding (including `.prevent`/`.stop`/`.self`/`.once`/`.capture` and
  # basic key filters), `this.targets.find/findAll/has`, and
  # `this.values.get/has/set`. Morphing, outlets, classes and CSS classes
  # APIs are intentionally out of scope.
  module Stimulus
    JS = {{ read_file("#{__DIR__}/assets/stimulus.js") }}

    # One identifier -> ES module specifier entry from the manifest.
    class ControllerEntry
      getter identifier : String
      getter path : String?

      def initialize(@identifier : String, @path : String? = nil)
        raise ArgumentError.new("stimulus controller identifier cannot be empty") if @identifier.empty?
      end

      # Import-map specifier used by the loader when no explicit class was
      # registered. Defaults to `controllers/<identifier>_controller`.
      def module_path : String
        @path || "controllers/#{@identifier}_controller"
      end
    end

    class Manifest
      getter controllers : Array(ControllerEntry) = [] of ControllerEntry

      def controller(identifier : String, path : String? = nil) : ControllerEntry
        @controllers.reject! { |entry| entry.identifier == identifier }
        entry = ControllerEntry.new(identifier, path)
        @controllers << entry
        entry
      end

      def stimulus_controllers : Array(ControllerEntry)
        @controllers
      end

      def empty? : Bool
        @controllers.empty?
      end

      def to_h : Hash(String, String)
        result = {} of String => String
        @controllers.each { |entry| result[entry.identifier] = entry.module_path }
        result
      end
    end

    @@default : Manifest = Manifest.new
    @@mutex = Mutex.new

    def self.default : Manifest
      @@mutex.synchronize { @@default }
    end

    def self.manifest : Manifest
      default
    end

    def self.reset! : Manifest
      @@mutex.synchronize { @@default = Manifest.new }
    end

    def self.draw(& : Manifest ->) : Manifest
      manifest = Manifest.new
      yield manifest
      @@mutex.synchronize { @@default = manifest }
      manifest
    end

    def self.controller(identifier : String, path : String? = nil) : ControllerEntry
      default.controller(identifier, path)
    end

    # Convenience alias for the manifest contents.
    def self.stimulus_controllers : Array(ControllerEntry)
      default.stimulus_controllers
    end

    # Meta marker plus the loader module script. Module specifiers are passed
    # as escaped JSON; the loader JSON parses `data-*-value` attributes.
    def self.stimulus_tags(manifest : Manifest = default) : String
      modules_json = escape_json_for_script(manifest.to_h.to_json)
      names = manifest.controllers.map(&.identifier).join(" ")

      String.build do |io|
        io << %(<meta name="stimulus-controllers" content=") << HTML.escape(names) << %(">)
        io << %(\n<script type="module" data-stimulus>)
        io << %(window.__SACI_STIMULUS_MODULES__ = ) << modules_json << ";\n"
        io << JS
        io << %(</script>)
      end
    end

    # JS template for `saci generate stimulus_controller NAME`. Returns the
    # source string; the CLI command decides where to write it.
    def self.controller_template(name : String, actions : Array(String) = ["greet"]) : String
      identifier = identifier_for(name)
      String.build do |io|
        io << "// app/javascript/controllers/#{identifier}_controller.js\n"
        io << "// data-controller=\"#{identifier}\"\n"
        io << "// data-action=\"click->#{identifier}##{actions.first? || "greet"}\"\n"
        io << "export default class extends window.SaciStimulus.Controller {\n"
        io << "  connect() {\n"
        io << "  }\n\n"
        io << "  disconnect() {\n"
        io << "  }\n"
        actions.each do |action|
          io << "\n  #{method_name(action)}(event) {\n"
          io << "    // this.targets.find(\"name\")\n"
          io << "    // this.values.get(\"url\")\n"
          io << "  }\n"
        end
        io << "}\n"
      end
    end

    def self.stimulus_controller(name : String, actions : Array(String) = ["greet"]) : String
      controller_template(name, actions)
    end

    # "HelloController" / "hello_controller" / "hello" => "hello".
    def self.identifier_for(name : String) : String
      base = name.strip
      base = base.sub(/_controller$/, "").sub(/Controller$/, "")
      base = base.gsub(/([a-z0-9])([A-Z])/) { |_, match| "#{match[1]}_#{match[2]}" }
      base = base.gsub(/[^A-Za-z0-9]+/, "_")
      base.downcase.gsub('_', '-').strip('-')
    end

    private def self.method_name(action : String) : String
      cleaned = action.strip.gsub(/[^A-Za-z0-9_]+/, "_")
      cleaned = "action" if cleaned.empty?
      cleaned
    end

    private def self.escape_json_for_script(json : String) : String
      json.gsub("</", "<\\/")
        .gsub("<!--", "<\\u0021--")
        .gsub("\u2028", "\\u2028")
        .gsub("\u2029", "\\u2029")
    end
  end

  module CLI
    module Generate
      # Template-only generator helper. Wiring `saci generate stimulus_controller`
      # is a one-line call to this from generate_command.cr (coordinator owns
      # that file); no file is written here.
      def self.stimulus_controller(name : String, actions : Array(String) = ["greet"]) : String
        Stimulus.controller_template(name, actions)
      end
    end
  end
end
