require "http/formdata"

module Saci
  # Rails-like `params` hash: merges path params, query string and request body
  # (JSON + URL-encoded forms + multipart). Top-level scalar access stays flat
  # (`params["id"]`), while bracketed keys (`story[title]`, `tags[]`) and JSON
  # bodies build a nested tree (`params.require(:story).permit(...)`).
  class Params
    # A file sent as `multipart/form-data` (`params.file("avatar")`).
    #
    # The body is kept as a String (bytes preserved; text operations assume
    # UTF-8) with a `bytes` accessor for binary downloads.
    struct UploadedFile
      getter name : String
      getter filename : String
      getter content_type : String
      getter body : String

      def initialize(@name : String, @filename : String, @body : String, @content_type : String = "application/octet-stream")
      end

      def bytes : Bytes
        @body.to_slice
      end

      def size : Int32
        @body.bytesize
      end

      def read : String
        @body
      end
    end

    # The result of `Params#require`: wraps one nested value. Scalars behave
    # like Strings (`as_s`, `to_s`, `==`, `to_json` all delegate); hashes
    # support `permit` / `[]` / `dig` (Rails `ActionController::Parameters`
    # equivalent, static subset).
    class Value
      getter raw : JSON::Any

      def initialize(@raw : JSON::Any)
      end

      # Scalar value as a String (numbers/bools stringified, null -> "").
      # Raises `TypeError` for hashes/arrays — use `permit`/`as_a` instead.
      def as_s : String
        s = Params.scalar_string(@raw)
        raise TypeCastError.new("expected scalar param, got #{@raw.to_json}") if s.nil?
        s
      end

      def as_a : Array(JSON::Any)
        @raw.as_a? || raise TypeCastError.new("expected array param, got #{@raw.to_json}")
      end

      def as_h : Hash(String, JSON::Any)
        @raw.as_h? || raise TypeCastError.new("expected hash param, got #{@raw.to_json}")
      end

      def [](key : String | Symbol) : Value
        v = self[key]?
        raise KeyError.new("missing nested param: #{key}") if v.nil?
        v
      end

      def []?(key : String | Symbol) : Value?
        h = @raw.as_h?
        return nil unless h
        v = h[key.to_s]?
        v ? Value.new(v) : nil
      end

      def has_key?(key : String | Symbol) : Bool
        @raw.as_h?.try(&.has_key?(key.to_s)) || false
      end

      # Rails strong parameters on a required hash:
      #   ps = params.require(:story).permit(:title, :url, tags: [] of String)
      #
      # Plain keys permit scalars only (nested hashes/arrays under a plain
      # key are dropped, like Rails); `name: [...]` keyword entries — or
      # symbols nested in a positional array (`permit(:title, [:tags])`) —
      # permit an array value for that key.
      #
      # NOTE: Crystal cannot infer a type for a bare `[]` literal, so the
      # keyword form needs `[] of String` (or any element type — only the
      # key is used).
      def permit(*keys : String | Symbol | Array(Symbol), **arrays) : Hash(String, JSON::Any)
        array_names = [] of String
        arrays.each { |k, _| array_names << k.to_s }
        permit_keys(keys.to_a, array_names)
      end

      def permit_keys(keys : Array(String | Symbol | Array(Symbol)), arrays : Array(String)) : Hash(String, JSON::Any)
        h = @raw.as_h? || raise TypeCastError.new("expected hash param for permit, got #{@raw.to_json}")
        out = {} of String => JSON::Any
        array_keys = arrays.to_set
        keys.each do |k|
          if k.is_a?(Array)
            k.as(Array(Symbol)).each { |ak| array_keys << ak.to_s }
          else
            ks = k.to_s
            if v = h[ks]?
              out[ks] = v if v.as_h?.nil? && v.as_a?.nil?
            end
          end
        end
        array_keys.each do |ks|
          if v = h[ks]?
            out[ks] = v if v.as_a?
          end
        end
        out
      end

      def dig(*keys : String | Symbol) : JSON::Any?
        Params.dig_raw(@raw, keys.map(&.to_s))
      end

      def empty? : Bool
        if h = @raw.as_h?
          h.empty?
        elsif a = @raw.as_a?
          a.empty?
        else
          as_s.empty?
        end
      end

      def ==(other : Value) : Bool
        @raw == other.raw
      end

      def ==(other : String) : Bool
        Params.scalar_string(@raw) == other
      end

      def ==(other) : Bool
        @raw.raw == other
      end

      def to_s : String
        as_s
      rescue TypeCastError
        @raw.to_json
      end

      def to_s(io : IO) : Nil
        io << to_s
      end

      def to_json(builder : JSON::Builder) : Nil
        @raw.to_json(builder)
      end
    end

    getter values : Hash(String, String)
    getter data : Hash(String, JSON::Any)
    getter files : Hash(String, UploadedFile)

    def initialize(@values : Hash(String, String) = {} of String => String)
      @data = {} of String => JSON::Any
      @values.each { |k, v| @data[k] = JSON::Any.new(v) }
      @files = {} of String => UploadedFile
    end

    # Build params from an incoming request plus already-extracted path params.
    # Precedence (highest last): query < body < path.
    def self.build(request : HTTP::Request, path_params : Hash(String, String)) : Params
      data = {} of String => JSON::Any
      files = {} of String => UploadedFile

      # Query string (bracket-aware: `story[title]=x`, `tags[]=y`).
      if query = request.query
        URI::Params.parse(query).each do |key, value|
          assign_nested(data, key, value)
        end
      end

      # Body (POST/PUT/PATCH).
      if body = request.body
        content_type = request.headers["Content-Type"]? || ""
        raw = body.gets_to_end
        unless raw.empty?
          if content_type.includes?("application/json")
            begin
              parsed = JSON.parse(raw)
              if overlay = parsed.as_h?
                deep_merge!(data, overlay)
              end
            rescue JSON::ParseException
              # Invalid JSON -> ignore body, like Rails would 400 later.
              # Keep query/path params only.
            end
          elsif content_type.includes?("multipart/form-data")
            if m = raw_content_boundary(content_type)
              HTTP::FormData.parse(IO::Memory.new(raw), m) do |part|
                fname = part.name
                next if fname.nil? || fname.empty?
                if fn = part.filename
                  files[fname] = UploadedFile.new(
                    fname, fn, part.body.gets_to_end,
                    part.headers["Content-Type"]? || "application/octet-stream"
                  )
                  assign_nested(data, fname, fn)
                else
                  assign_nested(data, fname, part.body.gets_to_end)
                end
              end
            end
          elsif content_type.includes?("application/x-www-form-urlencoded") || form_like?(content_type, raw)
            # Form bodies, plus typeless bodies that look like forms
            # (spec clients often omit the header).
            begin
              URI::Params.parse(raw).each do |key, value|
                assign_nested(data, key, value)
              end
            rescue
              # Not urlencoded (e.g. raw text) -> ignore body.
            end
          end
        end
      end

      # Path params win over everything.
      path_params.each { |k, v| data[k] = JSON::Any.new(v) }

      params = new
      params.set_data!(data)
      params.set_files!(files)
      params
    end

    protected def set_data!(data : Hash(String, JSON::Any)) : Nil
      @data = data
      @values = {} of String => String
      data.each do |k, v|
        if s = self.class.scalar_string(v)
          @values[k] = s
        else
          @values[k] = v.to_json
        end
      end
    end

    protected def set_files!(files : Hash(String, UploadedFile)) : Nil
      @files = files
    end

    def [](key : String | Symbol) : String
      @values[key.to_s]
    end

    def []?(key : String | Symbol) : String?
      @values[key.to_s]?
    end

    def has_key?(key : String | Symbol) : Bool
      @values.has_key?(key.to_s)
    end

    def fetch(key : String | Symbol, default : String? = nil) : String?
      @values.fetch(key.to_s, default)
    end

    # Like Rails `params.require(:story)` — raises when missing (or blank, for
    # scalars). Returns a `Value`: call `as_s` for scalars, or `permit` for
    # hashes (`params.require(:story).permit(:title, tags: [])`).
    def require(key : String | Symbol) : Value
      k = key.to_s
      any = @data[k]?
      raise ParameterMissing.new("param is missing or empty: #{key}") if any.nil?
      if s = self.class.scalar_string(any)
        raise ParameterMissing.new("param is missing or empty: #{key}") if s.empty?
      end
      Value.new(any)
    end

    # Like Rails `params.permit(:a, :b)` — returns a filtered Hash of the
    # flat top-level scalars.
    def permit(*keys : String | Symbol) : Hash(String, String)
      allowed = keys.map(&.to_s).to_set
      @values.select { |k, _| allowed.includes?(k) }
    end

    # Walk the nested tree (`params.dig(:story, :title)`). Returns nil when
    # any level is missing (or not a hash).
    def dig(*keys : String | Symbol) : JSON::Any?
      return nil if keys.empty?
      first = @data[keys.first.to_s]?
      return first if keys.size == 1
      return nil if first.nil?
      self.class.dig_raw(first, keys.to_a[1..].map(&.to_s))
    end

    # Array param as Strings (`params.array("tags")`, or nested
    # `params.array("story", "tags")`). Missing/non-array -> `[]`; non-scalar
    # elements are skipped.
    def array(key : String | Symbol) : Array(String)
      array_at(@data[key.to_s]?)
    end

    def array(first : String | Symbol, second : String | Symbol) : Array(String)
      array_at(dig(first, second))
    end

    def array(first : String | Symbol, second : String | Symbol, third : String | Symbol, *rest : String | Symbol) : Array(String)
      array_at(dig(first, second, third, *rest))
    end

    private def array_at(node : JSON::Any?) : Array(String)
      arr = node.try(&.as_a?)
      return [] of String unless arr
      arr.compact_map { |e| self.class.scalar_string(e) }
    end

    # Uploaded file for a multipart field (nil when absent).
    # NOTE: several files under one field name keep the last one only.
    def file(key : String | Symbol) : UploadedFile?
      @files[key.to_s]?
    end

    def int(key : String | Symbol, default : Int32? = nil) : Int32?
      raw = @values[key.to_s]?
      return default if raw.nil?
      parsed = raw.to_i?
      parsed.nil? ? default : parsed
    rescue
      default
    end

    def to_h : Hash(String, String)
      @values.dup
    end

    # Copy with sensitive values filtered (see `Saci.filter_parameters`).
    def filtered : Hash(String, String)
      Saci.filter_params(to_h)
    end

    def each(&block : String, String ->)
      @values.each { |k, v| block.call(k, v) }
    end

    def empty? : Bool
      @values.empty? && @data.empty?
    end

    def to_s(io : IO) : Nil
      @values.to_s(io)
    end

    # -- nested parsing ----------------------------------------------------

    # Scalar as String, or nil for hashes/arrays. JSON null counts as scalar.
    def self.scalar_string(any : JSON::Any) : String?
      case r = any.raw
      when String          then r
      when Nil             then ""
      when Int64, Float64  then r.to_s
      when Bool            then r.to_s
      else                      nil
      end
    end

    def self.dig_raw(node : JSON::Any, keys : Array(String)) : JSON::Any?
      current : JSON::Any? = node
      keys.each do |k|
        h = current.try(&.as_h?)
        return nil unless h
        current = h[k]?
        return nil if current.nil?
      end
      current
    end

    private def self.raw_content_boundary(content_type : String) : String?
      if m = content_type.match(/boundary=([^;]+)/)
        m[1].strip.strip('"')
      end
    end

    # Typeless bodies that still look like `a=1&b=2` forms. JSON-looking
    # bodies are left alone (they need an explicit JSON content type).
    private def self.form_like?(content_type : String, raw : String) : Bool
      return false unless content_type.strip.empty?
      stripped = raw.lstrip
      return false if stripped.starts_with?("{") || stripped.starts_with?("[")
      raw.includes?("=")
    end

    private def self.deep_merge!(base : Hash(String, JSON::Any), overlay : Hash(String, JSON::Any)) : Nil
      overlay.each do |k, v|
        if bv = base[k]?
          bh = bv.as_h?
          oh = v.as_h?
          if bh && oh
            deep_merge!(bh, oh)
            next
          end
        end
        base[k] = v
      end
    end

    # `"story[tags][]"` -> `["story", "tags", ""]` (`""` = array append).
    private def self.parse_key(key : String) : Array(String)
      parts = [] of String
      if i = key.index('[')
        parts << key[0...i]
        pos = i
        while pos < key.size
          break unless key[pos] == '['
          close = key.index(']', pos)
          break unless close
          parts << key[pos + 1...close]
          pos = close + 1
        end
      else
        parts << key
      end
      parts
    end

    private def self.assign_nested(root : Hash(String, JSON::Any), key : String, value : String) : Nil
      assign_parts(root, parse_key(key), JSON::Any.new(value))
    end

    private def self.assign_parts(root : Hash(String, JSON::Any), parts : Array(String), value : JSON::Any) : Nil
      return if parts.empty?
      key = parts.first
      if parts.size == 1
        return if key.empty? # bare `[]=x` at hash level: nowhere to push
        root[key] = value
        return
      end
      return if key.empty?
      nxt = parts[1]
      if nxt.empty?
        if parts.size == 2
          existing = root[key]?
          arr = existing.try(&.as_a?) || (existing ? [existing] : [] of JSON::Any)
          arr << value
          root[key] = JSON::Any.new(arr)
        else
          # `key[][sub]=v`: append/merge a hash at the array tail.
          existing = root[key]?
          arr = existing.try(&.as_a?) || (existing ? [existing] : [] of JSON::Any)
          tail = arr.last?.try(&.as_h?)
          if tail.nil? || tail.has_key?(parts[2])
            tail = {} of String => JSON::Any
            arr << JSON::Any.new(tail)
          end
          assign_parts(tail, parts[2..], value)
          root[key] = JSON::Any.new(arr)
        end
      else
        sub = root[key]?.try(&.as_h?) || {} of String => JSON::Any
        assign_parts(sub, parts[1..], value)
        root[key] = JSON::Any.new(sub)
      end
    end
  end
end
