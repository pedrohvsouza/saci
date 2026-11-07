module Saci
  module Record
    # Class-level finder delegates + the `define_finders` macro (G233,
    # G27, G291–G293). Kept in a separate file so `record/query.cr` stays
    # focused on relation chaining; `record.cr` (coordinator-owned) must
    # `require "./record/finders"` after `base`.
    class Base
      def self.none : Query(self)
        all.none
      end

      def self.rewhere(**conds : Object) : Query(self)
        all.rewhere(**conds)
      end

      def self.unscope(*parts : Symbol) : Query(self)
        all.unscope(*parts)
      end

      def self.invert_where : Query(self)
        all.invert_where
      end

      def self.left_joins(*names : Symbol) : Query(self)
        all.left_joins(*names)
      end

      def self.left_outer_joins(*names : Symbol) : Query(self)
        all.left_outer_joins(*names)
      end

      def self.preload(*names : Symbol) : Query(self)
        all.preload(*names)
      end

      def self.preload(**nested) : Query(self)
        all.preload(**nested)
      end

      def self.eager_load(*names : Symbol) : Query(self)
        all.eager_load(*names)
      end

      def self.without(*names : Symbol) : Query(self)
        all.without(*names)
      end

      def self.references(*names : Symbol) : Query(self)
        all.references(*names)
      end

      def self.annotate(*comments : String | Symbol) : Query(self)
        all.annotate(*comments)
      end

      def self.readonly(value : Bool = true) : Query(self)
        all.readonly(value)
      end

      def self.lock(clause : String = "FOR UPDATE") : Query(self)
        all.lock(clause)
      end

      def self.from(source : String) : Query(self)
        all.from(source)
      end

      def self.regroup(*cols : String | Symbol) : Query(self)
        all.regroup(*cols)
      end

      def self.reselect(*cols : String | Symbol) : Query(self)
        all.reselect(*cols)
      end

      def self.having(sql : String, *args : Object) : Query(self)
        all.having(sql, *args)
      end

      def self.having(sql : String) : Query(self)
        all.having(sql)
      end

      def self.having(**conds : Object) : Query(self)
        all.having(**conds)
      end

      def self.missing(col : String | Symbol) : Query(self)
        all.missing(col)
      end

      def self.associated(name : Symbol) : Query(self)
        all.associated(name)
      end

      def self.in_order_of(col : String | Symbol, values : Array) : Query(self)
        all.in_order_of(col, values)
      end

      def self.excluding(*records : self) : Query(self)
        all.excluding(*records)
      end

      def self.excluding(records : Array(self)) : Query(self)
        all.excluding(records)
      end

      def self.find_or_create_by(**attrs : Object) : self
        all.find_or_create_by(**attrs)
      end

      def self.find_or_create_by(attrs : NamedTuple) : self
        all.find_or_create_by(attrs)
      end

      def self.find_or_initialize_by(**attrs : Object) : self
        all.find_or_initialize_by(**attrs)
      end

      def self.find_or_initialize_by(attrs : NamedTuple) : self
        all.find_or_initialize_by(attrs)
      end

      def self.create_or_find_by(**attrs : Object) : self
        all.create_or_find_by(**attrs)
      end

      def self.create_or_find_by(attrs : NamedTuple) : self
        all.create_or_find_by(attrs)
      end

      def self.find_sole_by(**conds : Object) : self
        all.find_sole_by(**conds)
      end

      def self.find_sole_by(conds : NamedTuple) : self
        all.find_sole_by(conds)
      end

      def self.sole : self
        all.sole
      end

      def self.any? : Bool
        all.any?
      end

      def self.many? : Bool
        all.many?
      end

      def self.none? : Bool
        all.none?
      end

      def self.one? : Bool
        all.one?
      end

      def self.ids : Array(Value)
        all.ids
      end

      def self.pick(col : String | Symbol) : Value?
        all.pick(col)
      end

      def self.pick(*cols : String | Symbol) : Array(Value)?
        all.pick(*cols)
      end

      def self.find_nth(index : Int32) : self?
        all.find_nth(index)
      end

      def self.find_nth(index : Int) : self?
        all.find_nth(index)
      end

      def self.take : self?
        all.take
      end

      def self.take(n : Int32) : Array(self)
        all.take(n)
      end

      def self.take(n : Int) : Array(self)
        all.take(n)
      end

      def self.last : self?
        all.last
      end

      def self.last(n : Int32) : Array(self)
        all.last(n)
      end

      def self.last(n : Int) : Array(self)
        all.last(n)
      end

      def self.second : self?
        all.second
      end

      def self.third : self?
        all.third
      end

      def self.fourth : self?
        all.fourth
      end

      def self.fifth : self?
        all.fifth
      end

      def self.forty_two : self?
        all.forty_two
      end

      def self.second_to_last : self?
        all.second_to_last
      end

      def self.third_to_last : self?
        all.third_to_last
      end

      def self.find_each(batch_size : Int32 = 1000, start : Value? = nil, & : self ->) : Nil
        all.find_each(batch_size, start) { |r| yield r }
      end

      def self.find_in_batches(batch_size : Int32 = 1000, start : Value? = nil, finish : Value? = nil, & : Array(self) ->) : Nil
        all.find_in_batches(batch_size, start, finish) { |batch| yield batch }
      end

      def self.in_batches(batch_size : Int32 = 1000, start : Value? = nil, finish : Value? = nil) : BatchEnumerator(self)
        all.in_batches(batch_size, start, finish)
      end

      def self.explain(analyze : Bool = false) : String
        all.explain(analyze)
      end

      # Compile-time alternative to Rails' `method_missing` dynamic finders:
      #
      # ```
      # class User < ApplicationRecord
      #   define_finders :email, :name
      # end
      #
      # User.find_by_email("a@b.c")          # => User?
      # User.find_by_email!("a@b.c")         # => User (raises RecordNotFound)
      # User.find_or_initialize_by_email("x") # => User (new when missing)
      # ```
      #
      # The bang finder raises `RecordNotFound`, matching `find_by!`.
      macro define_finders(*names)
        {% for name in names %}
          def self.find_by_{{name.id}}(value : Object) : self?
            where({{name.id}}: value).first
          end

          def self.find_by_{{name.id}}!(value : Object) : self
            where({{name.id}}: value).first || raise Saci::Record::RecordNotFound.new("Couldn't find #{self.name} with {{name.id}}")
          end

          def self.find_or_initialize_by_{{name.id}}(value : Object) : self
            where({{name.id}}: value).first || new({{name.id}}: value)
          end
        {% end %}
      end
    end
  end
end
