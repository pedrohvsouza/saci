require "ecr"

module Saci
  # Shared view helpers (also exposed as controller instance methods so
  # templates can call `markdown(...)`, `page_numbers(...)`, `rss_feed(...)`
  # directly).
  module Views
    # Minimal XSS-safe markdown: the input is HTML-escaped FIRST, then a
    # small subset is rendered — fenced code blocks, inline code, **bold**,
    # *italic*, [links](url) (http/https/relative only), `#` headings, and
    # blank-line-separated paragraphs. Anything else stays escaped text.
    def self.markdown(text : String) : String
      # Split out fenced code blocks first so their contents are never
      # formatted (only escaped).
      segments = [] of Tuple(Bool, String)
      pos = 0
      text.scan(/(?ms)^```(\w*)\n(.*?)^```[ \t]*$/) do |m|
        segments << {false, text[pos...m.begin(0)]} if m.begin(0) > pos
        segments << {true, m[2].rstrip}
        pos = m.end(0)
      end
      segments << {false, text[pos..]} if pos < text.size
      segments << {false, text} if segments.empty?
      segments.map do |(is_code, content)|
        if is_code
          %(<pre><code>#{HTML.escape(content)}</code></pre>)
        else
          render_markdown_text(content)
        end
      end.join("\n")
    end

    private def self.render_markdown_text(text : String) : String
      esc = HTML.escape(text)
      # Inline code (already escaped).
      esc = esc.gsub(/`([^`]+?)`/) { |_, m| "<code>#{m[1]}</code>" }
      # Links first (so `**` inside URLs is not mangled): only safe targets.
      esc = esc.gsub(/\[([^\]]+?)\]\(([^)\s]+?)\)/) do |_, m|
        label, url = m[1], m[2]
        if url.starts_with?("http://") || url.starts_with?("https://") || url.starts_with?("/") || url.starts_with?("#")
          %(<a href="#{url}">#{label}</a>)
        else
          label
        end
      end
      esc = esc.gsub(/\*\*([^*]+?)\*\*/) { |_, m| "<strong>#{m[1]}</strong>" }
      esc = esc.gsub(/(^|[^*\w])\*([^*\n]+?)\*/) { |_, m| "#{m[1]}<em>#{m[2]}</em>" }
      # Headings (# .. ###) and paragraphs.
      esc.split(/\n{2,}/).map do |para|
        para = para.strip
        if m = para.match(/\A(\#{1,3}) (.*)\z/m)
          level = m[1].size
          "<h#{level}>#{m[2].strip}</h#{level}>"
        elsif para.empty?
          ""
        else
          "<p>#{para.gsub(/\n/, "<br>")}</p>"
        end
      end.reject(&.empty?).join("\n")
    end

    # Page-number navigation (`/stories`, `/stories/page/2`, ...). `base`
    # may contain a `:page` (or `%{page}`) placeholder; otherwise page 1
    # links to `base` itself and the rest to `base/page/N` (or `?page=N`
    # when `base` already has a query string). Returns `""` for one page.
    def self.page_numbers(current : Int32, total : Int32, base : String, window : Int32 = 2) : String
      return "" if total <= 1
      current = current.clamp(1, total)
      pages = [] of Int32?
      (1..total).each do |p|
        if p == 1 || p == total || (p - current).abs <= window
          pages << p
        elsif pages.last != nil
          pages << nil
        end
      end
      String.build do |io|
        io << %(<nav class="pagination">)
        if current > 1
          io << %(<a href="#{HTML.escape(page_url(base, current - 1))}" rel="prev">« Prev</a>)
        end
        pages.each do |p|
          if p.nil?
            io << %(<span class="gap">…</span>)
          elsif p == current
            io << %(<span class="current">#{p}</span>)
          else
            io << %(<a href="#{HTML.escape(page_url(base, p))}">#{p}</a>)
          end
        end
        if current < total
          io << %(<a href="#{HTML.escape(page_url(base, current + 1))}" rel="next">Next »</a>)
        end
        io << "</nav>"
      end
    end

    private def self.page_url(base : String, page : Int32) : String
      if base.includes?(":page")
        base.sub(":page", page.to_s)
      elsif base.includes?("%{page}")
        base.gsub("%{page}", page.to_s)
      elsif base.includes?("?")
        "#{base}&page=#{page}"
      elsif page == 1
        base
      else
        stripped = base.ends_with?("/") ? base[0...-1] : base
        "#{stripped}/page/#{page}"
      end
    end

    # One RSS item for `rss_feed` (render the result with `render xml:`).
    struct RSSItem
      getter title : String
      getter link : String
      getter description : String
      getter pub_date : Time?
      getter guid : String?

      def initialize(@title : String, @link : String, @description : String, @pub_date : Time? = nil, @guid : String? = nil)
      end
    end

    # Builds an RSS 2.0 feed string (all text escaped).
    def self.rss_feed(*, title : String, link : String, description : String, items : Array(RSSItem)) : String
      String.build do |io|
        io << %(<?xml version="1.0" encoding="UTF-8"?>\n<rss version="2.0">\n<channel>\n)
        io << "<title>#{HTML.escape(title)}</title>\n"
        io << "<link>#{HTML.escape(link)}</link>\n"
        io << "<description>#{HTML.escape(description)}</description>\n"
        items.each do |item|
          io << "<item>\n"
          io << "<title>#{HTML.escape(item.title)}</title>\n"
          io << "<link>#{HTML.escape(item.link)}</link>\n"
          io << "<description>#{HTML.escape(item.description)}</description>\n"
          if date = item.pub_date
            io << "<pubDate>#{HTML.escape(date.to_utc.to_s("%a, %d %b %Y %H:%M:%S GMT"))}</pubDate>\n"
          end
          io << "<guid>#{HTML.escape(item.guid || item.link)}</guid>\n"
          io << "</item>\n"
        end
        io << "</channel>\n</rss>\n"
      end
    end
  end

  # Form builder used by `Controller#form_with` (plain string building —
  # usable anywhere, no template capture needed). With `model:` + `scope:`,
  # fields default their values from the model and names scope to
  # `scope[field]` (Rails `form_with model:` equivalent):
  #
  # ```
  # form_with("/stories", model: @story, scope: "story") do |f|
  #   f.error_messages +
  #   f.text_field("title") +
  #   f.check_box("user_is_author") +
  #   f.select("category", ["tech", "news"]) +
  #   f.submit
  # end
  # ```
  class FormBuilder
    def initialize(@url : String, @http_method : String = "post", @authenticity_token : String? = nil, @model : Saci::Record::Base? = nil, @scope : String? = nil, @multipart : Bool = false)
    end

    def build(content : String) : String
      method = @http_method.downcase
      form_method = (method == "get" || method == "post") ? method : "post"
      String.build do |io|
        io << %(<form action=") << HTML.escape(@url) << %(" method=") << form_method << %(")
        io << %( enctype="multipart/form-data") if @multipart
        io << ">"
        unless form_method == method
          io << %(<input type="hidden" name="_method" value=") << HTML.escape(method.upcase) << %(">)
        end
        if token = @authenticity_token
          io << %(<input type="hidden" name="authenticity_token" value=") << HTML.escape(token) << %(">)
        end
        io << content
        io << "</form>"
      end
    end

    def label(field : String, text : String) : String
      %(<label for="#{HTML.escape(field_id(field))}">#{HTML.escape(text)}</label>)
    end

    def text_field(name : String, value : String? = nil) : String
      input("text", name, value || model_string(name))
    end

    def password_field(name : String) : String
      %(<input type="password" name="#{HTML.escape(field_name(name))}" id="#{HTML.escape(field_id(name))}"#{error_class(name)}>)
    end

    def hidden_field(name : String, value : String) : String
      input("hidden", name, value)
    end

    def textarea(name : String, value : String? = nil) : String
      %(<textarea name="#{HTML.escape(field_name(name))}" id="#{HTML.escape(field_id(name))}"#{error_class(name)}>#{HTML.escape(value || model_string(name) || "")}</textarea>)
    end

    # Rails-style checkbox (hidden `0` + `1` box, checked from the model
    # when `checked` is nil).
    def check_box(name : String, checked : Bool? = nil) : String
      is_checked = checked.nil? ? model_truthy?(name) : checked
      String.build do |io|
        io << %(<input type="hidden" name=") << HTML.escape(field_name(name)) << %(" value="0">)
        io << %(<input type="checkbox" name=") << HTML.escape(field_name(name)) << %(" id=") << HTML.escape(field_id(name)) << %(" value="1")
        io << " checked" if is_checked
        io << error_class(name)
        io << ">"
      end
    end

    # `options` as bare values (`["tech", "news"]`) or label/value pairs
    # (`[{"Tech", "tech"}]`). Selection defaults to the model value.
    def select(name : String, options : Array(String) | Array(Tuple(String, String)), selected : String? = nil) : String
      current = selected || model_string(name)
      String.build do |io|
        io << %(<select name=") << HTML.escape(field_name(name)) << %(" id=") << HTML.escape(field_id(name)) << %(") << error_class(name) << ">"
        options.each do |opt|
          label, value = opt.is_a?(Tuple) ? {opt[0], opt[1]} : {opt, opt}
          io << %(<option value=") << HTML.escape(value) << %(")
          io << " selected" if current == value
          io << ">" << HTML.escape(label) << "</option>"
        end
        io << "</select>"
      end
    end

    def date_field(name : String, value : String? = nil) : String
      input("date", name, value || model_date(name))
    end

    def file_field(name : String) : String
      %(<input type="file" name="#{HTML.escape(field_name(name))}" id="#{HTML.escape(field_id(name))}"#{error_class(name)}>)
    end

    def submit(label : String = "Save") : String
      %(<input type="submit" value="#{HTML.escape(label)}">)
    end

    # Renders `record.errors` as an error list (`""` when clean). Needs a
    # `model:` builder (plain builders render `""`).
    def error_messages : String
      model = @model
      return "" unless model
      messages = model.errors.full_messages
      return "" if messages.empty?
      String.build do |io|
        io << %(<div class="errors"><ul>)
        messages.each { |msg| io << "<li>" << HTML.escape(msg) << "</li>" }
        io << "</ul></div>"
      end
    end

    private def input(type : String, name : String, value : String?) : String
      base = %(<input type="#{type}" name="#{HTML.escape(field_name(name))}" id="#{HTML.escape(field_id(name))}") + error_class(name)
      if value
        base + %( value="#{HTML.escape(value)}">)
      else
        base + ">"
      end
    end

    private def field_name(name : String) : String
      scope = @scope
      scope ? "#{scope}[#{name}]" : name
    end

    private def field_id(name : String) : String
      scope = @scope
      scope ? "#{scope}_#{name}" : name
    end

    # Appends ` class="field-with-errors"` when the model has errors on the
    # field (leading space included, so it slots into a tag).
    private def error_class(name : String) : String
      model = @model
      return "" unless model
      model.errors[name].any? ? %( class="field-with-errors") : ""
    end

    private def model_raw(name : String) : Saci::Record::Value
      @model.try(&.__saci_get_attr(name))
    end

    private def model_string(name : String) : String?
      case v = model_raw(name)
      when Nil   then nil
      when Time  then v.to_s
      when Bytes then String.new(v)
      else            v.to_s
      end
    end

    private def model_date(name : String) : String?
      case v = model_raw(name)
      when Time then v.to_utc.to_s("%Y-%m-%d")
      when Nil  then nil
      else           nil
      end
    end

    private def model_truthy?(name : String) : Bool
      case v = model_raw(name)
      when Nil          then false
      when Bool         then v
      when Int32, Int64 then v != 0
      when Float32      then v != 0
      when Float64      then v != 0
      when String       then v == "1" || v.downcase == "true"
      else                   true
      end
    end
  end

  class Controller
    # Template content for layouts (`<%= content %>`).
    def content : String
      @__content ||= ""
    end

    # Renders `views/<path>.ecr` (Symbol = relative to this controller's
    # view dir, e.g. `render_template(:show)` in PostsController renders
    # `views/posts/show.ecr`) inside `views/layouts/<layout>.ecr`
    # (`layout: false` skips the layout). `status:` sets the response code
    # (e.g. `render_template :new, status: 422`). Templates see controller
    # instance variables (`@post`) and helpers — escape output with `h()`.
    # Views resolve from `<project>/src/views` (the compile-time working
    # directory — shard resolution already requires building from the
    # project root, so this holds for apps and specs alike).
    macro render_template(name, layout = "application", status = 200)
      {% views_root = system("pwd").strip + "/src/views" %}
      {% ctrl_path = @type.name.stringify.split("::").map { |p| p.gsub(/Controller$/, "").underscore }.join("/") %}
      {% if name.is_a?(SymbolLiteral) %}
        {% template = ctrl_path + "/" + name.id.stringify %}
      {% else %}
        {% template = name.id.stringify %}
      {% end %}
      {% if layout.is_a?(StringLiteral) %}
        __saci_view_io = IO::Memory.new
        ECR.embed("{{views_root + "/" + template + ".ecr"}}", "__saci_view_io")
        @__content = __saci_view_io.to_s
        __saci_layout_io = IO::Memory.new
        ECR.embed("{{views_root + "/layouts/" + layout.id.stringify + ".ecr"}}", "__saci_layout_io")
        render html: __saci_layout_io.to_s, status: {{status}}
      {% else %}
        __saci_view_io = IO::Memory.new
        ECR.embed("{{views_root + "/" + template + ".ecr"}}", "__saci_view_io")
        render html: __saci_view_io.to_s, status: {{status}}
      {% end %}
    end

    # Renders a partial (`views/<path>.ecr`) to a String, for `<%= %>`.
    # Locals become template variables:
    #   render_partial("comments/comment", comment: comment)
    # With `collection:`, the partial renders once per item (joined); the
    # item variable defaults to the partial's singular basename (`as:`
    # overrides it):
    #   render_partial("comments/comment", collection: comments)
    #   render_partial("shared/row", collection: rows, as: "row")
    macro render_partial(path, **locals)
      {% views_root = system("pwd").strip + "/src/views" %}
      {% if locals.keys.map(&.id.stringify).includes?("collection") %}
        {% parts = path.id.stringify.split("/") %}
        {% base = parts.last %}
        {% singular = base.ends_with?("s") ? base[0...base.size - 1] : base %}
        {% as_name = locals["as".id] %}
        {% local_name = as_name ? as_name.stringify.gsub(/^:/, "").gsub(/^"/, "").gsub(/"$/, "") : singular %}
        __saci_collection_out = IO::Memory.new
        ({{locals["collection".id]}}).each do |__saci_item|
          {{local_name.id}} = __saci_item
          __saci_collection_io = IO::Memory.new
          ECR.embed("{{views_root + "/" + path.id.stringify + ".ecr"}}", "__saci_collection_io")
          __saci_collection_out << __saci_collection_io.to_s
        end
        __saci_collection_out.to_s
      {% else %}
        {% for k, v in locals %}
          {{k.id}} = {{v}}
        {% end %}
        __saci_partial_io = IO::Memory.new
        ECR.embed("{{views_root + "/" + path.id.stringify + ".ecr"}}", "__saci_partial_io")
        __saci_partial_io.to_s
      {% end %}
    end

    # Builds an HTML form (POST + `_method` override + CSRF token included).
    # With `model:` + `scope:`, fields bind to the model and scope their
    # names (`story[title]`); `multipart: true` sets the upload encoding.
    # All values are escaped.
    def form_with(url : String, method : String = "post", authenticity_token : String? = nil, model : Saci::Record::Base? = nil, scope : String? = nil, multipart : Bool = false, & : FormBuilder -> String) : String
      token = authenticity_token.nil? && method.downcase != "get" ? form_authenticity_token : authenticity_token
      builder = FormBuilder.new(url, method, token, model, scope, multipart)
      builder.build(yield builder)
    end

    # Standalone link, or a self-contained mini-form for non-GET methods
    # (includes the CSRF token — no JavaScript needed).
    def link_to(text : String, url : String, method : Symbol? = nil) : String
      if verb = method
        token = form_authenticity_token
        String.build do |io|
          io << %(<form action=") << HTML.escape(url) << %(" method="post" style="display:inline">)
          io << %(<input type="hidden" name="_method" value=") << HTML.escape(verb.to_s.upcase) << %(">)
          io << %(<input type="hidden" name="authenticity_token" value=") << HTML.escape(token) << %(">)
          io << %(<button type="submit">) << HTML.escape(text) << %(</button></form>)
        end
      else
        %(<a href="#{HTML.escape(url)}">#{HTML.escape(text)}</a>)
      end
    end

    # XSS-safe minimal markdown (see `Saci::Views.markdown`).
    def markdown(text : String) : String
      Views.markdown(text)
    end

    # Page-number navigation HTML (see `Saci::Views.page_numbers`).
    def page_numbers(current : Int32, total : Int32, base : String, window : Int32 = 2) : String
      Views.page_numbers(current, total, base, window)
    end

    # RSS 2.0 feed string — render it with `render xml:`.
    def rss_feed(*, title : String, link : String, description : String, items : Array(Views::RSSItem)) : String
      Views.rss_feed(title: title, link: link, description: description, items: items)
    end

    # Streams a file as a download (or inline).
    def send_file(path : String, filename : String? = nil, content_type : String = "application/octet-stream", disposition : String = "attachment") : Nil
      name = filename || File.basename(path)
      response.headers["Content-Type"] = content_type
      response.headers["Content-Disposition"] = "#{disposition}; filename=\"#{name}\""
      response.content_length = File.size(path)
      File.open(path, "rb") do |file|
        IO.copy(file, response)
      end
      @performed = true
    end

    # Sends in-memory bytes as a download (or inline).
    def send_data(data : Bytes | String, filename : String, content_type : String = "application/octet-stream", disposition : String = "attachment") : Nil
      bytes = data.is_a?(String) ? data.to_slice : data
      response.headers["Content-Type"] = content_type
      response.headers["Content-Disposition"] = "#{disposition}; filename=\"#{filename}\""
      response.content_length = bytes.size
      response.write(bytes)
      @performed = true
    end

    # -- HTTP caching ----------------------------------------------------------
    #
    # ```
    # def show
    #   @post = Post.find(params["id"])
    #   return unless stale?(@post)
    #   render json: @post
    # end
    # ```
    #
    # Sets validators, replies 304 when the client copy is fresh, and returns
    # false in that case (so the `return unless` idiom skips rendering).
    def stale?(etag : String? = nil, last_modified : Time? = nil) : Bool
      response.headers["ETag"] = weak_etag(etag) if etag
      if time = last_modified
        response.headers["Last-Modified"] = time.to_utc.to_s("%a, %d %b %Y %H:%M:%S GMT")
      end
      if cache_fresh?(etag, last_modified)
        head :not_modified
        false
      else
        true
      end
    end

    # Record overload: etag from table/id/updated_at, last-modified from
    # `updated_at` when the column exists.
    def stale?(record : Saci::Record::Base) : Bool
      pk = record.class.primary_key_name
      id_value = record.__saci_get_attr(pk)
      updated = record.__saci_get_attr("updated_at")
      tag = updated.is_a?(Time) ? "#{record.class.table_name}/#{id_value}-#{updated.to_unix}" : "#{record.class.table_name}/#{id_value}"
      stale?(etag: tag, last_modified: updated.is_a?(Time) ? updated : nil)
    end

    # Same as `stale?` without the boolean (use, then render unconditionally).
    def fresh_when(etag : String? = nil, last_modified : Time? = nil) : Nil
      stale?(etag: etag, last_modified: last_modified)
    end

    def fresh_when(record : Saci::Record::Base) : Nil
      stale?(record)
    end

    # `Cache-Control: max-age=N, public|private`.
    def expires_in(duration : Time::Span, public : Bool = false) : Nil
      scope = public ? "public" : "private"
      response.headers["Cache-Control"] = "max-age=#{duration.total_seconds.to_i}, #{scope}"
    end

    private def weak_etag(fragment : String) : String
      return fragment if fragment.starts_with?("W/") || (fragment.starts_with?("\"") && fragment.ends_with?("\""))
      "W/\"#{Saci.etag_digest(fragment)}\""
    end

    private def cache_fresh?(etag : String?, last_modified : Time?) : Bool
      if inm = request.headers["If-None-Match"]?
        return true if inm.strip == "*"
        if tag = etag
          ours = normalize_etag(weak_etag(tag))
          return true if inm.split(",").any? { |candidate| normalize_etag(candidate) == ours }
        end
      end
      if ims = request.headers["If-Modified-Since"]?
        if time = last_modified
          begin
            since = Time.parse(ims.strip, "%a, %d %b %Y %H:%M:%S GMT", Time::Location::UTC)
            return true if time.to_unix <= since.to_unix
          rescue Time::Format::Error
          end
        end
      end
      false
    end

    private def normalize_etag(value : String) : String
      cleaned = value.strip
      cleaned = cleaned[2..] if cleaned.starts_with?("W/")
      if cleaned.size >= 2 && cleaned.starts_with?("\"") && cleaned.ends_with?("\"")
        cleaned = cleaned[1...-1]
      end
      cleaned
    end
  end
end
