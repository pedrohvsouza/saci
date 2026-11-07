require "json"
require "./record"

module Saci
  module Job
    # Converts job arguments to JSON-safe values. In addition to the usual
    # JSON primitives, arrays, tuples, hashes and `NamedTuple`s, a
    # `Saci::Record::Base` instance is serialized as a GlobalID-style
    # reference:
    #
    # ```
    # {"_saci_record" => "User", "id" => 42}
    # ```
    #
    # The payload remains ordinary JSON, so it crosses the durable queue
    # boundary, survives restarts and can be inspected from the dashboard.
    # Resolve it inside `perform` with `Saci::Job::GlobalID.load`:
    #
    # ```
    # class NotifyJob < Saci::Job::Base
    #   def perform(payload : JSON::Any) : Nil
    #     user = Saci::Job::GlobalID.load(payload["user"]).as(User)
    #     Notifier.call(user)
    #   end
    # end
    #
    # NotifyJob.perform_later({user: user, count: 3})
    # ```
    #
    # Every model auto-registers with `Saci::Record`'s polymorphic registry
    # (the same registry `belongs_to polymorphic: true` uses), so resolving
    # a reference needs no extra wiring. Unsupported argument classes raise
    # `ArgumentError` with the offending type instead of silently JSON
    # encoding their internals.
    module GlobalID
      RECORD_KEY = "_saci_record"
      GID_KEY    = "gid"

      def self.encode(value : Saci::Record::Base) : JSON::Any
        id = value.__saci_get_attr(value.class.__saci_primary_key)
        if id.nil?
          raise ArgumentError.new(
            "Saci::Job: cannot enqueue an unsaved #{value.class.name} as a job argument " \
            "(primary key #{value.class.__saci_primary_key.inspect} is nil); save it first")
        end
        JSON::Any.new({
          RECORD_KEY => JSON::Any.new(value.class.name),
          "id"       => json_scalar(id),
        } of String => JSON::Any)
      end

      def self.encode(value : JSON::Any) : JSON::Any
        value
      end

      def self.encode(value : Hash) : JSON::Any
        hash = {} of String => JSON::Any
        value.each { |key, item| hash[key.to_s] = encode(item) }
        JSON::Any.new(hash)
      end

      def self.encode(value : NamedTuple) : JSON::Any
        hash = {} of String => JSON::Any
        value.each { |key, item| hash[key.to_s] = encode(item) }
        JSON::Any.new(hash)
      end

      def self.encode(value : Array) : JSON::Any
        JSON::Any.new(value.map { |item| encode(item) })
      end

      def self.encode(value : Tuple) : JSON::Any
        JSON::Any.new(value.map { |item| encode(item) })
      end

      def self.encode(value : Number) : JSON::Any
        JSON.parse(value.to_json)
      end

      def self.encode(value : String) : JSON::Any
        JSON::Any.new(value)
      end

      def self.encode(value : Symbol) : JSON::Any
        JSON::Any.new(value.to_s)
      end

      def self.encode(value : Bool) : JSON::Any
        JSON::Any.new(value)
      end

      def self.encode(value : Time) : JSON::Any
        JSON::Any.new(value.to_rfc3339)
      end

      def self.encode(value : Bytes) : JSON::Any
        JSON::Any.new(value.map { |byte| JSON::Any.new(byte.to_i64) })
      end

      def self.encode(value : Nil) : JSON::Any
        JSON::Any.new(nil)
      end

      # Reject anything else at enqueue time. This deliberately catches
      # arbitrary objects (IOs, connections, procs, custom structs without a
      # JSON representation) so enqueueing never silently stores a useless
      # representation.
      def self.encode(value) : JSON::Any
        raise ArgumentError.new(
          "Saci::Job: unsupported job argument #{value.class}. " \
          "Use JSON primitives, arrays, hashes, NamedTuples, JSON::Any, " \
          "Saci::Record::Base instances or serialize custom values explicitly")
      end

      def self.record?(value : JSON::Any) : Bool
        hash = value.as_h?
        return false unless hash
        hash.has_key?(RECORD_KEY) || hash.has_key?(GID_KEY)
      end

      # Resolves `{"_saci_record" => "User", "id" => 1}` (or a `{"gid" =>
      # "User/1"}` / `gid://saci/User/1` reference) through the polymorphic
      # registry. Raises `Saci::Record::RecordNotFound` when the class or
      # row no longer exists; that is intentional: a job referring to a
      # deleted record should fail loudly rather than silently skip work.
      def self.load(value : JSON::Any) : Saci::Record::Base
        hash = value.as_h?
        unless hash
          raise ArgumentError.new("Saci::Job::GlobalID.load expects a record reference object, got #{value.raw.class}")
        end
        type, id = reference_parts(hash)
        record = Saci::Record.resolve_polymorphic(type, id)
        record || raise Saci::Record::RecordNotFound.new(
          "Couldn't find #{type} with id=#{id} for job argument")
      end

      # Nilable variant for optional arguments.
      def self.load?(value : JSON::Any?) : Saci::Record::Base?
        return nil if value.nil?
        return nil unless record?(value)
        load(value)
      end

      def self.load_all(values : Array(JSON::Any)) : Array(Saci::Record::Base)
        values.map { |value| load(value) }
      end

      # Serializes a record reference without going through `Job.encode`
      # (useful in custom adapters/tests).
      def self.dump(record : Saci::Record::Base) : JSON::Any
        encode(record)
      end

      private def self.reference_parts(hash : Hash(String, JSON::Any)) : Tuple(String, Saci::Record::Value)
        if (type_value = hash[RECORD_KEY]?)
          type = type_value.as_s? || raise ArgumentError.new("Saci::Job: malformed #{RECORD_KEY} (expected a class name)")
          id_value = hash["id"]? || raise ArgumentError.new("Saci::Job: record reference is missing \"id\"")
          {type, id_scalar(id_value)}
        elsif (gid_value = hash[GID_KEY]?)
          parse_gid(gid_value.as_s? || raise ArgumentError.new("Saci::Job: malformed gid (expected a string)"))
        else
          raise ArgumentError.new("Saci::Job: not a record reference (expected #{RECORD_KEY.inspect} or #{GID_KEY.inspect})")
        end
      end

      private def self.id_scalar(value : JSON::Any) : Saci::Record::Value
        case raw = value.raw
        when String  then raw
        when Int64   then raw
        when Int32   then raw.to_i64
        when Float64 then raw == raw.to_i64.to_f64 ? raw.to_i64 : raise ArgumentError.new("Saci::Job: record id must be an integer or string, got #{raw}")
        when Bool    then raw
        else
          raise ArgumentError.new("Saci::Job: record id must be an integer or string, got #{raw.class}")
        end
      end

      private def self.parse_gid(gid : String) : Tuple(String, Saci::Record::Value)
        source = gid.starts_with?("gid://") ? gid.sub("gid://", "") : gid
        parts = source.split("/")
        if parts.size >= 3 && parts[0] == "saci"
          return {parts[1], parts[2..].join("/")}
        end
        if parts.size >= 2
          return {parts[0], parts[1..].join("/")}
        end
        if bits = source.split(":", 2)
          if bits.size == 2
            return {bits[0], bits[1]}
          end
        end
        raise ArgumentError.new("Saci::Job: malformed gid #{gid.inspect} (expected Class/id or gid://saci/Class/id)")
      end

      private def self.json_scalar(value : Nil) : JSON::Any
        JSON::Any.new(nil)
      end

      private def self.json_scalar(value : Bool | Int32 | Int64 | Float32 | Float64 | String) : JSON::Any
        JSON.parse(value.to_json)
      end

      private def self.json_scalar(value : Time) : JSON::Any
        JSON::Any.new(value.to_rfc3339)
      end

      private def self.json_scalar(value : Bytes) : JSON::Any
        JSON::Any.new(value.map { |byte| JSON::Any.new(byte.to_i64) })
      end

      private def self.json_scalar(value : Array(String)) : JSON::Any
        JSON.parse(value.to_json)
      end

      private def self.json_scalar(value : Saci::Record::Value) : JSON::Any
        raise ArgumentError.new("Saci::Job: unsupported record primary key type #{value.class}")
      end
    end

    # Public entry point used by `Job::Base` and adapters.
    def self.encode(value) : JSON::Any
      GlobalID.encode(value)
    end
  end
end
