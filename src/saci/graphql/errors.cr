require "json"

module Saci
  module GraphQL
    # Source position used in parse errors and GraphQL `locations` entries.
    struct Location
      getter line : Int32
      getter column : Int32

      def initialize(@line : Int32, @column : Int32)
      end

      def to_json_any : JSON::Any
        JSON::Any.new({
          "line"   => JSON::Any.new(@line),
          "column" => JSON::Any.new(@column),
        } of String => JSON::Any)
      end
    end

    # A resolved path segment: field response key or list index.
    alias PathSegment = String | Int32

    # One entry in the GraphQL response `errors` array.
    class ExecutionError
      getter message : String
      getter locations : Array(Location)
      getter path : Array(PathSegment)

      def initialize(@message : String, @locations = [] of Location, @path = [] of PathSegment)
      end

      def to_json_any : JSON::Any
        obj = {"message" => JSON::Any.new(@message)} of String => JSON::Any
        unless @locations.empty?
          obj["locations"] = JSON::Any.new(@locations.map(&.to_json_any))
        end
        unless @path.empty?
          obj["path"] = JSON::Any.new(@path.map do |segment|
            case segment
            when Int32 then JSON::Any.new(segment.to_i64)
            else            JSON::Any.new(segment.to_s)
            end
          end)
        end
        JSON::Any.new(obj)
      end
    end

    # Raised by resolvers to return a clean error message to the client
    # (the executor turns it into an `errors` entry and nulls the field).
    class ExecutionErrorRaised < Exception
      getter locations : Array(Location)
      getter path : Array(PathSegment)

      def initialize(message : String, @locations = [] of Location, @path = [] of PathSegment)
        super(message)
      end
    end

    # Internal control-flow exception implementing GraphQL null propagation.
    class NullPropagation < Exception
      getter path : Array(PathSegment)

      def initialize(@path : Array(PathSegment))
        super("null propagation")
      end
    end
  end
end
