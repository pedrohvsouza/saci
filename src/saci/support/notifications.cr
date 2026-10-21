require "json"

module Saci
  # ActiveSupport::Notifications-style instrumentation.
  #
  # ```
  # sub = Saci::Notifications.subscribe("sql.saci") do |event|
  #   puts "#{event.name} #{event.duration.round(2)}ms #{event["sql"]}"
  # end
  #
  # Saci::Notifications.instrument("render.saci", {"view" => "posts/index"}) do
  #   render_template
  # end
  # Saci::Notifications.unsubscribe(sub)
  # ```
  #
  # Durations are monotonic milliseconds. Subscribers run synchronously after
  # the instrumented block (including when it raises; the exception is added
  # to the payload and re-raised). Payload values are a fixed union because
  # Crystal has no heterogeneous `Object` hash.
  module Notifications
    alias Value = String | Symbol | Int32 | Int64 | Float32 | Float64 | Bool | Time | Time::Span | Nil
    alias Payload = Hash(String, Value)
    alias Callback = Proc(Event, Nil)

    struct Event
      getter name : String
      getter payload : Payload
      getter duration : Float64
      getter time : Time

      def initialize(@name : String, @payload : Payload, @duration : Float64, @time : Time = Time.utc)
      end

      def [](key : String | Symbol) : Value?
        @payload[key.to_s]?
      end

      def []?(key : String | Symbol) : Value?
        @payload[key.to_s]?
      end

      def duration_ms : Float64
        @duration
      end

      def duration_seconds : Float64
        @duration / 1000.0
      end
    end

    class Subscription
      getter id : UInt64
      getter pattern : String | Regex

      def initialize(@id : UInt64, @pattern : String | Regex)
      end

      def to_s(io : IO) : Nil
        io << "#<Saci::Notifications::Subscription " << @pattern << '>'
      end
    end

    private struct Entry
      getter subscription : Subscription
      getter callback : Callback

      def initialize(@subscription : Subscription, @callback : Callback)
      end
    end

    @@entries = [] of Entry
    @@mutex = Mutex.new
    @@next_id = 0_u64

    def self.subscribe(pattern : String | Regex, &block : Event ->) : Subscription
      subscription = @@mutex.synchronize do
        @@next_id += 1
        Subscription.new(@@next_id, pattern)
      end
      callback = ->(event : Event) { block.call(event); nil }
      @@mutex.synchronize { @@entries << Entry.new(subscription, callback) }
      subscription
    end

    def self.unsubscribe(subscription : Subscription) : Bool
      @@mutex.synchronize do
        before = @@entries.size
        @@entries.reject! { |entry| entry.subscription.id == subscription.id }
        @@entries.size != before
      end
    end

    def self.unsubscribe_all : Nil
      @@mutex.synchronize { @@entries.clear }
    end

    def self.subscribers(name : String) : Array(Subscription)
      snapshot.select { |entry| matches?(entry.subscription.pattern, name) }.map(&.subscription)
    end

    # Publishes an already-measured event (used by `Saci.event.notify`).
    def self.publish(name : String, payload : Payload = Payload.new, duration : Float64 = 0.0) : Nil
      publish_payload(name, payload, duration)
    end

    def self.publish(name : String, payload : Hash(String, V), duration : Float64 = 0.0) : Nil forall V
      publish_payload(name, to_payload(payload), duration)
    end

    private def self.publish_payload(name : String, payload : Payload, duration : Float64) : Nil
      event = Event.new(name, payload.dup, duration)
      snapshot.each do |entry|
        entry.callback.call(event) if matches?(entry.subscription.pattern, name)
      end
    end

    def self.notify(name : String, payload : Payload = Payload.new) : Nil
      publish_payload(name, payload, 0.0)
    end

    def self.notify(name : String, payload : Hash(String, V)) : Nil forall V
      publish_payload(name, to_payload(payload), 0.0)
    end

    def self.instrument(name : String, payload : Payload = Payload.new, & : -> T) : T forall T
      started = Time.instant
      begin
        result = yield
        publish_payload(name, payload, elapsed_ms(started))
        result
      rescue ex
        payload["exception"] = ex.class.name
        payload["exception_message"] = ex.message
        publish_payload(name, payload, elapsed_ms(started))
        raise ex
      end
    end

    def self.instrument(name : String, payload : Hash(String, V), & : -> T) : T forall V, T
      started = Time.instant
      converted = to_payload(payload)
      begin
        result = yield
        publish_payload(name, converted, elapsed_ms(started))
        result
      rescue ex
        converted["exception"] = ex.class.name
        converted["exception_message"] = ex.message
        publish_payload(name, converted, elapsed_ms(started))
        raise ex
      end
    end

    private def self.to_payload(payload : Hash(String, V)) : Payload forall V
      result = Payload.new
      payload.each { |key, value| result[key] = coerce_value(value) }
      result
    end

    private def self.coerce_value(value : Value) : Value
      value
    end

    private def self.coerce_value(value) : Value
      value.to_s
    end

    private def self.elapsed_ms(started : Time::Instant) : Float64
      (Time.instant - started).total_milliseconds
    end

    private def self.snapshot : Array(Entry)
      @@mutex.synchronize { @@entries.dup }
    end

    private def self.matches?(pattern : String, name : String) : Bool
      pattern == name
    end

    private def self.matches?(pattern : Regex, name : String) : Bool
      pattern.matches?(name)
    end
  end

  # Rails 8.1 `Rails.event` facade: ad-hoc structured events with context and
  # fiber-local tags. Shares the `Saci::Notifications` subscriber registry, so
  # one subscription can observe both instrumented spans and `.notify` calls.
  class EventReporter
    def notify(name : String, payload : Notifications::Payload = Notifications::Payload.new) : Nil
      merged = Notifications::Payload.new
      context.each { |key, value| merged[key] = value }
      payload.each { |key, value| merged[key] = value }
      Notifications.publish(name, merged)
    end

    def notify(name : String, payload : Hash(String, V)) : Nil forall V
      merged = Notifications::Payload.new
      context.each { |key, value| merged[key] = value }
      payload.each { |key, value| merged[key] = value.as(Notifications::Value) }
      Notifications.publish(name, merged)
    end

    def subscribe(pattern : String | Regex, &block : Notifications::Event ->) : Notifications::Subscription
      Notifications.subscribe(pattern) { |event| block.call(event) }
    end

    def unsubscribe(subscription : Notifications::Subscription) : Bool
      Notifications.unsubscribe(subscription)
    end

    def instrument(name : String, payload : Notifications::Payload = Notifications::Payload.new, & : -> T) : T forall T
      Notifications.instrument(name, payload) { yield }
    end

    def instrument(name : String, payload : Hash(String, V), & : -> T) : T forall V, T
      Notifications.instrument(name, payload) { yield }
    end

    def context : Hash(String, String)
      @@context_mutex.synchronize { (@@fiber_context[Fiber.current.object_id]? || {} of String => String).dup }
    end

    def context=(values : Hash(String, String)) : Nil
      @@context_mutex.synchronize { @@fiber_context[Fiber.current.object_id] = values.dup }
    end

    def with_context(values : Hash(String, String), & : -> T) : T forall T
      key = Fiber.current.object_id
      previous = @@context_mutex.synchronize { @@fiber_context[key]? }
      @@context_mutex.synchronize do
        merged = (previous || {} of String => String).dup
        values.each { |k, v| merged[k] = v }
        @@fiber_context[key] = merged
      end
      begin
        yield
      ensure
        @@context_mutex.synchronize do
          if previous
            @@fiber_context[key] = previous
          else
            @@fiber_context.delete(key)
          end
        end
      end
    end

    def tags : Array(String)
      Saci.current_tags
    end

    def with_tags(*tags : String, & : -> T) : T forall T
      Saci.tagged(*tags) { yield }
    end

    @@fiber_context = {} of UInt64 => Hash(String, String)
    @@context_mutex = Mutex.new
  end

  @@event_reporter : EventReporter? = nil
  @@event_mutex = Mutex.new

  def self.event : EventReporter
    @@event_mutex.synchronize { @@event_reporter ||= EventReporter.new }
  end
end
