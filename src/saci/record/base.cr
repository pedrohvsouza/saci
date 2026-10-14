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
    # `Bool`, `Time`, `Bytes` (all automatically nilable).
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
          __saci_run_validations(errors)
        end

        def __saci_apply_defaults : Nil
          super
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
      macro column(decl, primary = false, default = nil)
        {% ctype = decl.type.stringify %}
        {% if ctype.ends_with?("?") %}
          {% raise "Saci::Record.column #{decl.var}: declare a non-nilable type (nilability is automatic). Got: #{ctype}" %}
        {% end %}
        {% unless ["Int32", "Int64", "Float64", "String", "Bool", "Time", "Bytes"].includes?(ctype) %}
          {% raise "Saci::Record.column #{decl.var}: unsupported type #{ctype}. Supported: Int32, Int64, Float64, String, Bool, Time, Bytes." %}
        {% end %}
        @{{decl.var.id}} : {{decl.type}}?

        def {{decl.var.id}} : {{decl.type}}?
          @{{decl.var.id}}
        end

        def {{decl.var.id}}=(value : {{decl.type}}?) : {{decl.type}}?
          @{{decl.var.id}} = value
        end

        def self.__saci_column_names : Array(Tuple(String, String))
          previous_def + [{ {{decl.var.stringify}}, {{ctype}} }]
        end

        def __saci_set_attr(key : String, value : Saci::Record::Value) : Bool
          if key == {{decl.var.stringify}}
            {% if ctype == "String" %}
              @{{decl.var.id}} = value.nil? ? nil : value.to_s
            {% elsif ctype == "Int64" %}
              @{{decl.var.id}} = Saci::Record.to_i64(value)
            {% elsif ctype == "Int32" %}
              @{{decl.var.id}} = Saci::Record.to_i32(value)
            {% elsif ctype == "Float64" %}
              @{{decl.var.id}} = Saci::Record.to_f64(value)
            {% elsif ctype == "Bool" %}
              @{{decl.var.id}} = Saci::Record.to_bool(value)
            {% elsif ctype == "Time" %}
              @{{decl.var.id}} = value.is_a?(Time) ? value : nil
            {% elsif ctype == "Bytes" %}
              @{{decl.var.id}} = value.is_a?(Bytes) ? value : nil
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

      def run_validations(errors : Errors) : Nil
      end

      def __saci_apply_defaults : Nil
      end

      # -- construction -----------------------------------------------------

      @new_record : Bool = true
      @destroyed : Bool = false
      @errors : Errors? = nil

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

      # -- persistence ------------------------------------------------------

      def save : Bool
        return false unless valid?
        touch_timestamps
        if new_record?
          insert_record
        else
          update_record
        end
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

      def destroy : Bool
        return false if new_record? || destroyed?
        pk = self.class.__saci_primary_key
        pk_val = __saci_get_attr(pk)
        return false if pk_val.nil?
        conn = self.class.connection
        ad = Record.adapter_of(conn)
        Record.exec_compat(conn, "DELETE FROM #{Record.quote(self.class.table_name, ad)} WHERE #{Record.quote(pk, ad)} = ?", [Record.to_db(pk_val, ad)] of Value)
        @destroyed = true
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

      def valid? : Bool
        errors.clear
        run_validations(errors)
        errors.empty?
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
            # pooled connection) — never via a separate query.
            res = Record.exec_compat(conn, "INSERT INTO #{table} DEFAULT VALUES")
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

      protected def __saci_mark_persisted! : Nil
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

      def self.delete_all : Int64
        all.delete_all
      end

      # -- validations ------------------------------------------------------

      macro validates(col, presence = nil, min_length = nil, max_length = nil, format = nil, uniqueness = nil)
        def __saci_run_validations(errors : Saci::Record::Errors) : Nil
          previous_def
          {% if presence %}
            %present{{col.id}} = self.{{col.id}}
            if %present{{col.id}}.nil? || (%present{{col.id}}.is_a?(String) && %present{{col.id}}.as(String).strip.empty?)
              errors.add({{col.id.stringify}}, "can't be blank")
            end
          {% end %}
          {% if min_length || max_length %}
            %len_raw{{col.id}} = self.{{col.id}}
            %len_str{{col.id}} = %len_raw{{col.id}}.nil? ? nil : %len_raw{{col.id}}.to_s
            unless %len_str{{col.id}}.nil?
              {% if min_length %}
                if %len_str{{col.id}}.not_nil!.size < {{min_length}}
                  errors.add({{col.id.stringify}}, "is too short (minimum is {{min_length}} characters)")
                end
              {% end %}
              {% if max_length %}
                if %len_str{{col.id}}.not_nil!.size > {{max_length}}
                  errors.add({{col.id.stringify}}, "is too long (maximum is {{max_length}} characters)")
                end
              {% end %}
            end
          {% end %}
          {% if format %}
            %fmt{{col.id}} = self.{{col.id}}
            if %fmt{{col.id}} && (%fmt{{col.id}}.to_s !~ {{format}})
              errors.add({{col.id.stringify}}, "is invalid")
            end
          {% end %}
          {% if uniqueness %}
            {% if uniqueness.is_a?(ArrayLiteral) %}
              {% scopes = uniqueness %}
            {% elsif uniqueness.is_a?(SymbolLiteral) %}
              {% scopes = [uniqueness] %}
            {% else %}
              {% scopes = [] of ASTNode %}
            {% end %}
            %uniq{{col.id}} = self.{{col.id}}
            unless %uniq{{col.id}}.nil?
              %uad{{col.id}} = Saci::Record.adapter_of(self.class.connection)
              %uscope{{col.id}} = self.class.where(Saci::Record.quote({{col.id.stringify}}, %uad{{col.id}}) + " = ?", Saci::Record.to_db(%uniq{{col.id}}, %uad{{col.id}}))
              {% for s in scopes %}
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
      # dangling — like Rails).
      macro belongs_to(name, class_name = nil, foreign_key = nil)
        {% k = (class_name ? class_name.id.stringify : name.id.stringify.camelcase).id %}
        {% fk = (foreign_key ? foreign_key.id.stringify : "#{name.id}_id").id %}
        def {{name.id}} : {{k}}?
          %fk_val = self.{{fk}}
          %fk_val.nil? ? nil : {{k}}.find(%fk_val)
        end
      end

      # `has_many :posts` returns a chainable `Query`, Rails-relation-like:
      # `user.posts.where(published: true).to_a`.
      #
      # MACRO HYGIENE WARNING: `%fk_name` is bound from `{{...}}`, so it
      # must NEVER appear inside a `"#{}"` interpolation alongside a method
      # call — the interpreter folds it at expansion time and double-quotes
      # the value (`WHERE (""user_id"" = ?)`). String `+` keeps it runtime.
      # Likewise, bind macro strings with single `.stringify`, never
      # `.stringify.stringify` (the latter bakes quote chars into the value).
      macro has_many(name, class_name = nil, foreign_key = nil)
        {% n = name.id.stringify %}
        {% sing = n.ends_with?("ies") ? n[0...-3] + "y" : (n.ends_with?("s") ? n[0...-1] : n) %}
        {% k = (class_name ? class_name.id.stringify : sing.camelcase).id %}
        def {{name.id}} : Saci::Record::Query({{k}})
          {% if foreign_key %}
            %fk_name = {{foreign_key.id.stringify}}
          {% else %}
            %fk_name = "#{Saci::Record::Inflector.underscore(self.class.name.split("::").last)}_id"
          {% end %}
          %had = Saci::Record.adapter_of(self.class.connection)
          {{k}}.where(Saci::Record.quote(%fk_name, %had) + " = ?", __saci_get_attr(self.class.__saci_primary_key))
        end
      end
    end
  end
end
