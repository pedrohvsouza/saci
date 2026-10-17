module Saci
  # Hotwire Turbo primitives, server-side only (no JavaScript bundled, no
  # new dependencies). Frames and streams are plain HTML strings; the
  # browser behavior comes from the Turbo CDN script (see README).
  #
  # Escaping contract (pinned by spec, read carefully):
  # * `id` / `target` / `targets` / `src` / `loading` attributes are
  #   HTML-escaped by the builders.
  # * `html` payloads go into `<template>` RAW and unescaped. Turbo parses
  #   `<template>` content as HTML, so escaping it would render literal
  #   tags instead of elements. Escape user input YOURSELF with `h()` (or
  #   `HTML.escape`) before composing the payload:
  #     Turbo.append("msgs", "<p>#{h(params["text"]? || "")}</p>")
  #
  # Morph / page-refresh (`<meta name="turbo-refresh-method">`,
  # `turbo:morph` attributes) are out of scope — plain attribute markup
  # the app can emit itself; see README.
  module Turbo
    # Media type for turbo-stream responses (Rails parity).
    STREAM_CONTENT_TYPE = "text/vnd.turbo-stream.html"

    # Wraps the block's HTML in a `<turbo-frame>` element. `src` (remote
    # URL, lazy-loads on visibility) and `loading: "lazy"` are optional
    # (both escaped). Block content is inserted RAW (same contract as
    # stream payloads — escape user input with `h()` yourself).
    def self.turbo_frame_tag(id : String, src : String? = nil, loading : String? = nil, & : -> String) : String
      String.build do |io|
        io << %(<turbo-frame id=") << HTML.escape(id) << %(")
        io << %( src=") << HTML.escape(src) << %(") if src
        io << %( loading=") << HTML.escape(loading) << %(") if loading
        io << ">" << yield << "</turbo-frame>"
      end
    end

    # -- stream builders (each returns one `<turbo-stream>` element) --------
    # `targets:` emits a `targets="..."` CSS-selector attribute instead of
    # `target="..."` (Rails parity); both are escaped. `html` is RAW.

    def self.append(target : String, html : String, targets : String? = nil) : String
      stream("append", target, html, targets)
    end

    def self.prepend(target : String, html : String, targets : String? = nil) : String
      stream("prepend", target, html, targets)
    end

    def self.replace(target : String, html : String, targets : String? = nil) : String
      stream("replace", target, html, targets)
    end

    def self.update(target : String, html : String, targets : String? = nil) : String
      stream("update", target, html, targets)
    end

    def self.before(target : String, html : String, targets : String? = nil) : String
      stream("before", target, html, targets)
    end

    def self.after(target : String, html : String, targets : String? = nil) : String
      stream("after", target, html, targets)
    end

    # `remove` carries no content (Rails parity: no `<template>` element).
    def self.remove(target : String, targets : String? = nil) : String
      if sel = targets
        %(<turbo-stream action="remove" targets="#{HTML.escape(sel)}"></turbo-stream>)
      else
        %(<turbo-stream action="remove" target="#{HTML.escape(target)}"></turbo-stream>)
      end
    end

    private def self.stream(action : String, target : String, html : String, targets : String?) : String
      if sel = targets
        %(<turbo-stream action="#{action}" targets="#{HTML.escape(sel)}"><template>#{html}</template></turbo-stream>)
      else
        %(<turbo-stream action="#{action}" target="#{HTML.escape(target)}"><template>#{html}</template></turbo-stream>)
      end
    end

    # -- Cable integration (streams ARE cable streams) -----------------------
    # Broadcasts the rendered `<turbo-stream>` element as the message
    # payload on `stream` (clients subscribed to that stream receive the
    # HTML string and apply it via a `<turbo-cable-stream-source>` /
    # custom consumer — see README for the wiring + CDN snippet).

    def self.broadcast_append(stream : String, target : String, html : String, server : Cable::Server = Cable.server) : Nil
      server.broadcast(stream, append(target, html))
    end

    def self.broadcast_prepend(stream : String, target : String, html : String, server : Cable::Server = Cable.server) : Nil
      server.broadcast(stream, prepend(target, html))
    end

    def self.broadcast_replace(stream : String, target : String, html : String, server : Cable::Server = Cable.server) : Nil
      server.broadcast(stream, replace(target, html))
    end

    def self.broadcast_update(stream : String, target : String, html : String, server : Cable::Server = Cable.server) : Nil
      server.broadcast(stream, update(target, html))
    end

    def self.broadcast_remove(stream : String, target : String, server : Cable::Server = Cable.server) : Nil
      server.broadcast(stream, remove(target))
    end

    def self.broadcast_before(stream : String, target : String, html : String, server : Cable::Server = Cable.server) : Nil
      server.broadcast(stream, before(target, html))
    end

    def self.broadcast_after(stream : String, target : String, html : String, server : Cable::Server = Cable.server) : Nil
      server.broadcast(stream, after(target, html))
    end
  end

  # Controller helpers (reopened here so controller.cr/views.cr/cable.cr
  # stay untouched). All take parameters, so dispatcher codegen ignores
  # them (only public zero-argument methods are dispatchable).
  class Controller
    # Frame helper in template/action context (block content RAW — `h()`
    # user input yourself).
    def turbo_frame_tag(id : String, src : String? = nil, loading : String? = nil, & : -> String) : String
      Turbo.turbo_frame_tag(id, src: src, loading: loading) { yield }
    end

    # Rails-style keyword render for streams:
    #   render turbo_stream: Turbo.append("msgs", "<p>hi</p>")
    #   render turbo_stream: [Turbo.append(...), Turbo.remove(...)], status: :ok
    # Replies with `Turbo::STREAM_CONTENT_TYPE` unless `content_type:` given.
    def render(*, turbo_stream : String | Array(String), status : Int32 | Symbol = 200, content_type : String? = nil) : Nil
      body = turbo_stream.is_a?(Array) ? turbo_stream.join : turbo_stream
      render html: body, status: status, content_type: content_type || Turbo::STREAM_CONTENT_TYPE
    end

    # Explicit equivalent (`render_turbo_stream Turbo.append(...)`).
    def render_turbo_stream(streams : String | Array(String), status : Int32 | Symbol = 200, content_type : String? = nil) : Nil
      render turbo_stream: streams, status: status, content_type: content_type
    end
  end
end
