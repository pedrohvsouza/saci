require "json"
require "set"
require "./errors"
require "./values"
require "./type"
require "./type_ref"
require "./parser"
require "./schema"
require "./context"
require "./introspection"

module Saci
  module GraphQL
    class ExecutionResult
      getter data : JSON::Any?
      getter errors : Array(ExecutionError)
      getter? parse_error : Bool

      def initialize(@data : JSON::Any?, @errors : Array(ExecutionError) = [] of ExecutionError, @parse_error : Bool = false, @data_set : Bool = true)
      end

      def self.request_error(message : String, locations : Array(Location) = [] of Location, parse_error : Bool = false) : ExecutionResult
        new(nil, [ExecutionError.new(message, locations)], parse_error, false)
      end

      def success? : Bool
        @errors.empty?
      end

      def to_h : Hash(String, JSON::Any)
        hash = {} of String => JSON::Any
        hash["data"] = @data.not_nil! if @data_set && !@data.nil?
        hash["data"] = JSON::Any.new(nil) if @data_set && @data.nil?
        hash["errors"] = JSON::Any.new(@errors.map(&.to_json_any)) unless @errors.empty?
        hash
      end

      def to_json : String
        to_h.to_json
      end
    end

    class Executor
      class FieldGroup
        getter key : String
        getter name : String
        getter nodes : Array(Language::FieldSelection)

        def initialize(@key : String, @name : String, @nodes : Array(Language::FieldSelection))
        end

        def selections : Array(Language::Selection)
          @nodes.flat_map(&.selections)
        end

        def location : Location
          @nodes.first.location
        end

        def arguments : Array(Language::Argument)
          @nodes.first.arguments
        end
      end

      def initialize(
        @schema : Schema,
        @document : Language::Document,
        @context : Context,
        @root_value : Box?,
      )
        @errors = [] of ExecutionError
        @variables = {} of String => JSON::Any
        @fragments = {} of String => Language::FragmentDefinition
        @document.fragments.each { |fragment| @fragments[fragment.name] = fragment }
      end

      def execute : ExecutionResult
        operation = select_operation
        return operation unless operation.is_a?(Language::OperationDefinition)

        prepare_variables(operation)
        return ExecutionResult.new(nil, @errors, false, false) unless @errors.empty?

        if operation.operation == :subscription
          @errors << ExecutionError.new("Subscriptions are not supported by Saci::GraphQL")
          return ExecutionResult.new(nil, @errors, false, false)
        end

        root_definition = if operation.operation == :mutation
                            @schema.mutation_type
                          else
                            @schema.query_type
                          end
        if root_definition.nil?
          @errors << ExecutionError.new("Schema has no #{operation.operation} root type")
          return ExecutionResult.new(nil, @errors, false, false)
        end

        begin
          data = execute_selection_set(root_definition, @root_value, operation.selections, [] of PathSegment, root: true)
          ExecutionResult.new(data, @errors)
        rescue NullPropagation
          ExecutionResult.new(JSON::Any.new(nil), @errors)
        end
      end

      private def select_operation : Language::OperationDefinition | ExecutionResult
        name = @context.operation_name
        if name
          if operation = @document.operation(name)
            return operation
          end
          @errors << ExecutionError.new("Unknown operation named '#{name}'")
          return ExecutionResult.new(nil, @errors, false, false)
        end

        if @document.operations.empty?
          @errors << ExecutionError.new("Query document contains no operations")
          return ExecutionResult.new(nil, @errors, false, false)
        end

        if @document.operations.size > 1
          @errors << ExecutionError.new("Must provide operation name if query contains multiple operations")
          return ExecutionResult.new(nil, @errors, false, false)
        end

        @document.operations.first
      end

      private def prepare_variables(operation : Language::OperationDefinition) : Nil
        operation.variables.each do |variable|
          ref = TypeRef.parse(variable.type.to_s)
          if provided = @context.variables[variable.name]?
            if coerced = coerce_input(provided, ref, variable.location)
              @variables[variable.name] = coerced
            end
          elsif default = variable.default_value
            value = evaluate_ast_value(default)
            if coerced = coerce_input(value, ref, variable.location)
              @variables[variable.name] = coerced
            end
          elsif ref.non_null?
            @errors << ExecutionError.new("Variable $#{variable.name} of required type #{ref} was not provided", [variable.location])
          end
        end
      end

      private def execute_selection_set(
        definition : TypeDefinition,
        source : Box?,
        selections : Array(Language::Selection),
        path : Array(PathSegment),
        root : Bool = false,
      ) : JSON::Any
        factory = definition.factory
        unless factory
          @errors << ExecutionError.new("Type #{definition.name} cannot be used as an object")
          return JSON::Any.new(nil)
        end
        object = factory.call(source)
        groups = collect_fields(selections, definition.name)
        result = {} of String => JSON::Any

        groups.each do |group|
          key = group.key
          if group.name == "__typename"
            result[key] = JSON::Any.new(definition.name)
            next
          end

          if root && group.name == "__schema"
            value = Values.wrap(Introspection::SchemaValue.new(@schema))
            complete_and_store(result, key, TypeRef.parse("__Schema").non_null, value, group, path, nil)
            next
          end

          if root && group.name == "__type"
            value = resolve_type_meta_field(group, path)
            complete_and_store(result, key, TypeRef.parse("__Type"), value, group, path, nil)
            next
          end

          field = definition.field(group.name)
          if field.nil?
            @errors << ExecutionError.new("Cannot query field '#{group.name}' on type '#{definition.name}'", [group.location], path + [key])
            result[key] = JSON::Any.new(nil)
            next
          end

          arguments = coerce_arguments(field, group.arguments, group.location, path + [key])
          if arguments.nil?
            result[key] = JSON::Any.new(nil)
            next
          end

          begin
            value = field.resolver.call(object, arguments, @context)
          rescue error : ExecutionErrorRaised
            @errors << ExecutionError.new(error.message || "Execution error", error.locations.empty? ? [group.location] : error.locations, path + [key])
            if field.type.non_null?
              raise NullPropagation.new(path + [key])
            end
            result[key] = JSON::Any.new(nil)
            next
          rescue error
            @errors << ExecutionError.new(error.message || error.class.name, [group.location], path + [key])
            if field.type.non_null?
              raise NullPropagation.new(path + [key])
            end
            result[key] = JSON::Any.new(nil)
            next
          end

          complete_and_store(result, key, field.type, value, group, path, field)
        end

        JSON::Any.new(result)
      end

      private def complete_and_store(
        result : Hash(String, JSON::Any),
        key : String,
        ref : TypeRef,
        value : Value,
        group : FieldGroup,
        path : Array(PathSegment),
        field : FieldDefinition?,
      ) : Nil
        begin
          result[key] = complete_value(ref, value, group.selections, path + [key], field, group.location, group.name)
        rescue NullPropagation
          if ref.non_null?
            raise NullPropagation.new(path + [key])
          else
            result[key] = JSON::Any.new(nil)
          end
        end
      end

      private def complete_value(
        ref : TypeRef,
        value : Value,
        selections : Array(Language::Selection),
        path : Array(PathSegment),
        field : FieldDefinition?,
        location : Location,
        field_name : String,
      ) : JSON::Any
        case ref.kind
        when :non_null
          if value.null?
            @errors << ExecutionError.new("Cannot return null for non-nullable field #{field_name}", [location], path)
            raise NullPropagation.new(path)
          end
          complete_value(ref.of_type.not_nil!, value, selections, path, field, location, field_name)
        when :list
          return JSON::Any.new(nil) if value.null?
          items = Values.as_list(value)
          if items.nil?
            @errors << ExecutionError.new("Expected a list for field '#{field_name}'", [location], path)
            return JSON::Any.new(nil)
          end
          output = [] of JSON::Any
          inner = ref.of_type.not_nil!
          items.each_with_index do |item, index|
            begin
              output << complete_value(inner, item, selections, path + [index], field, location, field_name)
            rescue NullPropagation
              if inner.non_null?
                raise NullPropagation.new(path)
              else
                output << JSON::Any.new(nil)
              end
            end
          end
          JSON::Any.new(output)
        else
          return JSON::Any.new(nil) if value.null?
          type_name = ref.name.not_nil!
          definition = @schema.type(type_name)
          if definition.nil?
            @errors << ExecutionError.new("Unknown type '#{type_name}' for field '#{field_name}'", [location], path)
            return JSON::Any.new(nil)
          end

          case definition.kind
          when :scalar
            serialize_scalar(type_name, value, location, path, field_name)
          when :enum
            serialize_enum(definition, value, location, path, field_name)
          when :object
            box = box_for(value)
            if box.nil? && !value.is_a?(ObjectValue)
              @errors << ExecutionError.new("Expected an object for field '#{field_name}'", [location], path)
              return JSON::Any.new(nil)
            end
            execute_selection_set(definition, box, selections, path)
          when :input
            @errors << ExecutionError.new("Input type '#{type_name}' cannot be used as a field type", [location], path)
            JSON::Any.new(nil)
          else
            JSON::Any.new(nil)
          end
        end
      end

      private def box_for(value : Value) : Box?
        case value
        when ObjectValue
          value.box
        when ScalarValue
          raw = value.value
          if hash = raw.as_h?
            Values.box(hash)
          end
        end
      end

      private def serialize_scalar(type_name : String, value : Value, location : Location, path : Array(PathSegment), field_name : String) : JSON::Any
        raw = Values.scalar_json(value)
        case type_name
        when "ID"
          return JSON::Any.new(nil) if raw.raw.nil?
          JSON::Any.new(raw.raw.to_s)
        when "String"
          if string = raw.as_s?
            JSON::Any.new(string)
          else
            @errors << ExecutionError.new("String cannot represent value: #{raw.to_json}", [location], path)
            JSON::Any.new(nil)
          end
        when "Int"
          if integer = raw.as_i64?
            JSON::Any.new(integer)
          elsif float = raw.as_f?
            if float == float.to_i64.to_f64
              JSON::Any.new(float.to_i64)
            else
              @errors << ExecutionError.new("Int cannot represent non-integer value: #{raw.to_json}", [location], path)
              JSON::Any.new(nil)
            end
          else
            @errors << ExecutionError.new("Int cannot represent value: #{raw.to_json}", [location], path)
            JSON::Any.new(nil)
          end
        when "Float"
          if float = raw.as_f?
            JSON::Any.new(float)
          elsif integer = raw.as_i64?
            JSON::Any.new(integer.to_f64)
          else
            @errors << ExecutionError.new("Float cannot represent value: #{raw.to_json}", [location], path)
            JSON::Any.new(nil)
          end
        when "Boolean"
          bool = raw.as_bool?
          if !bool.nil?
            JSON::Any.new(bool)
          else
            @errors << ExecutionError.new("Boolean cannot represent value: #{raw.to_json}", [location], path)
            JSON::Any.new(nil)
          end
        else
          # JSON and custom scalars pass through.
          raw
        end
      end

      private def serialize_enum(definition : TypeDefinition, value : Value, location : Location, path : Array(PathSegment), field_name : String) : JSON::Any
        internal = Values.internal_string(value)
        if internal
          if enum_value = definition.enum_value_by_internal(internal) || definition.enum_value_by_name(internal)
            return JSON::Any.new(enum_value.name)
          end
        end
        @errors << ExecutionError.new("Enum '#{definition.name}' cannot represent value #{Values.scalar_json(value).to_json}", [location], path)
        JSON::Any.new(nil)
      end

      private def resolve_type_meta_field(group : FieldGroup, path : Array(PathSegment)) : Value
        name = nil
        group.arguments.each do |argument|
          if argument.name == "name"
            value = evaluate_ast_value(argument.value)
            name = value.as_s?
          end
        end
        if name.nil?
          @errors << ExecutionError.new("__type requires a `name` argument", [group.location], path + [group.key])
          return Values.wrap(nil)
        end
        if definition = @schema.type(name)
          Values.wrap(Introspection::TypeValue.named(definition, @schema))
        else
          Values.wrap(nil)
        end
      end

      private def collect_fields(
        selections : Array(Language::Selection),
        type_name : String,
        groups = [] of FieldGroup,
        by_key = {} of String => FieldGroup,
        visited = Set(String).new,
      ) : Array(FieldGroup)
        selections.each do |selection|
          next unless include_selection?(selection.directives)

          case selection
          when Language::FieldSelection
            key = selection.response_key
            if group = by_key[key]?
              group.nodes << selection
            else
              group = FieldGroup.new(key, selection.name, [selection])
              by_key[key] = group
              groups << group
            end
          when Language::FragmentSpread
            fragment = @fragments[selection.name]?
            if fragment.nil?
              @errors << ExecutionError.new("Unknown fragment '#{selection.name}'", [selection.location])
              next
            end
            next if visited.includes?(selection.name)
            visited << selection.name
            next unless fragment.type_condition == type_name
            next unless include_selection?(fragment.directives)
            collect_fields(fragment.selections, type_name, groups, by_key, visited)
          when Language::InlineFragment
            condition = selection.type_condition
            next if condition && condition != type_name
            collect_fields(selection.selections, type_name, groups, by_key, visited)
          end
        end
        groups
      end

      private def include_selection?(directives : Array(Language::Directive)) : Bool
        directives.each do |directive|
          case directive.name
          when "skip", "include"
            condition = nil
            directive.arguments.each do |argument|
              if argument.name == "if"
                condition = evaluate_ast_value(argument.value).as_bool?
              end
            end
            if condition.nil?
              @errors << ExecutionError.new("Directive @#{directive.name} requires a boolean `if` argument", [directive.location])
              next
            end
            return false if directive.name == "skip" && condition
            return false if directive.name == "include" && !condition
          end
        end
        true
      end

      private def coerce_arguments(
        field : FieldDefinition,
        provided : Array(Language::Argument),
        location : Location,
        path : Array(PathSegment),
      ) : Arguments?
        result = {} of String => JSON::Any
        seen = Set(String).new

        provided.each do |argument|
          definition = field.argument(argument.name)
          if definition.nil?
            @errors << ExecutionError.new("Unknown argument '#{argument.name}' on field '#{field.name}'", [argument.location], path)
            return nil
          end
          seen << argument.name
          value = evaluate_ast_value(argument.value)
          if coerced = coerce_input(value, definition.type, argument.location)
            result[argument.name] = coerced
          else
            return nil
          end
        end

        field.arguments.each do |definition|
          next if seen.includes?(definition.name)
          if default = definition.default_value
            if coerced = coerce_input(default, definition.type, location)
              result[definition.name] = coerced
            else
              return nil
            end
          elsif definition.type.non_null?
            @errors << ExecutionError.new("Missing required argument '#{definition.name}' on field '#{field.name}'", [location], path)
            return nil
          end
        end
        result
      end

      private def evaluate_ast_value(value : Language::Value) : JSON::Any
        case value
        when Language::VariableValue
          @variables[value.name]? || JSON::Any.new(nil)
        when Language::IntValue
          JSON::Any.new(value.value)
        when Language::FloatValue
          JSON::Any.new(value.value)
        when Language::StringValue
          JSON::Any.new(value.value)
        when Language::BooleanValue
          JSON::Any.new(value.value)
        when Language::NullValue
          JSON::Any.new(nil)
        when Language::EnumValue
          JSON::Any.new(value.name)
        when Language::ListValue
          JSON::Any.new(value.values.map { |item| evaluate_ast_value(item) })
        when Language::ObjectValue
          hash = {} of String => JSON::Any
          value.fields.each { |(name, item)| hash[name] = evaluate_ast_value(item) }
          JSON::Any.new(hash)
        else
          JSON::Any.new(nil)
        end
      end

      private def coerce_input(value : JSON::Any, ref : TypeRef, location : Location) : JSON::Any?
        case ref.kind
        when :non_null
          if value.raw.nil?
            @errors << ExecutionError.new("Expected non-null value of type #{ref}", [location])
            return nil
          end
          coerce_input(value, ref.of_type.not_nil!, location)
        when :list
          inner = ref.of_type.not_nil!
          if array = value.as_a?
            output = [] of JSON::Any
            array.each do |item|
              if coerced = coerce_input(item, inner, location)
                output << coerced
              else
                return nil
              end
            end
            JSON::Any.new(output)
          else
            if coerced = coerce_input(value, inner, location)
              JSON::Any.new([coerced])
            end
          end
        else
          return JSON::Any.new(nil) if value.raw.nil?
          name = ref.name.not_nil!
          definition = @schema.type(name)
          if definition.nil?
            @errors << ExecutionError.new("Unknown input type '#{name}'", [location])
            return nil
          end
          case definition.kind
          when :scalar
            coerce_scalar_input(name, value, location)
          when :enum
            coerce_enum_input(definition, value, location)
          when :input
            coerce_input_object(definition, value, location)
          else
            @errors << ExecutionError.new("Type '#{name}' cannot be used as an input", [location])
            nil
          end
        end
      end

      private def coerce_scalar_input(name : String, value : JSON::Any, location : Location) : JSON::Any?
        case name
        when "ID"
          if string = value.as_s?
            JSON::Any.new(string)
          elsif integer = value.as_i64?
            JSON::Any.new(integer.to_s)
          else
            @errors << ExecutionError.new("ID cannot represent value: #{value.to_json}", [location])
            nil
          end
        when "String"
          if string = value.as_s?
            JSON::Any.new(string)
          else
            @errors << ExecutionError.new("String cannot represent value: #{value.to_json}", [location])
            nil
          end
        when "Int"
          if integer = value.as_i64?
            JSON::Any.new(integer)
          elsif float = value.as_f?
            if float == float.to_i64.to_f64
              JSON::Any.new(float.to_i64)
            else
              @errors << ExecutionError.new("Int cannot represent non-integer value: #{value.to_json}", [location])
              nil
            end
          else
            @errors << ExecutionError.new("Int cannot represent value: #{value.to_json}", [location])
            nil
          end
        when "Float"
          if float = value.as_f?
            JSON::Any.new(float)
          elsif integer = value.as_i64?
            JSON::Any.new(integer.to_f64)
          else
            @errors << ExecutionError.new("Float cannot represent value: #{value.to_json}", [location])
            nil
          end
        when "Boolean"
          bool = value.as_bool?
          if !bool.nil?
            JSON::Any.new(bool)
          else
            @errors << ExecutionError.new("Boolean cannot represent value: #{value.to_json}", [location])
            nil
          end
        else
          value
        end
      end

      private def coerce_enum_input(definition : TypeDefinition, value : JSON::Any, location : Location) : JSON::Any?
        name = value.as_s?
        if name
          if enum_value = definition.enum_value_by_name(name)
            return enum_value.value
          elsif enum_value = definition.enum_value_by_internal(name)
            return enum_value.value
          end
        end
        @errors << ExecutionError.new("Enum '#{definition.name}' cannot represent value: #{value.to_json}", [location])
        nil
      end

      private def coerce_input_object(definition : TypeDefinition, value : JSON::Any, location : Location) : JSON::Any?
        hash = value.as_h?
        if hash.nil?
          @errors << ExecutionError.new("Expected input object '#{definition.name}'", [location])
          return nil
        end

        result = {} of String => JSON::Any
        definition.arguments.each do |argument|
          if provided = hash[argument.name]?
            if coerced = coerce_input(provided, argument.type, location)
              result[argument.name] = coerced
            else
              return nil
            end
          elsif default = argument.default_value
            if coerced = coerce_input(default, argument.type, location)
              result[argument.name] = coerced
            else
              return nil
            end
          elsif argument.type.non_null?
            @errors << ExecutionError.new("Missing required input field '#{argument.name}' on '#{definition.name}'", [location])
            return nil
          end
        end

        hash.each_key do |key|
          unless definition.argument(key)
            @errors << ExecutionError.new("Unknown input field '#{key}' on '#{definition.name}'", [location])
            return nil
          end
        end
        JSON::Any.new(result)
      end
    end
  end
end
