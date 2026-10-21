require "./errors"

module Saci
  module GraphQL
    # A reference to a GraphQL type. `:named` refs are resolved against the
    # schema registry at execution/introspection time; this is what allows
    # forward references between Crystal type classes (GraphQL schemas are
    # naturally cyclic, Crystal constants are not visible to a macro that
    # runs before a later class is defined).
    class TypeRef
      getter kind : Symbol
      getter name : String?
      getter of_type : TypeRef?

      def initialize(@kind : Symbol, @name : String? = nil, @of_type : TypeRef? = nil)
      end

      def self.named(name : String) : TypeRef
        new(:named, normalize_name(name))
      end

      def self.list(of_type : TypeRef) : TypeRef
        new(:list, nil, of_type)
      end

      def self.non_null(of_type : TypeRef) : TypeRef
        new(:non_null, nil, of_type)
      end

      # Parses the subset of Crystal type syntax used by the DSL:
      # `String`, `[PostType]`, `[[Int]]`, `Array(PostType)`,
      # `String?` (the nilability is ignored; use `null: false` instead),
      # plus built-in scalar aliases (`Int32` -> Int, `Boolean`, `JSON`, ...).
      def self.parse(source : String) : TypeRef
        text = source.strip
        while text.starts_with?("::")
          text = text.lchop("::")
        end

        if text.starts_with?("::Union(") && text.ends_with?(")")
          inner = text[8..-2]
          parts = split_top_level(inner)
          chosen = parts.find { |part| normalize_name(part.strip) != "Nil" }
          return parse(chosen || "Nil")
        end

        if text.starts_with?("Union(") && text.ends_with?(")")
          inner = text[6..-2]
          parts = split_top_level(inner)
          chosen = parts.find { |part| normalize_name(part.strip) != "Nil" }
          return parse(chosen || "Nil")
        end

        if text.ends_with?("!")
          return parse(text[0..-2]).non_null
        end

        if text.starts_with?("[") && text.ends_with?("]")
          return list(parse(text[1..-2]))
        end

        if text.starts_with?("Array(") && text.ends_with?(")")
          return list(parse(text[6..-2]))
        end

        # A nilable Crystal type without the leading ::Union wrapper (e.g.
        # when the user writes `String?` in a hand-built TypeRef string).
        if text.ends_with?("?")
          return parse(text[0..-2])
        end

        named(text)
      end

      private def self.split_top_level(source : String) : Array(String)
        parts = [] of String
        depth = 0
        start = 0
        source.each_char_with_index do |char, index|
          case char
          when '(', '[', '{'
            depth += 1
          when ')', ']', '}'
            depth -= 1
          when ','
            if depth == 0
              parts << source[start...index]
              start = index + 1
            end
          end
        end
        parts << source[start..]
        parts
      end

      def self.normalize_name(name : String) : String
        text = name.strip
        while text.starts_with?("::")
          text = text.lchop("::")
        end
        text = text.lchop("Saci::GraphQL::")
        text = text.lchop("GraphQL::")
        case text
        when "Int8", "Int16", "Int32", "Int64", "UInt8", "UInt16", "UInt32", "UInt64"
          "Int"
        when "Float32", "Float64"
          "Float"
        when "Bool", "Boolean"
          "Boolean"
        when "JSON", "JSON::Any"
          "JSON"
        when "ID", "GraphQLID", "UUID"
          "ID"
        when "Nil"
          "Nil"
        else
          text
        end
      end

      def non_null? : Bool
        @kind == :non_null
      end

      def list? : Bool
        @kind == :list
      end

      def named? : Bool
        @kind == :named
      end

      def non_null : TypeRef
        non_null? ? self : TypeRef.non_null(self)
      end

      def non_null_if(condition : Bool) : TypeRef
        condition ? non_null : self
      end

      def items_non_null : TypeRef
        case @kind
        when :list
          TypeRef.list(@of_type.not_nil!.non_null)
        when :non_null
          TypeRef.non_null(@of_type.not_nil!.items_non_null)
        else
          self
        end
      end

      def items_non_null_if(condition : Bool) : TypeRef
        condition ? items_non_null : self
      end

      # Unwraps `NON_NULL`/`LIST` wrappers down to the named type.
      def named_type : TypeRef
        case @kind
        when :named
          self
        else
          @of_type.not_nil!.named_type
        end
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

      # Human-readable GraphQL type syntax (`[Post!]!`).
      def graphql_name : String
        to_s
      end
    end
  end
end
