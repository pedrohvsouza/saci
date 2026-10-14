require "ecr"

module Saci
  # Form builder used by `Controller#form_with` (plain string building —
  # usable anywhere, no template capture needed).
  class FormBuilder
    def initialize(@url : String, @http_method : String = "post", @authenticity_token : String? = nil)
    end

    def build(content : String) : String
      method = @http_method.downcase
      form_method = (method == "get" || method == "post") ? method : "post"
      String.build do |io|
        io << %(<form action=") << HTML.escape(@url) << %(" method=") << form_method << %(">)
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
      %(<label for="#{HTML.escape(field)}">#{HTML.escape(text)}</label>)
    end

    def text_field(name : String, value : String? = nil) : String
      input("text", name, value)
    end

    def password_field(name : String) : String
      %(<input type="password" name="#{HTML.escape(name)}">)
    end

    def hidden_field(name : String, value : String) : String
      input("hidden", name, value)
    end

    def textarea(name : String, value : String? = nil) : String
      %(<textarea name="#{HTML.escape(name)}">#{value ? HTML.escape(value) : ""}</textarea>)
    end

    def submit(label : String = "Save") : String
      %(<input type="submit" value="#{HTML.escape(label)}">)
    end

    private def input(type : String, name : String, value : String?) : String
      if value
        %(<input type="#{type}" name="#{HTML.escape(name)}" value="#{HTML.escape(value)}">)
      else
        %(<input type="#{type}" name="#{HTML.escape(name)}">)
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
    # (`layout: false` skips the layout). Templates see controller
    # instance variables (`@post`) and helpers — escape output with `h()`.
    # Views resolve from `<project>/src/views` (the compile-time working
    # directory — shard resolution already requires building from the
    # project root, so this holds for apps and specs alike).
    macro render_template(name, layout = "application")
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
        render html: __saci_layout_io.to_s
      {% else %}
        __saci_view_io = IO::Memory.new
        ECR.embed("{{views_root + "/" + template + ".ecr"}}", "__saci_view_io")
        render html: __saci_view_io.to_s
      {% end %}
    end

    # Renders a partial (`views/<path>.ecr`) to a String, for `<%= %>`.
    macro render_partial(name)
      {% views_root = system("pwd").strip + "/src/views" %}
      __saci_partial_io = IO::Memory.new
      ECR.embed("{{views_root + "/" + name.id.stringify + ".ecr"}}", "__saci_partial_io")
      __saci_partial_io.to_s
    end

    # Builds an HTML form (POST + `_method` override + CSRF token included).
    # All values are escaped.
    def form_with(url : String, method : String = "post", authenticity_token : String? = nil, & : FormBuilder -> String) : String
      token = authenticity_token.nil? && method.downcase != "get" ? form_authenticity_token : authenticity_token
      builder = FormBuilder.new(url, method, token)
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
