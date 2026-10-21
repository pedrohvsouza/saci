require "json"
require "uri"

# ActiveSupport-style core extensions. Only methods Crystal does not already
# provide are added; stdlib `try`, `in?`, `String#blank?/present?/presence`,
# and `Enumerable#in_groups_of` are intentionally left untouched.
#
# `method_missing`/dynamic receivers do not exist in Crystal, so a few Rails
# conveniences are explicit: `OrderedOptions#[]`, `StringInquirer#is?`, and
# `try(&block)` (stdlib) rather than `object.try(:name)`.

# Rails `Object#blank?`: only nil, false, empty strings/collections are
# blank. Numbers (including 0) and times are present.
class Object
  def blank? : Bool
    false
  end

  def present? : Bool
    !blank?
  end

  def presence : self?
    blank? ? nil : self
  end

  def to_param : String
    to_s
  end

  def deep_dup : self
    self
  end
end

struct Nil
  def blank? : Bool
    true
  end

  def present? : Bool
    false
  end

  def to_param : String
    ""
  end
end

struct Bool
  # Rails considers `false` blank; `true` is present.
  def blank? : Bool
    !self
  end

  def present? : Bool
    !blank?
  end
end

class Array(T)
  def blank? : Bool
    empty?
  end

  def deep_dup : Array(T)
    map do |value|
      case value
      when Hash, Array then value.deep_dup.as(T)
      else                  value
      end
    end
  end

  # "a, b, and c" (Rails `to_sentence`).
  def to_sentence(connector : String = "and", last_connector : String? = nil) : String
    items = map(&.to_s)
    case items.size
    when 0 then ""
    when 1 then items[0]
    when 2 then "#{items[0]} #{last_connector || connector} #{items[1]}"
    else
      "#{items[0...-1].join(", ")}, #{last_connector || connector} #{items[-1]}"
    end
  end

  # Balanced groups (Rails `in_groups`). Elements are nil-padded; use the
  # two-argument overload for a typed fill value.
  def in_groups(number : Int) : Array(Array(T?))
    raise ArgumentError.new("number must be positive") if number <= 0
    base, extra = size.divmod(number)
    index = 0
    Array(Array(T?)).new(number) do |group_index|
      count = base + (group_index < extra ? 1 : 0)
      group = [] of T?
      count.times do
        group << self[index] if index < size
        index += 1
      end
      group
    end
  end

  def in_groups(number : Int, fill_with : T) : Array(Array(T))
    groups = in_groups(number)
    max_size = groups.map(&.size).max? || 0
    groups.map do |group|
      filled = [] of T
      group.each { |value| filled << (value.nil? ? fill_with : value.not_nil!) }
      (max_size - group.size).times { filled << fill_with }
      filled
    end
  end

  def to_param : String
    join("/")
  end
end

class Hash(K, V)
  def blank? : Bool
    empty?
  end

  def stringify_keys : Hash(String, V)
    each_with_object({} of String => V) { |(key, value), result| result[key.to_s] = value }
  end

  # Crystal cannot intern symbols at runtime (`String#to_sym` does not exist),
  # so this returns an indifferent-access wrapper that accepts both string and
  # symbol keys. Use `Saci.symbolize_keys({...})` for compile-time literals
  # when a real `Hash(Symbol, V)` is required.
  def symbolize_keys : Saci::HashWithIndifferentAccess(V)
    result = Saci::HashWithIndifferentAccess(V).new
    each { |key, value| result[key.to_s] = value }
    result
  end

  # Recursively merges nested hashes; other values from *other* win.
  def deep_merge(other : Hash(K, V)) : Hash(K, V)
    result = dup
    other.each do |key, value|
      current = result[key]?
      result[key] = if current.is_a?(Hash) && value.is_a?(Hash)
                      current.deep_merge(value).as(V)
                    else
                      value
                    end
    end
    result
  end

  def deep_dup : Hash(K, V)
    result = {} of K => V
    each do |key, value|
      result[key] = case value
                    when Hash, Array then value.deep_dup.as(V)
                    else                  value
                    end
    end
    result
  end

  def slice(*keys : K) : Hash(K, V)
    result = {} of K => V
    keys.each { |key| result[key] = self[key] if has_key?(key) }
    result
  end

  def except(*keys : K) : Hash(K, V)
    rejected = keys.to_set
    each_with_object({} of K => V) { |(key, value), result| result[key] = value unless rejected.includes?(key) }
  end

  # URL-encoded query string, sorted by key for deterministic logs/tests.
  def to_query : String
    String.build do |io|
      keys.sort_by(&.to_s).each_with_index do |key, index|
        io << '&' if index > 0
        io << URI.encode_www_form(key.to_s) << '=' << URI.encode_www_form(self[key].to_s)
      end
    end
  end

  def to_param : String
    to_query
  end
end

# Crystal cannot intern symbols at runtime (`String#to_sym` does not exist);
# `Hash#symbolize_keys` therefore returns an indifferent-access wrapper. Use
# `Saci.symbolize_keys({...})` for compile-time hash literals when a real
# `Hash(Symbol, V)` is required.

class String
  def squish : String
    gsub(/\s+/, " ").strip
  end

  def html_safe : Saci::SafeBuffer
    Saci::SafeBuffer.new(self)
  end

  def html_safe? : Bool
    false
  end
end

module Saci
  # Marker wrapper for strings that must not be escaped again.
  class SafeBuffer
    getter value : String

    def initialize(@value : String)
    end

    def html_safe? : Bool
      true
    end

    def html_safe : SafeBuffer
      self
    end

    def to_s : String
      @value
    end

    def to_s(io : IO) : Nil
      io << @value
    end

    def empty? : Bool
      @value.empty?
    end

    def blank? : Bool
      @value.blank?
    end

    def size : Int32
      @value.size
    end

    def +(other : String | SafeBuffer) : SafeBuffer
      SafeBuffer.new(@value + other.to_s)
    end

    def concat(other : String | SafeBuffer) : self
      @value += other.to_s
      self
    end

    def ==(other : String) : Bool
      @value == other
    end

    def ==(other : SafeBuffer) : Bool
      @value == other.value
    end

    def inspect(io : IO) : Nil
      io << "#<Saci::SafeBuffer " << @value.inspect << '>'
    end
  end

  # Ordered string-keyed options (Rails `OrderedOptions`). Values are typed
  # by the caller: `OrderedOptions(Int32 | String).new`.
  class OrderedOptions(V)
    include Enumerable({String, V})

    def initialize
      @values = {} of String => V
    end

    def initialize(values : Hash(String, V))
      @values = values.dup
    end

    def [](key : String | Symbol) : V?
      @values[key.to_s]?
    end

    def []=(key : String | Symbol, value : V) : V
      @values[key.to_s] = value
    end

    def fetch(key : String | Symbol, default : V) : V
      @values.fetch(key.to_s, default)
    end

    def fetch(key : String | Symbol, & : String -> V) : V
      @values.fetch(key.to_s) { |missing| yield missing }
    end

    def has_key?(key : String | Symbol) : Bool
      @values.has_key?(key.to_s)
    end

    def delete(key : String | Symbol) : V?
      @values.delete(key.to_s)
    end

    def each(& : {String, V} ->) : Nil
      @values.each { |key, value| yield({key, value}) }
    end

    def to_h : Hash(String, V)
      @values.dup
    end

    def empty? : Bool
      @values.empty?
    end

    def size : Int32
      @values.size
    end

    def merge!(other : Hash(String, V)) : self
      @values.merge!(other)
      self
    end

    def inspect(io : IO) : Nil
      @values.inspect(io)
    end
  end

  # String-keyed hash that accepts symbols too (no true runtime indifferent
  # access in Crystal, but this covers the common params/config case).
  class HashWithIndifferentAccess(V)
    include Enumerable({String, V})

    def initialize
      @values = {} of String => V
    end

    def initialize(values : Hash(String, V))
      @values = values.transform_keys(&.to_s)
    end

    def [](key : String | Symbol) : V?
      @values[key.to_s]?
    end

    def []=(key : String | Symbol, value : V) : V
      @values[key.to_s] = value
    end

    def fetch(key : String | Symbol, default : V) : V
      @values.fetch(key.to_s, default)
    end

    def has_key?(key : String | Symbol) : Bool
      @values.has_key?(key.to_s)
    end

    def delete(key : String | Symbol) : V?
      @values.delete(key.to_s)
    end

    def each(& : {String, V} ->) : Nil
      @values.each { |key, value| yield({key, value}) }
    end

    def to_h : Hash(String, V)
      @values.dup
    end

    def keys : Array(String)
      @values.keys
    end

    def values : Array(V)
      @values.values
    end

    def empty? : Bool
      @values.empty?
    end

    def size : Int32
      @values.size
    end

    def merge(other : Hash(String, V)) : self
      result = HashWithIndifferentAccess(V).new(@values)
      other.each { |key, value| result[key] = value }
      result
    end

    def merge(other : Hash(Symbol, V)) : self
      result = HashWithIndifferentAccess(V).new(@values)
      other.each { |key, value| result[key] = value }
      result
    end

    def inspect(io : IO) : Nil
      @values.inspect(io)
    end
  end

  # `"production".inquiry` equivalent. Dynamic `production?` predicates are
  # impossible in Crystal, so use `is?("production")`.
  class StringInquirer
    getter value : String

    def initialize(@value : String)
    end

    def is?(other : String | Symbol) : Bool
      @value == other.to_s
    end

    def matches?(other : String | Symbol) : Bool
      is?(other)
    end

    def ==(other : String) : Bool
      @value == other
    end

    def ==(other : StringInquirer) : Bool
      @value == other.value
    end

    def to_s : String
      @value
    end

    def to_s(io : IO) : Nil
      io << @value
    end

    def inspect(io : IO) : Nil
      io << "#<Saci::StringInquirer " << @value.inspect << '>'
    end
  end

  # Explicit-type class attributes (`class_attribute :setting, String, "x"`).
  # Crystal class variables are per-class, so subclass defaults are not
  # copied automatically.
  module ClassAttributes
    macro class_attribute(name, type, default = nil)
      @@{{name}} : {{type}}? = {{default}}

      def self.{{name}} : {{type}}?
        @@{{name}}
      end

      def self.{{name}}=(value : {{type}}?) : {{type}}?
        @@{{name}} = value
      end

      def {{name}} : {{type}}?
        self.class.{{name}}
      end

      def {{name}}=(value : {{type}}?) : {{type}}?
        self.class.{{name}} = value
      end
    end
  end

  # Compile-time descendant tracking (Rails `DescendantsTracker`). Include in
  # a base class and call `Base.descendants` / `Base.subclasses`; Crystal's
  # macro `@type.all_subclasses` resolves the hierarchy at compile time, so no
  # runtime `inherited` hook is needed and results are class-name strings.
  #
  # ```
  # class ApplicationJob
  #   include Saci::Descendants
  # end
  #
  # ApplicationJob.descendants # => ["WelcomeJob", ...]
  # ```
  module Descendants
    macro descendants
      {{ @type.all_subclasses.map(&.name.stringify) }}
    end

    macro subclasses
      {{ @type.subclasses.map(&.name.stringify) }}
    end

    # Runtime registry retained for explicitly registered classes (useful when
    # only a name string is available).
    @@registry = {} of String => Array(String)
    @@mutex = Mutex.new

    def self.register(parent : String, child : String) : Nil
      @@mutex.synchronize do
        list = (@@registry[parent] ||= [] of String)
        list << child unless list.includes?(child)
      end
    end

    def self.subclasses_of(base : String) : Array(String)
      @@mutex.synchronize { (@@registry[base]? || [] of String).dup }
    end

    def self.descendants_of(base : String) : Array(String)
      direct = subclasses_of(base)
      result = direct.dup
      direct.each { |child| result.concat(descendants_of(child)) }
      result.uniq
    end

    def self.clear! : Nil
      @@mutex.synchronize { @@registry.clear }
    end
  end

  # Compile-time equivalent of `symbolize_keys` for hash literals:
  # `Saci.symbolize_keys({"a" => 1}) # => {:a => 1}`.
  macro symbolize_keys(hash)
    {% if hash.is_a?(HashLiteral) %}
      {
        {% for key, value in hash %}
          {{ key.is_a?(StringLiteral) ? key.id.symbolize : key }} => {{ value }},
        {% end %}
      }
    {% else %}
      {% raise "Saci.symbolize_keys requires a hash literal (Crystal symbols are compile-time); use Saci::HashWithIndifferentAccess for runtime keys" %}
    {% end %}
  end

  # Rails-style `extract_options!` for an args array whose last element is an
  # options hash. (Crystal splat arguments are Tuples, so this is explicit.)
  def self.extract_options!(args : Array(Hash(String, V))) : Hash(String, V) forall V
    args.pop? || {} of String => V
  end
end
