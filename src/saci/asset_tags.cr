require "html"

module Saci
  # Asset tag helpers (Rails `AssetTagHelper` equivalent). Sources resolve
  # through `Saci::Assets` (manifest fingerprinting with a documented
  # `/assets/<logical>` fallback for missing assets). Attributes are escaped.
  #
  # ```
  # <%= stylesheet_link_tag "app.css", media: "screen" %>
  # <%= javascript_include_tag "app.js", defer: true %>
  # <%= image_tag "images/logo.png", alt: "Logo", size: "64x64" %>
  # ```
  module Views
    # Asset URL helpers (also on `Saci::Assets` and `Saci::Controller`).
    def self.asset_path(source : String, digest : Bool = true) : String
      Assets.asset_path(source, digest)
    end

    def self.asset_url(source : String, *, host : String, protocol : String = "http", port : Int32? = nil) : String
      Assets.asset_url(source, host: host, protocol: protocol, port: port)
    end

    def self.image_tag(source : String, alt : String? = nil, size : String? = nil, **attributes) : String
      attrs = attributes_hash(attributes)
      attrs["src"] = Assets.asset_path(source)
      unless attrs.has_key?("alt")
        attrs["alt"] = alt || default_alt_text(source)
      end
      if size_value = size
        width, height = size_value.split("x", 2)
        attrs["width"] = width unless attrs.has_key?("width")
        attrs["height"] = height unless attrs.has_key?("height")
      end
      tag("img", attrs)
    end

    def self.stylesheet_link_tag(*sources : String, media : String? = nil, type : String? = nil, **attributes) : String
      sources.map do |source|
        attrs = attributes_hash(attributes)
        attrs["rel"] = "stylesheet" unless attrs.has_key?("rel")
        attrs["href"] = Assets.asset_path(source)
        attrs["media"] = media if media
        attrs["type"] = type || "text/css" unless attrs.has_key?("type")
        tag("link", attrs)
      end.join("\n")
    end

    def self.javascript_include_tag(*sources : String, defer : Bool = false, async : Bool = false, type : String? = nil, **attributes) : String
      sources.map do |source|
        attrs = attributes_hash(attributes)
        attrs["src"] = Assets.asset_path(source)
        attrs["defer"] = true if defer
        attrs["async"] = true if async
        attrs["type"] = type if type
        content_tag("script", attrs, "")
      end.join("\n")
    end

    def self.favicon_link_tag(source : String = "favicon.ico", **attributes) : String
      attrs = attributes_hash(attributes)
      attrs["rel"] = "icon" unless attrs.has_key?("rel")
      attrs["href"] = Assets.asset_path(source)
      attrs["type"] = favicon_type(source) unless attrs.has_key?("type")
      tag("link", attrs)
    end

    def self.audio_tag(*sources : String, controls : Bool = true, autoplay : Bool = false, **attributes) : String
      attrs = attributes_hash(attributes)
      attrs["controls"] = true if controls
      attrs["autoplay"] = true if autoplay
      if sources.size == 1
        attrs["src"] = Assets.asset_path(sources.first)
        content_tag("audio", attrs, "")
      else
        children = sources.map do |source|
          tag("source", {"src" => Assets.asset_path(source), "type" => media_type(source)})
        end.join
        content_tag("audio", attrs) { children }
      end
    end

    def self.video_tag(*sources : String, controls : Bool = true, autoplay : Bool = false, size : String? = nil, poster : String? = nil, **attributes) : String
      attrs = attributes_hash(attributes)
      attrs["controls"] = true if controls
      attrs["autoplay"] = true if autoplay
      attrs["poster"] = Assets.asset_path(poster) if poster
      if size_value = size
        width, height = size_value.split("x", 2)
        attrs["width"] = width unless attrs.has_key?("width")
        attrs["height"] = height unless attrs.has_key?("height")
      end
      if sources.size == 1
        attrs["src"] = Assets.asset_path(sources.first)
        content_tag("video", attrs, "")
      else
        children = sources.map do |source|
          tag("source", {"src" => Assets.asset_path(source), "type" => media_type(source)})
        end.join
        content_tag("video", attrs) { children }
      end
    end

    # `<link rel="alternate" type="application/rss+xml" ...>`; defaults to
    # `/feed.rss`, `/feed.atom` or `/feed.json` when `url` is omitted.
    def self.auto_discovery_link_tag(type : String | Symbol = "rss", url : String? = nil, title : String? = nil, **attributes) : String
      kind = type.to_s.downcase
      mime, default_title = case kind
                            when "atom"
                              {"application/atom+xml", "Atom"}
                            when "json"
                              {"application/feed+json", "JSON Feed"}
                            else
                              {"application/rss+xml", "RSS"}
                            end
      attrs = attributes_hash(attributes)
      attrs["rel"] = "alternate" unless attrs.has_key?("rel")
      attrs["type"] = mime unless attrs.has_key?("type")
      attrs["title"] = title || default_title unless attrs.has_key?("title")
      attrs["href"] = url || "/feed.#{kind == "json" ? "json" : kind}"
      tag("link", attrs)
    end

    private def self.default_alt_text(source : String) : String
      base = File.basename(source)
      base = base[0...-(File.extname(base).size)] unless File.extname(base).empty?
      base.split(/[_-]/).reject(&.empty?).map(&.capitalize).join(" ")
    end

    private def self.favicon_type(source : String) : String
      case File.extname(source).downcase
      when ".png"          then "image/png"
      when ".svg"          then "image/svg+xml"
      when ".gif"          then "image/gif"
      when ".jpg", ".jpeg" then "image/jpeg"
      else                      "image/x-icon"
      end
    end

    private def self.media_type(source : String) : String
      case File.extname(source).downcase
      when ".mp3"  then "audio/mpeg"
      when ".ogg"  then "audio/ogg"
      when ".wav"  then "audio/wav"
      when ".m4a"  then "audio/mp4"
      when ".mp4"  then "video/mp4"
      when ".webm" then "video/webm"
      when ".ogv"  then "video/ogg"
      when ".mov"  then "video/quicktime"
      else              "application/octet-stream"
      end
    end
  end

  class Controller
    # -- asset pipeline ------------------------------------------------------
    def asset_path(source : String, digest : Bool = true) : String
      Assets.asset_path(source, digest)
    end

    def asset_url(source : String, *, host : String, protocol : String = "http", port : Int32? = nil) : String
      Assets.asset_url(source, host: host, protocol: protocol, port: port)
    end

    # -- asset tags ----------------------------------------------------------
    def image_tag(source : String, alt : String? = nil, size : String? = nil, **attributes) : String
      Views.image_tag(source, alt, size, **attributes)
    end

    def stylesheet_link_tag(*sources : String, **options) : String
      Views.stylesheet_link_tag(*sources, **options)
    end

    def javascript_include_tag(*sources : String, **options) : String
      Views.javascript_include_tag(*sources, **options)
    end

    def favicon_link_tag(source : String = "favicon.ico", **attributes) : String
      Views.favicon_link_tag(source, **attributes)
    end

    def audio_tag(*sources : String, **options) : String
      Views.audio_tag(*sources, **options)
    end

    def video_tag(*sources : String, **options) : String
      Views.video_tag(*sources, **options)
    end

    def auto_discovery_link_tag(type : String | Symbol = "rss", url : String? = nil, title : String? = nil, **attributes) : String
      Views.auto_discovery_link_tag(type, url, title, **attributes)
    end
  end
end
