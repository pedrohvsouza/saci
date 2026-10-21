require "json"
require "big"
require "../record"
require "./errors"

module Saci
  module GraphQL
    # Argument map handed to resolvers. Values are already coerced to the
    # GraphQL argument types (variables are substituted, enum names become
    # their declared internal values, input objects become hashes).
    alias Arguments = Hash(String, JSON::Any)

    # Type-erased holder for an object source. Crystal's `Object` cannot hold
    # structs (NamedTuple, tuples), so sources are boxed in a generic wrapper.
    abstract class Box
      abstract def to_json_any : JSON::Any
      abstract def to_list : Array(Value)?
      abstract def type_label : String
    end

    class ValueBox(T) < Box
      getter value : T

      def initialize(@value : T)
      end

      def type_label : String
        {{ T.stringify }}
      end

      def to_json_any : JSON::Any
        {% if T <= JSON::Any %}
          @value
        {% elsif T <= Nil %}
          JSON::Any.new(nil)
        {% elsif T <= Array %}
          JSON::Any.new(@value.map { |item| Values.to_json_any(item) })
        {% elsif T <= Hash %}
          hash = {} of String => JSON::Any
          @value.each { |key, item| hash[key.to_s] = Values.to_json_any(item) }
          JSON::Any.new(hash)
        {% elsif T <= NamedTuple %}
          hash = {} of String => JSON::Any
          @value.each { |key, item| hash[key.to_s] = Values.to_json_any(item) }
          JSON::Any.new(hash)
        {% elsif T <= Symbol %}
          JSON::Any.new(@value.to_s)
        {% elsif T <= BigDecimal %}
          JSON::Any.new(@value.to_s)
        {% else %}
          # Arbitrary resolver objects are never valid JSON scalars, but the
          # compiler instantiates this branch for every boxed source type.
          # Keep it total instead of requiring `to_json(JSON::Builder)`.
          JSON::Any.new(@value.to_s)
        {% end %}
      end

      def to_list : Array(Value)?
        {% if T <= Array %}
          values = [] of Value
          @value.each { |item| values << Values.wrap(item) }
          values
        {% elsif T <= Saci::Record::Query %}
          values = [] of Value
          @value.to_a.each { |item| values << Values.wrap(item) }
          values
        {% else %}
          nil
        {% end %}
      end
    end

    # Runtime representation of a GraphQL value. Scalars are JSON::Any (which
    # covers String/Int/Float/Boolean/null); object sources stay boxed so
    # nested selections can keep resolving records and associations.
    abstract class Value
      def null? : Bool
        false
      end
    end

    class NullValue < Value
      def null? : Bool
        true
      end
    end

    class ScalarValue < Value
      getter value : JSON::Any

      def initialize(@value : JSON::Any)
      end
    end

    class EnumValue < Value
      getter name : String

      def initialize(@name : String)
      end
    end

    class ListValue < Value
      getter items : Array(Value)

      def initialize(@items : Array(Value))
      end
    end

    class ObjectValue < Value
      getter box : Box?

      def initialize(@box : Box?)
      end
    end

    module Values
      def self.box(value : T) : Box forall T
        ValueBox.new(value)
      end

      def self.list_value(items : Array) : ListValue
        values = [] of Value
        items.each { |item| values << wrap(item) }
        ListValue.new(values)
      end

      def self.wrap(value : Nil) : Value
        NullValue.new
      end

      def self.wrap(value : Bool | Int32 | Int64 | Float32 | Float64 | String) : Value
        ScalarValue.new(JSON::Any.new(value))
      end

      def self.wrap(value : Symbol) : Value
        ScalarValue.new(JSON::Any.new(value.to_s))
      end

      def self.wrap(value : JSON::Any) : Value
        if value.raw.nil?
          NullValue.new
        elsif array = value.as_a?
          list_value(array)
        elsif hash = value.as_h?
          ObjectValue.new(ValueBox.new(hash))
        else
          ScalarValue.new(value)
        end
      end

      def self.wrap(value : BigDecimal) : Value
        ScalarValue.new(JSON::Any.new(value.to_s))
      end

      def self.wrap(value : Array) : Value
        list_value(value)
      end

      def self.wrap(value : Hash) : Value
        ObjectValue.new(ValueBox.new(value))
      end

      def self.wrap(value : NamedTuple) : Value
        ObjectValue.new(ValueBox.new(value))
      end

      def self.wrap(value : Saci::Record::Query) : Value
        list_value(value.to_a)
      end

      def self.wrap(value : Proc) : Value
        ObjectValue.new(ValueBox.new(value))
      end

      # Fallback for nilable unions and user-defined source objects. Besides
      # plain classes this handles `T?` (nil -> GraphQL null, non-nil ->
      # boxed source) and common collections/scalars, so a resolver block
      # returning `Array(Thing)?` or `String?` does not accidentally box the
      # union type as an object.
      def self.wrap(value : T) forall T
        {% begin %}
        {% members = T.union_types %}
        {% non_nil = members.reject { |member| member <= Nil } %}
        {% if members.size > 1 %}
          if value.nil?
            NullValue.new
          else
            {% if non_nil.size == 1 %}
              {% member = non_nil[0] %}
              {% if member <= Array %}
                list_value(value.as({{member}}))
              {% elsif member <= Saci::Record::Query %}
                list_value(value.as({{member}}).to_a)
              {% elsif member <= Hash %}
                ObjectValue.new(ValueBox.new(value.as({{member}})))
              {% elsif member <= String %}
                ScalarValue.new(JSON::Any.new(value.as({{member}})))
              {% elsif member <= Bool %}
                ScalarValue.new(JSON::Any.new(value.as({{member}})))
              {% elsif member <= Int32 %}
                ScalarValue.new(JSON::Any.new(value.as({{member}})))
              {% elsif member <= Int64 %}
                ScalarValue.new(JSON::Any.new(value.as({{member}})))
              {% elsif member <= Float32 %}
                ScalarValue.new(JSON::Any.new(value.as({{member}})))
              {% elsif member <= Float64 %}
                ScalarValue.new(JSON::Any.new(value.as({{member}})))
              {% elsif member <= Symbol %}
                ScalarValue.new(JSON::Any.new(value.as({{member}}).to_s))
              {% elsif member <= BigDecimal %}
                ScalarValue.new(JSON::Any.new(value.as({{member}}).to_s))
              {% else %}
                ObjectValue.new(ValueBox.new(value.as({{member}})))
              {% end %}
            {% else %}
              ObjectValue.new(ValueBox.new(value.not_nil!))
            {% end %}
          end
        {% elsif T <= Nil %}
          NullValue.new
        {% elsif T <= Array %}
          list_value(value)
        {% elsif T <= Saci::Record::Query %}
          list_value(value.to_a)
        {% elsif T <= Hash %}
          ObjectValue.new(ValueBox.new(value))
        {% elsif T <= String %}
          ScalarValue.new(JSON::Any.new(value))
        {% elsif T <= Bool %}
          ScalarValue.new(JSON::Any.new(value))
        {% elsif T <= Int32 %}
          ScalarValue.new(JSON::Any.new(value))
        {% elsif T <= Int64 %}
          ScalarValue.new(JSON::Any.new(value))
        {% elsif T <= Float32 %}
          ScalarValue.new(JSON::Any.new(value))
        {% elsif T <= Float64 %}
          ScalarValue.new(JSON::Any.new(value))
        {% elsif T <= Symbol %}
          ScalarValue.new(JSON::Any.new(value.to_s))
        {% elsif T <= BigDecimal %}
          ScalarValue.new(JSON::Any.new(value.to_s))
        {% else %}
          ObjectValue.new(ValueBox.new(value))
        {% end %}
        {% end %}
      end

      # JSON representation used by JSON scalars and introspection defaults.
      def self.to_json_any(value : JSON::Any) : JSON::Any
        value
      end

      def self.to_json_any(value : Nil) : JSON::Any
        JSON::Any.new(nil)
      end

      def self.to_json_any(value : Bool | Int32 | Int64 | Float32 | Float64 | String) : JSON::Any
        JSON::Any.new(value)
      end

      def self.to_json_any(value : Symbol) : JSON::Any
        JSON::Any.new(value.to_s)
      end

      def self.to_json_any(value : Array) : JSON::Any
        JSON::Any.new(value.map { |item| to_json_any(item) })
      end

      def self.to_json_any(value : Hash) : JSON::Any
        hash = {} of String => JSON::Any
        value.each { |key, item| hash[key.to_s] = to_json_any(item) }
        JSON::Any.new(hash)
      end

      def self.to_json_any(value : NamedTuple) : JSON::Any
        hash = {} of String => JSON::Any
        value.each { |key, item| hash[key.to_s] = to_json_any(item) }
        JSON::Any.new(hash)
      end

      def self.to_json_any(value : BigDecimal) : JSON::Any
        JSON::Any.new(value.to_s)
      end

      def self.to_json_any(value : T) forall T
        JSON.parse(value.to_json)
      end

      # `argument default:` values are generated as `Values.json(literal)`.
      def self.json(value : T) forall T
        to_json_any(value)
      end

      # Calls a resolver proc/lambda when a field accessor returns one.
      # Supported shapes mirror common Crystal resolver styles:
      #   -> { ... }
      #   ->(args : Arguments) { ... }
      #   ->(args : Arguments, ctx : Context) { ... }
      #   ->(source : T, args : Arguments, ctx : Context) { ... }
      def self.call_if_proc(value : T, source : S, args : Arguments, ctx : Context) : Value forall T, S
        {% if T <= Proc %}
          {% if T <= Proc(Nil) %}
            wrap(value.call)
          {% elsif T <= Proc(Arguments) %}
            wrap(value.call(args))
          {% elsif T <= Proc(Arguments, Context) %}
            wrap(value.call(args, ctx))
          {% elsif T <= Proc(S, Arguments, Context) %}
            wrap(value.call(source, args, ctx))
          {% elsif T <= Proc(Object?, Arguments, Context) %}
            wrap(value.call(source.as?(Object?), args, ctx))
          {% else %}
            raise ExecutionErrorRaised.new("unsupported resolver proc type #{T}")
          {% end %}
        {% else %}
          wrap(value)
        {% end %}
      end

      def self.as_list(value : Value) : Array(Value)?
        case value
        when ListValue
          value.items
        when ObjectValue
          value.box.try(&.to_list)
        when ScalarValue
          if array = value.value.as_a?
            values = [] of Value
            array.each { |item| values << wrap(item) }
            values
          end
        end
      end

      # Scalar completion (also used for JSON scalars, where arbitrary
      # hashes/lists are allowed).
      def self.scalar_json(value : Value) : JSON::Any
        case value
        when NullValue
          JSON::Any.new(nil)
        when ScalarValue
          value.value
        when EnumValue
          JSON::Any.new(value.name)
        when ListValue
          JSON::Any.new(value.items.map { |item| scalar_json(item) })
        when ObjectValue
          if box = value.box
            box.to_json_any
          else
            JSON::Any.new(nil)
          end
        else
          JSON::Any.new(nil)
        end
      end

      # Internal enum value as a string (for matching `value "X", value: ...`).
      def self.internal_string(value : Value) : String?
        case value
        when ScalarValue
          raw = value.value.raw
          raw.nil? ? nil : raw.to_s
        when EnumValue
          value.name
        else
          nil
        end
      end
    end
  end
end
