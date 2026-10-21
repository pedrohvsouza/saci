require "./errors"

module Saci
  module GraphQL
    # GraphQL query-document lexer/parser (no external shards).
    #
    # Supports operations (query/mutation/subscription), variables, aliases,
    # directives, fragments (named and inline), all input value literals,
    # block strings, comments, and precise line/column errors.
    module Language
      class ParseError < Exception
        getter line : Int32
        getter column : Int32

        def initialize(message : String, @line : Int32, @column : Int32)
          super("#{message} at line #{@line}, column #{@column}")
        end

        def location : Location
          Location.new(@line, @column)
        end
      end

      struct Token
        getter kind : Symbol
        getter value : String
        getter line : Int32
        getter column : Int32

        def initialize(@kind : Symbol, @value : String, @line : Int32, @column : Int32)
        end

        def location : Location
          Location.new(@line, @column)
        end
      end

      class Lexer
        PUNCTUATION = "!$&():=@[]{|}"

        def initialize(@source : String)
          @index = 0
          @line = 1
          @column = 1
        end

        def tokenize : Array(Token)
          tokens = [] of Token
          loop do
            token = next_token
            tokens << token
            break if token.kind == :eof
          end
          tokens
        end

        private def next_token : Token
          skip_ignored
          line = @line
          column = @column
          return Token.new(:eof, "", line, column) if eof?

          char = current_char
          if char == '.'
            if peek_char(1) == '.' && peek_char(2) == '.'
              advance
              advance
              advance
              return Token.new(:punct, "...", line, column)
            end
            raise ParseError.new("Unexpected '.'", line, column)
          end

          if char == '"'
            return read_string(line, column)
          end

          if char.ascii_number? || (char == '-' && (peek_char(1) || '\0').ascii_number?)
            return read_number(line, column)
          end

          if name_start?(char)
            return read_name(line, column)
          end

          if PUNCTUATION.includes?(char)
            advance
            return Token.new(:punct, char.to_s, line, column)
          end

          raise ParseError.new("Unexpected character #{char.inspect}", line, column)
        end

        private def read_name(line : Int32, column : Int32) : Token
          buffer = String.build do |io|
            while !eof? && name_continue?(current_char)
              io << current_char
              advance
            end
          end
          Token.new(:name, buffer, line, column)
        end

        private def read_number(line : Int32, column : Int32) : Token
          start = @index
          kind = :int
          advance if current_char == '-'
          while !eof? && current_char.ascii_number?
            advance
          end
          if !eof? && current_char == '.' && (peek_char(1) || '\0').ascii_number?
            kind = :float
            advance
            while !eof? && current_char.ascii_number?
              advance
            end
          end
          if !eof? && (current_char == 'e' || current_char == 'E')
            kind = :float
            advance
            advance if !eof? && (current_char == '+' || current_char == '-')
            unless !eof? && current_char.ascii_number?
              raise ParseError.new("Invalid number exponent", @line, @column)
            end
            while !eof? && current_char.ascii_number?
              advance
            end
          end
          Token.new(kind, @source[start...@index], line, column)
        end

        private def read_string(line : Int32, column : Int32) : Token
          if peek_char(1) == '"' && peek_char(2) == '"'
            advance
            advance
            advance
            return read_block_string(line, column)
          end

          advance # opening quote
          value = String.build do |io|
            loop do
              raise ParseError.new("Unterminated string", line, column) if eof?
              char = current_char
              if char == '"'
                advance
                break
              elsif char == '\\'
                advance
                raise ParseError.new("Unterminated string escape", line, column) if eof?
                escape = current_char
                advance
                case escape
                when '"'  then io << '"'
                when '\\' then io << '\\'
                when '/'  then io << '/'
                when 'b'  then io << '\b'
                when 'f'  then io << '\f'
                when 'n'  then io << '\n'
                when 'r'  then io << '\r'
                when 't'  then io << '\t'
                when 'u'
                  hex = String.build do |hex_io|
                    4.times do
                      raise ParseError.new("Invalid unicode escape", @line, @column) if eof?
                      hex_io << current_char
                      advance
                    end
                  end
                  begin
                    io << hex.to_i(16).chr
                  rescue
                    raise ParseError.new("Invalid unicode escape", @line, @column)
                  end
                else
                  raise ParseError.new("Invalid string escape \\#{escape}", @line, @column)
                end
              elsif char == '\n' || char == '\r'
                raise ParseError.new("Unterminated string", line, column)
              else
                io << char
                advance
              end
            end
          end
          Token.new(:string, value, line, column)
        end

        private def read_block_string(line : Int32, column : Int32) : Token
          buffer = String.build do |io|
            loop do
              raise ParseError.new("Unterminated block string", line, column) if eof?
              if current_char == '"' && peek_char(1) == '"' && peek_char(2) == '"'
                advance
                advance
                advance
                break
              else
                io << current_char
                advance
              end
            end
          end
          Token.new(:string, buffer, line, column)
        end

        private def skip_ignored : Nil
          loop do
            break if eof?
            char = current_char
            case char
            when ' ', '\t', '\r', '\n', ',', '\u{FEFF}'
              advance
            when '#'
              while !eof? && current_char != '\n'
                advance
              end
            else
              break
            end
          end
        end

        private def eof? : Bool
          @index >= @source.size
        end

        private def current_char : Char
          @source[@index]
        end

        private def peek_char(offset : Int32) : Char?
          index = @index + offset
          index < @source.size ? @source[index] : nil
        end

        private def advance : Nil
          return if eof?
          char = @source[@index]
          @index += 1
          if char == '\n'
            @line += 1
            @column = 1
          else
            @column += 1
          end
        end

        private def name_start?(char : Char) : Bool
          char.ascii_letter? || char == '_'
        end

        private def name_continue?(char : Char) : Bool
          char.ascii_letter? || char.ascii_number? || char == '_'
        end
      end

      class TypeNode
        getter kind : Symbol
        getter name : String?
        getter of_type : TypeNode?

        def initialize(@kind : Symbol, @name : String? = nil, @of_type : TypeNode? = nil)
        end

        def self.named(name : String) : TypeNode
          new(:named, name)
        end

        def self.list(of_type : TypeNode) : TypeNode
          new(:list, nil, of_type)
        end

        def self.non_null(of_type : TypeNode) : TypeNode
          new(:non_null, nil, of_type)
        end

        def non_null? : Bool
          @kind == :non_null
        end

        def list? : Bool
          @kind == :list
        end

        def to_s(io : IO) : Nil
          case @kind
          when :named
            io << @name
          when :list
            io << '[' << @of_type << ']'
          when :non_null
            io << @of_type << '!'
          end
        end
      end

      abstract class Value
        getter location : Location

        def initialize(@location : Location)
        end
      end

      class VariableValue < Value
        getter name : String

        def initialize(@name : String, location : Location)
          super(location)
        end
      end

      class IntValue < Value
        getter value : Int64

        def initialize(@value : Int64, location : Location)
          super(location)
        end
      end

      class FloatValue < Value
        getter value : Float64

        def initialize(@value : Float64, location : Location)
          super(location)
        end
      end

      class StringValue < Value
        getter value : String

        def initialize(@value : String, location : Location)
          super(location)
        end
      end

      class BooleanValue < Value
        getter value : Bool

        def initialize(@value : Bool, location : Location)
          super(location)
        end
      end

      class NullValue < Value
        def initialize(location : Location)
          super(location)
        end
      end

      class EnumValue < Value
        getter name : String

        def initialize(@name : String, location : Location)
          super(location)
        end
      end

      class ListValue < Value
        getter values : Array(Value)

        def initialize(@values : Array(Value), location : Location)
          super(location)
        end
      end

      class ObjectValue < Value
        getter fields : Array(Tuple(String, Value))

        def initialize(@fields : Array(Tuple(String, Value)), location : Location)
          super(location)
        end
      end

      class Argument
        getter name : String
        getter value : Value
        getter location : Location

        def initialize(@name : String, @value : Value, @location : Location)
        end
      end

      class Directive
        getter name : String
        getter arguments : Array(Argument)
        getter location : Location

        def initialize(@name : String, @arguments : Array(Argument), @location : Location)
        end
      end

      abstract class Selection
        getter directives : Array(Directive)
        getter location : Location

        def initialize(@directives : Array(Directive), @location : Location)
        end
      end

      class FieldSelection < Selection
        getter alias_name : String?
        getter name : String
        getter arguments : Array(Argument)
        getter selections : Array(Selection)

        def initialize(
          @alias_name : String?,
          @name : String,
          @arguments : Array(Argument),
          @directives : Array(Directive),
          @selections : Array(Selection),
          @location : Location,
        )
          super(@directives, @location)
        end

        def response_key : String
          @alias_name || @name
        end
      end

      class FragmentSpread < Selection
        getter name : String

        def initialize(@name : String, @directives : Array(Directive), @location : Location)
          super(@directives, @location)
        end
      end

      class InlineFragment < Selection
        getter type_condition : String?
        getter selections : Array(Selection)

        def initialize(@type_condition : String?, @directives : Array(Directive), @selections : Array(Selection), @location : Location)
          super(@directives, @location)
        end
      end

      class VariableDefinition
        getter name : String
        getter type : TypeNode
        getter default_value : Value?
        getter location : Location

        def initialize(@name : String, @type : TypeNode, @default_value : Value?, @location : Location)
        end
      end

      class OperationDefinition
        getter operation : Symbol
        getter name : String?
        getter variables : Array(VariableDefinition)
        getter directives : Array(Directive)
        getter selections : Array(Selection)
        getter location : Location

        def initialize(
          @operation : Symbol,
          @name : String?,
          @variables : Array(VariableDefinition),
          @directives : Array(Directive),
          @selections : Array(Selection),
          @location : Location,
        )
        end
      end

      class FragmentDefinition
        getter name : String
        getter type_condition : String
        getter directives : Array(Directive)
        getter selections : Array(Selection)
        getter location : Location

        def initialize(
          @name : String,
          @type_condition : String,
          @directives : Array(Directive),
          @selections : Array(Selection),
          @location : Location,
        )
        end
      end

      class Document
        getter operations : Array(OperationDefinition)
        getter fragments : Array(FragmentDefinition)

        def initialize(@operations : Array(OperationDefinition), @fragments : Array(FragmentDefinition))
        end

        def operation(name : String? = nil) : OperationDefinition?
          if name
            @operations.find { |operation| operation.name == name }
          elsif @operations.size == 1
            @operations.first
          end
        end

        def fragment(name : String) : FragmentDefinition?
          @fragments.find { |fragment| fragment.name == name }
        end
      end

      class Parser
        def initialize(@source : String)
          @tokens = Lexer.new(@source).tokenize
          @index = 0
        end

        def self.parse(source : String) : Document
          new(source).parse_document
        end

        def parse_document : Document
          operations = [] of OperationDefinition
          fragments = [] of FragmentDefinition
          until peek.kind == :eof
            token = peek
            if token.kind == :punct && token.value == "{"
              operations << parse_anonymous_operation
            elsif token.kind == :name
              case token.value
              when "query", "mutation", "subscription"
                operations << parse_operation
              when "fragment"
                fragments << parse_fragment_definition
              else
                raise error("Expected query, mutation, subscription or fragment")
              end
            else
              raise error("Expected an operation or fragment definition")
            end
          end
          Document.new(operations, fragments)
        end

        private def parse_anonymous_operation : OperationDefinition
          location = peek.location
          selections = parse_selection_set
          OperationDefinition.new(:query, nil, [] of VariableDefinition, [] of Directive, selections, location)
        end

        private def parse_operation : OperationDefinition
          token = advance
          operation = case token.value
                      when "query"        then :query
                      when "mutation"     then :mutation
                      when "subscription" then :subscription
                      else                     raise error("Unknown operation #{token.value}")
                      end
          name = if peek.kind == :name
                   advance.value
                 end
          variables = peek_punct?("(") ? parse_variable_definitions : [] of VariableDefinition
          directives = parse_directives
          selections = parse_selection_set
          OperationDefinition.new(operation, name, variables, directives, selections, token.location)
        end

        private def parse_variable_definitions : Array(VariableDefinition)
          expect_punct("(")
          definitions = [] of VariableDefinition
          until peek_punct?(")")
            location = peek.location
            expect_punct("$")
            name = expect_name
            expect_punct(":")
            type = parse_type_node
            default_value = if peek_punct?("=")
                              advance
                              parse_value
                            end
            definitions << VariableDefinition.new(name, type, default_value, location)
          end
          expect_punct(")")
          definitions
        end

        private def parse_type_node : TypeNode
          if peek_punct?("[")
            advance
            inner = parse_type_node
            expect_punct("]")
            node = TypeNode.list(inner)
          else
            node = TypeNode.named(expect_name)
          end
          if peek_punct?("!")
            advance
            node = TypeNode.non_null(node)
          end
          node
        end

        private def parse_fragment_definition : FragmentDefinition
          token = advance
          if peek.kind == :name && peek.value == "on"
            raise error("Expected fragment name")
          end
          name = expect_name
          kw = expect_name
          raise error("Expected `on` in fragment definition") unless kw == "on"
          type_condition = expect_name
          directives = parse_directives
          selections = parse_selection_set
          FragmentDefinition.new(name, type_condition, directives, selections, token.location)
        end

        private def parse_selection_set : Array(Selection)
          expect_punct("{")
          selections = [] of Selection
          until peek_punct?("}")
            raise error("Unterminated selection set") if peek.kind == :eof
            selections << parse_selection
          end
          expect_punct("}")
          selections
        end

        private def parse_selection : Selection
          if peek_punct?("...")
            location = advance.location
            if peek.kind == :name && peek.value == "on"
              advance
              type_condition = expect_name
              directives = parse_directives
              selections = parse_selection_set
              InlineFragment.new(type_condition, directives, selections, location)
            elsif peek_punct?("@") || peek_punct?("{")
              directives = parse_directives
              selections = parse_selection_set
              InlineFragment.new(nil, directives, selections, location)
            else
              name = expect_name
              directives = parse_directives
              FragmentSpread.new(name, directives, location)
            end
          else
            parse_field
          end
        end

        private def parse_field : FieldSelection
          location = peek.location
          first = expect_name
          alias_name = nil
          name = first
          if peek_punct?(":")
            advance
            alias_name = first
            name = expect_name
          end
          arguments = peek_punct?("(") ? parse_arguments : [] of Argument
          directives = parse_directives
          selections = peek_punct?("{") ? parse_selection_set : [] of Selection
          FieldSelection.new(alias_name, name, arguments, directives, selections, location)
        end

        private def parse_arguments : Array(Argument)
          expect_punct("(")
          arguments = [] of Argument
          until peek_punct?(")")
            location = peek.location
            name = expect_name
            expect_punct(":")
            value = parse_value
            arguments << Argument.new(name, value, location)
          end
          expect_punct(")")
          arguments
        end

        private def parse_directives : Array(Directive)
          directives = [] of Directive
          while peek_punct?("@")
            location = advance.location
            name = expect_name
            arguments = peek_punct?("(") ? parse_arguments : [] of Argument
            directives << Directive.new(name, arguments, location)
          end
          directives
        end

        private def parse_value : Value
          token = peek
          location = token.location
          case token.kind
          when :punct
            case token.value
            when "$"
              advance
              VariableValue.new(expect_name, location)
            when "["
              advance
              values = [] of Value
              until peek_punct?("]")
                raise error("Unterminated list value") if peek.kind == :eof
                values << parse_value
              end
              advance
              ListValue.new(values, location)
            when "{"
              advance
              fields = [] of Tuple(String, Value)
              until peek_punct?("}")
                raise error("Unterminated object value") if peek.kind == :eof
                name = expect_name
                expect_punct(":")
                fields << {name, parse_value}
              end
              advance
              ObjectValue.new(fields, location)
            else
              raise error("Expected a value")
            end
          when :int
            advance
            begin
              IntValue.new(token.value.to_i64, location)
            rescue
              raise ParseError.new("Integer value is out of range", token.line, token.column)
            end
          when :float
            advance
            FloatValue.new(token.value.to_f64, location)
          when :string
            advance
            StringValue.new(token.value, location)
          when :name
            advance
            case token.value
            when "true"  then BooleanValue.new(true, location)
            when "false" then BooleanValue.new(false, location)
            when "null"  then NullValue.new(location)
            else              EnumValue.new(token.value, location)
            end
          else
            raise error("Expected a value")
          end
        end

        private def peek : Token
          @tokens[@index]
        end

        private def advance : Token
          token = @tokens[@index]
          @index += 1 unless token.kind == :eof
          token
        end

        private def peek_punct?(value : String) : Bool
          token = peek
          token.kind == :punct && token.value == value
        end

        private def expect_punct(value : String) : Token
          token = peek
          unless token.kind == :punct && token.value == value
            raise error("Expected '#{value}' but found #{describe(token)}")
          end
          advance
        end

        private def expect_name : String
          token = peek
          unless token.kind == :name
            raise error("Expected a name but found #{describe(token)}")
          end
          advance.value
        end

        private def describe(token : Token) : String
          token.kind == :eof ? "end of document" : "'#{token.value}'"
        end

        private def error(message : String) : ParseError
          token = peek
          ParseError.new(message, token.line, token.column)
        end
      end
    end
  end
end
