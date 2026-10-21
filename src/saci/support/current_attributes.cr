require "./time_zone"

module Saci
  # Request/job-scoped globals, Rails `CurrentAttributes` style.
  #
  # ```
  # Saci::Current.user = user
  # Saci::Current.request_id # => "..."
  # Saci::Current.reset
  #
  # Saci::Current.set(user: user) do
  #   # request/job work
  # end
  # ```
  #
  # Values are fiber-local, so concurrent requests cannot see each other's
  # state. Declare typed attributes on subclasses:
  #
  # ```
  # class Current < Saci::CurrentAttributes
  #   attribute user : User?
  #   attribute account_id : Int64?
  # end
  # ```
  #
  # Crystal has no runtime `Object` hash, so every attribute has a static type
  # (declare nilable attributes with `?`).
  class CurrentAttributes
    class MissingAttribute < Exception
    end

    def self.reset : Nil
      CurrentAttributes.reset_for(self.name)
    end

    def self.reset_all! : Nil
      CurrentAttributes.reset_everything!
    end

    # Declares a typed fiber-local attribute plus `<name>?`, `<name>_set?`,
    # `<name>=`, and `reset_<name>` helpers.
    macro attribute(decl)
      {% name = decl.var %}
      {% type = decl.type %}
      @@{{name}}_values = {} of UInt64 => {{type}}
      ::Saci::CurrentAttributes.register({{@type.name.stringify}}) do
        @@{{name}}_values.delete(Fiber.current.object_id)
      end

      def self.{{name}} : {{type}}
        key = Fiber.current.object_id
        if @@{{name}}_values.has_key?(key)
          @@{{name}}_values[key]
        else
          raise Saci::CurrentAttributes::MissingAttribute.new("Current.{{name.id}} is not set")
        end
      end

      def self.{{name}}? : {{type}}?
        @@{{name}}_values[Fiber.current.object_id]?
      end

      def self.{{name}}_set? : Bool
        @@{{name}}_values.has_key?(Fiber.current.object_id)
      end

      def self.{{name}}=(value : {{type}}) : {{type}}
        @@{{name}}_values[Fiber.current.object_id] = value
      end

      def self.reset_{{name}} : Nil
        @@{{name}}_values.delete(Fiber.current.object_id)
      end
    end

    # Rails `Current.set(user: ...) { ... }`; restores previous values (or
    # removes them if they were unset) after the block, including on raise.
    # Without a block the assignments persist until `reset`.
    macro set(**attrs, &block)
      {% if block %}
        {% for key, value in attrs %}
          __saci_prev_present_{{key.id}} = {{@type}}.{{key.id}}_set?
          __saci_prev_value_{{key.id}} = {{@type}}.{{key.id}}?
        {% end %}
        {% for key, value in attrs %}
          {{@type}}.{{key.id}} = ({{value}})
        {% end %}
        begin
          {{block.body}}
        ensure
          {% for key, value in attrs %}
            if __saci_prev_present_{{key.id}} && !__saci_prev_value_{{key.id}}.nil?
              {{@type}}.{{key.id}} = __saci_prev_value_{{key.id}}.not_nil!
            else
              {{@type}}.reset_{{key.id}}
            end
          {% end %}
        end
      {% else %}
        {% for key, value in attrs %}
          {{@type}}.{{key.id}} = ({{value}})
        {% end %}
      {% end %}
    end

    @@resetters = {} of String => Array(Proc(Nil))
    @@mutex = Mutex.new

    def self.register(klass : String, &block : -> Nil) : Nil
      proc = -> { block.call }
      @@mutex.synchronize do
        (@@resetters[klass] ||= [] of Proc(Nil)) << proc
      end
    end

    def self.reset_for(klass : String) : Nil
      procs = @@mutex.synchronize { (@@resetters[klass]? || [] of Proc(Nil)).dup }
      procs.each(&.call)
    end

    def self.reset_everything! : Nil
      procs = @@mutex.synchronize { @@resetters.values.flatten.dup }
      procs.each(&.call)
    end
  end

  # Values that commonly live in `Current`. `Record::Base` is included for
  # `Current.user`; add project-specific typed attributes in your own subclass
  # if you need other object types.
  alias CurrentValue = String | Int64 | Float64 | Bool | Time | Record::Base | Nil

  class Current < CurrentAttributes
    attribute user : CurrentValue
    attribute request_id : String?
    attribute locale : String?
    attribute time_zone : String?
    attribute request : HTTP::Server::Context?
    attribute job : String?
  end
end
