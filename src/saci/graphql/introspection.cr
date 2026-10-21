require "json"
require "./type"

module Saci
  module GraphQL
    # Minimal but GraphiQL-friendly introspection implementation.
    #
    # The `__Schema`/`__Type`/`__Field`/... objects are ordinary GraphQL
    # object types backed by small wrapper sources, so introspection goes
    # through the same selection/execution code as application fields.
    module Introspection
      # The GraphiQL/graphql-js introspection query (fragments included).
      QUERY = <<-GRAPHQL
      query IntrospectionQuery {
        __schema {
          queryType { name }
          mutationType { name }
          subscriptionType { name }
          types { ...FullType }
          directives {
            name
            description
            locations
            args { ...InputValue }
          }
        }
      }
      fragment FullType on __Type {
        kind
        name
        description
        fields(includeDeprecated: true) {
          name
          description
          args { ...InputValue }
          type { ...TypeRef }
          isDeprecated
          deprecationReason
        }
        inputFields { ...InputValue }
        interfaces { ...TypeRef }
        enumValues(includeDeprecated: true) {
          name
          description
          isDeprecated
          deprecationReason
        }
        possibleTypes { ...TypeRef }
      }
      fragment InputValue on __InputValue {
        name
        description
        type { ...TypeRef }
        defaultValue
      }
      fragment TypeRef on __Type {
        kind
        name
        ofType {
          kind
          name
          ofType {
            kind
            name
            ofType {
              kind
              name
              ofType { kind name }
            }
          }
        }
      }
      GRAPHQL

      class SchemaValue
        getter schema : Saci::GraphQL::Schema

        def initialize(@schema : Saci::GraphQL::Schema)
        end

        def description : String?
          nil
        end

        def types : Array(TypeValue)
          @schema.types.values.map { |definition| TypeValue.named(definition, @schema) }.sort_by { |value| value.name || "" }
        end

        def query_type : TypeValue
          TypeValue.named(@schema.query_type, @schema)
        end

        def mutation_type : TypeValue?
          if definition = @schema.mutation_type
            TypeValue.named(definition, @schema)
          end
        end

        def subscription_type : TypeValue?
          nil
        end

        def directives : Array(DirectiveValue)
          DirectiveValue.builtins
        end
      end

      class TypeValue
        getter schema : Saci::GraphQL::Schema
        getter definition : TypeDefinition?
        getter ref : TypeRef

        def initialize(@schema : Saci::GraphQL::Schema, @ref : TypeRef, @definition : TypeDefinition? = nil)
        end

        def self.named(definition : TypeDefinition, schema : Saci::GraphQL::Schema) : TypeValue
          new(schema, TypeRef.named(definition.name), definition)
        end

        def self.from_ref(ref : TypeRef, schema : Saci::GraphQL::Schema) : TypeValue
          named_ref = ref.named_type
          definition = schema.type(named_ref.name.not_nil!)
          new(schema, ref, definition)
        end

        def name : String?
          @ref.kind == :named ? @ref.name : nil
        end

        def kind : String
          case @ref.kind
          when :non_null
            "NON_NULL"
          when :list
            "LIST"
          else
            @definition.try(&.kind_label) || "SCALAR"
          end
        end

        def description : String?
          @definition.try(&.description)
        end

        def specified_by_url : String?
          nil
        end

        def fields(include_deprecated : Bool = false) : Array(FieldValue)?
          definition = @definition
          return nil unless definition && definition.object?
          values = definition.fields.map { |field| FieldValue.new(field, @schema) }
          values.reject! { |field| field.deprecated? } unless include_deprecated
          values
        end

        def interfaces : Array(TypeValue)
          [] of TypeValue
        end

        def possible_types : Array(TypeValue)
          [] of TypeValue
        end

        def enum_values(include_deprecated : Bool = false) : Array(EnumValueValue)?
          definition = @definition
          return nil unless definition && definition.enum?
          values = definition.enum_values.map { |value| EnumValueValue.new(value) }
          values.reject! { |value| value.deprecated? } unless include_deprecated
          values
        end

        def input_fields : Array(InputValue)?
          definition = @definition
          return nil unless definition && definition.input?
          definition.arguments.map { |argument| InputValue.new(argument, @schema) }
        end

        def of_type : TypeValue?
          case @ref.kind
          when :non_null, :list
            TypeValue.from_ref(@ref.of_type.not_nil!, @schema)
          end
        end
      end

      class FieldValue
        getter field : FieldDefinition
        getter schema : Saci::GraphQL::Schema

        def initialize(@field : FieldDefinition, @schema : Saci::GraphQL::Schema)
        end

        def name : String
          @field.name
        end

        def description : String?
          @field.description
        end

        def args : Array(InputValue)
          @field.arguments.map { |argument| InputValue.new(argument, @schema) }
        end

        def type : TypeValue
          TypeValue.from_ref(@field.type, @schema)
        end

        def deprecated? : Bool
          !@field.deprecation_reason.nil?
        end

        def is_deprecated : Bool
          deprecated?
        end

        def deprecation_reason : String?
          @field.deprecation_reason
        end
      end

      class InputValue
        getter argument : ArgumentDefinition
        getter schema : Saci::GraphQL::Schema

        def initialize(@argument : ArgumentDefinition, @schema : Saci::GraphQL::Schema)
        end

        def name : String
          @argument.name
        end

        def description : String?
          @argument.description
        end

        def type : TypeValue
          TypeValue.from_ref(@argument.type, @schema)
        end

        def default_value : String?
          value = @argument.default_value
          value.try(&.to_json)
        end
      end

      class EnumValueValue
        getter value : EnumValueDefinition

        def initialize(@value : EnumValueDefinition)
        end

        def name : String
          @value.name
        end

        def description : String?
          @value.description
        end

        def deprecated? : Bool
          !@value.deprecation_reason.nil?
        end

        def is_deprecated : Bool
          deprecated?
        end

        def deprecation_reason : String?
          @value.deprecation_reason
        end
      end

      class DirectiveValue
        getter name : String
        getter description : String?
        getter locations : Array(String)
        getter args : Array(InputValue)
        getter repeatable : Bool

        def initialize(@name : String, @description : String?, @locations : Array(String), @args : Array(InputValue), @repeatable : Bool = false)
        end

        def is_repeatable : Bool
          @repeatable
        end

        def self.builtins : Array(DirectiveValue)
          boolean_required = ArgumentDefinition.new("if", TypeRef.parse("Boolean").non_null)
          reason = ArgumentDefinition.new("reason", TypeRef.parse("String"), default_value: JSON::Any.new("No longer supported"))
          [
            new("skip", "Directs the executor to skip this field or fragment when the `if` argument is true.",
              ["FIELD", "FRAGMENT_SPREAD", "INLINE_FRAGMENT"], [InputValue.new(boolean_required, EmptySchema.instance)]),
            new("include", "Directs the executor to include this field or fragment only when the `if` argument is true.",
              ["FIELD", "FRAGMENT_SPREAD", "INLINE_FRAGMENT"], [InputValue.new(boolean_required, EmptySchema.instance)]),
            new("deprecated", "Marks an element of a GraphQL schema as no longer supported.",
              ["FIELD_DEFINITION", "ARGUMENT_DEFINITION", "INPUT_FIELD_DEFINITION", "ENUM_VALUE"],
              [InputValue.new(reason, EmptySchema.instance)]),
          ]
        end
      end

      # InputValue wants a schema for nested type refs. Built-in directive
      # argument `Boolean`/`String` types are scalars, so a tiny stand-in is
      # enough and avoids constructing a full schema just for directives.
      class EmptySchema < Saci::GraphQL::Schema
        @@instance : EmptySchema?

        def self.instance : EmptySchema
          @@instance ||= new
        end

        def initialize
          @query_type = TypeDefinition.new("Query", :object)
          @mutation_type = nil
          @types = {} of String => TypeDefinition
          @lookup = {} of String => TypeDefinition
        end
      end

      class IntroSchemaType < Saci::GraphQL::ObjectType
        source SchemaValue
        graphql_name "__Schema"
        description "A GraphQL schema description."

        field :description, String
        field :types, [IntroTypeType], null: false
        field :queryType, IntroTypeType, null: false do |source, _args, _ctx|
          source.query_type
        end
        field :mutationType, IntroTypeType do |source, _args, _ctx|
          source.mutation_type
        end
        field :subscriptionType, IntroTypeType do |source, _args, _ctx|
          source.subscription_type
        end
        field :directives, [IntroDirectiveType], null: false
      end

      class IntroTypeType < Saci::GraphQL::ObjectType
        source TypeValue
        graphql_name "__Type"
        description "A GraphQL type."

        field :kind, IntroTypeKind, null: false
        field :name, String
        field :description, String
        field :specifiedByURL, String do |source, _args, _ctx|
          source.specified_by_url
        end
        field :fields, [IntroFieldType] do
          argument :includeDeprecated, Boolean, default: false
          resolve do |source, args, _ctx|
            source.fields(args["includeDeprecated"]?.try(&.as_bool?) || false)
          end
        end
        field :interfaces, [IntroTypeType], null: false
        field :possibleTypes, [IntroTypeType], null: false do |source, _args, _ctx|
          source.possible_types
        end
        field :enumValues, [IntroEnumValueType] do
          argument :includeDeprecated, Boolean, default: false
          resolve do |source, args, _ctx|
            source.enum_values(args["includeDeprecated"]?.try(&.as_bool?) || false)
          end
        end
        field :inputFields, [IntroInputValueType] do |source, _args, _ctx|
          source.input_fields
        end
        field :ofType, IntroTypeType do |source, _args, _ctx|
          source.of_type
        end
      end

      class IntroFieldType < Saci::GraphQL::ObjectType
        source FieldValue
        graphql_name "__Field"
        description "A field of an object or interface type."

        field :name, String, null: false
        field :description, String
        field :args, [IntroInputValueType], null: false
        field :type, IntroTypeType, null: false
        field :isDeprecated, Boolean, null: false do |source, _args, _ctx|
          source.is_deprecated
        end
        field :deprecationReason, String do |source, _args, _ctx|
          source.deprecation_reason
        end
      end

      class IntroInputValueType < Saci::GraphQL::ObjectType
        source InputValue
        graphql_name "__InputValue"
        description "An argument or input-object field."

        field :name, String, null: false
        field :description, String
        field :type, IntroTypeType, null: false
        field :defaultValue, String do |source, _args, _ctx|
          source.default_value
        end
      end

      class IntroEnumValueType < Saci::GraphQL::ObjectType
        source EnumValueValue
        graphql_name "__EnumValue"
        description "One value of an enum type."

        field :name, String, null: false
        field :description, String
        field :isDeprecated, Boolean, null: false do |source, _args, _ctx|
          source.is_deprecated
        end
        field :deprecationReason, String do |source, _args, _ctx|
          source.deprecation_reason
        end
      end

      class IntroDirectiveType < Saci::GraphQL::ObjectType
        source DirectiveValue
        graphql_name "__Directive"
        description "A directive supported by the schema."

        field :name, String, null: false
        field :description, String
        field :locations, [String], null: false
        field :args, [IntroInputValueType], null: false
        field :isRepeatable, Boolean, null: false do |source, _args, _ctx|
          source.is_repeatable
        end
      end

      class IntroTypeKind < Saci::GraphQL::EnumType
        graphql_name "__TypeKind"
        description "The kind of a GraphQL type."

        value "SCALAR"
        value "OBJECT"
        value "INTERFACE"
        value "UNION"
        value "ENUM"
        value "INPUT_OBJECT"
        value "LIST"
        value "NON_NULL"
      end

      def self.definitions : Array(TypeDefinition)
        [
          IntroSchemaType.__gql_definition,
          IntroTypeType.__gql_definition,
          IntroFieldType.__gql_definition,
          IntroInputValueType.__gql_definition,
          IntroEnumValueType.__gql_definition,
          IntroDirectiveType.__gql_definition,
          IntroTypeKind.__gql_definition,
        ]
      end
    end
  end
end
