module Saci
  module Record
    # Rails-like validation errors collection (`record.errors`).
    class Errors
      getter messages : Hash(String, Array(String))

      def initialize
        @messages = {} of String => Array(String)
      end

      def add(attr : String | Symbol, message : String) : Nil
        list = @messages[attr.to_s]? || [] of String
        list << message
        @messages[attr.to_s] = list
      end

      def [](attr : String | Symbol) : Array(String)
        @messages[attr.to_s]? || [] of String
      end

      def empty? : Bool
        @messages.each_value.all?(&.empty?)
      end

      def clear : Nil
        @messages.clear
      end

      def full_messages : Array(String)
        @messages.flat_map do |attr, msgs|
          msgs.map { |m| "#{humanize(attr)} #{m}" }
        end
      end

      def to_s(io : IO) : Nil
        full_messages.join(", ", io)
      end

      private def humanize(attr : String) : String
        attr.split("_").map(&.capitalize).join(" ")
      end
    end
  end
end
