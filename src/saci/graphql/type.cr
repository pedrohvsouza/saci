require "json"
require "./errors"
require "./values"
require "./type_ref"
require "./context"

module Saci
  module GraphQL
    class ArgumentDefinition
      getter name : String
      getter type : TypeRef
      getter default_value : JSON::Any?
      getter description : String?

      def initialize(@name : String, @type : TypeRef, @default_value : JSON::Any? = nil, @description : String? = nil)
      end

      def required? : Bool
        @type.non_null?
      end
    end

    class EnumValueDefinition
      getter name : String
      getter description : String?
      getter value : JSON::Any
      getter deprecation_reason : String?

      def initialize(@name : String, @value : JSON::Any, @description : String? = nil, @deprecation_reason : String? = nil)
      end
    end

    class FieldDefinition
      getter name : String
      getter type : TypeRef
      getter arguments : Array(ArgumentDefinition)
      getter description : String?
      getter deprecation_reason : String?
      getter resolver : Proc(ObjectType, Arguments, Context, Value)

      def initialize(
        @name : String,
        @type : TypeRef,
        @arguments : Array(ArgumentDefinition),
        @description : String?,
        @deprecation_reason : String?,
        @resolver : Proc(ObjectType, Arguments, Context, Value),
      )
      end

      def argument(name : String) : ArgumentDefinition?
        @arguments.find { |argument| argument.name == name }
      end
    end

    class TypeDefinition
      getter name : String
      getter kind : Symbol
      getter description : String?
      getter fields : Array(FieldDefinition)
      getter arguments : Array(ArgumentDefinition)
      getter enum_values : Array(EnumValueDefinition)
      getter factory : Proc(Box?, ObjectType)?

      def initialize(
        @name : String,
        @kind : Symbol,
        @description : String? = nil,
        @fields : Array(FieldDefinition) = [] of FieldDefinition,
        @arguments : Array(ArgumentDefinition) = [] of ArgumentDefinition,
        @enum_values : Array(EnumValueDefinition) = [] of EnumValueDefinition,
        @factory : Proc(Box?, ObjectType)? = nil,
      )
      end

      def object? : Bool
        @kind == :object
      end

      def input? : Bool
        @kind == :input
      end

      def enum? : Bool
        @kind == :enum
      end

      def scalar? : Bool
        @kind == :scalar
      end

      def field(name : String) : FieldDefinition?
        @fields.find { |field| field.name == name }
      end

      def argument(name : String) : ArgumentDefinition?
        @arguments.find { |argument| argument.name == name }
      end

      def enum_value_by_name(name : String) : EnumValueDefinition?
        @enum_values.find { |value| value.name == name }
      end

      def enum_value_by_internal(value : String) : EnumValueDefinition?
        @enum_values.find { |item| item.value.raw.to_s == value }
      end

      # Introspection kind label.
      def kind_label : String
        case @kind
        when :object then "OBJECT"
        when :input  then "INPUT_OBJECT"
        when :enum   then "ENUM"
        when :scalar then "SCALAR"
        else              "UNKNOWN"
        end
      end
    end

    # Global type-class registry. Every `ObjectType`/`EnumType`/`InputObject`
    # subclass registers a lazy builder at load time; schemas resolve named
    # references through it, which makes forward/cyclic GraphQL types work
    # even though Crystal macros cannot see a class defined later in a file.
    module Registry
      @@builders = {} of String => Proc(TypeDefinition)
      @@cache : Array(TypeDefinition)? = nil

      def self.register(key : String, builder : Proc(TypeDefinition)) : Nil
        @@builders[key] = builder
        @@cache = nil
      end

      def self.definitions : Array(TypeDefinition)
        @@cache ||= @@builders.values.map(&.call)
      end

      # Maps both the Crystal class name and the declared GraphQL name to the
      # definition. Field declarations naturally spell the Crystal constant
      # (`IntroTypeType`, `PostType`) while introspection exposes the GraphQL
      # name (`__Type`, `Post`).
      def self.named_definitions : Hash(String, TypeDefinition)
        result = {} of String => TypeDefinition
        @@builders.each do |key, builder|
          definition = builder.call
          result[key] = definition
          result[key.split("::").last] = definition
          result[definition.name] = definition
        end
        result
      end

      def self.find(name : String) : TypeDefinition?
        named_definitions[name]? || definitions.find { |definition| definition.name == name }
      end

      def self.clear_cache : Nil
        @@cache = nil
      end
    end

    abstract class BaseType
      @@__gql_definition : TypeDefinition?

      def self.__gql_definition : TypeDefinition
        @@__gql_definition ||= __gql_build_definition
      end

      def self.__gql_build_definition : TypeDefinition
        raise "GraphQL type #{self} does not implement __gql_build_definition"
      end

      def self.__gql_type_name : String
        name = self.name
        name.split("::").last
      end

      def self.__gql_description : String?
        nil
      end

      macro graphql_name(value)
        def self.__gql_type_name : String
          {{value}}.to_s
        end
      end

      macro description(value)
        def self.__gql_description : String?
          {{value}}
        end
      end
    end

    class ObjectType < BaseType
      @__gql_source : Box?

      def initialize(@__gql_source : Box? = nil)
      end

      def __gql_source_box : Box?
        @__gql_source
      end

      def self.__gql_fields : Array(FieldDefinition)
        [] of FieldDefinition
      end

      def self.__gql_build_definition : TypeDefinition
        raise "abstract GraphQL object type"
      end

      macro inherited
        {% unless @type.abstract? %}
          # Seed the method so every `field` macro can use `previous_def`
          # even for the first field.
          def self.__gql_fields : Array(Saci::GraphQL::FieldDefinition)
            super
          end

          def self.__gql_build_definition : Saci::GraphQL::TypeDefinition
            Saci::GraphQL::TypeDefinition.new(
              __gql_type_name,
              :object,
              __gql_description,
              fields: __gql_fields,
              factory: ->(source : Saci::GraphQL::Box?) { {{@type}}.new(source).as(Saci::GraphQL::ObjectType) },
            )
          end

          Saci::GraphQL::Registry.register({{@type.name.stringify}}, -> { {{@type}}.__gql_definition })
        {% end %}
      end

      # Declares the Crystal object backing this GraphQL type. Field access is
      # generated statically, so a resolver block can omit the source only
      # when it does not need one.
      macro source(type)
        def __gql_typed_source : {{type}}
          box = @__gql_source
          raise Saci::GraphQL::ExecutionErrorRaised.new("GraphQL field resolution for #{self.class} needs a source object") if box.nil?
          box.as(Saci::GraphQL::ValueBox({{type}})).value
        end

        def self.__gql_source_type_name : String
          {{type.stringify}}
        end
      end

      # Defines one output field.
      #
      # ```
      # field :id, Saci::GraphQL::ID, null: false
      # field :posts, [PostType]
      # field :post, PostType do
      #   argument :id, Saci::GraphQL::ID, required: true
      #   resolve do |source, args, ctx|
      #     Post.find(args["id"].as_s.to_i64)
      #   end
      # end
      # field :summary, String do |source, _args, _ctx|
      #   source.title.upcase
      # end
      # ```
      macro field(name, type, null = true, items_nullable = true, description = nil, deprecation_reason = nil, resolver = nil, &block)
        {% has_block = !block.is_a?(Nop) %}
        {% block_has_args = has_block && !block.args.empty? %}
        {% body_exprs = has_block ? (block.body.is_a?(Expressions) ? block.body.expressions : [block.body]) : [] of ASTNode %}

        {% decl_args = [] of ASTNode %}
        {% resolve_call = nil %}
        {% decl_description = nil %}
        {% if has_block && !block_has_args %}
          {% for stmt in body_exprs %}
            {% if stmt.is_a?(Call) %}
              {% if stmt.name.stringify == "argument" %}
                {% decl_args << stmt %}
              {% elsif stmt.name.stringify == "description" && !stmt.args.empty? %}
                {% decl_description = stmt.args[0] %}
              {% elsif stmt.name.stringify == "resolve" && stmt.block.is_a?(Block) %}
                {% resolve_call = stmt.block %}
              {% end %}
            {% end %}
          {% end %}
        {% end %}

        {% resolver_block = block_has_args ? block : resolve_call %}
        {% field_desc = !description.is_a?(NilLiteral) ? description : decl_description %}
        {% field_deprecation = !deprecation_reason.is_a?(NilLiteral) ? deprecation_reason : nil %}
        {% src_method = @type.methods.find { |method| method.name == "__gql_typed_source" } %}
        {% src_type = src_method ? src_method.return_type : nil %}

        def __gql_field_{{name.id}}(__gql_args : Saci::GraphQL::Arguments, __gql_ctx : Saci::GraphQL::Context) : Saci::GraphQL::Value
          {% if resolver_block %}
            {% if resolver_block.args.size > 0 %}
              {% if src_type.nil? %}
                {{resolver_block.args[0].id}} = nil
              {% else %}
                {{resolver_block.args[0].id}} = __gql_typed_source
              {% end %}
            {% end %}
            {% if resolver_block.args.size > 1 %}
              {{resolver_block.args[1].id}} = __gql_args
            {% end %}
            {% if resolver_block.args.size > 2 %}
              {{resolver_block.args[2].id}} = __gql_ctx
            {% end %}
            {% if resolver_block.args.size > 3 %}
              {% raise "GraphQL field resolver for #{@type}##{name} accepts at most (source, args, ctx)" %}
            {% end %}
            Saci::GraphQL::Values.wrap(begin
              {{resolver_block.body}}
            end)
          {% elsif resolver && !resolver.is_a?(NilLiteral) %}
            {% if src_type.nil? %}
              Saci::GraphQL::Values.wrap(({{resolver}}).call(__gql_args, __gql_ctx))
            {% else %}
              Saci::GraphQL::Values.call_if_proc({{resolver}}, __gql_typed_source, __gql_args, __gql_ctx)
            {% end %}
          {% else %}
            {% if src_type.nil? %}
              {% raise "GraphQL field #{@type}##{name} needs a `source` declaration or a resolver block" %}
            {% end %}
            {% src_kind = src_type.stringify %}
            {% if src_kind.starts_with?("Hash") || src_kind == "JSON::Any" %}
              Saci::GraphQL::Values.wrap(__gql_typed_source[{{name}}.to_s]?)
            {% elsif src_kind.starts_with?("NamedTuple") %}
              Saci::GraphQL::Values.wrap(__gql_typed_source[{{name}}]?)
            {% else %}
              Saci::GraphQL::Values.wrap(__gql_typed_source.{{name.id}})
            {% end %}
          {% end %}
        end

        def self.__gql_fields : Array(Saci::GraphQL::FieldDefinition)
          previous_def + [
            Saci::GraphQL::FieldDefinition.new(
              {{name}}.to_s,
              Saci::GraphQL::TypeRef.parse({{type.stringify}}).items_non_null_if(!({{items_nullable}})).non_null_if(!({{null}})),
              [
                {% for stmt in decl_args %}
                  {% if stmt.named_args.is_a?(ArrayLiteral) %}
                    {% req = stmt.named_args.find { |arg| arg.name.stringify == "required" } %}
                    {% default_arg = stmt.named_args.find { |arg| arg.name.stringify == "default" } %}
                    {% desc_arg = stmt.named_args.find { |arg| arg.name.stringify == "description" } %}
                  {% else %}
                    {% req = nil %}
                    {% default_arg = nil %}
                    {% desc_arg = nil %}
                  {% end %}
                  Saci::GraphQL::ArgumentDefinition.new(
                    {{stmt.args[0]}}.to_s,
                    Saci::GraphQL::TypeRef.parse({{stmt.args[1].stringify}}).non_null_if({{req ? req.value : false}}),
                    default_value: {% if default_arg %}Saci::GraphQL::Values.json({{default_arg.value}}){% else %}nil{% end %},
                    description: {% if desc_arg %}{{desc_arg.value}}{% else %}nil{% end %},
                  ),
                {% end %}
              ] of Saci::GraphQL::ArgumentDefinition,
              {{field_desc}},
              {{field_deprecation}},
              ->(object : Saci::GraphQL::ObjectType, args : Saci::GraphQL::Arguments, ctx : Saci::GraphQL::Context) {
                object.as({{@type}}).__gql_field_{{name.id}}(args, ctx).as(Saci::GraphQL::Value)
              },
            ),
          ]
        end
      end
    end

    class EnumType < BaseType
      def self.__gql_enum_values : Array(EnumValueDefinition)
        [] of EnumValueDefinition
      end

      def self.__gql_build_definition : TypeDefinition
        raise "abstract GraphQL enum type"
      end

      macro inherited
        {% unless @type.abstract? %}
          def self.__gql_enum_values : Array(Saci::GraphQL::EnumValueDefinition)
            super
          end

          def self.__gql_build_definition : Saci::GraphQL::TypeDefinition
            Saci::GraphQL::TypeDefinition.new(
              __gql_type_name,
              :enum,
              __gql_description,
              enum_values: __gql_enum_values,
            )
          end

          Saci::GraphQL::Registry.register({{@type.name.stringify}}, -> { {{@type}}.__gql_definition })
        {% end %}
      end

      # `value "PUBLISHED", value: "published", description: "..."`.
      macro value(name, description = nil, value = nil)
        def self.__gql_enum_values : Array(Saci::GraphQL::EnumValueDefinition)
          previous_def + [
            {% if value.is_a?(NilLiteral) %}
              {% if description.is_a?(NilLiteral) %}
                Saci::GraphQL::EnumValueDefinition.new({{name}}.to_s, ::JSON::Any.new({{name}}.to_s), nil),
              {% else %}
                Saci::GraphQL::EnumValueDefinition.new({{name}}.to_s, ::JSON::Any.new({{name}}.to_s), {{description}}),
              {% end %}
            {% else %}
              {% if description.is_a?(NilLiteral) %}
                Saci::GraphQL::EnumValueDefinition.new({{name}}.to_s, Saci::GraphQL::Values.json({{value}}), nil),
              {% else %}
                Saci::GraphQL::EnumValueDefinition.new({{name}}.to_s, Saci::GraphQL::Values.json({{value}}), {{description}}),
              {% end %}
            {% end %}
          ]
        end
      end
    end

    class InputObjectType < BaseType
      def self.__gql_input_arguments : Array(ArgumentDefinition)
        [] of ArgumentDefinition
      end

      def self.__gql_build_definition : TypeDefinition
        raise "abstract GraphQL input object type"
      end

      macro inherited
        {% unless @type.abstract? %}
          def self.__gql_input_arguments : Array(Saci::GraphQL::ArgumentDefinition)
            super
          end

          def self.__gql_build_definition : Saci::GraphQL::TypeDefinition
            Saci::GraphQL::TypeDefinition.new(
              __gql_type_name,
              :input,
              __gql_description,
              arguments: __gql_input_arguments,
            )
          end

          Saci::GraphQL::Registry.register({{@type.name.stringify}}, -> { {{@type}}.__gql_definition })
        {% end %}
      end

      # Input object fields use the same `argument` DSL as field arguments.
      macro argument(name, type, required = false, default = nil, description = nil)
        def self.__gql_input_arguments : Array(Saci::GraphQL::ArgumentDefinition)
          previous_def + [
            Saci::GraphQL::ArgumentDefinition.new(
              {{name}}.to_s,
              Saci::GraphQL::TypeRef.parse({{type.stringify}}).non_null_if({{required}}),
              default_value: {% if default.is_a?(NilLiteral) %}nil{% else %}Saci::GraphQL::Values.json({{default}}){% end %},
              description: {% if description.is_a?(NilLiteral) %}nil{% else %}{{description}}{% end %},
            ),
          ]
        end
      end
    end

    # `InputObject` reads better in application code; `InputObjectType` stays
    # available for symmetry with `ObjectType`/`EnumType`.
    alias InputObject = InputObjectType
  end
end
