module Saci
  module Testing
    # A small, compile-time FactoryBot-like factory system.
    #
    # ```
    # factory :user, User do
    #   name "Alice"
    #   email { "user#{Saci::Testing::Factory.sequence(:email)}@example.com" }
    #   admin false
    #
    #   trait :admin do
    #     admin true
    #   end
    #
    #   belongs_to :team, :team
    #   has_many :posts, :post, count: 2
    # end
    #
    # user = Saci::Testing::Factory.create(:user, :admin, name: "Bob").as(User)
    # # or the generated typed helpers:
    # user = Saci::Testing::Factory.create_user(:admin, name: "Bob")
    # ```
    #
    # Limitations (Crystal has no runtime eval/constantize):
    # * The model class must be passed explicitly unless its name is exactly
    #   the camelized factory name in the current scope
    #   (`factory :user` infers `User`).
    # * `build`/`create` return `Saci::Record::Base`; `.as(User)` or the
    #   generated `build_user`/`create_user` helpers restore the static type.
    # * Traits support plain attributes only (not associations).
    # * `build` builds a `belongs_to` association but cannot set its foreign
    #   key (the target has no id yet). `create` creates the target and sets
    #   `<assoc>_id`. `has_many` children are created only by `create`.
    # * `attributes_for` evaluates plain attributes/overrides and omits
    #   associations (like FactoryBot's attribute strategy).
    # * Lazy blocks receive a `Context` as their single argument; use
    #   `Factory.sequence("name")` for per-call counter values.
    module Factory
      alias Value = Saci::Record::Value

      # Passed to lazy attribute blocks. Keeps sequence keys scoped when
      # using `ctx.sequence("email")`.
      class Context
        getter factory_name : String

        def initialize(@factory_name : String)
        end

        def sequence(name : String | Symbol = "sequence") : Int32
          Factory.sequence("#{@factory_name}:#{name}")
        end
      end

      class Attribute
        getter name : String
        getter block : Context -> Value

        def initialize(@name : String, @block : Context -> Value)
        end
      end

      class BelongsTo
        getter assoc : String
        getter target_factory : String
        getter foreign_key : String

        def initialize(@assoc : String, @target_factory : String, @foreign_key : String)
        end
      end

      class HasMany
        getter assoc : String
        getter target_factory : String
        getter count : Int32
        getter foreign_key : String?

        def initialize(@assoc : String, @target_factory : String, @count : Int32, @foreign_key : String?)
        end
      end

      class Definition
        getter name : String
        getter model : Saci::Record::Base.class
        getter attrs = [] of Attribute
        getter traits = {} of String => Array(Attribute)
        getter belongs_tos = [] of BelongsTo
        getter has_manies = [] of HasMany

        def initialize(@name : String, @model : Saci::Record::Base.class)
        end
      end

      @@definitions = {} of String => Definition
      @@mutex = Mutex.new
      @@sequences = {} of String => Int32
      @@sequence_mutex = Mutex.new

      def self.define_runtime(name : String, model : Saci::Record::Base.class) : Nil
        @@mutex.synchronize { @@definitions[name] = Definition.new(name, model) }
      end

      # Called by the `factory` macro for a plain attribute.
      def self.attribute(factory : String, name : String, block : Context -> Value) : Nil
        definition(factory).attrs << Attribute.new(name, block)
      end

      # Called by the `factory` macro for an attribute inside a trait.
      def self.trait_attribute(factory : String, trait : String, name : String, block : Context -> Value) : Nil
        defn = definition(factory)
        (defn.traits[trait] ||= [] of Attribute) << Attribute.new(name, block)
      end

      def self.belongs_to(factory : String, assoc : String, target_factory : String, foreign_key : String? = nil) : Nil
        definition(factory).belongs_tos << BelongsTo.new(assoc, target_factory, foreign_key || "#{assoc}_id")
      end

      def self.has_many(factory : String, assoc : String, target_factory : String, count : Int = 1, foreign_key : String? = nil) : Nil
        definition(factory).has_manies << HasMany.new(assoc, target_factory, count.to_i32, foreign_key)
      end

      def self.definition(name : String | Symbol) : Definition
        @@mutex.synchronize do
          @@definitions[name.to_s]? ||
            raise ArgumentError.new("Unknown factory #{name.inspect} (known: #{@@definitions.keys.sort.inspect})")
        end
      end

      def self.defined?(name : String | Symbol) : Bool
        @@mutex.synchronize { @@definitions.has_key?(name.to_s) }
      end

      def self.names : Array(String)
        @@mutex.synchronize { @@definitions.keys.sort }
      end

      # Global sequences, keyed by name. Call inside a lazy attribute block:
      # `"user#{Factory.sequence(:email)}@example.com"`.
      def self.sequence(name : String | Symbol = "sequence") : Int32
        @@sequence_mutex.synchronize do
          value = (@@sequences[name.to_s]? || 0) + 1
          @@sequences[name.to_s] = value
          value
        end
      end

      def self.reset_sequences! : Nil
        @@sequence_mutex.synchronize { @@sequences.clear }
      end

      # Used by the `sequence :email, "user%d@example.com"` macro form.
      def self.sequence_value(name : String, format : String? = nil) : Value
        value = sequence(name)
        return value.to_i64 unless format
        return format.gsub("%s", value.to_s) if format.includes?("%s")
        return sprintf(format, value) if format.includes?("%d")
        "#{format}#{value}"
      end

      # Used by the `sequence :email do |n| ... end` macro form.
      def self.sequence_attribute(name : String, block : Int32 -> Value) : Value
        block.call(sequence(name))
      end

      # Turns common Crystal literals into the ORM's bind-value union.
      def self.coerce(value : Object) : Value
        case value
        when Nil, Bool, Int32, Int64, Float32, Float64, String, Time, Bytes
          value
        when Symbol
          value.to_s
        when Array(String)
          value
        when Array
          value.map(&.to_s)
        when Saci::Record::Value
          value
        else
          raise ArgumentError.new("Factory attribute value #{value.inspect} (#{value.class}) cannot be stored; use String/Int/Float/Bool/Time/Bytes/Array(String)/nil")
        end
      end

      def self.named_to_hash(attrs : NamedTuple) : Hash(String, Value)
        result = {} of String => Value
        attrs.each { |key, value| result[key.to_s] = coerce(value) }
        result
      end

      # NOTE: Crystal requires at least one argument for a positional splat
      # (`*traits`) and for a double splat (`**overrides`), so the pretty
      # call forms are generated as explicit arity overloads. Use the
      # `*_with_traits` variants for four or more traits.
      def self.build(factory_name : String | Symbol) : Saci::Record::Base
        build_internal(factory_name.to_s, :build, [] of String, {} of String => Value)
      end

      def self.build(factory_name : String | Symbol, **overrides : Object) : Saci::Record::Base
        build_internal(factory_name.to_s, :build, [] of String, named_to_hash(overrides))
      end

      def self.build(factory_name : String | Symbol, trait1 : String | Symbol) : Saci::Record::Base
        build_internal(factory_name.to_s, :build, [trait1.to_s], {} of String => Value)
      end

      def self.build(factory_name : String | Symbol, trait1 : String | Symbol, **overrides : Object) : Saci::Record::Base
        build_internal(factory_name.to_s, :build, [trait1.to_s], named_to_hash(overrides))
      end

      def self.build(factory_name : String | Symbol, trait1 : String | Symbol, trait2 : String | Symbol) : Saci::Record::Base
        build_internal(factory_name.to_s, :build, [trait1.to_s, trait2.to_s], {} of String => Value)
      end

      def self.build(factory_name : String | Symbol, trait1 : String | Symbol, trait2 : String | Symbol, **overrides : Object) : Saci::Record::Base
        build_internal(factory_name.to_s, :build, [trait1.to_s, trait2.to_s], named_to_hash(overrides))
      end

      def self.build(factory_name : String | Symbol, trait1 : String | Symbol, trait2 : String | Symbol, trait3 : String | Symbol) : Saci::Record::Base
        build_internal(factory_name.to_s, :build, [trait1.to_s, trait2.to_s, trait3.to_s], {} of String => Value)
      end

      def self.build(factory_name : String | Symbol, trait1 : String | Symbol, trait2 : String | Symbol, trait3 : String | Symbol, **overrides : Object) : Saci::Record::Base
        build_internal(factory_name.to_s, :build, [trait1.to_s, trait2.to_s, trait3.to_s], named_to_hash(overrides))
      end

      def self.build_with_traits(factory_name : String | Symbol, traits : Array(String | Symbol)) : Saci::Record::Base
        build_internal(factory_name.to_s, :build, traits.map(&.to_s), {} of String => Value)
      end

      def self.build_with_traits(factory_name : String | Symbol, traits : Array(String | Symbol), **overrides : Object) : Saci::Record::Base
        build_internal(factory_name.to_s, :build, traits.map(&.to_s), named_to_hash(overrides))
      end

      def self.create(factory_name : String | Symbol) : Saci::Record::Base
        create_internal(factory_name.to_s, [] of String, {} of String => Value)
      end

      def self.create(factory_name : String | Symbol, **overrides : Object) : Saci::Record::Base
        create_internal(factory_name.to_s, [] of String, named_to_hash(overrides))
      end

      def self.create(factory_name : String | Symbol, trait1 : String | Symbol) : Saci::Record::Base
        create_internal(factory_name.to_s, [trait1.to_s], {} of String => Value)
      end

      def self.create(factory_name : String | Symbol, trait1 : String | Symbol, **overrides : Object) : Saci::Record::Base
        create_internal(factory_name.to_s, [trait1.to_s], named_to_hash(overrides))
      end

      def self.create(factory_name : String | Symbol, trait1 : String | Symbol, trait2 : String | Symbol) : Saci::Record::Base
        create_internal(factory_name.to_s, [trait1.to_s, trait2.to_s], {} of String => Value)
      end

      def self.create(factory_name : String | Symbol, trait1 : String | Symbol, trait2 : String | Symbol, **overrides : Object) : Saci::Record::Base
        create_internal(factory_name.to_s, [trait1.to_s, trait2.to_s], named_to_hash(overrides))
      end

      def self.create(factory_name : String | Symbol, trait1 : String | Symbol, trait2 : String | Symbol, trait3 : String | Symbol) : Saci::Record::Base
        create_internal(factory_name.to_s, [trait1.to_s, trait2.to_s, trait3.to_s], {} of String => Value)
      end

      def self.create(factory_name : String | Symbol, trait1 : String | Symbol, trait2 : String | Symbol, trait3 : String | Symbol, **overrides : Object) : Saci::Record::Base
        create_internal(factory_name.to_s, [trait1.to_s, trait2.to_s, trait3.to_s], named_to_hash(overrides))
      end

      def self.create_with_traits(factory_name : String | Symbol, traits : Array(String | Symbol)) : Saci::Record::Base
        create_internal(factory_name.to_s, traits.map(&.to_s), {} of String => Value)
      end

      def self.create_with_traits(factory_name : String | Symbol, traits : Array(String | Symbol), **overrides : Object) : Saci::Record::Base
        create_internal(factory_name.to_s, traits.map(&.to_s), named_to_hash(overrides))
      end

      def self.build_list(factory_name : String | Symbol, count : Int) : Array(Saci::Record::Base)
        build_list_internal(factory_name.to_s, count, [] of String, {} of String => Value)
      end

      def self.build_list(factory_name : String | Symbol, count : Int, **overrides : Object) : Array(Saci::Record::Base)
        build_list_internal(factory_name.to_s, count, [] of String, named_to_hash(overrides))
      end

      def self.build_list(factory_name : String | Symbol, count : Int, trait1 : String | Symbol) : Array(Saci::Record::Base)
        build_list_internal(factory_name.to_s, count, [trait1.to_s], {} of String => Value)
      end

      def self.build_list(factory_name : String | Symbol, count : Int, trait1 : String | Symbol, **overrides : Object) : Array(Saci::Record::Base)
        build_list_internal(factory_name.to_s, count, [trait1.to_s], named_to_hash(overrides))
      end

      def self.create_list(factory_name : String | Symbol, count : Int) : Array(Saci::Record::Base)
        create_list_internal(factory_name.to_s, count, [] of String, {} of String => Value)
      end

      def self.create_list(factory_name : String | Symbol, count : Int, **overrides : Object) : Array(Saci::Record::Base)
        create_list_internal(factory_name.to_s, count, [] of String, named_to_hash(overrides))
      end

      def self.create_list(factory_name : String | Symbol, count : Int, trait1 : String | Symbol) : Array(Saci::Record::Base)
        create_list_internal(factory_name.to_s, count, [trait1.to_s], {} of String => Value)
      end

      def self.create_list(factory_name : String | Symbol, count : Int, trait1 : String | Symbol, **overrides : Object) : Array(Saci::Record::Base)
        create_list_internal(factory_name.to_s, count, [trait1.to_s], named_to_hash(overrides))
      end

      def self.attributes_for(factory_name : String | Symbol) : Hash(String, Value)
        attributes_for_internal(factory_name.to_s, [] of String, {} of String => Value)
      end

      def self.attributes_for(factory_name : String | Symbol, **overrides : Object) : Hash(String, Value)
        attributes_for_internal(factory_name.to_s, [] of String, named_to_hash(overrides))
      end

      def self.attributes_for(factory_name : String | Symbol, trait1 : String | Symbol) : Hash(String, Value)
        attributes_for_internal(factory_name.to_s, [trait1.to_s], {} of String => Value)
      end

      def self.attributes_for(factory_name : String | Symbol, trait1 : String | Symbol, **overrides : Object) : Hash(String, Value)
        attributes_for_internal(factory_name.to_s, [trait1.to_s], named_to_hash(overrides))
      end

      private def self.build_list_internal(name : String, count : Int, traits : Array(String), overrides : Hash(String, Value)) : Array(Saci::Record::Base)
        Array(Saci::Record::Base).new(count) do
          build_internal(name, :build, traits, overrides.dup)
        end
      end

      private def self.create_list_internal(name : String, count : Int, traits : Array(String), overrides : Hash(String, Value)) : Array(Saci::Record::Base)
        Array(Saci::Record::Base).new(count) do
          create_internal(name, traits, overrides.dup)
        end
      end

      private def self.attributes_for_internal(name : String, traits : Array(String), overrides : Hash(String, Value)) : Hash(String, Value)
        defn = definition(name)
        attrs = evaluate_attributes(defn, traits)
        overrides.each { |key, value| attrs[key] = value }
        attrs
      end

      def self.reset! : Nil
        @@mutex.synchronize { @@definitions.clear }
        reset_sequences!
      end

      private def self.create_internal(name : String, traits : Array(String), overrides : Hash(String, Value)) : Saci::Record::Base
        build_internal(name, :create, traits, overrides)
      end

      private def self.build_internal(name : String, strategy : Symbol, traits : Array(String), overrides : Hash(String, Value)) : Saci::Record::Base
        defn = definition(name)
        attrs = evaluate_attributes(defn, traits)
        overrides.each { |key, value| attrs[key] = value }

        # belongs_to: create the target first (create strategy) or build it
        # (build strategy), then set the foreign key when the target has one.
        defn.belongs_tos.each do |assoc|
          next if attrs.has_key?(assoc.foreign_key)
          target = if strategy == :create
                     create_internal(assoc.target_factory, [] of String, {} of String => Value)
                   else
                     build_internal(assoc.target_factory, :build, [] of String, {} of String => Value)
                   end
          target_id = target.__saci_get_attr(target.class.__saci_primary_key)
          attrs[assoc.foreign_key] = target_id if target_id
        end

        record = defn.model.new
        attrs.each do |key, value|
          unless record.__saci_set_attr(key, value)
            raise Saci::Record::UnknownAttributeError.new("unknown factory attribute '#{key}' for #{defn.model}")
          end
        end

        if strategy == :create
          record.save!
          assign_has_many(defn, record)
        end
        record
      end

      private def self.assign_has_many(defn : Definition, record : Saci::Record::Base) : Nil
        defn.has_manies.each do |assoc|
          owner_id = record.__saci_get_attr(record.class.__saci_primary_key)
          next if owner_id.nil?
          fk = assoc.foreign_key || Saci::Record::Migration.fk_default_column(record.class.table_name)
          assoc.count.times do
            create_internal(assoc.target_factory, [] of String, {fk => owner_id})
          end
        end
      end

      private def self.evaluate_attributes(defn : Definition, traits : Array(String)) : Hash(String, Value)
        ctx = Context.new(defn.name)
        attrs = {} of String => Value
        defn.attrs.each { |attr| attrs[attr.name] = attr.block.call(ctx) }
        traits.each do |trait|
          entries = defn.traits[trait]? ||
                    raise ArgumentError.new("Unknown trait #{trait.inspect} for factory #{defn.name.inspect}")
          entries.each { |attr| attrs[attr.name] = attr.block.call(ctx) }
        end
        attrs
      end

      # Compile-time DSL. Included into `Object` by `saci/testing.cr`, so
      # `factory` can be used at file/module scope (not inside a `describe`
      # block — Crystal cannot declare methods dynamically).
      module DSL
        macro factory(name, model = nil, &block)
          {% if model.is_a?(NilLiteral) %}
            {% inferred = name.id.stringify.camelcase %}
            {% if @type.has_constant?(inferred) %}
              {% model = inferred.id %}
            {% else %}
              {% raise "factory #{name}: cannot infer model constant #{inferred}; pass it explicitly, e.g. `factory :user, User do ... end`" %}
            {% end %}
          {% end %}
          {% fname = name.id.stringify %}
          {% body = block.body %}
          {% factory_exps = body.is_a?(Expressions) ? body.expressions : [body] %}
          Saci::Testing::Factory.define_runtime({{fname}}, {{model}})
          {% for exp in factory_exps %}
            {% if exp.is_a?(Call) %}
              {% call_name = exp.name.stringify %}
              {% if call_name == "trait" %}
                {% trait_name = exp.args[0].id.stringify %}
                {% trait_body = exp.block.body %}
                {% trait_exps = trait_body.is_a?(Expressions) ? trait_body.expressions : [trait_body] %}
                {% for inner in trait_exps %}
                  {% if inner.is_a?(Call) %}
                    {% inner_name = inner.name.stringify %}
                    {% if inner_name == "belongs_to" || inner_name == "association" || inner_name == "has_many" %}
                      {% raise "factory #{name}: trait #{trait_name} only supports plain attributes (associations are not supported in traits)" %}
                    {% end %}
                    {% if inner.block %}
                      {% if inner.block.args.size == 1 %}
                        Saci::Testing::Factory.trait_attribute({{fname}}, {{trait_name}}, {{inner_name}}, ->(__ctx : Saci::Testing::Factory::Context) : Saci::Record::Value {
                          {{inner.block.args[0]}} = __ctx
                          Saci::Testing::Factory.coerce({{inner.block.body}})
                        })
                      {% elsif inner.block.args.empty? %}
                        Saci::Testing::Factory.trait_attribute({{fname}}, {{trait_name}}, {{inner_name}}, ->(__ctx : Saci::Testing::Factory::Context) : Saci::Record::Value {
                          Saci::Testing::Factory.coerce({{inner.block.body}})
                        })
                      {% else %}
                        {% raise "factory #{name}: attribute blocks take at most one argument (a Factory::Context)" %}
                      {% end %}
                    {% elsif inner.args.size > 0 %}
                      {% value = inner.args[0] %}
                      {% if value.is_a?(ProcLiteral) %}
                        Saci::Testing::Factory.trait_attribute({{fname}}, {{trait_name}}, {{inner_name}}, ->(__ctx : Saci::Testing::Factory::Context) : Saci::Record::Value {
                          {% if value.args.size == 1 %}
                            Saci::Testing::Factory.coerce(({{value}}).call(__ctx))
                          {% else %}
                            Saci::Testing::Factory.coerce(({{value}}).call)
                          {% end %}
                        })
                      {% else %}
                        Saci::Testing::Factory.trait_attribute({{fname}}, {{trait_name}}, {{inner_name}}, ->(__ctx : Saci::Testing::Factory::Context) : Saci::Record::Value {
                          Saci::Testing::Factory.coerce({{value}})
                        })
                      {% end %}
                    {% else %}
                      {% raise "factory #{name}: trait attribute #{inner_name} needs a value or block" %}
                    {% end %}
                  {% end %}
                {% end %}
              {% elsif call_name == "belongs_to" || call_name == "association" %}
                {% assoc = exp.args[0].id.stringify %}
                {% target = exp.args.size > 1 ? exp.args[1].id.stringify : assoc %}
                {% fk = nil %}
                {% unless exp.named_args.is_a?(Nop) %}
                  {% for named in exp.named_args %}
                    {% if named.name.stringify == "foreign_key" %}
                      {% fk = named.value %}
                    {% elsif named.name.stringify == "factory" %}
                      {% target = named.value.id.stringify %}
                    {% end %}
                  {% end %}
                {% end %}
                Saci::Testing::Factory.belongs_to({{fname}}, {{assoc}}, {{target}}, {{fk}})
              {% elsif call_name == "has_many" %}
                {% assoc = exp.args[0].id.stringify %}
                {% target = exp.args.size > 1 ? exp.args[1].id.stringify : assoc %}
                {% count = 1 %}
                {% fk = nil %}
                {% unless exp.named_args.is_a?(Nop) %}
                  {% for named in exp.named_args %}
                    {% if named.name.stringify == "count" %}
                      {% count = named.value %}
                    {% elsif named.name.stringify == "foreign_key" %}
                      {% fk = named.value %}
                    {% elsif named.name.stringify == "factory" %}
                      {% target = named.value.id.stringify %}
                    {% end %}
                  {% end %}
                {% end %}
                Saci::Testing::Factory.has_many({{fname}}, {{assoc}}, {{target}}, {{count}}, {{fk}})
              {% elsif call_name == "sequence" %}
                {% seq_name = exp.args[0].id.stringify %}
                {% if exp.block %}
                  {% if exp.block.args.size == 1 %}
                    Saci::Testing::Factory.attribute({{fname}}, {{seq_name}}, ->(__ctx : Saci::Testing::Factory::Context) : Saci::Record::Value {
                      Saci::Testing::Factory.sequence_attribute({{seq_name}}, ->({{exp.block.args[0]}} : Int32) : Saci::Record::Value {
                        Saci::Testing::Factory.coerce({{exp.block.body}})
                      })
                    })
                  {% elsif exp.block.args.empty? %}
                    Saci::Testing::Factory.attribute({{fname}}, {{seq_name}}, ->(__ctx : Saci::Testing::Factory::Context) : Saci::Record::Value {
                      Saci::Testing::Factory.sequence_attribute({{seq_name}}, ->(__n : Int32) : Saci::Record::Value {
                        Saci::Testing::Factory.coerce({{exp.block.body}})
                      })
                    })
                  {% else %}
                    {% raise "factory #{name}: sequence block takes zero or one argument" %}
                  {% end %}
                {% elsif exp.args.size > 1 %}
                  {% format = exp.args[1] %}
                  Saci::Testing::Factory.attribute({{fname}}, {{seq_name}}, ->(__ctx : Saci::Testing::Factory::Context) : Saci::Record::Value {
                    Saci::Testing::Factory.sequence_value({{seq_name}}, {{format}})
                  })
                {% else %}
                  Saci::Testing::Factory.attribute({{fname}}, {{seq_name}}, ->(__ctx : Saci::Testing::Factory::Context) : Saci::Record::Value {
                    Saci::Testing::Factory.sequence_value({{seq_name}})
                  })
                {% end %}
              {% else %}
                {% if exp.block %}
                  {% if exp.block.args.size == 1 %}
                    Saci::Testing::Factory.attribute({{fname}}, {{call_name}}, ->(__ctx : Saci::Testing::Factory::Context) : Saci::Record::Value {
                      {{exp.block.args[0]}} = __ctx
                      Saci::Testing::Factory.coerce({{exp.block.body}})
                    })
                  {% elsif exp.block.args.empty? %}
                    Saci::Testing::Factory.attribute({{fname}}, {{call_name}}, ->(__ctx : Saci::Testing::Factory::Context) : Saci::Record::Value {
                      Saci::Testing::Factory.coerce({{exp.block.body}})
                    })
                  {% else %}
                    {% raise "factory #{name}: attribute blocks take at most one argument (a Factory::Context)" %}
                  {% end %}
                {% elsif exp.args.size > 0 %}
                  {% value = exp.args[0] %}
                  {% if value.is_a?(ProcLiteral) %}
                    Saci::Testing::Factory.attribute({{fname}}, {{call_name}}, ->(__ctx : Saci::Testing::Factory::Context) : Saci::Record::Value {
                      {% if value.args.size == 1 %}
                        Saci::Testing::Factory.coerce(({{value}}).call(__ctx))
                      {% else %}
                        Saci::Testing::Factory.coerce(({{value}}).call)
                      {% end %}
                    })
                  {% else %}
                    Saci::Testing::Factory.attribute({{fname}}, {{call_name}}, ->(__ctx : Saci::Testing::Factory::Context) : Saci::Record::Value {
                      Saci::Testing::Factory.coerce({{value}})
                    })
                  {% end %}
                {% else %}
                  {% raise "factory #{name}: attribute #{call_name} needs a value or block" %}
                {% end %}
              {% end %}
            {% end %}
          {% end %}

          module Saci::Testing::Factory
            def self.build_{{name.id}} : {{model}}
              build({{fname}}).as({{model}})
            end

            def self.build_{{name.id}}(**overrides : Object) : {{model}}
              build({{fname}}, **overrides).as({{model}})
            end

            def self.build_{{name.id}}(trait1 : String | Symbol) : {{model}}
              build({{fname}}, trait1).as({{model}})
            end

            def self.build_{{name.id}}(trait1 : String | Symbol, **overrides : Object) : {{model}}
              build({{fname}}, trait1, **overrides).as({{model}})
            end

            def self.create_{{name.id}} : {{model}}
              create({{fname}}).as({{model}})
            end

            def self.create_{{name.id}}(**overrides : Object) : {{model}}
              create({{fname}}, **overrides).as({{model}})
            end

            def self.create_{{name.id}}(trait1 : String | Symbol) : {{model}}
              create({{fname}}, trait1).as({{model}})
            end

            def self.create_{{name.id}}(trait1 : String | Symbol, **overrides : Object) : {{model}}
              create({{fname}}, trait1, **overrides).as({{model}})
            end

            def self.attributes_for_{{name.id}} : Hash(String, Saci::Record::Value)
              attributes_for({{fname}})
            end

            def self.attributes_for_{{name.id}}(**overrides : Object) : Hash(String, Saci::Record::Value)
              attributes_for({{fname}}, **overrides)
            end

            def self.attributes_for_{{name.id}}(trait1 : String | Symbol) : Hash(String, Saci::Record::Value)
              attributes_for({{fname}}, trait1)
            end

            def self.attributes_for_{{name.id}}(trait1 : String | Symbol, **overrides : Object) : Hash(String, Saci::Record::Value)
              attributes_for({{fname}}, trait1, **overrides)
            end
          end
        end
      end
    end
  end
end
