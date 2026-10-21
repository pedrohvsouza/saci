require "./core_ext"

# Record-level ActiveSupport conveniences. Required after `saci/record`.
module Saci
  module Record
    class Base
      # Rails `as_json(only:, except:, methods:)`. `methods:` cannot call
      # arbitrary Crystal methods by name; it is accepted for source
      # compatibility but ignored (add computed keys in application code).
      def as_json(*, only : Array(String | Symbol)? = nil, except : Array(String | Symbol)? = nil, methods : Array(String | Symbol)? = nil) : Hash(String, JSON::Any)
        only_keys = only.try(&.map(&.to_s))
        except_keys = except.try(&.map(&.to_s).to_set)
        result = {} of String => JSON::Any
        self.class.__saci_column_names.each do |(name, _)|
          next if only_keys && !only_keys.includes?(name)
          next if except_keys && except_keys.includes?(name)
          result[name] = Base.json_value(read_attribute(name))
        end
        result
      end

      # URL segment for this record (Rails `to_param`): primary key as string.
      def to_param : String
        value = read_attribute(self.class.primary_key_name)
        value.nil? ? "" : value.to_s
      end

      protected def self.json_value(value : Saci::Record::Value) : JSON::Any
        case value
        when Nil
          JSON::Any.new(nil)
        when Bool
          JSON::Any.new(value)
        when Int32
          JSON::Any.new(value.to_i64)
        when Int64
          JSON::Any.new(value)
        when Float32, Float64
          JSON::Any.new(value.to_f64)
        when Time
          JSON::Any.new(value.to_rfc3339)
        when Bytes
          JSON::Any.new(value.hexstring)
        when Array(String)
          JSON::Any.new(value.map { |item| JSON::Any.new(item) })
        else
          JSON::Any.new(value.to_s)
        end
      end
    end
  end
end
