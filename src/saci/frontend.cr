require "html"
require "./controller"
require "./views"
require "./turbo"
require "./importmap"
require "./turbo_drive"
require "./stimulus"
require "./pwa"

module Saci
  # Additional Turbo tag helpers (G73). `turbo_frame_tag` already lives on
  # `Saci::Turbo` and `Saci::Controller`; this file only adds the missing
  # `Views` wrapper plus `turbo_stream_from` / generic `turbo_stream` tags, so
  # there is still exactly one implementation of each helper.
  module Turbo
    # `<turbo-cable-stream-source>` for a Saci Cable stream. Unlike Rails
    # there is no signed stream name: the cable consumer reads `stream`.
    # One element is emitted per stream, newline-separated.
    def self.turbo_stream_from(stream : String, *more_streams, channel : String = "Saci::Turbo::StreamsChannel") : String
      ([stream] + more_streams.map(&.to_s).to_a).map do |name|
        %(<turbo-cable-stream-source channel="#{HTML.escape(channel)}" stream="#{HTML.escape(name)}"></turbo-cable-stream-source>)
      end.join("\n")
    end

    # Generic `<turbo-stream>` builder used by custom actions. `html` goes
    # inside `<template>` RAW (same escaping contract as the other builders).
    def self.turbo_stream(action : String, *, target : String? = nil, targets : String? = nil, html : String? = nil) : String
      if target && targets
        raise ArgumentError.new("turbo_stream takes either target: or targets:, not both")
      end
      selector = if sel = targets
                   %( targets="#{HTML.escape(sel)}")
                 elsif id = target
                   %( target="#{HTML.escape(id)}")
                 else
                   raise ArgumentError.new("turbo_stream requires target: or targets:")
                 end
      body = html ? "<template>#{html}</template>" : ""
      %(<turbo-stream action="#{HTML.escape(action)}"#{selector}>#{body}</turbo-stream>)
    end

    # Positional convenience form: `turbo_stream("append", "msgs", "<p>x</p>")`.
    def self.turbo_stream(action : String, target : String, html : String? = nil) : String
      turbo_stream(action, target: target, targets: nil, html: html)
    end
  end

  module Views
    def self.turbo_frame_tag(id : String, src : String? = nil, loading : String? = nil, & : -> String) : String
      Turbo.turbo_frame_tag(id, src: src, loading: loading) { yield }
    end

    def self.turbo_stream_from(stream : String, *more_streams, channel : String = "Saci::Turbo::StreamsChannel") : String
      Turbo.turbo_stream_from(stream, *more_streams, channel: channel)
    end

    def self.turbo_stream(action : String, *, target : String? = nil, targets : String? = nil, html : String? = nil) : String
      Turbo.turbo_stream(action, target: target, targets: targets, html: html)
    end

    def self.turbo_stream(action : String, target : String, html : String? = nil) : String
      Turbo.turbo_stream(action, target, html)
    end

    # Import map + modulepreload links (see `Saci::Importmap`).
    def self.importmap_tags(manifest : Importmap::Manifest = Importmap.default, preload : Bool = true) : String
      Importmap.importmap_tags(manifest, preload: preload)
    end

    # Rails-compatible alias for `importmap_tags`.
    def self.javascript_importmap_tags(manifest : Importmap::Manifest = Importmap.default, preload : Bool = true) : String
      Importmap.importmap_tags(manifest, preload: preload)
    end

    def self.turbo_drive_tags(enabled : Bool? = nil) : String
      TurboDrive.turbo_drive_tags(enabled)
    end

    def self.stimulus_tags(manifest : Stimulus::Manifest = Stimulus.manifest) : String
      Stimulus.stimulus_tags(manifest)
    end

    def self.pwa_tags(manifest_path : String = "/manifest.json",
                      service_worker : String? = "/service-worker.js",
                      theme_color : String? = nil,
                      icon : String? = nil,
                      scope : String = "/",
                      register : Bool = true) : String
      PWA.pwa_tags(
        manifest_path: manifest_path,
        service_worker: service_worker,
        theme_color: theme_color,
        icon: icon,
        scope: scope,
        register: register
      )
    end

    def self.manifest_tag(manifest_path : String = "/manifest.json", theme_color : String? = nil) : String
      PWA.manifest_tag(manifest_path, theme_color)
    end
  end

  # Controller wrappers so ECR templates can call the helpers directly. The
  # existing `turbo_frame_tag` lives in turbo.cr and is intentionally not
  # redefined here.
  class Controller
    def importmap_tags(manifest : Importmap::Manifest = Importmap.default, preload : Bool = true) : String
      Views.importmap_tags(manifest, preload)
    end

    def javascript_importmap_tags(manifest : Importmap::Manifest = Importmap.default, preload : Bool = true) : String
      Views.importmap_tags(manifest, preload)
    end

    def turbo_drive_tags(enabled : Bool? = nil) : String
      Views.turbo_drive_tags(enabled)
    end

    def stimulus_tags(manifest : Stimulus::Manifest = Stimulus.manifest) : String
      Views.stimulus_tags(manifest)
    end

    def pwa_tags(manifest_path : String = "/manifest.json",
                 service_worker : String? = "/service-worker.js",
                 theme_color : String? = nil,
                 icon : String? = nil,
                 scope : String = "/",
                 register : Bool = true) : String
      Views.pwa_tags(
        manifest_path: manifest_path,
        service_worker: service_worker,
        theme_color: theme_color,
        icon: icon,
        scope: scope,
        register: register
      )
    end

    def manifest_tag(manifest_path : String = "/manifest.json", theme_color : String? = nil) : String
      Views.manifest_tag(manifest_path, theme_color)
    end

    def turbo_stream_from(stream : String, *more_streams, channel : String = "Saci::Turbo::StreamsChannel") : String
      Turbo.turbo_stream_from(stream, *more_streams, channel: channel)
    end

    def turbo_stream(action : String, *, target : String? = nil, targets : String? = nil, html : String? = nil) : String
      Turbo.turbo_stream(action, target: target, targets: targets, html: html)
    end

    def turbo_stream(action : String, target : String, html : String? = nil) : String
      Turbo.turbo_stream(action, target, html)
    end
  end
end
