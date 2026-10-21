require "json"
require "./errors"
require "./type"
require "./parser"
require "./context"

module Saci
  module GraphQL
    # Schema registry + execution entry point.
    #
    # ```
    # class QueryType < Saci::GraphQL::ObjectType
    #   graphql_name "Query"
    #   field :hello, String do |_source, _args, _ctx|
    #     "world"
    #   end
    # end
    #
    # class AppSchema < Saci::GraphQL::Schema
    #   query QueryType
    # end
    #
    # AppSchema.execute("{ hello }").to_json
    # ```
    class Schema
      getter query_type : TypeDefinition
      getter mutation_type : TypeDefinition?
      getter types : Hash(String, TypeDefinition)

      BUILTIN_SCALARS = {
        "String"  => "Built-in String scalar",
        "Int"     => "Built-in 64-bit integer scalar",
        "Float"   => "Built-in double-precision floating point scalar",
        "Boolean" => "Built-in boolean scalar",
        "ID"      => "Built-in opaque identifier scalar",
        "JSON"    => "Arbitrary JSON value scalar",
      }

      def self.__gql_query_definition : TypeDefinition?
        nil
      end

      def self.__gql_mutation_definition : TypeDefinition?
        nil
      end

      def self.__gql_extra_definitions : Array(TypeDefinition)
        [] of TypeDefinition
      end

      # Declares the query root type.
      macro query(type)
        def self.__gql_query_definition : Saci::GraphQL::TypeDefinition?
          {{type}}.__gql_definition
        end
      end

      # Declares the mutation root type.
      macro mutation(type)
        def self.__gql_mutation_definition : Saci::GraphQL::TypeDefinition?
          {{type}}.__gql_definition
        end
      end

      # Registers additional types that are not reachable from a field
      # (usually only needed for types that are never referenced directly).
      macro types(*types)
        def self.__gql_extra_definitions : Array(Saci::GraphQL::TypeDefinition)
          [{% for type in types %}{{type}}.__gql_definition,{% end %}] of Saci::GraphQL::TypeDefinition
        end
      end

      # Named class form: `Saci::GraphQL::Schema.define(AppSchema) do ... end`.
      macro define(name = nil, &block)
        {% if name %}
          class {{name.id}} < Saci::GraphQL::Schema
            {{block.body}}
          end
        {% else %}
          {% raise "Saci::GraphQL::Schema.define requires a schema class name, e.g. Schema.define(AppSchema) do ... end" %}
        {% end %}
      end

      def self.execute(
        query : String,
        *,
        variables : Hash(String, JSON::Any) | JSON::Any | String | Nil = nil,
        operation_name : String? = nil,
        root_value : Box? = nil,
        context : Context? = nil,
        request : HTTP::Request? = nil,
        controller : Saci::Controller? = nil,
      ) : ExecutionResult
        document = Language::Parser.parse(query)
        schema = new
        execution_context = context || Context.new(schema, query, operation_name, normalize_variables(variables), request, controller)
        Executor.new(schema, document, execution_context, root_value).execute
      rescue error : Language::ParseError
        ExecutionResult.request_error(error.message || "Parse error", [error.location], parse_error: true)
      end

      def self.normalize_variables(value : Hash(String, JSON::Any) | JSON::Any | String | Nil) : Arguments
        case value
        when nil
          {} of String => JSON::Any
        when Hash(String, JSON::Any)
          value
        when JSON::Any
          value.as_h? || {} of String => JSON::Any
        when String
          parsed = JSON.parse(value)
          parsed.as_h? || {} of String => JSON::Any
        else
          {} of String => JSON::Any
        end
      rescue JSON::ParseException
        {} of String => JSON::Any
      end

      def initialize
        available = {} of String => TypeDefinition
        BUILTIN_SCALARS.each do |name, description|
          available[name] = TypeDefinition.new(name, :scalar, description)
        end
        Saci::GraphQL::Introspection.definitions.each do |definition|
          available[definition.name] = definition
        end
        Registry.named_definitions.each do |name, definition|
          available[name] = definition
        end
        self.class.__gql_extra_definitions.each do |definition|
          available[definition.name] = definition
        end

        query_definition = self.class.__gql_query_definition
        raise ArgumentError.new("#{self.class} has no query root (add `query SomeType`)") unless query_definition
        mutation_definition = self.class.__gql_mutation_definition

        @query_type = query_definition
        @mutation_type = mutation_definition

        reachable = {} of String => TypeDefinition
        queue = [] of TypeDefinition
        queue << query_definition
        queue << mutation_definition if mutation_definition

        until queue.empty?
          definition = queue.shift
          next if reachable.has_key?(definition.name)
          reachable[definition.name] = definition
          definition.fields.each do |field|
            collect_ref(field.type, available, reachable, queue)
            field.arguments.each { |argument| collect_ref(argument.type, available, reachable, queue) }
          end
          definition.arguments.each { |argument| collect_ref(argument.type, available, reachable, queue) }
        end

        # Built-in scalars and introspection types are always visible to
        # GraphiQL, even when no field currently uses them.
        available.each do |name, definition|
          if definition.scalar? && BUILTIN_SCALARS.has_key?(name)
            reachable[definition.name] ||= definition
          elsif definition.name.starts_with?("__")
            reachable[definition.name] ||= definition
          end
        end
        @types = reachable
        @lookup = {} of String => TypeDefinition
        available.each do |name, definition|
          @lookup[name] = definition if reachable.has_key?(definition.name)
        end
      end

      private def collect_ref(ref : TypeRef, available : Hash(String, TypeDefinition), reachable : Hash(String, TypeDefinition), queue : Array(TypeDefinition)) : Nil
        case ref.kind
        when :list, :non_null
          collect_ref(ref.of_type.not_nil!, available, reachable, queue)
        when :named
          name = ref.name.not_nil!
          return if reachable.has_key?(name)
          if definition = available[name]?
            queue << definition
          end
        end
      end

      def type(name : String) : TypeDefinition?
        @lookup[name]?
      end

      def query_type_name : String
        @query_type.name
      end

      def mutation_type_name : String?
        @mutation_type.try(&.name)
      end

      def execute(
        document : Language::Document,
        variables : Arguments = Arguments.new,
        operation_name : String? = nil,
        root_value : Box? = nil,
        context : Context? = nil,
      ) : ExecutionResult
        execution_context = context || Context.new(self, String::Builder.new.to_s, operation_name, variables)
        Executor.new(self, document, execution_context, root_value).execute
      end
    end
  end
end
