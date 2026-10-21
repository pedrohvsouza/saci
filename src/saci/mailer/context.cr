require "json"

module Saci
  module Mailer
    # Parameter bag for parameterized mailers (`Mailer.with(user: u).welcome`).
    # Values are JSON-safe snapshots so the same bag can ride through
    # `deliver_later` without holding on to records.
    class Params
      include Enumerable({String, JSON::Any})

      def initialize(@raw : Hash(String, JSON::Any) = {} of String => JSON::Any)
      end

      def self.empty : Params
        new
      end

      def self.build(named : NamedTuple) : Params
        raw = {} of String => JSON::Any
        named.each { |key, value| raw[key.to_s] = any(value) }
        new(raw)
      end

      def self.any(value : JSON::Any) : JSON::Any
        value
      end

      def self.any(value : String) : JSON::Any
        JSON::Any.new(value)
      end

      def self.any(value : Int) : JSON::Any
        JSON::Any.new(value.to_i64)
      end

      def self.any(value : Float) : JSON::Any
        JSON::Any.new(value)
      end

      def self.any(value : Bool) : JSON::Any
        JSON::Any.new(value)
      end

      def self.any(value : Nil) : JSON::Any
        JSON::Any.new(nil)
      end

      def self.any(value : Time) : JSON::Any
        JSON::Any.new(value.to_rfc3339)
      end

      def self.any(value : Symbol) : JSON::Any
        JSON::Any.new(value.to_s)
      end

      def self.any(value : Array(String)) : JSON::Any
        JSON::Any.new(value.map { |item| JSON::Any.new(item) })
      end

      def self.any(value : Hash(String, String)) : JSON::Any
        h = {} of String => JSON::Any
        value.each { |k, v| h[k] = JSON::Any.new(v) }
        JSON::Any.new(h)
      end

      # Fallback keeps `with(...)` compiling for records and other objects.
      # Values crossing `deliver_later` must be JSON-safe, so arbitrary
      # objects degrade to their string form (pass ids for real jobs).
      def self.any(value) : JSON::Any
        JSON::Any.new(value.to_s)
      end

      def [](key : String | Symbol) : JSON::Any
        @raw[key.to_s]? || raise KeyError.new("missing mailer param: #{key}")
      end

      def []?(key : String | Symbol) : JSON::Any?
        @raw[key.to_s]?
      end

      def fetch(key : String | Symbol, default : JSON::Any) : JSON::Any
        @raw[key.to_s]? || default
      end

      def has_key?(key : String | Symbol) : Bool
        @raw.has_key?(key.to_s)
      end

      def empty? : Bool
        @raw.empty?
      end

      def size : Int32
        @raw.size
      end

      def each(& : {String, JSON::Any} ->) : Nil
        @raw.each { |k, v| yield({k, v}) }
      end

      def to_h : Hash(String, JSON::Any)
        @raw.dup
      end

      def to_json(json : JSON::Builder) : Nil
        @raw.to_json(json)
      end

      # Convenience scalar readers. They raise `TypeCastError` for the wrong
      # JSON shape rather than silently stringifying objects.
      def as_s(key : String | Symbol) : String
        self[key].as_s
      end

      def as_s?(key : String | Symbol) : String?
        self[key]?.try(&.as_s?)
      end

      def as_i(key : String | Symbol) : Int64
        self[key].as_i64
      end

      def as_i?(key : String | Symbol) : Int64?
        self[key]?.try(&.as_i64?)
      end

      def as_bool(key : String | Symbol) : Bool
        self[key].as_bool
      end

      def as_bool?(key : String | Symbol) : Bool?
        self[key]?.try(&.as_bool?)
      end
    end

    # Per-fiber execution context for a mailer action.
    #
    # Crystal's mailer actions are class methods, so callbacks/attachments
    # cannot hang off an instance. A fiber-local stack gives each action an
    # isolated draft (headers/attachments/params) and keeps concurrent/mailer
    # jobs from sharing state.
    class Context
      getter params : Params
      getter headers : Hash(String, String)
      getter attachments : Attachments
      property action : String?
      property mailer : String?
      property mail : Mail?
      property? staged : Bool

      def initialize(@params : Params = Params.empty, @action : String? = nil,
                     @mailer : String? = nil, @staged : Bool = false)
        @headers = {} of String => String
        @attachments = Attachments.new
      end

      @@stacks = {} of UInt64 => Array(Context)
      @@stack_mutex = Mutex.new

      private def self.key : UInt64
        Fiber.current.object_id
      end

      def self.current : Context?
        stack = @@stack_mutex.synchronize { @@stacks[key]? }
        stack.try(&.last?)
      end

      def self.push(context : Context) : Nil
        @@stack_mutex.synchronize do
          (@@stacks[key] ||= [] of Context) << context
        end
      end

      def self.pop(context : Context) : Nil
        @@stack_mutex.synchronize do
          stack = @@stacks[key]?
          return unless stack
          if stack.last?.try(&.same?(context))
            stack.pop
          else
            stack.delete(context)
          end
          @@stacks.delete(key) if stack.empty?
        end
      end

      # Returns the current context, creating a staged one when an accessor
      # (`attachments`/`headers`) is used before `mail` is called. The staged
      # context is adopted and closed by the next `mail` call.
      def self.stage(action : String? = nil) : Context
        existing = current
        return existing if existing
        context = Context.new(action: action, staged: true)
        push(context)
        context
      end

      # Runs a parameterized action with `params` and `action` visible to the
      # mail method.
      def self.with_params(params : Params, action : String, & : -> T) : T forall T
        context = Context.new(params: params, action: action, staged: false)
        push(context)
        begin
          yield
        ensure
          pop(context)
        end
      end

      # Runs `block` with `context` current. Used by tests and by callbacks
      # that need to wrap another mailer.
      def self.with(context : Context, & : -> T) : T forall T
        push(context)
        begin
          yield
        ensure
          pop(context)
        end
      end

      def with_current(& : -> T) : T forall T
        Context.with(self) { yield }
      end
    end
  end
end
