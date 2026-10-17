module Saci
  module Record
    # ActiveRecord-equivalent base class.
    #
    # ```
    # class ApplicationRecord < Saci::Record::Base
    # end
    #
    # class Post < ApplicationRecord
    #   column id : Int64, primary: true
    #   column title : String
    #   column views : Int64
    #   column published : Bool
    #   timestamps
    #
    #   validates :title, presence: true, max_length: 200
    #
    #   belongs_to :user
    # end
    #
    # post = Post.create(title: "Hi")
    # post.persisted? # => true
    # Post.where(published: true).order(views: :desc).limit(5).to_a
    # ```
    #
    # Supported column types: `Int32`, `Int64`, `Float64`, `String`,
    # `Bool`, `Time`, `Bytes` (all automatically nilable), plus logical
    # types `Decimal` (Float64-backed), `Date` (Time-backed), `JSON`
    # (String-backed, with a `<name>_json` helper) and `Array(String)`
    # (string arrays: native `TEXT[]` on PostgreSQL, JSON text elsewhere).
    class Base
      # -- connection ------------------------------------------------------
      # Delegates to the module-global connection (see `Saci::Record` —
      # Crystal class variables are per-class, so connection state cannot
      # live here and be visible to subclasses).

      def self.connection=(db : DB::Database) : Nil
        Record.connection = db
      end

      def self.connection : DB::Database | DB::Connection
        Record.connection
      end

      def self.transaction(&block : DB::Connection -> T) : T? forall T
        Record.transaction_on(self.connection) { |conn| block.call(conn) }
      end

      # Pins this model to a named database (`Saci::Record.establish_connection`).
      #
      # ```
      # class Event < ApplicationRecord
      #   connects_to database: "analytics"
      # end
      # ```
      macro connects_to(database = nil)
        {% if database %}
          def self.connection : DB::Database | DB::Connection
            Saci::Record.connection_for({{database}}.to_s)
          end
        {% end %}
      end

      # -- schema DSL -------------------------------------------------------

      macro inherited
        # Self-register for schema drift checks (`Saci::Record.check_schema!`,
        # mirroring `Saci::Job.register`). A statement, not a method — the
        # `previous_def` chains below are untouched. Column-less
        # intermediates (e.g. `ApplicationRecord`) register too but are
        # skipped by the check (no columns = no table by design).
        Saci::Record.register_model(self)

        def self.__saci_column_names : Array(Tuple(String, String))
          super
        end

        def __saci_set_attr(key : String, value : Saci::Record::Value) : Bool
          super
        end

        def __saci_get_attr(key : String) : Saci::Record::Value
          super
        end

        def __saci_run_validations(errors : Saci::Record::Errors) : Nil
          super
        end

        def run_validations(errors : Saci::Record::Errors) : Nil
          super
        end

        def __saci_before_validation : Nil
          super
        end

        def __saci_before_validation_on_create : Nil
          super
        end

        def __saci_before_validation_on_update : Nil
          super
        end

        def __saci_before_save : Nil
          super
        end

        def __saci_after_save : Nil
          super
        end

        def __saci_after_create : Nil
          super
        end

        def __saci_after_create_commit : Nil
          super
        end

        def __saci_after_update_commit : Nil
          super
        end

        def __saci_after_commit : Nil
          super
        end

        def __saci_after_destroy : Nil
          super
        end

        def __saci_run_dependents : Nil
          super
        end

        def self.__saci_assoc_kinds : Hash(String, Symbol)
          super
        end

        def self.__saci_preload_assoc(records : Array(Saci::Record::Base), assoc_name : String) : Nil
          super
        end

        def self.__saci_join_sql(assoc_name : String) : String?
          super
        end

        def self.__saci_reset_counter(id : Saci::Record::Value, assoc_name : String) : Bool
          super
        end

        def __saci_apply_defaults : Nil
          super
        end

        # Auto-register every model for polymorphic resolution (full name +
        # short name). Batch fetcher runs one `WHERE pk IN (...)` query.
        Saci::Record.register_polymorphic({{@type.name.stringify}}) do |ids|
          if ids.empty?
            [] of Saci::Record::Base
          else
            ad = Saci::Record.adapter_of({{@type}}.connection)
            ph = Array(String).new(ids.size, "?").join(", ")
            {{@type}}.where(Saci::Record.quote({{@type}}.primary_key_name, ad) + " IN (" + ph + ")", ids).to_a.map { |r| r.as(Saci::Record::Base) }
          end
        end
      end

      # Explicit table name (`table "posts"`). Default: inflected class name
      # (`SpecUser` -> `spec_users`).
      macro table(name)
        def self.__saci_table_name : String
          {{name}}
        end
      end

      def self.__saci_table_name : String
        Inflector.tableize(self.name.split("::").last)
      end

      def self.table_name : String
        __saci_table_name
      end

      def self.__saci_primary_key : String
        "id"
      end

      def self.primary_key_name : String
        __saci_primary_key
      end

      def self.__saci_timestamps? : Bool
        false
      end

      # Declares a typed attribute. Automatically nilable.
      # `default:` sets the initial value on `new` (like ActiveRecord).
      #
      # Logical types `Decimal` (Float64-backed, e.g. confidence scores),
      # `Date` (Time-backed, use `.date` on values), `JSON`
      # (String-backed, with a `<name>_json` / `<name>_json=` `JSON::Any`
      # helper) and `Array(String)` (string arrays, declared as
      # `column tags : Array(String)` for `t.string_array` columns) map to
      # physical column types for storage.
      macro column(decl, primary = false, default = nil)
        {% ctype = decl.type.stringify %}
        {% if ctype.ends_with?("?") %}
          {% raise "Saci::Record.column #{decl.var}: declare a non-nilable type (nilability is automatic). Got: #{ctype}" %}
        {% end %}
        {% if ctype == "Decimal" %}
          {% ptype = "Float64" %}
          {% stype = "Float64" %}
        {% elsif ctype == "Date" %}
          {% ptype = "Time" %}
          {% stype = "Time" %}
        {% elsif ctype == "JSON" %}
          {% ptype = "String" %}
          {% stype = "String" %}
        {% elsif ctype == "Array(String)" %}
          {% ptype = "Array(String)" %}
          {% stype = "Array(String)" %}
        {% else %}
          {% ptype = ctype %}
          {% stype = ctype %}
        {% end %}
        {% unless ["Int32", "Int64", "Float64", "String", "Bool", "Time", "Bytes", "Array(String)"].includes?(ptype) %}
          {% raise "Saci::Record.column #{decl.var}: unsupported type #{ctype}. Supported: Int32, Int64, Float64, String, Bool, Time, Bytes, Decimal, Date, JSON, Array(String)." %}
        {% end %}
        @{{decl.var.id}} : {{ptype.id}}?

        def {{decl.var.id}} : {{ptype.id}}?
          @{{decl.var.id}}
        end

        def {{decl.var.id}}=(value : {{ptype.id}}?) : {{ptype.id}}?
          @{{decl.var.id}} = value
        end

        {% if ctype == "JSON" %}
          # Parsed view of a JSON column (`nil` when blank; raises
          # `JSON::ParseException` on corrupt content).
          def {{decl.var.id}}_json : ::JSON::Any?
            %raw = @{{decl.var.id}}
            return nil if %raw.nil? || %raw.strip.empty?
            ::JSON.parse(%raw)
          end

          def {{decl.var.id}}_json=(value : ::JSON::Any) : ::JSON::Any
            @{{decl.var.id}} = value.to_json
            value
          end
        {% end %}

        def self.__saci_column_names : Array(Tuple(String, String))
          previous_def + [{ {{decl.var.stringify}}, {{stype}} }]
        end

        def __saci_set_attr(key : String, value : Saci::Record::Value) : Bool
          if key == {{decl.var.stringify}}
            {% if stype == "String" %}
              @{{decl.var.id}} = value.nil? ? nil : value.to_s
            {% elsif stype == "Int64" %}
              @{{decl.var.id}} = Saci::Record.to_i64(value)
            {% elsif stype == "Int32" %}
              @{{decl.var.id}} = Saci::Record.to_i32(value)
            {% elsif stype == "Float64" %}
              @{{decl.var.id}} = Saci::Record.to_f64(value)
            {% elsif stype == "Bool" %}
              @{{decl.var.id}} = Saci::Record.to_bool(value)
            {% elsif stype == "Time" %}
              @{{decl.var.id}} = value.is_a?(Time) ? value : nil
            {% elsif stype == "Bytes" %}
              @{{decl.var.id}} = value.is_a?(Bytes) ? value : nil
            {% elsif stype == "Array(String)" %}
              @{{decl.var.id}} = Saci::Record.to_string_array(value)
            {% end %}
            return true
          end
          previous_def
        end

        def __saci_get_attr(key : String) : Saci::Record::Value
          return @{{decl.var.id}} if key == {{decl.var.stringify}}
          previous_def
        end

        {% unless default.is_a?(NilLiteral) %}
          def __saci_apply_defaults : Nil
            previous_def
            @{{decl.var.id}} = {{default}}
          end
        {% end %}

        {% if primary %}
          def self.__saci_primary_key : String
            {{decl.var.stringify}}
          end
        {% end %}
      end

      # Adds `created_at` / `updated_at` columns, auto-maintained on save.
      macro timestamps
        column created_at : Time
        column updated_at : Time

        def self.__saci_timestamps? : Bool
          true
        end
      end

      def self.__saci_column_names : Array(Tuple(String, String))
        [] of Tuple(String, String)
      end

      def __saci_set_attr(key : String, value : Saci::Record::Value) : Bool
        false
      end

      def __saci_get_attr(key : String) : Saci::Record::Value
        nil
      end

      def __saci_run_validations(errors : Errors) : Nil
      end

      # Entry point for `valid?`: the most-derived class resolves the chain
      # (each subclass's `inherited` hook forwards via `super`, and every
      # `validates`/`validate` macro appends to `__saci_run_validations`
      # with `previous_def`). The `__saci_run_validations` call happens
      # HERE, once — calling it from each subclass hook ran leaf validations
      # twice whenever a model inherited from an intermediate base class
      # (e.g. `ApplicationRecord < Saci::Record::Base`).
      def run_validations(errors : Errors) : Nil
        __saci_run_validations(errors)
      end

      # Callback chains (overridden via `previous_def` by the callback
      # macros below; the `inherited` hook forwards them through super).
      def __saci_before_validation : Nil
      end

      def __saci_before_validation_on_create : Nil
      end

      def __saci_before_validation_on_update : Nil
      end

      def __saci_before_save : Nil
      end

      def __saci_after_save : Nil
      end

      def __saci_after_create : Nil
      end

      def __saci_after_create_commit : Nil
      end

      def __saci_after_update_commit : Nil
      end

      def __saci_after_commit : Nil
      end

      def __saci_after_destroy : Nil
      end

      # `dependent:` association cleanup (overridden per association).
      def __saci_run_dependents : Nil
      end

      # Association metadata for `includes` (`name => kind`), accumulated
      # via `previous_def` by the association macros below.
      def self.__saci_assoc_kinds : Hash(String, Symbol)
        {} of String => Symbol
      end

      # Preloads one association (by `__saci_assoc_kinds` name) for already
      # loaded records. Each association macro prepends its own branch and
      # delegates the rest via `previous_def`.
      def self.__saci_preload_assoc(records : Array(Saci::Record::Base), assoc_name : String) : Nil
        raise ArgumentError.new("includes() cannot preload '#{assoc_name}' on #{self.name} (only belongs_to/has_many/has_one; has_many :through is not supported)")
      end

      # Symbol-form `joins(:assoc)` fragment for one association, or nil when
      # unknown (each association macro prepends its branch via previous_def).
      def self.__saci_join_sql(assoc_name : String) : String?
        nil
      end

      # Resets a `counter_cache` column for one `has_many` association.
      # Returns true when handled, false to delegate via `previous_def`.
      def self.__saci_reset_counter(id : Value, assoc_name : String) : Bool
        false
      end

      def __saci_apply_defaults : Nil
      end

      # -- construction -----------------------------------------------------

      @new_record : Bool = true
      @destroyed : Bool = false
      @errors : Errors? = nil
      # Extra result columns from raw-SQL `select` (see `read_attribute`).
      @__saci_extra : Hash(String, Value) = {} of String => Value
      # Eager-loaded associations (`includes`), keyed by association name.
      @__saci_assoc_cache : Hash(String, Base | Array(Base) | Nil) = {} of String => Base | Array(Base) | Nil
      # Validation context (`:create`/`:update`), set by `valid?` — drives
      # `on:` options on validations and callbacks.
      @__saci_validation_context : Symbol = :create

      def __saci_validation_context : Symbol
        @__saci_validation_context
      end

      def initialize
        __saci_apply_defaults
      end

      def initialize(attrs : NamedTuple)
        __saci_apply_defaults
        assign(attrs)
      end

      def initialize(**attrs : Object)
        __saci_apply_defaults
        assign(attrs)
      end

      def assign(attrs : NamedTuple) : Nil
        attrs.each do |key, value|
          unless __saci_set_attr(key.to_s, value)
            raise UnknownAttributeError.new("unknown attribute '#{key}' for #{self.class}")
          end
        end
      end

      def assign(**attrs : Object) : Nil
        assign(attrs)
      end

      def new_record? : Bool
        @new_record
      end

      def persisted? : Bool
        !@new_record && !@destroyed
      end

      def destroyed? : Bool
        @destroyed
      end

      def errors : Errors
        @errors ||= Errors.new
      end

      # Raw-SQL `select` expressions (`SELECT COUNT(*) AS n`) are readable
      # here (model columns take precedence when names collide).
      def read_attribute(name : String | Symbol) : Value
        key = name.to_s
        if @__saci_extra.has_key?(key)
          return @__saci_extra[key]
        end
        __saci_get_attr(key)
      end

      # Shorthand for `read_attribute`.
      def [](name : String | Symbol) : Value
        read_attribute(name)
      end

      # Stores one raw-`select` extra column (called by `Query#to_a`).
      def __saci_push_extra(name : String, value : Value) : Nil
        @__saci_extra[name] = value
      end

      # Eager-loaded association cache (used by association getters).
      def __saci_assoc_cache : Hash(String, Base | Array(Base) | Nil)
        @__saci_assoc_cache
      end

      # Assigns one eager-loaded association (called by preloaders).
      def __saci_set_assoc(key : String, value : Base | Array(Base) | Nil) : Nil
        @__saci_assoc_cache[key] = value
      end

      # -- persistence ------------------------------------------------------

      def save : Bool
        return false unless valid?
        __saci_before_save
        touch_timestamps
        was_new = new_record?
        if was_new
          insert_record
        else
          update_record
        end
        __saci_after_create if was_new
        __saci_after_save
        __saci_fire_after_commit(was_new)
        true
      end

      def save! : self
        raise RecordInvalid.new(errors) unless save
        self
      end

      def update(attrs : NamedTuple) : Bool
        assign(attrs)
        save
      end

      def update(**attrs : Object) : Bool
        update(attrs)
      end

      def update!(attrs : NamedTuple) : self
        assign(attrs)
        save!
      end

      def update!(**attrs : Object) : self
        update!(attrs)
      end

      # `update_columns(name: "x")` — writes the given columns directly,
      # skipping validations and callbacks (like Rails). Timestamps are not
      # touched. Raises on new records, unknown attributes and primary keys.
      def update_columns(attrs : NamedTuple) : Bool
        raise RecordNotSaved.new("Cannot update_columns on a new #{self.class} record") if new_record?
        return true if attrs.empty?
        pairs = [] of Tuple(String, Value)
        attrs.each do |k, v|
          key = k.to_s
          unless self.class.__saci_column_names.any? { |(n, _)| n == key }
            raise UnknownAttributeError.new("unknown attribute '#{key}' for #{self.class}")
          end
          if key == self.class.__saci_primary_key
            raise ArgumentError.new("update_columns cannot update the primary key '#{key}'")
          end
          pairs << {key, v.as(Value)}
        end
        return true if pairs.empty?
        __saci_update_pairs(pairs)
      end

      def update_columns(**attrs : Object) : Bool
        update_columns(attrs)
      end

      def update_columns : Bool
        true
      end

      # `touch` — sets `updated_at` (plus any given columns) to now and
      # persists, skipping validations and callbacks. Returns `false` for
      # new records.
      def touch : Bool
        __saci_touch([] of String)
      end

      def touch(*cols : String | Symbol) : Bool
        __saci_touch(cols.to_a.map(&.to_s))
      end

      private def __saci_touch(keys : Array(String)) : Bool
        return false if new_record?
        now = Time.utc
        pairs = [] of Tuple(String, Value)
        if self.class.__saci_timestamps?
          pairs << {"updated_at", now}
        end
        keys.each do |key|
          unless self.class.__saci_column_names.any? { |(n, _)| n == key }
            raise UnknownAttributeError.new("unknown attribute '#{key}' for #{self.class}")
          end
          pairs << {key, now} unless key == "updated_at"
        end
        return true if pairs.empty?
        __saci_update_pairs(pairs)
      end

      # Direct column write shared by `update_columns` and `touch`.
      # Pairs carry native values (encoded per adapter for SQL only, so
      # in-memory attributes keep their declared types).
      private def __saci_update_pairs(pairs : Array(Tuple(String, Value))) : Bool
        pk = self.class.__saci_primary_key
        pk_val = __saci_get_attr(pk)
        raise RecordNotSaved.new("Cannot update #{self.class} without primary key") if pk_val.nil?
        conn = self.class.connection
        ad = Record.adapter_of(conn)
        sets = pairs.map { |(n, _)| "#{Record.quote(n, ad)} = ?" }.join(", ")
        vals = pairs.map { |(_, v)| Record.to_db(v, ad) } + [Record.to_db(pk_val, ad)] of Value
        Record.exec_compat(conn,
          "UPDATE #{Record.quote(self.class.table_name, ad)} SET #{sets} WHERE #{Record.quote(pk, ad)} = ?",
          vals)
        pairs.each do |(n, v)|
          __saci_set_attr(n, v)
        end
        true
      end

      def destroy : Bool
        return false if new_record? || destroyed?
        pk = self.class.__saci_primary_key
        pk_val = __saci_get_attr(pk)
        return false if pk_val.nil?
        __saci_run_dependents
        conn = self.class.connection
        ad = Record.adapter_of(conn)
        Record.exec_compat(conn, "DELETE FROM #{Record.quote(self.class.table_name, ad)} WHERE #{Record.quote(pk, ad)} = ?", [Record.to_db(pk_val, ad)] of Value)
        @destroyed = true
        __saci_after_destroy
        __saci_fire_after_commit(false)
        true
      end

      def reload : self
        pk = self.class.__saci_primary_key
        fresh = self.class.find(__saci_get_attr(pk).as(Value))
        self.class.__saci_column_names.each do |(name, _)|
          __saci_set_attr(name, fresh.__saci_get_attr(name))
        end
        @new_record = false
        @destroyed = false
        self
      end

      def valid?(context : Symbol? = nil) : Bool
        errors.clear
        @__saci_validation_context = context || (new_record? ? :create : :update)
        __saci_before_validation
        if __saci_validation_context == :create
          __saci_before_validation_on_create
        else
          __saci_before_validation_on_update
        end
        run_validations(errors)
        errors.empty?
      end

      # Fires `after_commit` chains immediately, or defers them to the
      # outermost transaction's commit (discarded on rollback) — Rails
      # `after_commit` semantics.
      private def __saci_fire_after_commit(was_new : Bool) : Nil
        conn = self.class.connection
        if conn.is_a?(DB::Connection)
          if db = Record.tx_database_for(conn)
            Record.defer_after_commit(db) do
              __saci_after_commit
              if was_new
                __saci_after_create_commit
              else
                __saci_after_update_commit
              end
            end
            return
          end
        end
        __saci_after_commit
        if was_new
          __saci_after_create_commit
        else
          __saci_after_update_commit
        end
      end

      private def touch_timestamps : Nil
        return unless self.class.__saci_timestamps?
        now = Time.utc
        __saci_set_attr("created_at", now) if new_record?
        __saci_set_attr("updated_at", now)
      end

      private def insert_record : Nil
        pk = self.class.__saci_primary_key
        pk_val = __saci_get_attr(pk)
        conn = self.class.connection
        ad = Record.adapter_of(conn)
        cols = self.class.__saci_column_names
        # Skip the nil primary key (autoincrement) and nil-valued columns so
        # DB-level DEFAULTs apply — Rails inserts only set attributes.
        use_cols = cols.reject do |(n, _)|
          (n == pk && pk_val.nil?) || (n != pk && __saci_get_attr(n).nil?)
        end
        table = Record.quote(self.class.table_name, ad)
        if use_cols.empty?
          if ad == :postgres
            new_id = nil
            Record.query_compat(conn, "INSERT INTO #{table} DEFAULT VALUES RETURNING #{Record.quote(pk, ad)}") do |rs|
              rs.each { new_id = rs.read(Int64) }
            end
            __saci_set_attr(pk, new_id) if pk_val.nil?
          else
            # NOTE: the id is read from the insert's own ExecResult (same
            # pooled connection) — never via a separate query. MySQL has no
            # `DEFAULT VALUES` syntax (`INSERT INTO t () VALUES ()` instead).
            empty_sql = ad == :mysql ? "INSERT INTO #{table} () VALUES ()" : "INSERT INTO #{table} DEFAULT VALUES"
            res = Record.exec_compat(conn, empty_sql)
            if pk_val.nil?
              __saci_set_attr(pk, res.last_insert_id)
            end
          end
        else
          names = use_cols.map { |(n, _)| Record.quote(n, ad) }
          placeholders = use_cols.map { "?" }.join(", ")
          values = use_cols.map { |(n, _)| Record.to_db(__saci_get_attr(n), ad) }
          if ad == :postgres
            # crystal-pg has no `last_insert_id` — RETURNING instead.
            new_id = nil
            Record.query_compat(conn,
              "INSERT INTO #{table} (#{names.join(", ")}) VALUES (#{placeholders}) RETURNING #{Record.quote(pk, ad)}",
              values) do |rs|
              rs.each { new_id = rs.read(Int64) }
            end
            __saci_set_attr(pk, new_id) if pk_val.nil?
          else
            res = Record.exec_compat(conn,
              "INSERT INTO #{table} (#{names.join(", ")}) VALUES (#{placeholders})",
              values)
            if pk_val.nil?
              __saci_set_attr(pk, res.last_insert_id)
            end
          end
        end
        @new_record = false
      end

      private def update_record : Nil
        pk = self.class.__saci_primary_key
        pk_val = __saci_get_attr(pk)
        raise RecordNotSaved.new("Cannot update #{self.class} without primary key") if pk_val.nil?
        conn = self.class.connection
        ad = Record.adapter_of(conn)
        cols = self.class.__saci_column_names.reject { |(n, _)| n == pk }
        sets = cols.map { |(n, _)| "#{Record.quote(n, ad)} = ?" }.join(", ")
        values = cols.map { |(n, _)| Record.to_db(__saci_get_attr(n), ad) } + [Record.to_db(pk_val, ad)] of Value
        Record.exec_compat(conn,
          "UPDATE #{Record.quote(self.class.table_name, ad)} SET #{sets} WHERE #{Record.quote(pk, ad)} = ?",
          values)
      end

      # -- loading ----------------------------------------------------------

      def self.load_row(rs : DB::ResultSet, adapter : Adapter = :sqlite) : self
        obj = new
        __saci_column_names.each do |(col_name, col_type)|
          obj.__saci_set_attr(col_name, Record.read_typed(rs, col_type, adapter))
        end
        obj.__saci_mark_persisted!
        obj
      end

      def __saci_mark_persisted! : Nil
        @new_record = false
      end

      # -- finders ----------------------------------------------------------

      def self.all : Query(self)
        Query(self).new(self)
      end

      def self.where(**conds : Object) : Query(self)
        all.where(**conds)
      end

      def self.where(sql : String, *args : Object) : Query(self)
        all.where(sql, *args)
      end

      def self.where(sql : String) : Query(self)
        all.where(sql)
      end

      def self.where(sql : String, args : Array(Value)) : Query(self)
        all.where(sql, args)
      end

      def self.order(field : Symbol | String, dir : Symbol = :asc) : Query(self)
        all.order(field, dir)
      end

      def self.order(**opts : Object) : Query(self)
        all.order(**opts)
      end

      def self.limit(n : Int) : Query(self)
        all.limit(n)
      end

      def self.offset(n : Int) : Query(self)
        all.offset(n)
      end

      def self.first : self?
        all.first
      end

      def self.count : Int64
        all.count
      end

      def self.exists?(**conds : Object) : Bool
        where(**conds).exists?
      end

      def self.exists?(sql : String, *args : Object) : Bool
        where(sql, *args).exists?
      end

      def self.find(id : Value) : self
        pk = __saci_primary_key
        ad = Record.adapter_of(connection)
        where("#{Record.quote(pk, ad)} = ?", Record.to_db(id, ad)).first ||
          raise RecordNotFound.new("Couldn't find #{self.name} with '#{pk}'=#{id}")
      end

      def self.find_by(**conds : Object) : self?
        where(**conds).first
      end

      def self.find_by!(**conds : Object) : self
        where(**conds).first! rescue raise RecordNotFound.new("Couldn't find #{self.name}")
      end

      def self.create(attrs : NamedTuple) : self
        obj = new(attrs)
        obj.save
        obj
      end

      def self.create(**attrs : Object) : self
        create(attrs)
      end

      def self.create!(attrs : NamedTuple) : self
        obj = new(attrs)
        obj.save!
        obj
      end

      def self.create!(**attrs : Object) : self
        create!(attrs)
      end

      def self.pluck(col : String | Symbol) : Array(Value)
        all.pluck(col)
      end

      def self.select(*cols : String | Symbol) : Query(self)
        all.select(*cols)
      end

      def self.distinct : Query(self)
        all.distinct
      end

      def self.group(*cols : String | Symbol) : GroupedQuery(self)
        all.group(*cols)
      end

      def self.joins(sql : String) : Query(self)
        all.joins(sql)
      end

      def self.joins(*names : Symbol) : Query(self)
        all.joins(*names)
      end

      def self.includes(*names : Symbol) : Query(self)
        all.includes(*names)
      end

      def self.includes(**nested) : Query(self)
        all.includes(**nested)
      end

      def self.sum(col : String | Symbol) : Float64
        all.sum(col)
      end

      def self.average(col : String | Symbol) : Float64?
        all.average(col)
      end

      def self.avg(col : String | Symbol) : Float64?
        all.avg(col)
      end

      def self.minimum(col : String | Symbol) : Value
        all.minimum(col)
      end

      def self.maximum(col : String | Symbol) : Value
        all.maximum(col)
      end

      def self.delete_all : Int64
        all.delete_all
      end

      # `upsert({id: 1, name: "x"})` — INSERT ... ON CONFLICT(pk) DO UPDATE
      # (SQLite/PostgreSQL) or ON DUPLICATE KEY UPDATE (MySQL). Skips
      # validations and callbacks, like Rails. Timestamps are maintained
      # (`created_at` set on insert and preserved on conflict, `updated_at`
      # always bumped). Returns `true` on success.
      def self.upsert(attrs : NamedTuple) : Bool
        conn = connection
        ad = Record.adapter_of(conn)
        cols_meta = __saci_column_names
        pairs = [] of Tuple(String, Value)
        attrs.each do |k, v|
          key = k.to_s
          unless cols_meta.any? { |(n, _)| n == key }
            raise UnknownAttributeError.new("unknown attribute '#{key}' for #{self}")
          end
          pairs << {key, Record.to_db(v, ad)}
        end
        return true if pairs.empty?
        pk = __saci_primary_key
        stamp = __saci_timestamps?
        if stamp
          now = Record.to_db(Time.utc, ad)
          pairs << {"created_at", now} unless pairs.any? { |(n, _)| n == "created_at" }
          pairs << {"updated_at", now} unless pairs.any? { |(n, _)| n == "updated_at" }
        end
        table = Record.quote(table_name, ad)
        names = pairs.map { |(n, _)| Record.quote(n, ad) }
        placeholders = pairs.map { "?" }.join(", ")
        vals = pairs.map { |(_, v)| v }
        rest = stamp ? pairs.reject { |(n, _)| n == pk || n == "created_at" } : pairs.reject { |(n, _)| n == pk }
        if rest.empty?
          Record.exec_compat(conn,
            "INSERT INTO #{table} (#{names.join(", ")}) VALUES (#{placeholders}) ON CONFLICT(#{Record.quote(pk, ad)}) DO NOTHING",
            vals)
        elsif ad == :mysql
          upd = rest.map { |(n, _)| "#{Record.quote(n, ad)} = VALUES(#{Record.quote(n, ad)})" }.join(", ")
          Record.exec_compat(conn,
            "INSERT INTO #{table} (#{names.join(", ")}) VALUES (#{placeholders}) ON DUPLICATE KEY UPDATE #{upd}",
            vals)
        else
          upd = rest.map { |(n, _)| "#{Record.quote(n, ad)} = excluded.#{Record.quote(n, ad)}" }.join(", ")
          Record.exec_compat(conn,
            "INSERT INTO #{table} (#{names.join(", ")}) VALUES (#{placeholders}) ON CONFLICT(#{Record.quote(pk, ad)}) DO UPDATE SET #{upd}",
            vals)
        end
        true
      end

      def self.upsert(**attrs : Object) : Bool
        upsert(attrs)
      end

      def self.upsert : Bool
        true
      end

      # -- counters & touching ------------------------------------------------
      # `update_counter(id, :views, 1)` / `update_counters(id, {views: 1})` —
      # atomic `COALESCE(col,0) + delta` writes, skipping validations and
      # callbacks (like Rails). `update_counter` also exists on instances.
      def self.update_counter(id : Value, column : String | Symbol, delta : Int64 = 1_i64) : Bool
        col = column.to_s
        unless __saci_column_names.any? { |(n, _)| n == col }
          raise UnknownAttributeError.new("unknown attribute '#{col}' for #{self}")
        end
        Record.update_counter(connection, table_name, __saci_primary_key, id, col, delta)
        true
      end

      def self.update_counters(id : Value, counters : Hash(String | Symbol, Int)) : Bool
        counters.each do |col, delta|
          update_counter(id, col.to_s, delta.to_i64)
        end
        true
      end

      def self.update_counters(id : Value, counters : NamedTuple) : Bool
        counters.each do |col, delta|
          update_counter(id, col.to_s, delta.to_i64)
        end
        true
      end

      def self.update_counters(id : Value, **counters : Int) : Bool
        counters.each do |col, delta|
          update_counter(id, col.to_s, delta.to_i64)
        end
        true
      end

      def update_counter(column : String | Symbol, delta : Int64 = 1_i64) : Bool
        pk = __saci_get_attr(self.class.__saci_primary_key)
        raise RecordNotSaved.new("Cannot update_counter on a new #{self.class} record") if pk.nil?
        self.class.update_counter(pk, column, delta)
      end

      # `reset_counters(id, :orm_books)` — recounts each `has_many`
      # association and writes the `<child_table>_count` (or
      # `<assoc>_count` fallback) column. Raises `UnknownAttributeError`
      # when the association or counter column is unknown.
      def self.reset_counters(id : Value, *counters : String | Symbol) : Bool
        raise ArgumentError.new("reset_counters requires at least one association") if counters.empty?
        counters.each do |assoc|
          name = assoc.to_s
          unless __saci_assoc_kinds.has_key?(name)
            raise UnknownAttributeError.new("unknown association '#{name}' for #{self}")
          end
          handled = __saci_reset_counter(id, name)
          unless handled
            raise UnknownAttributeError.new("reset_counters: association '#{name}' on #{self} does not support counter reset (only has_many)")
          end
        end
        true
      end

      # `touch_all` — bumps `updated_at` (plus optional extra timestamp
      # columns) on every row, skipping validations and callbacks. Returns
      # the number of rows touched.
      def self.touch_all(*names, time : Time? = nil) : Int64
        all.touch_all(*names, time: time)
      end

      # -- validations ------------------------------------------------------

      macro validates(col, presence = nil, min_length = nil, max_length = nil, length = nil, format = nil, uniqueness = nil, inclusion = nil, numericality = nil, allow_nil = nil, allow_blank = nil, on = nil, **_saci_cond)
        # -- macro-time normalization ------------------------------------
        {% if on %}
          {% on_s = on.id.stringify %}
          {% unless on_s == "create" || on_s == "update" %}
            {% raise "validates: unsupported on: #{on} (expected :create or :update)" %}
          {% end %}
        {% end %}
        # length: {minimum:, maximum:, in:, within:, allow_nil:, allow_blank:}
        {% lmin = min_length %}
        {% lmax = max_length %}
        {% len_allow_nil = allow_nil == true %}
        {% len_allow_blank = allow_blank == true %}
        {% if length %}
          {% unless length.is_a?(NamedTupleLiteral) %}
            {% raise "validates #{col}: length: expects {minimum: .., maximum: .., in: .., within: ..} (got #{length})" %}
          {% end %}
          {% unless length[:minimum].is_a?(NilLiteral) %}
            {% lmin = length[:minimum] %}
          {% end %}
          {% unless length[:maximum].is_a?(NilLiteral) %}
            {% lmax = length[:maximum] %}
          {% end %}
          {% lrange = length[:in] %}
          {% if lrange.is_a?(NilLiteral) %}
            {% lrange = length[:within] %}
          {% end %}
          {% unless lrange.is_a?(NilLiteral) %}
            {% unless lrange.is_a?(RangeLiteral) %}
              {% raise "validates #{col}: length: in:/within: expects a Range (got #{lrange})" %}
            {% end %}
            {% lmin = lrange.begin %}
            {% lmax = lrange.end %}
          {% end %}
          {% if length[:allow_nil] == true %}
            {% len_allow_nil = true %}
          {% end %}
          {% if length[:allow_blank] == true %}
            {% len_allow_blank = true %}
          {% end %}
        {% end %}
        # uniqueness: true | :scope | [:scopes] |
        #   {scope: .., case_sensitive: false}
        {% u_scopes = [] of ASTNode %}
        {% u_case_insensitive = false %}
        {% if uniqueness %}
          {% if uniqueness.is_a?(NamedTupleLiteral) %}
            {% if uniqueness[:case_sensitive] == false %}
              {% u_case_insensitive = true %}
            {% end %}
            {% u_scope_raw = uniqueness[:scope] %}
            {% if u_scope_raw.is_a?(ArrayLiteral) %}
              {% u_scopes = u_scope_raw %}
            {% elsif u_scope_raw.is_a?(SymbolLiteral) %}
              {% u_scopes = [u_scope_raw] %}
            {% elsif u_scope_raw.is_a?(NilLiteral) %}
            {% else %}
              {% raise "validates #{col}: uniqueness: scope: expects a Symbol or Array (got #{u_scope_raw})" %}
            {% end %}
          {% elsif uniqueness.is_a?(ArrayLiteral) %}
            {% u_scopes = uniqueness %}
          {% elsif uniqueness.is_a?(SymbolLiteral) %}
            {% u_scopes = [uniqueness] %}
          {% end %}
        {% end %}
        # inclusion: {in: [...]} (or a bare Array/Tuple/Range)
        {% inc_set = nil %}
        {% inc_allow_nil = allow_nil == true %}
        {% inc_allow_blank = allow_blank == true %}
        {% if inclusion %}
          {% if inclusion.is_a?(NamedTupleLiteral) %}
            {% inc_set = inclusion[:in] %}
            {% if inclusion[:allow_nil] == true %}
              {% inc_allow_nil = true %}
            {% end %}
            {% if inclusion[:allow_blank] == true %}
              {% inc_allow_blank = true %}
            {% end %}
          {% else %}
            {% inc_set = inclusion %}
          {% end %}
          {% unless inc_set.is_a?(ArrayLiteral) || inc_set.is_a?(TupleLiteral) || inc_set.is_a?(RangeLiteral) %}
            {% raise "validates #{col}: inclusion: expects {in: [...]} or an Array/Tuple/Range (got #{inclusion})" %}
          {% end %}
        {% end %}
        # numericality: true | {only_integer:, greater_than:, ...}
        {% n_only_int = nil %}
        {% n_gt = nil %}
        {% n_gte = nil %}
        {% n_lt = nil %}
        {% n_lte = nil %}
        {% n_eq = nil %}
        {% num_allow_nil = allow_nil == true %}
        {% num_allow_blank = allow_blank == true %}
        {% if numericality %}
          {% if numericality.is_a?(NamedTupleLiteral) %}
            {% n_only_int = numericality[:only_integer] %}
            {% n_gt = numericality[:greater_than] %}
            {% n_gte = numericality[:greater_than_or_equal_to] %}
            {% n_lt = numericality[:less_than] %}
            {% n_lte = numericality[:less_than_or_equal_to] %}
            {% n_eq = numericality[:equal_to] %}
            {% if numericality[:allow_nil] == true %}
              {% num_allow_nil = true %}
            {% end %}
            {% if numericality[:allow_blank] == true %}
              {% num_allow_blank = true %}
            {% end %}
          {% end %}
        {% end %}
        {% check_int = false %}
        {% unless n_only_int.is_a?(NilLiteral) %}
          {% if n_only_int.stringify != "false" %}
            {% check_int = true %}
          {% end %}
        {% end %}
        def __saci_run_validations(errors : Saci::Record::Errors) : Nil
          previous_def
          {% if on %}
            if __saci_validation_context != {{on}}
              return
            end
          {% end %}
          {% _saci_if = _saci_cond[:if] %}
          {% _saci_unless = _saci_cond[:unless] %}
          {% unless _saci_if.is_a?(NilLiteral) %}
            {% if _saci_if.is_a?(SymbolLiteral) %}
              return unless self.{{_saci_if.id}}
            {% elsif _saci_if.is_a?(ProcLiteral) %}
              {% if _saci_if.args.size == 0 %}
                return unless ({{_saci_if}}).call
              {% else %}
                return unless ({{_saci_if}}).call(self)
              {% end %}
            {% else %}
              {% raise "validates #{col}: if: must be a Symbol or Proc (got #{_saci_if})" %}
            {% end %}
          {% end %}
          {% unless _saci_unless.is_a?(NilLiteral) %}
            {% if _saci_unless.is_a?(SymbolLiteral) %}
              return if self.{{_saci_unless.id}}
            {% elsif _saci_unless.is_a?(ProcLiteral) %}
              {% if _saci_unless.args.size == 0 %}
                return if ({{_saci_unless}}).call
              {% else %}
                return if ({{_saci_unless}}).call(self)
              {% end %}
            {% else %}
              {% raise "validates #{col}: unless: must be a Symbol or Proc (got #{_saci_unless})" %}
            {% end %}
          {% end %}
          {% if presence %}
            %present{{col.id}} = self.{{col.id}}
            if %present{{col.id}}.nil? || (%present{{col.id}}.is_a?(String) && %present{{col.id}}.as(String).strip.empty?)
              errors.add({{col.id.stringify}}, "can't be blank")
            end
          {% end %}
          {% if lmin || lmax %}
            %len_raw{{col.id}} = self.{{col.id}}
            {% if len_allow_blank %}
              %len_skip{{col.id}} = !%len_raw{{col.id}}.nil? && Saci::Record.blank?(%len_raw{{col.id}})
            {% else %}
              %len_skip{{col.id}} = false
            {% end %}
            unless %len_skip{{col.id}}
              %len_str{{col.id}} = %len_raw{{col.id}}.nil? ? nil : %len_raw{{col.id}}.to_s
              unless %len_str{{col.id}}.nil?
                {% unless lmin.is_a?(NilLiteral) %}
                  if %len_str{{col.id}}.not_nil!.size < {{lmin}}
                    errors.add({{col.id.stringify}}, "is too short (minimum is {{lmin}} characters)")
                  end
                {% end %}
                {% unless lmax.is_a?(NilLiteral) %}
                  if %len_str{{col.id}}.not_nil!.size > {{lmax}}
                    errors.add({{col.id.stringify}}, "is too long (maximum is {{lmax}} characters)")
                  end
                {% end %}
              end
            end
          {% end %}
          {% if format %}
            %fmt{{col.id}} = self.{{col.id}}
            {% if allow_blank == true %}
              %fmt_skip{{col.id}} = !%fmt{{col.id}}.nil? && Saci::Record.blank?(%fmt{{col.id}})
            {% else %}
              %fmt_skip{{col.id}} = false
            {% end %}
            if %fmt{{col.id}} && !%fmt_skip{{col.id}}
              if %fmt{{col.id}}.to_s !~ {{format}}
                errors.add({{col.id.stringify}}, "is invalid")
              end
            end
          {% end %}
          {% if uniqueness %}
            %uniq{{col.id}} = self.{{col.id}}
            {% if allow_blank == true %}
              %uniq_skip{{col.id}} = %uniq{{col.id}}.nil? || Saci::Record.blank?(%uniq{{col.id}})
            {% else %}
              %uniq_skip{{col.id}} = %uniq{{col.id}}.nil?
            {% end %}
            unless %uniq_skip{{col.id}}
              %uad{{col.id}} = Saci::Record.adapter_of(self.class.connection)
              {% if u_case_insensitive %}
                %uq_col{{col.id}} = Saci::Record.quote({{col.id.stringify}}, %uad{{col.id}})
                %uscope{{col.id}} = if %uad{{col.id}} == :sqlite
                  self.class.where(%uq_col{{col.id}} + " = ? COLLATE NOCASE", Saci::Record.to_db(%uniq{{col.id}}, %uad{{col.id}}))
                else
                  self.class.where("LOWER(" + %uq_col{{col.id}} + ") = LOWER(?)", Saci::Record.to_db(%uniq{{col.id}}, %uad{{col.id}}))
                end
              {% else %}
                %uscope{{col.id}} = self.class.where(Saci::Record.quote({{col.id.stringify}}, %uad{{col.id}}) + " = ?", Saci::Record.to_db(%uniq{{col.id}}, %uad{{col.id}}))
              {% end %}
              {% for s in u_scopes %}
                %scv{{col.id}}{{s.id}} = __saci_get_attr({{s.id.stringify}})
                %uscope{{col.id}} = %scv{{col.id}}{{s.id}}.nil? ? %uscope{{col.id}}.where(Saci::Record.quote({{s.id.stringify}}, %uad{{col.id}}) + " IS NULL") : %uscope{{col.id}}.where(Saci::Record.quote({{s.id.stringify}}, %uad{{col.id}}) + " = ?", Saci::Record.to_db(%scv{{col.id}}{{s.id}}, %uad{{col.id}}))
              {% end %}
              %upk{{col.id}} = __saci_get_attr(self.class.__saci_primary_key)
              unless %upk{{col.id}}.nil?
                %uscope{{col.id}} = %uscope{{col.id}}.where(Saci::Record.quote(self.class.__saci_primary_key, %uad{{col.id}}) + " != ?", Saci::Record.to_db(%upk{{col.id}}, %uad{{col.id}}))
              end
              if %uscope{{col.id}}.exists?
                errors.add({{col.id.stringify}}, "has already been taken")
              end
            end
          {% end %}
          {% if inclusion %}
            %inc_v{{col.id}} = self.{{col.id}}
            {% if inc_allow_blank %}
              %inc_skip{{col.id}} = Saci::Record.blank?(%inc_v{{col.id}})
            {% else %}
              %inc_skip{{col.id}} = false
            {% end %}
            if %inc_v{{col.id}}.nil?
              {% unless inc_allow_nil %}
                errors.add({{col.id.stringify}}, "is not included in the list") unless %inc_skip{{col.id}}
              {% end %}
            elsif !%inc_skip{{col.id}} && !({{inc_set}}).includes?(%inc_v{{col.id}})
              errors.add({{col.id.stringify}}, "is not included in the list")
            end
          {% end %}
          {% if numericality %}
            %num_raw{{col.id}} = self.{{col.id}}
            {% if num_allow_blank %}
              %num_skip{{col.id}} = Saci::Record.blank?(%num_raw{{col.id}})
            {% elsif num_allow_nil %}
              %num_skip{{col.id}} = %num_raw{{col.id}}.nil?
            {% else %}
              %num_skip{{col.id}} = false
            {% end %}
            unless %num_skip{{col.id}}
              if %num_raw{{col.id}}.nil?
                errors.add({{col.id.stringify}}, "is not a number")
              else
                %num_str{{col.id}} = %num_raw{{col.id}}.to_s
                %num_val{{col.id}} = %num_str{{col.id}}.to_f64?
                if %num_val{{col.id}}.nil?
                  errors.add({{col.id.stringify}}, "is not a number")
                else
                  {% if check_int %}
                    if %num_str{{col.id}} !~ /\A[+-]?\d+\z/
                      errors.add({{col.id.stringify}}, "must be an integer")
                    end
                  {% end %}
                  {% unless n_gt.is_a?(NilLiteral) %}
                    if %num_val{{col.id}} <= {{n_gt}}
                      errors.add({{col.id.stringify}}, "must be greater than {{n_gt}}")
                    end
                  {% end %}
                  {% unless n_gte.is_a?(NilLiteral) %}
                    if %num_val{{col.id}} < {{n_gte}}
                      errors.add({{col.id.stringify}}, "must be greater than or equal to {{n_gte}}")
                    end
                  {% end %}
                  {% unless n_lt.is_a?(NilLiteral) %}
                    if %num_val{{col.id}} >= {{n_lt}}
                      errors.add({{col.id.stringify}}, "must be less than {{n_lt}}")
                    end
                  {% end %}
                  {% unless n_lte.is_a?(NilLiteral) %}
                    if %num_val{{col.id}} > {{n_lte}}
                      errors.add({{col.id.stringify}}, "must be less than or equal to {{n_lte}}")
                    end
                  {% end %}
                  {% unless n_eq.is_a?(NilLiteral) %}
                    if %num_val{{col.id}} != {{n_eq}}
                      errors.add({{col.id.stringify}}, "must be equal to {{n_eq}}")
                    end
                  {% end %}
                end
              end
            end
          {% end %}
        end
      end

      # Custom validation method(s) (`validate :check_something`, multiple
      # names, optional `on:`) or a block (`validate { errors.add(...) }`,
      # `|record|` optional). Methods report via `errors.add`.
      # `if:`/`unless:` take a method name Symbol or a Proc (`->(r) { ... }`
      # with one arg receives the record, zero-arg is called bare).
      macro validate(*names, on = nil, **_saci_cond, &block)
        {% if on %}
          {% on_s = on.id.stringify %}
          {% unless on_s == "create" || on_s == "update" %}
            {% raise "validate: unsupported on: #{on} (expected :create or :update)" %}
          {% end %}
        {% end %}
        def __saci_run_validations(errors : Saci::Record::Errors) : Nil
          previous_def
          {% _saci_if = _saci_cond[:if] %}
          {% _saci_unless = _saci_cond[:unless] %}
          {% unless _saci_if.is_a?(NilLiteral) %}
            {% if _saci_if.is_a?(SymbolLiteral) %}
              return unless self.{{_saci_if.id}}
            {% elsif _saci_if.is_a?(ProcLiteral) %}
              {% if _saci_if.args.size == 0 %}
                return unless ({{_saci_if}}).call
              {% else %}
                return unless ({{_saci_if}}).call(self)
              {% end %}
            {% else %}
              {% raise "validate: if: must be a Symbol or Proc" %}
            {% end %}
          {% end %}
          {% unless _saci_unless.is_a?(NilLiteral) %}
            {% if _saci_unless.is_a?(SymbolLiteral) %}
              return if self.{{_saci_unless.id}}
            {% elsif _saci_unless.is_a?(ProcLiteral) %}
              {% if _saci_unless.args.size == 0 %}
                return if ({{_saci_unless}}).call
              {% else %}
                return if ({{_saci_unless}}).call(self)
              {% end %}
            {% else %}
              {% raise "validate: unless: must be a Symbol or Proc" %}
            {% end %}
          {% end %}
          {% if on %}
            if __saci_validation_context == {{on}}
              {% for n in names %}
                self.{{n.id}}
              {% end %}
              {% if block %}
                {% if block.args.size == 1 %}
                  {{block.args[0]}} = self
                {% elsif block.args.size > 1 %}
                  {% raise "validate blocks take at most one argument" %}
                {% end %}
                {{block.body}}
              {% end %}
            end
          {% else %}
            {% for n in names %}
              self.{{n.id}}
            {% end %}
            {% if block %}
              {% if block.args.size == 1 %}
                {{block.args[0]}} = self
              {% elsif block.args.size > 1 %}
                {% raise "validate blocks take at most one argument" %}
              {% end %}
              {{block.body}}
            {% end %}
          {% end %}
        end
      end

      # -- callbacks ------------------------------------------------------
      #
      # Minimal Rails-compatible set: `before_validation` (with `on:`),
      # `before_save`, `after_save`, `after_create`, `after_commit` (with
      # `on:`) and `after_destroy`. Each accepts method names, inline
      # lambdas (`after_create -> { ... }`) and/or a block
      # (`before_save { |record| ... }`, `|record|` optional):
      #
      # ```
      # before_validation :normalize, on: :create
      # after_create :notify, :audit
      # after_commit :rebuild_cache, on: :create
      # before_save { |post| post.title = post.title.strip }
      # ```
      #
      # Chains accumulate via `previous_def` (declaration order, parents
      # first). `after_commit` without `on:` fires after every save and
      # destroy; it is deferred to the outermost transaction's commit and
      # discarded on rollback. (Inside explicit transactions the callbacks
      # fire at commit time, not save time.)

      macro before_validation(*names, on = nil, &block)
        {% if on %}
          {% on_s = on.id.stringify %}
          {% if on_s == "create" %}
            {% chain = "__saci_before_validation_on_create".id %}
          {% elsif on_s == "update" %}
            {% chain = "__saci_before_validation_on_update".id %}
          {% else %}
            {% raise "before_validation: unsupported on: #{on} (expected :create or :update)" %}
          {% end %}
        {% else %}
          {% chain = "__saci_before_validation".id %}
        {% end %}
        def {{chain}} : Nil
          previous_def
          {% for n in names %}
            {% if n.is_a?(ProcLiteral) %}
              ({{n}}).call
            {% else %}
              self.{{n.id}}
            {% end %}
          {% end %}
          {% if block %}
            {% if block.args.size == 1 %}
              {{block.args[0]}} = self
            {% elsif block.args.size > 1 %}
              {% raise "callback blocks take at most one argument" %}
            {% end %}
            {{block.body}}
          {% end %}
        end
      end

      macro before_save(*names, &block)
        def __saci_before_save : Nil
          previous_def
          {% for n in names %}
            {% if n.is_a?(ProcLiteral) %}
              ({{n}}).call
            {% else %}
              self.{{n.id}}
            {% end %}
          {% end %}
          {% if block %}
            {% if block.args.size == 1 %}
              {{block.args[0]}} = self
            {% elsif block.args.size > 1 %}
              {% raise "callback blocks take at most one argument" %}
            {% end %}
            {{block.body}}
          {% end %}
        end
      end

      macro after_save(*names, &block)
        def __saci_after_save : Nil
          previous_def
          {% for n in names %}
            {% if n.is_a?(ProcLiteral) %}
              ({{n}}).call
            {% else %}
              self.{{n.id}}
            {% end %}
          {% end %}
          {% if block %}
            {% if block.args.size == 1 %}
              {{block.args[0]}} = self
            {% elsif block.args.size > 1 %}
              {% raise "callback blocks take at most one argument" %}
            {% end %}
            {{block.body}}
          {% end %}
        end
      end

      macro after_create(*names, &block)
        def __saci_after_create : Nil
          previous_def
          {% for n in names %}
            {% if n.is_a?(ProcLiteral) %}
              ({{n}}).call
            {% else %}
              self.{{n.id}}
            {% end %}
          {% end %}
          {% if block %}
            {% if block.args.size == 1 %}
              {{block.args[0]}} = self
            {% elsif block.args.size > 1 %}
              {% raise "callback blocks take at most one argument" %}
            {% end %}
            {{block.body}}
          {% end %}
        end
      end

      macro after_commit(*names, on = nil, &block)
        {% if on %}
          {% on_s = on.id.stringify %}
          {% if on_s == "create" %}
            {% chain = "__saci_after_create_commit".id %}
          {% elsif on_s == "update" %}
            {% chain = "__saci_after_update_commit".id %}
          {% else %}
            {% raise "after_commit: unsupported on: #{on} (expected :create or :update)" %}
          {% end %}
        {% else %}
          {% chain = "__saci_after_commit".id %}
        {% end %}
        def {{chain}} : Nil
          previous_def
          {% for n in names %}
            {% if n.is_a?(ProcLiteral) %}
              ({{n}}).call
            {% else %}
              self.{{n.id}}
            {% end %}
          {% end %}
          {% if block %}
            {% if block.args.size == 1 %}
              {{block.args[0]}} = self
            {% elsif block.args.size > 1 %}
              {% raise "callback blocks take at most one argument" %}
            {% end %}
            {{block.body}}
          {% end %}
        end
      end

      macro after_destroy(*names, &block)
        def __saci_after_destroy : Nil
          previous_def
          {% for n in names %}
            {% if n.is_a?(ProcLiteral) %}
              ({{n}}).call
            {% else %}
              self.{{n.id}}
            {% end %}
          {% end %}
          {% if block %}
            {% if block.args.size == 1 %}
              {{block.args[0]}} = self
            {% elsif block.args.size > 1 %}
              {% raise "callback blocks take at most one argument" %}
            {% end %}
            {{block.body}}
          {% end %}
        end
      end

      # Rails `has_secure_password` (bcrypt). Requires a `password_digest`
      # column; adds virtual `password` / `password_confirmation` attributes
      # (digest computed on assignment) plus `authenticate`:
      #
      # ```
      # class User < ApplicationRecord
      #   column password_digest : String
      #   has_secure_password
      # end
      #
      # user.authenticate("secret") # => user or nil
      # ```
      macro has_secure_password(validations = true)
        @password : String?
        @password_confirmation : String?

        def password : String?
          @password
        end

        def password=(value : String?) : String?
          @password = value
          if digest_value = value
            self.password_digest = Saci::Record.bcrypt_digest(digest_value)
          else
            self.password_digest = nil
          end
          value
        end

        def password_confirmation : String?
          @password_confirmation
        end

        def password_confirmation=(value : String?) : String?
          @password_confirmation = value
        end

        # Virtual attributes participate in mass-assignment (`new`/`assign`).
        def __saci_set_attr(key : String, value : Saci::Record::Value) : Bool
          if key == "password"
            self.password = value.nil? ? nil : value.to_s
            return true
          elsif key == "password_confirmation"
            self.password_confirmation = value.nil? ? nil : value.to_s
            return true
          end
          previous_def
        end

        def authenticate(unencrypted_password : String) : self?
          digest = self.password_digest
          return nil if digest.nil? || digest.empty?
          Saci::Record.bcrypt_verify(digest, unencrypted_password) ? self : nil
        end

        def __saci_run_validations(errors : Saci::Record::Errors) : Nil
          previous_def
          {% if validations %}
            %pw_digest = self.password_digest
            if new_record? && (%pw_digest.nil? || %pw_digest.empty?) && (@password.nil? || @password == "")
              errors.add("password", "can't be blank")
            end
            unless @password.nil?
              if @password_confirmation && @password != @password_confirmation
                errors.add("password_confirmation", "doesn't match Password")
              end
              if @password.not_nil!.bytesize > 72
                errors.add("password", "is too long (maximum is 72 characters)")
              end
            end
          {% end %}
        end
      end

      # -- associations -----------------------------------------------------

      # `belongs_to :user` reads `user_id` and returns the `User`
      # (nil when the foreign key is nil, raises `RecordNotFound` when
      # dangling — like Rails). Honors `includes` preloading.
      #
      # `counter_cache: true` maintains `<child_table>_count` on the parent
      # (a Symbol/String names the column explicitly); `touch: true` bumps
      # the parent's `updated_at` on save and destroy (`touch: :col` bumps
      # that column too).
      macro belongs_to(name, class_name = nil, foreign_key = nil, counter_cache = nil, touch = nil, polymorphic = nil)
        {% if polymorphic %}
          {% type_col = "#{name.id}_type" %}
          {% id_col = "#{name.id}_id" %}
          # Polymorphic `belongs_to :notifiable, polymorphic: true` — reads
          # `<name>_type` (class name) + `<name>_id` and resolves through the
          # `Saci::Record` polymorphic registry (every model auto-registers).
          # Nil type/id → nil; dangling rows raise `RecordNotFound`.
          def {{name.id}} : Saci::Record::Base?
            if __saci_assoc_cache.has_key?({{name.id.stringify}})
              return __saci_assoc_cache[{{name.id.stringify}}].as(Saci::Record::Base?)
            end
            t = __saci_get_attr({{type_col}})
            i = __saci_get_attr({{id_col}})
            if t.nil? || i.nil?
              nil
            else
              Saci::Record.resolve_polymorphic(t.to_s, i)
            end
          end

          def {{name.id}}=(obj : Saci::Record::Base?) : Saci::Record::Base?
            if obj.nil?
              __saci_set_attr({{type_col}}, nil)
              __saci_set_attr({{id_col}}, nil)
            else
              __saci_set_attr({{type_col}}, obj.class.name)
              pk = obj.__saci_get_attr(obj.class.__saci_primary_key)
              __saci_set_attr({{id_col}}, pk)
            end
            obj
          end

          def self.__saci_preload_{{name.id}}(records : Array(Saci::Record::Base)) : Nil
            by_type = {} of String => Array(Saci::Record::Base)
            ids_by_type = {} of String => Array(Saci::Record::Value)
            records.each do |rec|
              t = rec.__saci_get_attr({{type_col}})
              i = rec.__saci_get_attr({{id_col}})
              next if t.nil? || i.nil?
              ts = t.to_s
              (by_type[ts] ||= [] of Saci::Record::Base) << rec
              (ids_by_type[ts] ||= [] of Saci::Record::Value) << i
            end
            ids_by_type.each do |ts, ids|
              found = Saci::Record.resolve_polymorphic_many(ts, ids)
              owners = by_type[ts]
              owners.each do |rec|
                iid = rec.__saci_get_attr({{id_col}})
                if iid.nil?
                  rec.__saci_set_assoc({{name.id.stringify}}, nil)
                elsif hit = found[iid]?
                  rec.__saci_set_assoc({{name.id.stringify}}, hit)
                end
              end
            end
            records.each do |rec|
              unless rec.__saci_assoc_cache.has_key?({{name.id.stringify}})
                t = rec.__saci_get_attr({{type_col}})
                i = rec.__saci_get_attr({{id_col}})
                if t.nil? || i.nil?
                  rec.__saci_set_assoc({{name.id.stringify}}, nil)
                end
              end
            end
          end

          def self.__saci_preload_assoc(records : Array(Saci::Record::Base), assoc_name : String) : Nil
            if assoc_name == {{name.id.stringify}}
              __saci_preload_{{name.id}}(records)
            else
              previous_def
            end
          end

          def self.__saci_assoc_kinds : Hash(String, Symbol)
            %kinds = previous_def.dup
            %kinds[{{name.id.stringify}}] = :belongs_to
            %kinds
          end

          def self.__saci_join_sql(assoc_name : String) : String?
            if assoc_name == {{name.id.stringify}}
              raise ArgumentError.new("joins(:{{name.id}}) is not supported on polymorphic belongs_to (no single target table)")
            else
              previous_def
            end
          end
        {% else %}
        {% k = (class_name ? class_name.id.stringify : name.id.stringify.camelcase).id %}
        {% fk = (foreign_key ? foreign_key.id.stringify : "#{name.id}_id").id %}
        {% fk_str = (foreign_key ? foreign_key.id.stringify : "#{name.id}_id") %}
        def {{name.id}} : {{k}}?
          if __saci_assoc_cache.has_key?({{name.id.stringify}})
            return __saci_assoc_cache[{{name.id.stringify}}].as({{k}}?)
          end
          %fk_val = self.{{fk}}
          %fk_val.nil? ? nil : {{k}}.find(%fk_val)
        end

        {% if counter_cache %}
          def __saci_after_create : Nil
            previous_def
            %cc_fk = __saci_get_attr({{fk_str}})
            unless %cc_fk.nil?
              {% if counter_cache == true %}
                %cc_col = self.class.table_name + "_count"
              {% else %}
                %cc_col = {{counter_cache.id.stringify}}
              {% end %}
              Saci::Record.update_counter({{k}}.connection, {{k}}.table_name, {{k}}.primary_key_name, %cc_fk, %cc_col, 1_i64)
            end
          end

          def __saci_after_destroy : Nil
            previous_def
            %cc_fk = __saci_get_attr({{fk_str}})
            unless %cc_fk.nil?
              {% if counter_cache == true %}
                %cc_col = self.class.table_name + "_count"
              {% else %}
                %cc_col = {{counter_cache.id.stringify}}
              {% end %}
              Saci::Record.update_counter({{k}}.connection, {{k}}.table_name, {{k}}.primary_key_name, %cc_fk, %cc_col, -1_i64)
            end
          end
        {% end %}

        {% if touch %}
          def __saci_after_save : Nil
            previous_def
            %t_fk = __saci_get_attr({{fk_str}})
            unless %t_fk.nil?
              %t_cols = [] of String
              {% unless touch == true %}
                %t_cols << {{touch.id.stringify}}
              {% end %}
              %t_cols << "updated_at" if {{k}}.__saci_timestamps? && !%t_cols.includes?("updated_at")
              Saci::Record.touch_row({{k}}.connection, {{k}}.table_name, {{k}}.primary_key_name, %t_fk, %t_cols)
            end
          end

          def __saci_after_destroy : Nil
            previous_def
            %t_fk = __saci_get_attr({{fk_str}})
            unless %t_fk.nil?
              %t_cols = [] of String
              {% unless touch == true %}
                %t_cols << {{touch.id.stringify}}
              {% end %}
              %t_cols << "updated_at" if {{k}}.__saci_timestamps? && !%t_cols.includes?("updated_at")
              Saci::Record.touch_row({{k}}.connection, {{k}}.table_name, {{k}}.primary_key_name, %t_fk, %t_cols)
            end
          end
        {% end %}

        def self.__saci_preload_{{name.id}}(records : Array(Saci::Record::Base)) : Nil
          %ids = [] of Saci::Record::Value
          records.each do |%rec|
            %pfk = %rec.__saci_get_attr({{fk_str}})
            %ids << %pfk unless %pfk.nil?
          end
          %pmap = {} of Saci::Record::Value => {{k}}
          unless %ids.empty?
            %puniq = %ids.uniq
            %pph = Array(String).new(%puniq.size, "?").join(", ")
            %phad = Saci::Record.adapter_of({{k}}.connection)
            {{k}}.where(Saci::Record.quote({{k}}.primary_key_name, %phad) + " IN (" + %pph + ")", %puniq).to_a.each do |%t|
              %pmap[%t.__saci_get_attr({{k}}.primary_key_name)] = %t
            end
          end
          records.each do |%rec|
            %pfk = %rec.__saci_get_attr({{fk_str}})
            if %pfk.nil?
              %rec.__saci_set_assoc({{name.id.stringify}}, nil)
            elsif %found = %pmap[%pfk]?
              %rec.__saci_set_assoc({{name.id.stringify}}, %found)
            end
          end
        end

        def self.__saci_preload_assoc(records : Array(Saci::Record::Base), assoc_name : String) : Nil
          if assoc_name == {{name.id.stringify}}
            __saci_preload_{{name.id}}(records)
          else
            previous_def
          end
        end

        def self.__saci_assoc_kinds : Hash(String, Symbol)
          %kinds = previous_def.dup
          %kinds[{{name.id.stringify}}] = :belongs_to
          %kinds
        end

        def self.__saci_join_sql(assoc_name : String) : String?
          if assoc_name == {{name.id.stringify}}
            ad = Saci::Record.adapter_of(self.connection)
            base = Saci::Record.quote(self.table_name, ad)
            target = Saci::Record.quote({{k}}.table_name, ad)
            target_pk = Saci::Record.quote({{k}}.primary_key_name, ad)
            base_fk = Saci::Record.quote({{fk_str}}, ad)
            "INNER JOIN " + target + " ON " + target + "." + target_pk + " = " + base + "." + base_fk
          else
            previous_def
          end
        end
        {% end %}
      end

      # `has_many :posts` returns a chainable `Query`, Rails-relation-like:
      # `user.posts.where(published: true).to_a`.
      #
      # `has_many :tags, through: :taggings` traverses a join model
      # (e.g. Story -> tags through taggings): the join rows are fetched via
      # the `through` association, their `<source>_id` foreign keys are
      # collected (`source` defaults to the singular association name), and a
      # chainable `Query` on the target (`WHERE id IN (...)`) is returned.
      # Empty joins yield `Target.where("1 = 0")` (chainable, no rows).
      #
      # MACRO HYGIENE WARNING: `%fk_name` is bound from `{{...}}`, so it
      # must NEVER appear inside a `"#{}"` interpolation alongside a method
      # call — the interpreter folds it at expansion time and double-quotes
      # the value (`WHERE (""user_id"" = ?)`). String `+` keeps it runtime.
      # Likewise, bind macro strings with single `.stringify`, never
      # `.stringify.stringify` (the latter bakes quote chars into the value).
      macro has_many(name, class_name = nil, foreign_key = nil, through = nil, source = nil, dependent = nil, **_saci_opts)
        {% n = name.id.stringify %}
        {% sing = n.ends_with?("ies") ? n[0...-3] + "y" : (n.ends_with?("s") ? n[0...-1] : n) %}
        {% k = (class_name ? class_name.id.stringify : sing.camelcase).id %}
        {% as_opt = _saci_opts[:as] %}
        {% if as_opt %}
          {% iface = as_opt.id.stringify %}
          {% poly_fk = iface + "_id" %}
          {% poly_type = iface + "_type" %}
          def {{name.id}} : Saci::Record::Query({{k}})
            if __saci_assoc_cache.has_key?({{n}})
              cached = __saci_assoc_cache[{{n}}].as(Array(Saci::Record::Base)).map { |el| el.as({{k}}) }
              had = Saci::Record.adapter_of(self.class.connection)
              tval = self.class.name
              return {{k}}.where(Saci::Record.quote({{poly_fk}}, had) + " = ? AND " + Saci::Record.quote({{poly_type}}, had) + " = ?", __saci_get_attr(self.class.__saci_primary_key), tval).__saci_with_records(cached)
            end
            pkval = __saci_get_attr(self.class.__saci_primary_key)
            if pkval.nil?
              {{k}}.where("1 = 0")
            else
              had = Saci::Record.adapter_of(self.class.connection)
              tval = self.class.name
              {{k}}.where(Saci::Record.quote({{poly_fk}}, had) + " = ? AND " + Saci::Record.quote({{poly_type}}, had) + " = ?", pkval, tval)
            end
          end

          def self.__saci_preload_{{name.id}}(records : Array(Saci::Record::Base)) : Nil
            grouped = {} of Saci::Record::Value => Array(Saci::Record::Base)
            owner_pks = [] of Saci::Record::Value
            records.each do |rec|
              opk = rec.__saci_get_attr(__saci_primary_key)
              owner_pks << opk unless opk.nil?
            end
            unless owner_pks.empty?
              puniq = owner_pks.uniq
              pph = Array(String).new(puniq.size, "?").join(", ")
              phad = Saci::Record.adapter_of({{k}}.connection)
              tname = self.name
              binds = puniq.dup
              binds << tname
              {{k}}.where(Saci::Record.quote({{poly_fk}}, phad) + " IN (" + pph + ") AND " + Saci::Record.quote({{poly_type}}, phad) + " = ?", binds).to_a.each do |t|
                tfk = t.__saci_get_attr({{poly_fk}})
                unless tfk.nil?
                  (grouped[tfk] ||= [] of Saci::Record::Base) << t
                end
              end
            end
            records.each do |rec|
              opk = rec.__saci_get_attr(__saci_primary_key)
              list = opk.nil? ? [] of Saci::Record::Base : (grouped[opk]? || [] of Saci::Record::Base)
              rec.__saci_set_assoc({{n}}, list)
            end
          end

          def self.__saci_preload_assoc(records : Array(Saci::Record::Base), assoc_name : String) : Nil
            if assoc_name == {{n}}
              __saci_preload_{{name.id}}(records)
            else
              previous_def
            end
          end

          def self.__saci_assoc_kinds : Hash(String, Symbol)
            %kinds = previous_def.dup
            %kinds[{{n}}] = :has_many
            %kinds
          end

          def self.__saci_join_sql(assoc_name : String) : String?
            if assoc_name == {{n}}
              ad = Saci::Record.adapter_of(self.connection)
              base = Saci::Record.quote(self.table_name, ad)
              base_pk = Saci::Record.quote(self.__saci_primary_key, ad)
              target = Saci::Record.quote({{k}}.table_name, ad)
              fkq = Saci::Record.quote({{poly_fk}}, ad)
              typeq = Saci::Record.quote({{poly_type}}, ad)
              "INNER JOIN " + target + " ON " + target + "." + fkq + " = " + base + "." + base_pk + " AND " + target + "." + typeq + " = '" + self.name.gsub("'", "''") + "'"
            else
              previous_def
            end
          end

          def self.__saci_reset_counter(id : Saci::Record::Value, assoc_name : String) : Bool
            if assoc_name == {{n}}
              had = Saci::Record.adapter_of(self.connection)
              tname = self.name
              cnt = {{k}}.where(Saci::Record.quote({{poly_fk}}, had) + " = ? AND " + Saci::Record.quote({{poly_type}}, had) + " = ?", id, tname).count
              counter_col = {{k}}.table_name + "_count"
              unless __saci_column_names.any? { |(cname, _)| cname == counter_col }
                counter_col = {{n}} + "_count"
              end
              unless __saci_column_names.any? { |(cname, _)| cname == counter_col }
                raise Saci::Record::UnknownAttributeError.new("reset_counters: no counter column '#{counter_col}' on #{self.name}")
              end
              Saci::Record.exec_compat(connection, "UPDATE " + Saci::Record.quote(table_name, had) + " SET " + Saci::Record.quote(counter_col, had) + " = ? WHERE " + Saci::Record.quote(__saci_primary_key, had) + " = ?", [cnt] of Saci::Record::Value + [Saci::Record.to_db(id, had)] of Saci::Record::Value)
              true
            else
              previous_def
            end
          end
        {% elsif through %}
          {% through_call = through.id %}
          {% src = (source ? source.id.stringify : sing) %}
          {% src_fk = src + "_id" %}
          def {{name.id}} : Saci::Record::Query({{k}})
            %join_rows = self.{{through_call}}.to_a
            %fk_vals = [] of Saci::Record::Value
            %join_rows.each do |%jr|
              %fk_vals << %jr.__saci_get_attr({{src_fk}})
            end
            %ids = %fk_vals.select { |%v| !%v.nil? }
            if %ids.empty?
              {{k}}.where("1 = 0")
            else
              %ph = Array(String).new(%ids.size, "?").join(", ")
              %had = Saci::Record.adapter_of({{k}}.connection)
              {{k}}.where(Saci::Record.quote("id", %had) + " IN (" + %ph + ")", %ids)
            end
          end

          def self.__saci_assoc_kinds : Hash(String, Symbol)
            %kinds = previous_def.dup
            %kinds[{{n}}] = :through
            %kinds
          end

          def self.__saci_join_sql(assoc_name : String) : String?
            if assoc_name == {{n}}
              raise ArgumentError.new("joins(:{{name.id}}) is not supported on has_many :through (preload the join instead)")
            else
              previous_def
            end
          end
        {% else %}
          def {{name.id}} : Saci::Record::Query({{k}})
            if __saci_assoc_cache.has_key?({{n}})
              %cached = __saci_assoc_cache[{{n}}].as(Array(Saci::Record::Base)).map { |%el| %el.as({{k}}) }
              {% if foreign_key %}
                %fk_name = {{foreign_key.id.stringify}}
              {% else %}
                %fk_name = "#{Saci::Record::Inflector.underscore(self.class.name.split("::").last)}_id"
              {% end %}
              %had = Saci::Record.adapter_of(self.class.connection)
              return {{k}}.where(Saci::Record.quote(%fk_name, %had) + " = ?", __saci_get_attr(self.class.__saci_primary_key)).__saci_with_records(%cached)
            end
            {% if foreign_key %}
              %fk_name = {{foreign_key.id.stringify}}
            {% else %}
              %fk_name = "#{Saci::Record::Inflector.underscore(self.class.name.split("::").last)}_id"
            {% end %}
            %had = Saci::Record.adapter_of(self.class.connection)
            {{k}}.where(Saci::Record.quote(%fk_name, %had) + " = ?", __saci_get_attr(self.class.__saci_primary_key))
          end

          def self.__saci_preload_{{name.id}}(records : Array(Saci::Record::Base)) : Nil
            %grouped = {} of Saci::Record::Value => Array(Saci::Record::Base)
            %owner_pks = [] of Saci::Record::Value
            records.each do |%rec|
              %opk = %rec.__saci_get_attr(__saci_primary_key)
              %owner_pks << %opk unless %opk.nil?
            end
            unless %owner_pks.empty?
              %puniq = %owner_pks.uniq
              %pph = Array(String).new(%puniq.size, "?").join(", ")
              %phad = Saci::Record.adapter_of({{k}}.connection)
              {% if foreign_key %}
                %hfk = {{foreign_key.id.stringify}}
              {% else %}
                %hfk = "#{Saci::Record::Inflector.underscore(self.name.split("::").last)}_id"
              {% end %}
              {{k}}.where(Saci::Record.quote(%hfk, %phad) + " IN (" + %pph + ")", %puniq).to_a.each do |%t|
                %tfk = %t.__saci_get_attr(%hfk)
                unless %tfk.nil?
                  (%grouped[%tfk] ||= [] of Saci::Record::Base) << %t
                end
              end
            end
            records.each do |%rec|
              %opk = %rec.__saci_get_attr(__saci_primary_key)
              %list = %opk.nil? ? [] of Saci::Record::Base : (%grouped[%opk]? || [] of Saci::Record::Base)
              %rec.__saci_set_assoc({{n}}, %list)
            end
          end

          def self.__saci_preload_assoc(records : Array(Saci::Record::Base), assoc_name : String) : Nil
            if assoc_name == {{n}}
              __saci_preload_{{name.id}}(records)
            else
              previous_def
            end
          end

          def self.__saci_assoc_kinds : Hash(String, Symbol)
            %kinds = previous_def.dup
            %kinds[{{n}}] = :has_many
            %kinds
          end

          def self.__saci_join_sql(assoc_name : String) : String?
            if assoc_name == {{n}}
              ad = Saci::Record.adapter_of(self.connection)
              base = Saci::Record.quote(self.table_name, ad)
              base_pk = Saci::Record.quote(self.__saci_primary_key, ad)
              target = Saci::Record.quote({{k}}.table_name, ad)
              {% if foreign_key %}
                fkq = Saci::Record.quote({{foreign_key.id.stringify}}, ad)
              {% else %}
                fkq = Saci::Record.quote(Saci::Record::Inflector.underscore(self.name.split("::").last) + "_id", ad)
              {% end %}
              "INNER JOIN " + target + " ON " + target + "." + fkq + " = " + base + "." + base_pk
            else
              previous_def
            end
          end

          def self.__saci_reset_counter(id : Saci::Record::Value, assoc_name : String) : Bool
            if assoc_name == {{n}}
              had = Saci::Record.adapter_of(self.connection)
              {% if foreign_key %}
                fkcol = {{foreign_key.id.stringify}}
              {% else %}
                fkcol = Saci::Record::Inflector.underscore(self.name.split("::").last) + "_id"
              {% end %}
              cnt = {{k}}.where(Saci::Record.quote(fkcol, had) + " = ?", id).count
              counter_col = {{k}}.table_name + "_count"
              unless __saci_column_names.any? { |(cname, _)| cname == counter_col }
                counter_col = {{n}} + "_count"
              end
              unless __saci_column_names.any? { |(cname, _)| cname == counter_col }
                raise Saci::Record::UnknownAttributeError.new("reset_counters: no counter column '#{counter_col}' on #{self.name}")
              end
              Saci::Record.exec_compat(connection, "UPDATE " + Saci::Record.quote(table_name, had) + " SET " + Saci::Record.quote(counter_col, had) + " = ? WHERE " + Saci::Record.quote(__saci_primary_key, had) + " = ?", [cnt] of Saci::Record::Value + [Saci::Record.to_db(id, had)] of Saci::Record::Value)
              true
            else
              previous_def
            end
          end
        {% end %}
        {% if dependent %}
          def __saci_run_dependents : Nil
            previous_def
            {% if as_opt %}
              {% if dependent.id.stringify == "destroy" %}
                self.{{name.id}}.to_a.each(&.destroy)
              {% elsif dependent.id.stringify == "delete_all" %}
                self.{{name.id}}.delete_all
              {% elsif dependent.id.stringify == "nullify" %}
                poly_pk = __saci_get_attr(self.class.__saci_primary_key)
                unless poly_pk.nil?
                  poly_had = Saci::Record.adapter_of(self.class.connection)
                  poly_tname = self.class.name
                  Saci::Record.exec_compat(
                    {{k}}.connection,
                    "UPDATE " + Saci::Record.quote({{k}}.table_name, poly_had) +
                      " SET " + Saci::Record.quote({{poly_fk}}, poly_had) + " = NULL, " + Saci::Record.quote({{poly_type}}, poly_had) + " = NULL" +
                      " WHERE " + Saci::Record.quote({{poly_fk}}, poly_had) + " = ? AND " + Saci::Record.quote({{poly_type}}, poly_had) + " = ?",
                    [Saci::Record.to_db(poly_pk, poly_had), poly_tname] of Saci::Record::Value)
                end
              {% elsif dependent.id.stringify == "restrict_with_exception" %}
                if self.{{name.id}}.exists?
                  raise Saci::Record::DeleteRestrictionError.new("Cannot delete #{self.class} because dependent {{name.id}} exist")
                end
              {% else %}
                raise Saci::Record::RecordNotSaved.new("Unsupported dependent option {{dependent}} on {{name.id}} (supported: :destroy, :delete_all, :nullify, :restrict_with_exception)")
              {% end %}
            {% elsif through %}
              %dep_q = self.{{through_call}}
              {% if dependent.id.stringify == "destroy" %}
                %dep_q.to_a.each(&.destroy)
              {% elsif dependent.id.stringify == "delete_all" %}
                %dep_q.delete_all
              {% elsif dependent.id.stringify == "nullify" %}
                raise Saci::Record::RecordNotSaved.new("dependent: :nullify is not supported on has_many :through ({{name.id}})")
              {% elsif dependent.id.stringify == "restrict_with_exception" %}
                if self.{{through_call}}.exists?
                  raise Saci::Record::DeleteRestrictionError.new("Cannot delete #{self.class} because dependent {{name.id}} exist")
                end
              {% else %}
                raise Saci::Record::RecordNotSaved.new("Unsupported dependent option {{dependent}} on {{name.id}} (supported: :destroy, :delete_all, :nullify, :restrict_with_exception)")
              {% end %}
            {% else %}
              {% if dependent.id.stringify == "destroy" %}
                self.{{name.id}}.to_a.each(&.destroy)
              {% elsif dependent.id.stringify == "delete_all" %}
                self.{{name.id}}.delete_all
              {% elsif dependent.id.stringify == "nullify" %}
                %pk_val = __saci_get_attr(self.class.__saci_primary_key)
                unless %pk_val.nil?
                  {% if foreign_key %}
                    %fk_col = {{foreign_key.id.stringify}}
                  {% else %}
                    %fk_col = "#{Saci::Record::Inflector.underscore(self.class.name.split("::").last)}_id"
                  {% end %}
                  %had = Saci::Record.adapter_of(self.class.connection)
                  Saci::Record.exec_compat(
                    {{k}}.connection,
                    "UPDATE " + Saci::Record.quote({{k}}.table_name, %had) +
                      " SET " + Saci::Record.quote(%fk_col, %had) + " = NULL" +
                      " WHERE " + Saci::Record.quote(%fk_col, %had) + " = ?",
                    [%pk_val] of Saci::Record::Value)
                end
              {% elsif dependent.id.stringify == "restrict_with_exception" %}
                if self.{{name.id}}.exists?
                  raise Saci::Record::DeleteRestrictionError.new("Cannot delete #{self.class} because dependent {{name.id}} exist")
                end
              {% else %}
                raise Saci::Record::RecordNotSaved.new("Unsupported dependent option {{dependent}} on {{name.id}} (supported: :destroy, :delete_all, :nullify, :restrict_with_exception)")
              {% end %}
            {% end %}
          end
        {% end %}
      end

      # `has_one :moderation` returns the first matching record or nil
      # (foreign key defaults to `<owner>_id` on the target, like `has_many`).
      # Honors `includes` preloading.
      macro has_one(name, class_name = nil, foreign_key = nil, dependent = nil)
        {% n = name.id.stringify %}
        {% k = (class_name ? class_name.id.stringify : n.camelcase).id %}
        def {{name.id}} : {{k}}?
          if __saci_assoc_cache.has_key?({{n}})
            return __saci_assoc_cache[{{n}}].as({{k}}?)
          end
          {% if foreign_key %}
            %fk_name = {{foreign_key.id.stringify}}
          {% else %}
            %fk_name = "#{Saci::Record::Inflector.underscore(self.class.name.split("::").last)}_id"
          {% end %}
          %pk_val = __saci_get_attr(self.class.__saci_primary_key)
          if %pk_val.nil?
            nil
          else
            %had = Saci::Record.adapter_of(self.class.connection)
            {{k}}.where(Saci::Record.quote(%fk_name, %had) + " = ?", %pk_val).first
          end
        end

        def self.__saci_preload_{{name.id}}(records : Array(Saci::Record::Base)) : Nil
          %owner_pks = [] of Saci::Record::Value
          records.each do |%rec|
            %opk = %rec.__saci_get_attr(__saci_primary_key)
            %owner_pks << %opk unless %opk.nil?
          end
          %found = {} of Saci::Record::Value => {{k}}
          unless %owner_pks.empty?
            %puniq = %owner_pks.uniq
            %pph = Array(String).new(%puniq.size, "?").join(", ")
            %phad = Saci::Record.adapter_of({{k}}.connection)
            {% if foreign_key %}
              %hfk = {{foreign_key.id.stringify}}
            {% else %}
              %hfk = "#{Saci::Record::Inflector.underscore(self.name.split("::").last)}_id"
            {% end %}
            {{k}}.where(Saci::Record.quote(%hfk, %phad) + " IN (" + %pph + ")", %puniq).to_a.each do |%t|
              %tfk = %t.__saci_get_attr(%hfk)
              unless %tfk.nil?
                %found[%tfk] = %t unless %found.has_key?(%tfk)
              end
            end
          end
          records.each do |%rec|
            %opk = %rec.__saci_get_attr(__saci_primary_key)
            if %opk.nil?
              %rec.__saci_set_assoc({{n}}, nil)
            elsif %one = %found[%opk]?
              %rec.__saci_set_assoc({{n}}, %one)
            end
          end
        end

        def self.__saci_preload_assoc(records : Array(Saci::Record::Base), assoc_name : String) : Nil
          if assoc_name == {{n}}
            __saci_preload_{{name.id}}(records)
          else
            previous_def
          end
        end

        def self.__saci_assoc_kinds : Hash(String, Symbol)
          %kinds = previous_def.dup
          %kinds[{{n}}] = :has_one
          %kinds
        end

        def self.__saci_join_sql(assoc_name : String) : String?
          if assoc_name == {{n}}
            ad = Saci::Record.adapter_of(self.connection)
            base = Saci::Record.quote(self.table_name, ad)
            base_pk = Saci::Record.quote(self.__saci_primary_key, ad)
            target = Saci::Record.quote({{k}}.table_name, ad)
            {% if foreign_key %}
              fkq = Saci::Record.quote({{foreign_key.id.stringify}}, ad)
            {% else %}
              fkq = Saci::Record.quote(Saci::Record::Inflector.underscore(self.name.split("::").last) + "_id", ad)
            {% end %}
            "INNER JOIN " + target + " ON " + target + "." + fkq + " = " + base + "." + base_pk
          else
            previous_def
          end
        end
        {% if dependent %}
          def __saci_run_dependents : Nil
            previous_def
            {% if dependent.id.stringify == "destroy" %}
              if %one = self.{{name.id}}
                %one.destroy
              end
            {% elsif dependent.id.stringify == "delete_all" %}
              %pk_val = __saci_get_attr(self.class.__saci_primary_key)
              unless %pk_val.nil?
                {% if foreign_key %}
                  %fk_col = {{foreign_key.id.stringify}}
                {% else %}
                  %fk_col = "#{Saci::Record::Inflector.underscore(self.class.name.split("::").last)}_id"
                {% end %}
                %had = Saci::Record.adapter_of(self.class.connection)
                Saci::Record.exec_compat(
                  {{k}}.connection,
                  "DELETE FROM " + Saci::Record.quote({{k}}.table_name, %had) +
                    " WHERE " + Saci::Record.quote(%fk_col, %had) + " = ?",
                  [%pk_val] of Saci::Record::Value)
              end
            {% elsif dependent.id.stringify == "nullify" %}
              %pk_val = __saci_get_attr(self.class.__saci_primary_key)
              unless %pk_val.nil?
                {% if foreign_key %}
                  %fk_col = {{foreign_key.id.stringify}}
                {% else %}
                  %fk_col = "#{Saci::Record::Inflector.underscore(self.class.name.split("::").last)}_id"
                {% end %}
                %had = Saci::Record.adapter_of(self.class.connection)
                Saci::Record.exec_compat(
                  {{k}}.connection,
                  "UPDATE " + Saci::Record.quote({{k}}.table_name, %had) +
                    " SET " + Saci::Record.quote(%fk_col, %had) + " = NULL" +
                    " WHERE " + Saci::Record.quote(%fk_col, %had) + " = ?",
                  [%pk_val] of Saci::Record::Value)
              end
            {% elsif dependent.id.stringify == "restrict_with_exception" %}
              unless self.{{name.id}}.nil?
                raise Saci::Record::DeleteRestrictionError.new("Cannot delete #{self.class} because dependent {{name.id}} exists")
              end
            {% else %}
              raise Saci::Record::RecordNotSaved.new("Unsupported dependent option {{dependent}} on {{name.id}} (supported: :destroy, :delete_all, :nullify, :restrict_with_exception)")
            {% end %}
          end
        {% end %}
      end
    end
  end
end
