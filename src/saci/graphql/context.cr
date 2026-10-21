require "http/server"
require "./errors"
require "./values"

module Saci
  module GraphQL
    # Per-request execution context passed to resolver blocks.
    class Context
      getter schema : Saci::GraphQL::Schema
      getter query : String
      getter operation_name : String?
      getter variables : Arguments
      getter request : HTTP::Request?
      getter controller : Saci::Controller?
      getter state : Hash(String, JSON::Any)

      def initialize(
        @schema : Saci::GraphQL::Schema,
        @query : String = "",
        @operation_name : String? = nil,
        @variables : Arguments = Arguments.new,
        @request : HTTP::Request? = nil,
        @controller : Saci::Controller? = nil,
        @state : Hash(String, JSON::Any) = {} of String => JSON::Any,
      )
      end

      def [](key : String) : JSON::Any?
        @state[key]?
      end

      def []=(key : String, value : JSON::Any) : Nil
        @state[key] = value
      end
    end
  end
end
