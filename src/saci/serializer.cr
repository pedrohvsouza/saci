require "json"
require "./record"

module Saci
  # ActiveModelSerializers-style JSON shaping (G304).
  #
  # Serializers are compile-time declared against one object type. Crystal
  # has no runtime `send`, so `attributes`/`has_many`/`has_one`/`attribute`
  # generate readers and a static dispatch table instead of reflecting on
  # method names at runtime.
  #
  # ```
  # class CommentSerializer < Saci::Serializer(Comment)
  #   attributes :id, :body
  # end
  #
  # class PostSerializer < Saci::Serializer(Post)
  #   attributes :id, :title, :created_at
  #   attribute(:headline) { "#{object.title.upcase}" }
  #   has_many :comments, serializer: CommentSerializer
  #   has_one :author, serializer: UserSerializer
  # end
  #
  # PostSerializer.new(post).as_json
  # PostSerializer.new(post, only: [:id, :title]).to_json
  # PostSerializer.new(post, root: "post", key_transform: :camel).to_json
  # PostSerializer.collection(Post.all, root: true).to_json
  # render json: PostSerializer.new(post) # just works: `to_json` is defined
  # ```
  #
  # Options:
  # * `only:` / `except:` — filter attributes and associations by declared
  #   name.
  # * `include:` — when present, only the named associations are emitted
  #   (attributes are unaffected).
  # * `root:` — `true` derives a root from the serializer name, a Symbol or
  #   String is used verbatim, `false` disables the class-level root.
  # * `key_transform:` — `:snake` (default), `:camel` (`firstName`),
  #   `:camel_upper`/`:pascal` (`FirstName`).
  #
  # Class-level defaults are available through `root "post"` and
  # `key_transform :camel`. `only:`/`except:`/`include:` accept arrays of
  # Symbols or Strings (do not mix the two element types in one array —
  # Crystal has no heterogeneous array literals).
  #
  # `Saci::Record::Base` is reopened below with `as_json`/`to_json` so that
  # association serialization can fall back to a model's columns when no
  # serializer is supplied, and so `render json: record` works.
  class Serializer(T)
    # Per-render options. Internal representation uses `Set(String)` so
    # membership checks are cheap and string/symbol callers converge.
    class Options
      getter only : Set(String)?
      getter except : Set(String)?
      getter includes : Set(String)?
      getter root : String | Symbol | Bool | Nil
      getter key_transform : Symbol?

      def initialize(
        only : Array(Symbol) | Array(String) | Nil = nil,
        except : Array(Symbol) | Array(String) | Nil = nil,
        includes : Array(Symbol) | Array(String) | Nil = nil,
        @root : String | Symbol | Bool | Nil = nil,
        @key_transform : Symbol? = nil,
      )
        @only = Options.names(only)
        @except = Options.names(except)
        @includes = Options.names(includes)
      end

      def with_root(root : String | Symbol | Bool | Nil) : Options
        Options.new(
          only: @only.try(&.to_a),
          except: @except.try(&.to_a),
          includes: @includes.try(&.to_a),
          root: root,
          key_transform: @key_transform,
        )
      end

      def self.names(values : Array(Symbol) | Array(String) | Nil) : Set(String)?
        return nil if values.nil?
        values.map(&.to_s).to_set
      end
    end

    # A rendered collection. Kept as a small wrapper (instead of a bare
    # `Array`) so the collection can carry a root while each item remains
    # unrooted.
    class Collection
      getter items : Array(Hash(String, JSON::Any))
      getter root : String?

      def initialize(@items : Array(Hash(String, JSON::Any)), @root : String? = nil)
      end

      def size : Int32
        @items.size
      end

      def empty? : Bool
        @items.empty?
      end

      def as_json : JSON::Any
        array = JSON::Any.new(@items.map { |item| JSON::Any.new(item) }.to_a)
        if r = @root
          JSON::Any.new({r => array})
        else
          array
        end
      end

      def to_json : String
        as_json.to_json
      end

      def to_json(json : JSON::Builder) : Nil
        as_json.to_json(json)
      end
    end

    getter object : T
    getter options : Options

    def initialize(@object : T, @options : Options)
    end

    # Keyword form: `new(record, only: [:id], include: [:comments])`.
    # `**opts` is used (instead of explicit keyword parameters) so the
    # `include:` spelling works even though `include` is a Crystal keyword.
    def initialize(@object : T, **opts)
      @options = Serializer(T).build_options(**opts)
    end

    def as_json : Hash(String, JSON::Any)
      result = {} of String => JSON::Any
      self.class.__saci_serializer_members.each do |(name, kind)|
        next unless include_member?(name, kind)
        result[output_key(name)] = __saci_json_member(name)
      end
      if r = root_name
        {r => JSON::Any.new(result)}
      else
        result
      end
    end

    def to_json : String
      as_json.to_json
    end

    def to_json(json : JSON::Builder) : Nil
      as_json.to_json(json)
    end

    # Render an enumerable of objects through this serializer.
    #
    # ```
    # PostSerializer.collection(posts, only: [:id], root: true).to_json
    # ```
    def self.collection(objects : Enumerable(T), **opts) : Collection
      options = build_options(**opts)
      root = collection_root(options)
      item_options = options.with_root(false)
      items = objects.map { |object| new(object, item_options).as_json }
      Collection.new(items, root)
    end

    # Same as `collection.to_json`; handy for `render json:`.
    def self.render_collection(objects : Enumerable(T), **opts) : String
      collection(objects, **opts).to_json
    end

    # -- compile-time DSL ------------------------------------------------

    # Declares plain attributes read from `@object` with the same reader
    # name. A missing reader is a compile error (explicit, not magic).
    macro attributes(*names)
      {% for name in names %}
        def {{name.id}}
          @object.{{name.id}}
        end
      {% end %}

      def self.__saci_serializer_members : Array(Tuple(String, Symbol))
        previous_def + [
          {% for name in names %}
            { {{name.id.stringify}}, :attribute },
          {% end %}
        ]
      end

      private def __saci_json_member(member_name : String) : ::JSON::Any
        case member_name
        {% for name in names %}
        when {{name.id.stringify}}
          ::Saci::Serializer.dump(self.{{name.id}})
        {% end %}
        else
          previous_def
        end
      end
    end

    # Computed attribute. The block runs in serializer context, so
    # `object` and previously declared attribute readers are available.
    macro attribute(name, &block)
      def {{name.id}}
        {% if block.args.size == 1 %}
          {{block.args[0]}} = self
        {% end %}
        {{block.body}}
      end

      def self.__saci_serializer_members : Array(Tuple(String, Symbol))
        previous_def + [{ {{name.id.stringify}}, :attribute }]
      end

      private def __saci_json_member(member_name : String) : ::JSON::Any
        case member_name
        when {{name.id.stringify}}
          ::Saci::Serializer.dump(self.{{name.id}})
        else
          previous_def
        end
      end
    end

    # Association rendered with an explicit serializer. The serializer must
    # accept the association's element type (i.e. `CommentSerializer <
    # Saci::Serializer(Comment)` for `has_many :comments`).
    macro has_many(name, serializer = nil)
      def self.__saci_serializer_members : Array(Tuple(String, Symbol))
        previous_def + [{ {{name.id.stringify}}, :association }]
      end

      private def __saci_json_assoc_{{name.id}} : ::JSON::Any
        {% if serializer %}
          values = [] of ::JSON::Any
          @object.{{name.id}}.each do |item|
            values << ::JSON::Any.new({{serializer}}.new(item).as_json)
          end
          ::JSON::Any.new(values)
        {% else %}
          ::Saci::Serializer.dump_collection(@object.{{name.id}})
        {% end %}
      end

      private def __saci_json_member(member_name : String) : ::JSON::Any
        case member_name
        when {{name.id.stringify}}
          __saci_json_assoc_{{name.id}}
        else
          previous_def
        end
      end
    end

    # Singular association. Nil renders as JSON null.
    macro has_one(name, serializer = nil)
      def self.__saci_serializer_members : Array(Tuple(String, Symbol))
        previous_def + [{ {{name.id.stringify}}, :association }]
      end

      private def __saci_json_assoc_{{name.id}} : ::JSON::Any
        {% if serializer %}
          value = @object.{{name.id}}
          return ::JSON::Any.new(nil) if value.nil?
          ::JSON::Any.new({{serializer}}.new(value).as_json)
        {% else %}
          ::Saci::Serializer.dump(@object.{{name.id}})
        {% end %}
      end

      private def __saci_json_member(member_name : String) : ::JSON::Any
        case member_name
        when {{name.id.stringify}}
          __saci_json_assoc_{{name.id}}
        else
          previous_def
        end
      end
    end

    macro root(value)
      def self.__saci_serializer_root : String?
        {{value}}.to_s
      end
    end

    macro key_transform(name)
      def self.__saci_serializer_key_transform : Symbol
        {{name}}
      end
    end

    # -- runtime dispatch table defaults --------------------------------

    # Per-class stubs so the DSL macros can chain with `previous_def`
    # within the subclass (Crystal's `previous_def` does not reach an
    # inherited generic-base definition directly). `super` bridges to the
    # parent, mirroring `Saci::Record::Base.inherited`.
    macro inherited
      def self.__saci_serializer_members : Array(Tuple(String, Symbol))
        super
      end

      private def __saci_json_member(member_name : String) : JSON::Any
        super
      end
    end

    def self.__saci_serializer_members : Array(Tuple(String, Symbol))
      [] of Tuple(String, Symbol)
    end

    def self.__saci_serializer_root : String?
      nil
    end

    def self.__saci_serializer_key_transform : Symbol
      :snake
    end

    private def __saci_json_member(member_name : String) : JSON::Any
      raise ArgumentError.new("unknown serializer member #{member_name.inspect} on #{self.class}")
    end

    private def include_member?(name : String, kind : Symbol) : Bool
      if only = @options.only
        return false unless only.includes?(name)
      end
      if except = @options.except
        return false if except.includes?(name)
      end
      if kind == :association
        if includes = @options.includes
          return false unless includes.includes?(name)
        end
      end
      true
    end

    private def output_key(name : String) : String
      transform = @options.key_transform || self.class.__saci_serializer_key_transform
      case transform
      when :camel
        Serializer.camelize(name)
      when :camel_upper, :pascal
        Serializer.camelize(name, upper: true)
      else
        name
      end
    end

    private def root_name : String?
      case value = @options.root
      when false
        nil
      when String
        value
      when Symbol
        value.to_s
      when true
        self.class.__saci_serializer_root || Serializer.default_root(self.class.name)
      else
        self.class.__saci_serializer_root
      end
    end

    # -- helpers shared by all serializer instances ---------------------

    def self.build_options(**opts) : Options
      Options.new(
        only: opts[:only]?,
        except: opts[:except]?,
        includes: opts[:include]?,
        root: opts[:root]?,
        key_transform: opts[:key_transform]?,
      )
    end

    def self.collection_root(options : Options) : String?
      case value = options.root
      when false
        nil
      when String
        value
      when Symbol
        value.to_s
      when true
        Serializer.default_root(self.name, plural: true)
      else
        self.__saci_serializer_root.try { |root| Saci::Record::Inflector.pluralize(root) }
      end
    end

    # "first_name" -> "firstName" (or "FirstName" with `upper: true`).
    def self.camelize(name : String, upper : Bool = false) : String
      parts = name.split('_')
      return name if parts.empty?
      head = parts.shift
      tail = parts.map { |part| part.empty? ? part : part[0].upcase.to_s + part[1..] }
      result = ([head] + tail).join
      return result if result.empty?
      upper ? result[0].upcase.to_s + result[1..] : result
    end

    # Derives a default root from a serializer class name:
    # `PostSerializer` -> `post` / `posts`.
    def self.default_root(serializer_name : String, plural : Bool = false) : String
      base = serializer_name.split("::").last
      if base.ends_with?("Serializer") && base.size > "Serializer".size
        base = base[0...-"Serializer".size]
      end
      root = Saci::Record::Inflector.underscore(base)
      plural ? Saci::Record::Inflector.pluralize(root) : root
    end

    # -- value conversion ------------------------------------------------

    def self.dump(value : Nil) : JSON::Any
      JSON::Any.new(nil)
    end

    def self.dump(value : JSON::Any) : JSON::Any
      value
    end

    # `read_attribute` returns the `Record::Value` union; Crystal does not
    # distribute overload resolution over a union, so this overload is
    # required (otherwise the generic fallback would try `Slice#to_json`).
    def self.dump(value : Saci::Record::Value) : JSON::Any
      case v = value
      when Nil
        JSON::Any.new(nil)
      when Time
        JSON::Any.new(v.to_rfc3339)
      when Bytes
        JSON::Any.new(v.map { |byte| JSON::Any.new(byte.to_i64) }.to_a)
      when Array(String)
        JSON::Any.new(v.map { |item| JSON::Any.new(item) }.to_a)
      when Bool
        JSON::Any.new(v)
      when Int32
        JSON::Any.new(v.to_i64)
      when Float32
        JSON::Any.new(v.to_f64)
      when Int64
        JSON::Any.new(v)
      when Float64
        JSON::Any.new(v)
      else
        JSON::Any.new(v.to_s)
      end
    end

    def self.dump(value : Saci::Record::Base) : JSON::Any
      JSON::Any.new(value.as_json)
    end

    # `Slice#to_json` only takes an IO, so handle blobs explicitly.
    def self.dump(value : Bytes) : JSON::Any
      JSON::Any.new(value.map { |byte| JSON::Any.new(byte.to_i64) }.to_a)
    end

    def self.dump(value : Array) : JSON::Any
      values = [] of JSON::Any
      value.each { |item| values << dump(item) }
      JSON::Any.new(values)
    end

    def self.dump(value : Hash) : JSON::Any
      values = {} of String => JSON::Any
      value.each { |key, item| values[key.to_s] = dump(item) }
      JSON::Any.new(values)
    end

    # Fallback for primitives, Time, and anything implementing `to_json`.
    # Unknown values degrade to their string form rather than failing a
    # whole render.
    def self.dump(value) : JSON::Any
      JSON.parse(value.to_json)
    rescue
      JSON::Any.new(value.to_s)
    end

    def self.dump_collection(items) : JSON::Any
      values = [] of JSON::Any
      items.each { |item| values << dump(item) }
      JSON::Any.new(values)
    end
  end
end

# `Record::Base#as_json`/`#to_json` make model values usable directly in
# serializers (`has_many` without an explicit serializer) and in
# `render json: record`. `Time` is rendered as RFC3339 by `JSON::Any`.
class Saci::Record::Base
  def as_json : Hash(String, JSON::Any)
    values = {} of String => JSON::Any
    self.class.__saci_column_names.each do |(name, _type)|
      values[name] = Saci::Serializer.dump(read_attribute(name))
    end
    values
  end

  def to_json : String
    as_json.to_json
  end

  def to_json(json : JSON::Builder) : Nil
    as_json.to_json(json)
  end
end
