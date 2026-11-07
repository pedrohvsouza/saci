require "./native_types"

module Saci
  module Record
    # Column definition used by `TableDefinition` and `add_column`.
    # Stores the *logical* type; SQL renders per adapter (`to_sql`).
    # `enum_values` serves `:enum` columns; `precision` (0..6) serves
    # `:datetime`. `to_sql` takes the owning table so PostgreSQL enum
    # columns can reference their standalone type
    # (`Migration.enum_type_name`).
    #
    # Extended types (`:uuid`, `:binary`, `:hstore`, …) are rendered by
    # `NativeTypes`; `default_sql` carries a raw SQL default expression
    # (e.g. `"gen_random_uuid()"`), `subtype` serves `:range`, `size`
    # serves `:bit`/`:bit_varying`, and `generated_as`/`stored` render
    # generated columns (`t.virtual`).
    struct ColumnDef
      getter name : String
      getter logical_type : Symbol
      getter null : Bool
      getter default_value : Value
      getter primary_key : Bool
      getter enum_values : Array(String)?
      getter precision : Int32?
      getter scale : Int32?
      getter default_sql : String?
      getter subtype : Symbol?
      getter size : Int32?
      getter generated_as : String?
      getter stored : Bool

      def initialize(@name, @logical_type, @null, @default_value, @primary_key, @enum_values : Array(String)? = nil, @precision : Int32? = nil, @scale : Int32? = nil, *, @default_sql : String? = nil, @subtype : Symbol? = nil, @size : Int32? = nil, @generated_as : String? = nil, @stored : Bool = false)
      end

      def to_sql(adapter : Adapter = :sqlite, table : String? = nil) : String
        String.build do |s|
          enum_type = table ? Migration.enum_type_name(table, @name) : nil
          type_sql = if NativeTypes.extended?(@logical_type)
                       NativeTypes.db_type(@logical_type, adapter, @subtype, @size)
                     else
                       Record.db_type(@logical_type, adapter, @enum_values, enum_type, @precision, @scale)
                     end
          s << "#{Record.quote(@name, adapter)} #{type_sql}"
          if @primary_key
            # Only integer `:serial` primary keys auto-increment. UUID
            # primary keys are plain `PRIMARY KEY` everywhere (PostgreSQL
            # additionally gets a `gen_random_uuid()` default below).
            case adapter
            when :postgres
              s << " PRIMARY KEY"
            when :mysql
              s << (@logical_type == :serial ? " AUTO_INCREMENT PRIMARY KEY" : " PRIMARY KEY")
            else
              s << (@logical_type == :serial ? " PRIMARY KEY AUTOINCREMENT" : " PRIMARY KEY")
            end
          end
          s << " NOT NULL" unless @null
          if ga = @generated_as
            # Generated columns cannot carry a DEFAULT.
            stored_sql = (@stored || adapter == :postgres) ? "STORED" : "VIRTUAL"
            s << " GENERATED ALWAYS AS (#{ga}) #{stored_sql}"
          elsif d = @default_sql
            s << " DEFAULT #{d}"
          elsif @logical_type == :uuid && @primary_key && adapter == :postgres && @default_value.nil?
            # Built in since PostgreSQL 13; older servers need pgcrypto.
            s << " DEFAULT gen_random_uuid()"
          elsif d = Record.column_default_sql(@default_value, adapter)
            s << " DEFAULT #{d}"
          end
        end
      end
    end

    # A foreign key declared inside `create_table` (emitted as a table-level
    # `FOREIGN KEY ... REFERENCES ...` clause so SQLite parses it at
    # CREATE time; valid on PostgreSQL/MySQL too).
    struct TableForeignKey
      getter column : String
      getter to_table : String
      getter on_delete : Symbol?
      getter name : String?
      getter deferrable : Symbol?

      def initialize(@column, @to_table, @on_delete, @name, @deferrable : Symbol? = nil)
      end
    end

    # A CHECK constraint declared inside `create_table` (table-level, so
    # SQLite accepts it at CREATE time).
    struct TableCheck
      getter expression : String
      getter name : String?

      def initialize(@expression, @name : String? = nil)
      end
    end

    # An index declared inside `create_table` (`t.index`), executed after
    # the table has been created.
    struct TableIndex
      getter columns : Array(String)
      getter name : String?
      getter unique : Bool

      def initialize(@columns, @name = nil, @unique = false)
      end
    end

    # Schema builder yielded to `create_table`.
    #
    # ```
    # create_table :posts do |t|
    #   t.string :title, null: false
    #   t.text :body
    #   t.integer :user_id
    #   t.boolean :published, default: false
    #   t.timestamps
    # end
    # ```
    class TableDefinition
      getter columns : Array(ColumnDef)
      getter foreign_keys : Array(TableForeignKey)
      getter pending_indexes : Array(String)
      getter checks : Array(TableCheck)
      getter defined_indexes : Array(TableIndex)

      def initialize
        @columns = [] of ColumnDef
        @foreign_keys = [] of TableForeignKey
        @pending_indexes = [] of String
        @checks = [] of TableCheck
        @defined_indexes = [] of TableIndex
      end

      def string(name : String | Symbol, null : Bool = true, default : Value = nil)
        add(name, :string, null, default)
      end

      def text(name : String | Symbol, null : Bool = true, default : Value = nil)
        add(name, :text, null, default)
      end

      def integer(name : String | Symbol, null : Bool = true, default : Value = nil)
        add(name, :integer, null, default)
      end

      def bigint(name : String | Symbol, null : Bool = true, default : Value = nil)
        add(name, :bigint, null, default)
      end

      def float(name : String | Symbol, null : Bool = true, default : Value = nil)
        add(name, :float, null, default)
      end

      def decimal(name : String | Symbol, null : Bool = true, default : Value = nil, precision : Int32? = nil, scale : Int32? = nil)
        if p = precision
          unless 0 <= p <= 38
            raise ArgumentError.new("decimal #{name}: precision #{p} is out of range (expected 0..38)")
          end
        end
        @columns << ColumnDef.new(name.to_s, :decimal, null, default, false, nil, precision, scale)
      end

      def date(name : String | Symbol, null : Bool = true, default : Value = nil)
        add(name, :date, null, default)
      end

      def json(name : String | Symbol, null : Bool = true, default : Value = nil)
        add(name, :json, null, default)
      end

      def boolean(name : String | Symbol, null : Bool = true, default : Value = nil)
        add(name, :boolean, null, default)
      end

      # See `NativeTypes` for the adapter matrix.
      #
      # `default:` accepts a value, `:gen_random_uuid` (translated to the
      # PostgreSQL function) or a `Proc(String)` returning raw SQL. The
      # explicit `default_sql:` wins.
      def uuid(name : String | Symbol, null : Bool = true, default : Value | Symbol | Proc(String) = nil, *, default_sql : String? = nil, primary_key : Bool = false)
        value : Value = nil
        sql = default_sql
        case default
        when Nil
          # no default
        when Symbol
          sql ||= default == :gen_random_uuid ? "gen_random_uuid()" : default.to_s
        when Proc(String)
          sql ||= default.call
        else
          value = default
        end
        @columns << ColumnDef.new(name.to_s, :uuid, primary_key ? false : null, value, primary_key, default_sql: sql)
      end

      # `t.binary`/`t.bytea`: `BYTEA` on PostgreSQL, `BLOB` elsewhere.
      # Assign/read `Bytes` (the ORM already maps `Bytes` in `Value`).
      def binary(name : String | Symbol, null : Bool = true, default : Value = nil)
        @columns << ColumnDef.new(name.to_s, :binary, null, default, false)
      end

      def bytea(name : String | Symbol, null : Bool = true, default : Value = nil)
        @columns << ColumnDef.new(name.to_s, :bytea, null, default, false)
      end

      def hstore(name : String | Symbol, null : Bool = true, default : Value = nil)
        @columns << ColumnDef.new(name.to_s, :hstore, null, default, false)
      end

      def inet(name : String | Symbol, null : Bool = true, default : Value = nil)
        @columns << ColumnDef.new(name.to_s, :inet, null, default, false)
      end

      def cidr(name : String | Symbol, null : Bool = true, default : Value = nil)
        @columns << ColumnDef.new(name.to_s, :cidr, null, default, false)
      end

      def macaddr(name : String | Symbol, null : Bool = true, default : Value = nil)
        @columns << ColumnDef.new(name.to_s, :macaddr, null, default, false)
      end

      def interval(name : String | Symbol, null : Bool = true, default : Value = nil)
        @columns << ColumnDef.new(name.to_s, :interval, null, default, false)
      end

      def money(name : String | Symbol, null : Bool = true, default : Value = nil)
        @columns << ColumnDef.new(name.to_s, :money, null, default, false)
      end

      def bit(name : String | Symbol, null : Bool = true, default : Value = nil, *, size : Int32? = nil)
        @columns << ColumnDef.new(name.to_s, :bit, null, default, false, size: size)
      end

      def bit_varying(name : String | Symbol, null : Bool = true, default : Value = nil, *, size : Int32? = nil)
        @columns << ColumnDef.new(name.to_s, :bit_varying, null, default, false, size: size)
      end

      def point(name : String | Symbol, null : Bool = true, default : Value = nil)
        @columns << ColumnDef.new(name.to_s, :point, null, default, false)
      end

      # PostgreSQL range column. `subtype:` selects the range type
      # (`:int4`, `:int8`, `:num`, `:ts`, `:tstz`, `:date`); SQLite/MySQL
      # store the range literal as text.
      def range(name : String | Symbol, subtype : Symbol = :int4, null : Bool = true, default : Value = nil)
        @columns << ColumnDef.new(name.to_s, :range, null, default, false, subtype: subtype)
      end

      def xml(name : String | Symbol, null : Bool = true, default : Value = nil)
        @columns << ColumnDef.new(name.to_s, :xml, null, default, false)
      end

      def oid(name : String | Symbol, null : Bool = true, default : Value = nil)
        @columns << ColumnDef.new(name.to_s, :oid, null, default, false)
      end

      # Generic column helper: `t.column :token, :uuid`.
      def column(name : String | Symbol, type : Symbol, null : Bool = true, default : Value = nil, values : Array(String)? = nil, precision : Int32? = nil, scale : Int32? = nil, *, default_sql : String? = nil, subtype : Symbol? = nil, size : Int32? = nil, generated_as : String? = nil, stored : Bool = false, primary_key : Bool = false)
        if type == :enum
          vals = values
          if vals.nil? || vals.empty?
            raise ArgumentError.new("enum #{name}: values must not be empty")
          end
        end
        if p = precision
          unless 0 <= p <= 6
            raise ArgumentError.new("#{name}: precision #{p} is out of range (expected 0..6)")
          end
        end
        @columns << ColumnDef.new(name.to_s, type, null, default, primary_key, values, precision, scale,
          default_sql: default_sql, subtype: subtype, size: size, generated_as: generated_as, stored: stored)
      end

      # Generated/virtual column:
      # `t.virtual :full_name, type: :string, expression: "first || ' ' || last", stored: true`.
      # PostgreSQL always renders STORED (it has no VIRTUAL columns);
      # SQLite/MySQL honour `stored: false` with VIRTUAL.
      def virtual(name : String | Symbol, type : Symbol, expression : String, stored : Bool = false, null : Bool = true)
        column(name, type, null: null, generated_as: expression, stored: stored)
      end

      # Alias matching PostgreSQL's terminology.
      def generated(name : String | Symbol, type : Symbol, expression : String, stored : Bool = true, null : Bool = true)
        virtual(name, type, expression, stored, null)
      end

      # Index created after CREATE TABLE. `t.index :email, unique: true`,
      # `t.index [:user_id, :created_at], name: "idx"`.
      def index(cols : String | Symbol | Array(String | Symbol), name : String? = nil, unique : Bool = false)
        list = cols.is_a?(Array) ? cols.map(&.to_s) : [cols.to_s]
        @defined_indexes << TableIndex.new(list, name, unique)
      end

      # Check constraint emitted inside CREATE TABLE (works on SQLite,
      # PostgreSQL and MySQL). `t.check_constraint "price > 0", name: "price_positive"`.
      def check_constraint(expression : String, name : String? = nil)
        @checks << TableCheck.new(expression, name)
      end

      def datetime(name : String | Symbol, null : Bool = true, default : Value = nil, precision : Int32? = nil)
        if p = precision
          unless 0 <= p <= 6
            raise ArgumentError.new("datetime #{name}: precision #{p} is out of range (expected 0..6)")
          end
        end
        @columns << ColumnDef.new(name.to_s, :datetime, null, default, false, nil, precision)
      end

      # PostgreSQL enum column (`t.enum :status, values: ["draft",
      # "published"]`). Creates a standalone type named
      # `<table>_<column>_enum` on PostgreSQL (idempotently — reruns keep
      # the existing type); renders `ENUM(...)` inline on MySQL and `TEXT`
      # on SQLite. The model column stays `String`; on SQLite enforce the
      # set with `validates :status, inclusion: {in: [...]}` (nothing
      # enforces it at the DB level there).
      def enum(name : String | Symbol, values : Array(String), null : Bool = true, default : Value = nil)
        if values.empty?
          raise ArgumentError.new("enum #{name}: values must not be empty")
        end
        @columns << ColumnDef.new(name.to_s, :enum, null, default, false, values, nil)
      end

      # String array column (`column tags : Array(String)` on the model).
      # PostgreSQL stores `TEXT[]` (bound as a native PG array); MySQL and
      # SQLite store JSON-encoded text (like `:json`). Assign a new array
      # to change it (in-place mutation is not tracked).
      def string_array(name : String | Symbol, null : Bool = true, default : Value = nil)
        @columns << ColumnDef.new(name.to_s, :string_array, null, default, false, nil, nil)
      end

      # Rails-like `t.timestamps` (NOT NULL, ORM maintains them on save).
      # `precision:` (0..6) renders `TIMESTAMP(p)` on PostgreSQL and
      # `DATETIME(fsp)` on MySQL; SQLite ignores it (stores RFC3339 text).
      def timestamps(precision : Int32? = nil)
        if p = precision
          unless 0 <= p <= 6
            raise ArgumentError.new("timestamps: precision #{p} is out of range (expected 0..6)")
          end
        end
        @columns << ColumnDef.new("created_at", :datetime, false, nil, false, nil, precision)
        @columns << ColumnDef.new("updated_at", :datetime, false, nil, false, nil, precision)
      end

      # Rails-like `t.references :user`: a `bigint` `<name>_id` column plus
      # an optional index and an optional foreign key.
      #
      # `foreign_key:` defaults to `false` (explicit, documented): unlike
      # Rails 5+ (which defaults to true), Saci never adds a constraint you
      # did not ask for — FKs lock writes and can surprise on large tables.
      # Pass `foreign_key: true` for `REFERENCES <plural>(id)`, or a Symbol
      # for a custom target table (`foreign_key: :accounts`). `to_table:`
      # overrides the target explicitly; `on_delete:` is `:cascade`
      # (`CASCADE`), `:nullify` (`SET NULL`), `:restrict` (`RESTRICT`) or
      # `:no_action` (`NO ACTION`). `index:` (default true) creates a plain
      # index on the `<name>_id` column after `CREATE TABLE`.
      def references(name : String | Symbol, foreign_key : Bool | Symbol | Nil = false, null : Bool = true, index : Bool = true, to_table : String | Symbol | Nil = nil, on_delete : Symbol? = nil, *, type : Symbol = :bigint, polymorphic : Bool = false, deferrable : Symbol? = nil)
        col = "#{name}_id"
        add(col, type, null, nil)
        if polymorphic
          # Polymorphic references carry `<name>_type` (class name) and
          # cannot have a database foreign key. Index both columns, the
          # usual lookup pattern.
          add("#{name}_type", :string, null, nil)
          @defined_indexes << TableIndex.new([col, "#{name}_type"], nil, false) if index
        else
          @pending_indexes << col if index
        end
        if fk = foreign_key
          if polymorphic
            raise ArgumentError.new("references #{name}: polymorphic references cannot have a foreign key")
          end
          target = to_table ? to_table.to_s : (fk.is_a?(Symbol) ? fk.to_s : Record::Inflector.pluralize(name.to_s))
          @foreign_keys << TableForeignKey.new(col, target, on_delete, nil, deferrable)
        end
      end

      # Block-form foreign key: `t.foreign_key :users, column: :user_id`.
      # Works on all three adapters (emitted inside `CREATE TABLE`, which is
      # the only place SQLite parses FKs). `on_delete:` as in `references`.
      # `deferrable:` (`:deferred`/`:immediate`) is PostgreSQL-only DDL.
      def foreign_key(to_table : String | Symbol, column : String | Symbol, on_delete : Symbol? = nil, name : String? = nil, deferrable : Symbol? = nil)
        @foreign_keys << TableForeignKey.new(column.to_s, to_table.to_s, on_delete, name, deferrable)
      end

      private def add(name : String | Symbol, logical : Symbol, null : Bool, default : Value)
        @columns << ColumnDef.new(name.to_s, logical, null, default, false)
      end
    end

    # Rails-like migration.
    #
    # ```
    # class CreatePosts < Saci::Record::Migration
    #   def change
    #     create_table :posts do |t|
    #       t.string :title, null: false
    #       t.timestamps
    #     end
    #   end
    # end
    #
    # Saci::Record::Migrator.migrate(db, [CreatePosts] of Saci::Record::Migration.class)
    # ```
    #
    # Define `change` with reversible operations (`create_table`,
    # `add_column`, `add_index`, `add_foreign_key`, `rename_table`,
    # `rename_column`) for automatic rollback, or `up`/`down`
    # for full control. `drop_table`/`remove_column`/`remove_index`/
    # `remove_foreign_key`/`change_column` inside `change` raise
    # `IrreversibleMigration` on rollback (`change_column` and the
    # removals cannot be inverted without the original definition).
    # NOTE: intentionally not abstract — `Migrator` instantiates migrations
    # through the `Migration.class` metaclass, which abstract classes forbid.
    class Migration
      @inverting : Bool = false
      @inverse_ops : Array(-> Nil) = [] of (-> Nil)

      # Default FK constraint name: `fk_<from>_on_<column>`.
      def self.fk_constraint_name(from_table : String | Symbol, column : String | Symbol) : String
        "fk_#{from_table}_on_#{column}"
      end

      # Maps `:cascade`/`:nullify`/`:restrict`/`:no_action` to DDL.
      def self.on_delete_sql(action : Symbol) : String
        case action
        when :cascade   then "CASCADE"
        when :nullify   then "SET NULL"
        when :restrict  then "RESTRICT"
        when :no_action then "NO ACTION"
        else                 raise ArgumentError.new("Unknown on_delete #{action.inspect} (expected :cascade, :nullify, :restrict or :no_action)")
        end
      end

      # Naive singularize for the default FK column (`:users` → `user_id`).
      def self.fk_default_column(to_table : String | Symbol) : String
        base = to_table.to_s
        singular = if base.ends_with?("ies") && base.size > 3
                     base[0...-3] + "y"
                   elsif (base.ends_with?("ses") || base.ends_with?("xes") || base.ends_with?("zes") || base.ends_with?("ches") || base.ends_with?("shes")) && base.size > 2
                     base[0...-2]
                   elsif base.ends_with?("s") && !base.ends_with?("ss") && base.size > 1
                     base[0...-1]
                   else
                     base
                   end
        "#{singular}_id"
      end

      # `ALTER TABLE ... ADD CONSTRAINT ... FOREIGN KEY ... REFERENCES ...`.
      # Same syntax on PostgreSQL and MySQL (InnoDB assumed).
      # `deferrable:` adds `DEFERRABLE INITIALLY DEFERRED` (PostgreSQL;
      # SQLite accepts the clause too, MySQL does not). `validate: false`
      # emits PostgreSQL's `NOT VALID` (constraint enforced for new rows
      # only until `validate_foreign_key`).
      def self.add_fk_sql(adapter : Adapter, from_table : String | Symbol, to_table : String | Symbol, column : String | Symbol, on_delete : Symbol? = nil, name : String? = nil, deferrable : Symbol? = nil, validate : Bool = true) : String
        from, to, col = from_table.to_s, to_table.to_s, column.to_s
        cname = name || fk_constraint_name(from, col)
        sql = "ALTER TABLE #{Record.quote(from, adapter)} ADD CONSTRAINT #{Record.quote(cname, adapter)} FOREIGN KEY (#{Record.quote(col, adapter)}) REFERENCES #{Record.quote(to, adapter)} (#{Record.quote("id", adapter)})"
        sql += " ON DELETE #{on_delete_sql(on_delete)}" if on_delete
        sql += deferrable_sql(deferrable, adapter) if deferrable
        sql += " NOT VALID" if adapter == :postgres && !validate
        sql
      end

      # `DEFERRABLE INITIALLY DEFERRED` / `... IMMEDIATE`. MySQL has no
      # deferrable constraints (returns "" there).
      def self.deferrable_sql(deferrable : Symbol, adapter : Adapter) : String
        return "" if adapter == :mysql
        case deferrable
        when :deferred  then " DEFERRABLE INITIALLY DEFERRED"
        when :immediate then " DEFERRABLE INITIALLY IMMEDIATE"
        else                 raise ArgumentError.new("Unknown deferrable #{deferrable.inspect} (expected :deferred or :immediate)")
        end
      end

      # PostgreSQL drops FKs via `DROP CONSTRAINT`; MySQL via
      # `DROP FOREIGN KEY` (the backing index, if any, is kept).
      def self.remove_fk_sql(adapter : Adapter, from_table : String | Symbol, name : String | Symbol) : String
        from, cname = from_table.to_s, name.to_s
        if adapter == :mysql
          "ALTER TABLE #{Record.quote(from, adapter)} DROP FOREIGN KEY #{Record.quote(cname, adapter)}"
        else
          "ALTER TABLE #{Record.quote(from, adapter)} DROP CONSTRAINT #{Record.quote(cname, adapter)}"
        end
      end

      # Table-level FK clause for inside `CREATE TABLE` (all adapters,
      # including SQLite which only parses FKs at CREATE time).
      def self.create_table_fk_sql(adapter : Adapter, from_table : String | Symbol, fk : TableForeignKey) : String
        cname = fk.name || fk_constraint_name(from_table, fk.column)
        sql = "CONSTRAINT #{Record.quote(cname, adapter)} FOREIGN KEY (#{Record.quote(fk.column, adapter)}) REFERENCES #{Record.quote(fk.to_table, adapter)} (#{Record.quote("id", adapter)})"
        if od = fk.on_delete
          sql += " ON DELETE #{on_delete_sql(od)}"
        end
        if d = fk.deferrable
          sql += deferrable_sql(d, adapter)
        end
        sql
      end

      # `CREATE [UNIQUE] INDEX [CONCURRENTLY] [IF NOT EXISTS] ...`.
      # `algorithm: :concurrently` is PostgreSQL-only (and cannot run
      # inside a transaction — combine it with `disable_ddl_transaction!`).
      # `where:` renders a partial index (PostgreSQL/SQLite). MySQL lacks
      # `IF NOT EXISTS` for indexes; callers fall back to introspection
      # (`IndexExists`) and only then build this statement.
      def self.create_index_sql(adapter : Adapter, table : String | Symbol, cols : Array(String), name : String, unique : Bool = false, if_not_exists : Bool = false, algorithm : Symbol? = nil, where : String? = nil) : String
        if algorithm && algorithm != :concurrently
          raise ArgumentError.new("Unknown index algorithm #{algorithm.inspect} (expected :concurrently or nil)")
        end
        if algorithm == :concurrently && adapter != :postgres
          raise ArgumentError.new("algorithm: :concurrently is only supported on PostgreSQL (adapter: #{adapter})")
        end
        concurrent = algorithm == :concurrently ? " CONCURRENTLY" : ""
        exists_sql = if if_not_exists
                       case adapter
                       when :postgres, :sqlite then " IF NOT EXISTS"
                       else                         "" # MySQL: caller checks index_exists?
                       end
                     else
                       ""
                     end
        uniq = unique ? "UNIQUE " : ""
        sql = "CREATE #{uniq}INDEX#{concurrent}#{exists_sql} #{Record.quote(name, adapter)} ON #{Record.quote(table, adapter)} (#{cols.map { |c| Record.quote(c, adapter) }.join(", ")})"
        sql += " WHERE #{where}" if where
        sql
      end

      # `DROP INDEX ...` per adapter. PostgreSQL/SQLite use the index name
      # globally; MySQL requires `ON <table>`. `algorithm: :concurrently`
      # (PostgreSQL only) emits `DROP INDEX CONCURRENTLY`.
      def self.drop_index_sql(adapter : Adapter, table : String | Symbol, name : String | Symbol, if_exists : Bool = false, algorithm : Symbol? = nil) : String
        if algorithm == :concurrently && adapter != :postgres
          raise ArgumentError.new("algorithm: :concurrently is only supported on PostgreSQL (adapter: #{adapter})")
        end
        exists_sql = if_exists ? " IF EXISTS" : ""
        if adapter == :mysql
          "DROP INDEX #{Record.quote(name, adapter)} ON #{Record.quote(table, adapter)}"
        else
          concurrent = algorithm == :concurrently ? " CONCURRENTLY" : ""
          "DROP INDEX#{concurrent}#{exists_sql} #{Record.quote(name, adapter)}"
        end
      end

      # `ALTER TABLE ... ADD CONSTRAINT ... CHECK (...)`.
      # SQLite cannot add a CHECK constraint to an existing table (declare
      # it inside `create_table` with `t.check_constraint`); the instance
      # helper raises there. PostgreSQL supports `NOT VALID`.
      def self.add_check_constraint_sql(adapter : Adapter, table : String | Symbol, expression : String, name : String, validate : Bool = true) : String
        if adapter == :sqlite
          raise ArgumentError.new("add_check_constraint #{table} is not supported on SQLite (CHECK constraints are parsed at CREATE TABLE time only; declare it with t.check_constraint inside create_table)")
        end
        sql = "ALTER TABLE #{Record.quote(table, adapter)} ADD CONSTRAINT #{Record.quote(name, adapter)} CHECK (#{expression})"
        sql += " NOT VALID" if adapter == :postgres && !validate
        sql
      end

      # `ALTER TABLE ... DROP CONSTRAINT ...` (PostgreSQL/SQLite) or
      # `DROP CHECK ...` (MySQL 8.0.16+).
      def self.remove_check_constraint_sql(adapter : Adapter, table : String | Symbol, name : String | Symbol, if_exists : Bool = false) : String
        if adapter == :sqlite
          raise ArgumentError.new("remove_check_constraint #{table} is not supported on SQLite (CHECK constraints are CREATE TABLE clauses; table rebuild is out of scope)")
        end
        if adapter == :mysql
          "ALTER TABLE #{Record.quote(table, adapter)} DROP CHECK #{Record.quote(name, adapter)}"
        else
          "ALTER TABLE #{Record.quote(table, adapter)} DROP CONSTRAINT #{if_exists ? "IF EXISTS " : ""}#{Record.quote(name, adapter)}"
        end
      end

      # PostgreSQL `VALIDATE CONSTRAINT` (used after `NOT VALID`).
      def self.validate_constraint_sql(adapter : Adapter, table : String | Symbol, name : String | Symbol) : String
        unless adapter == :postgres
          raise ArgumentError.new("VALIDATE CONSTRAINT is only supported on PostgreSQL (adapter: #{adapter})")
        end
        "ALTER TABLE #{Record.quote(table, adapter)} VALIDATE CONSTRAINT #{Record.quote(name, adapter)}"
      end

      # `CREATE [OR REPLACE] VIEW ...`. PostgreSQL has no
      # `IF NOT EXISTS` for views and MySQL has neither form: the instance
      # helper falls back to `view_exists?` there, while the pure builder
      # emits the closest native statement.
      def self.create_view_sql(adapter : Adapter, name : String | Symbol, sql : String, if_not_exists : Bool = false, or_replace : Bool = false) : String
        if adapter == :sqlite
          # SQLite: IF NOT EXISTS yes, OR REPLACE no.
          "CREATE VIEW#{if_not_exists ? " IF NOT EXISTS" : ""} #{Record.quote(name, adapter)} AS #{sql}"
        elsif or_replace
          "CREATE OR REPLACE VIEW #{Record.quote(name, adapter)} AS #{sql}"
        elsif if_not_exists && adapter == :postgres
          # PostgreSQL has no IF NOT EXISTS; caller checks view_exists?.
          "CREATE VIEW #{Record.quote(name, adapter)} AS #{sql}"
        elsif if_not_exists && adapter == :mysql
          # MySQL has no IF NOT EXISTS; caller checks view_exists?.
          "CREATE VIEW #{Record.quote(name, adapter)} AS #{sql}"
        else
          "CREATE VIEW #{Record.quote(name, adapter)} AS #{sql}"
        end
      end

      # `DROP VIEW [IF EXISTS]` (all three adapters support IF EXISTS).
      def self.drop_view_sql(adapter : Adapter, name : String | Symbol, if_exists : Bool = false) : String
        "DROP VIEW#{if_exists ? " IF EXISTS" : ""} #{Record.quote(name, adapter)}"
      end

      # `ALTER TABLE ... RENAME TO` variants for indexes. SQLite has no
      # rename-index statement; the instance helper recreates it there.
      def self.rename_index_sql(adapter : Adapter, table : String | Symbol, old_name : String | Symbol, new_name : String | Symbol) : String
        case adapter
        when :postgres
          "ALTER INDEX #{Record.quote(old_name, adapter)} RENAME TO #{Record.quote(new_name, adapter)}"
        when :mysql
          "ALTER TABLE #{Record.quote(table, adapter)} RENAME INDEX #{Record.quote(old_name, adapter)} TO #{Record.quote(new_name, adapter)}"
        else
          raise ArgumentError.new("rename_index is not supported on SQLite as a single statement; the migration helper recreates the index instead")
        end
      end

      # `ALTER TABLE <old> RENAME TO <new>` (all three adapters).
      def self.rename_table_sql(adapter : Adapter, old_name : String | Symbol, new_name : String | Symbol) : String
        "ALTER TABLE #{Record.quote(old_name, adapter)} RENAME TO #{Record.quote(new_name, adapter)}"
      end

      # `ALTER TABLE <t> RENAME COLUMN <old> TO <new>` (PostgreSQL, MySQL 8+,
      # and SQLite ≥ 3.25 all support this form).
      def self.rename_column_sql(adapter : Adapter, table : String | Symbol, old_name : String | Symbol, new_name : String | Symbol) : String
        "ALTER TABLE #{Record.quote(table, adapter)} RENAME COLUMN #{Record.quote(old_name, adapter)} TO #{Record.quote(new_name, adapter)}"
      end

      # Standalone PostgreSQL enum type name for `t.enum` columns:
      # `<table>_<column>_enum` (spec-pinned convention).
      def self.enum_type_name(table : String | Symbol, column : String | Symbol) : String
        "#{table}_#{column}_enum"
      end

      # Idempotent PostgreSQL `CREATE TYPE ... AS ENUM` for a `t.enum`
      # column. A `DO` block swallows `duplicate_object`, so re-running a
      # migration (or retrying after a partially applied one — DDL is not
      # transactional) keeps the existing type instead of failing. Returns
      # nil on MySQL/SQLite (inline `ENUM(...)` / `TEXT` — no type to
      # create).
      def self.create_enum_sql(adapter : Adapter, table : String | Symbol, column : String | Symbol, values : Array(String)) : String?
        return nil unless adapter == :postgres
        if values.empty?
          raise ArgumentError.new("enum #{table}.#{column}: values must not be empty")
        end
        type = enum_type_name(table, column)
        list = values.map { |v| "'#{v.gsub("'", "''")}'" }.join(", ")
        "DO $$ BEGIN CREATE TYPE #{Record.quote(type, adapter)} AS ENUM (#{list}); EXCEPTION WHEN duplicate_object THEN NULL; END $$;"
      end

      # Drops a `t.enum` standalone type (rollback). `IF EXISTS` keeps it
      # safe when the forward migration never created one (e.g. a MySQL /
      # SQLite run of the same migration). Returns nil on MySQL/SQLite.
      def self.drop_enum_sql(adapter : Adapter, table : String | Symbol, column : String | Symbol) : String?
        return nil unless adapter == :postgres
        "DROP TYPE IF EXISTS #{Record.quote(enum_type_name(table, column), adapter)}"
      end

      # Per-adapter `change_column` statements (no DB needed).
      # PostgreSQL: `ALTER COLUMN TYPE ... USING` + null/default adjusts.
      # MySQL: single `MODIFY COLUMN <full definition>` (InnoDB assumed).
      # SQLite: raises — SQLite cannot alter a column type in place (a full
      # table rebuild is out of scope); redefine the table instead.
      def self.change_column_sqls(adapter : Adapter, table : String | Symbol, column : String | Symbol, type : Symbol, null : Bool = true, default : Value = nil) : Array(String)
        tbl, col = table.to_s, column.to_s
        case adapter
        when :sqlite
          raise ArgumentError.new("change_column #{tbl}.#{col} is not supported on SQLite (SQLite cannot alter a column type in place; table rebuild is out of scope — recreate the table instead)")
        when :mysql
          ["ALTER TABLE #{Record.quote(tbl, adapter)} MODIFY COLUMN #{ColumnDef.new(col, type, null, default, false).to_sql(adapter)}"]
        else
          type_sql = NativeTypes.extended?(type) ? NativeTypes.db_type(type, adapter) : Record.db_type(type, adapter)
          stmts = ["ALTER TABLE #{Record.quote(tbl, adapter)} ALTER COLUMN #{Record.quote(col, adapter)} TYPE #{type_sql} USING #{Record.quote(col, adapter)}::#{type_sql}"]
          stmts << "ALTER TABLE #{Record.quote(tbl, adapter)} ALTER COLUMN #{Record.quote(col, adapter)} #{null ? "DROP NOT NULL" : "SET NOT NULL"}"
          if d = Record.column_default_sql(default, adapter)
            stmts << "ALTER TABLE #{Record.quote(tbl, adapter)} ALTER COLUMN #{Record.quote(col, adapter)} SET DEFAULT #{d}"
          else
            stmts << "ALTER TABLE #{Record.quote(tbl, adapter)} ALTER COLUMN #{Record.quote(col, adapter)} DROP DEFAULT"
          end
          stmts
        end
      end

      def initialize(@db : DB::Database | DB::Connection)
      end

      def change : Nil
      end

      def up : Nil
        change
      end

      # Default `down` replays `change` in reverse: while `@inverting`,
      # helpers record inverse operations instead of executing, then run
      # them newest-first. `drop_table`/`remove_column`/`remove_index`
      # inside `change` raise `IrreversibleMigration` on rollback.
      def down : Nil
        @inverse_ops.clear
        @inverting = true
        begin
          change
        ensure
          @inverting = false
        end
        @inverse_ops.reverse_each(&.call)
      end

      # `create_table :posts, id: :uuid` creates a UUID primary key
      # (PostgreSQL `DEFAULT gen_random_uuid()`; SQLite/MySQL store the
      # application-supplied string). `id: false` disables the key.
      # `if_not_exists: true` makes the migration rerunnable: the table
      # (and its enum types/indexes) is left untouched when it exists.
      def create_table(name : String | Symbol, id : Bool | Symbol = true, if_not_exists : Bool = false, & : TableDefinition ->) : Nil
        ad = Record.adapter_of(@db)
        tbl = name.to_s
        if if_not_exists && Introspection.table_exists?(@db, tbl)
          # Still yield so callers can build definitions in tests, but do
          # not emit anything for an existing table.
          yield TableDefinition.new
          return
        end
        t = TableDefinition.new
        case id
        when true
          t.columns << ColumnDef.new("id", :serial, false, nil, true)
        when false
          # no primary key column
        when :uuid
          t.columns << ColumnDef.new("id", :uuid, false, nil, true)
        when :serial, :bigint, :integer
          t.columns << ColumnDef.new("id", :serial, false, nil, true)
        when :string, :text
          t.columns << ColumnDef.new("id", :string, false, nil, true)
        else
          raise ArgumentError.new("create_table #{tbl}: unsupported id option #{id.inspect} (expected true, false, :uuid, :serial, :bigint, :integer or :string)")
        end
        yield t
        enum_cols = t.columns.select { |c| c.logical_type == :enum }
        if @inverting
          @inverse_ops << -> {
            Record.exec_compat(@db, Migration.drop_table_sql(ad, tbl, if_exists: true))
            # Rollback drops the standalone PG enum types (plain columns
            # need nothing — arrays drop with the table).
            enum_cols.each do |c|
              if drop = Migration.drop_enum_sql(ad, tbl, c.name)
                Record.exec_compat(@db, drop)
              end
            end
            nil
          }
          return
        end
        enum_cols.each do |c|
          vals = c.enum_values
          if vals.nil? || vals.empty?
            raise ArgumentError.new("enum #{tbl}.#{c.name}: values must not be empty")
          end
          if stmt = Migration.create_enum_sql(ad, tbl, c.name, vals)
            Record.exec_compat(@db, stmt)
          end
        end
        cols_sql = t.columns.map(&.to_sql(ad, tbl)).join(", ")
        fk_sql = t.foreign_keys.map { |fk| Migration.create_table_fk_sql(ad, tbl, fk) }
        check_sql = t.checks.map { |c| Migration.check_clause_sql(ad, c) }
        all_sql = ([cols_sql] + fk_sql + check_sql).reject(&.empty?).join(", ")
        create = "CREATE TABLE#{if_not_exists ? " IF NOT EXISTS" : ""} #{Record.quote(tbl, ad)} (#{all_sql})"
        Record.exec_compat(@db, create)
        t.pending_indexes.each do |col|
          index_name = "index_#{tbl}_on_#{col}"
          Record.exec_compat(@db, Migration.create_index_sql(ad, tbl, [col], index_name, if_not_exists: if_not_exists))
        end
        t.defined_indexes.each do |ix|
          index_name = ix.name || "index_#{tbl}_on_#{ix.columns.join("_and_")}"
          Record.exec_compat(@db, Migration.create_index_sql(ad, tbl, ix.columns, index_name, unique: ix.unique, if_not_exists: if_not_exists))
        end
      end

      # Table-level CHECK clause used inside CREATE TABLE.
      def self.check_clause_sql(adapter : Adapter, check : TableCheck) : String
        prefix = if name = check.name
                   "CONSTRAINT #{Record.quote(name, adapter)} "
                 else
                   ""
                 end
        "#{prefix}CHECK (#{check.expression})"
      end

      def self.drop_table_sql(adapter : Adapter, name : String | Symbol, if_exists : Bool = false) : String
        "DROP TABLE#{if_exists ? " IF EXISTS" : ""} #{Record.quote(name, adapter)}"
      end

      def drop_table(name : String | Symbol, if_exists : Bool = false) : Nil
        if @inverting
          raise IrreversibleMigration.new("Cannot auto-invert drop_table #{name}; define up/down instead of change.")
        end
        ad = Record.adapter_of(@db)
        Record.exec_compat(@db, Migration.drop_table_sql(ad, name, if_exists))
      end

      # Adds a column. `if_not_exists:` is native on PostgreSQL
      # (`ADD COLUMN IF NOT EXISTS`); SQLite/MySQL fall back to
      # introspection and become a no-op when the column is present.
      # Extended types (`:uuid`, `:binary`, `:hstore`, …) are rendered by
      # `NativeTypes`; `default_sql:` carries a raw SQL default,
      # `generated_as:`/`stored:` create a generated column.
      def add_column(table : String | Symbol, name : String | Symbol, type : Symbol, null : Bool = true, default : Value = nil, values : Array(String)? = nil, precision : Int32? = nil, scale : Int32? = nil, if_not_exists : Bool = false, *, default_sql : String? = nil, subtype : Symbol? = nil, size : Int32? = nil, generated_as : String? = nil, stored : Bool = false) : Nil
        ad = Record.adapter_of(@db)
        tbl, col = table.to_s, name.to_s
        if if_not_exists && Introspection.column_exists?(@db, tbl, col)
          return
        end
        if @inverting
          @inverse_ops << -> {
            Record.exec_compat(@db, "ALTER TABLE #{Record.quote(tbl, ad)} DROP COLUMN #{Record.quote(col, ad)}")
            if type == :enum
              if drop = Migration.drop_enum_sql(ad, tbl, col)
                Record.exec_compat(@db, drop)
              end
            end
            nil
          }
          return
        end
        if type == :enum
          vals = values
          if vals.nil? || vals.empty?
            raise ArgumentError.new("add_column #{tbl}.#{col} :enum requires values: [...]")
          end
          if stmt = Migration.create_enum_sql(ad, tbl, col, vals)
            Record.exec_compat(@db, stmt)
          end
        end
        exists_sql = (if_not_exists && ad == :postgres) ? " IF NOT EXISTS" : ""
        column_sql = ColumnDef.new(col, type, null, default, false, values, precision, scale,
          default_sql: default_sql, subtype: subtype, size: size, generated_as: generated_as, stored: stored)
        Record.exec_compat(@db, "ALTER TABLE #{Record.quote(tbl, ad)} ADD COLUMN#{exists_sql} #{column_sql.to_sql(ad, tbl)}")
      end

      # `drop_column` is an alias of `remove_column` with the same
      # idempotency option.
      def drop_column(table : String | Symbol, name : String | Symbol, if_exists : Bool = false) : Nil
        remove_column(table, name, if_exists)
      end

      def remove_column(table : String | Symbol, name : String | Symbol, if_exists : Bool = false) : Nil
        if @inverting
          raise IrreversibleMigration.new("Cannot auto-invert remove_column #{table}.#{name}; define up/down instead of change.")
        end
        ad = Record.adapter_of(@db)
        tbl, col = table.to_s, name.to_s
        if if_exists
          unless Introspection.column_exists?(@db, tbl, col)
            return
          end
        end
        exists_sql = (if_exists && ad == :postgres) ? "IF EXISTS " : ""
        Record.exec_compat(@db, "ALTER TABLE #{Record.quote(tbl, ad)} DROP COLUMN #{exists_sql}#{Record.quote(col, ad)}")
      end

      # Removes several columns at once (`remove_columns :users, :a, :b`
      # or `remove_columns :users, [:a, :b]`). Irreversible on rollback,
      # like `remove_column`.
      def remove_columns(table : String | Symbol, columns : Array(String | Symbol)) : Nil
        columns.each { |c| remove_column(table, c) }
      end

      def remove_columns(table : String | Symbol, *columns : String | Symbol) : Nil
        columns.each { |c| remove_column(table, c) }
      end

      # Adds an index. `if_not_exists:` is native on PostgreSQL/SQLite;
      # MySQL falls back to `index_exists?`. `algorithm: :concurrently`
      # (PostgreSQL) cannot run inside a transaction — combine it with
      # `disable_ddl_transaction!`. `where:` creates a partial index on
      # PostgreSQL/SQLite.
      def add_index(table : String | Symbol, cols : String | Symbol | Array(String | Symbol), name : String? = nil, unique : Bool = false, if_not_exists : Bool = false, algorithm : Symbol? = nil, where : String? = nil) : Nil
        ad = Record.adapter_of(@db)
        list = cols.is_a?(Array) ? cols.map(&.to_s) : [cols.to_s]
        index_name = name || "index_#{table}_on_#{list.join("_and_")}"
        if if_not_exists && Introspection.index_exists?(@db, table, list, name: index_name)
          return
        end
        if @inverting
          drop_sql = Migration.drop_index_sql(ad, table, index_name, if_exists: true, algorithm: algorithm)
          @inverse_ops << -> { Record.exec_compat(@db, drop_sql); nil }
          return
        end
        Record.exec_compat(@db, Migration.create_index_sql(ad, table, list, index_name, unique: unique, if_not_exists: if_not_exists, algorithm: algorithm, where: where))
      end

      # Removes an index by name, or by column(s) using the conventional
      # `index_<table>_on_<columns>` name:
      #
      # ```
      # remove_index :users, :index_users_on_email
      # remove_index :users, column: :email
      # remove_index :users, if_exists: true, column: :email
      # ```
      #
      # `if_exists:` falls back to introspection on SQLite/MySQL.
      # Irreversible on rollback (Rails behavior) — use `up`/`down`.
      def remove_index(table : String | Symbol, name : String | Symbol, if_exists : Bool = false, algorithm : Symbol? = nil, *, column : String | Symbol | Array(String | Symbol) | Nil = nil) : Nil
        remove_index_impl(table, name.to_s, column, if_exists, algorithm)
      end

      # `remove_index :users, [:first, :last]` derives the conventional
      # name from the column list.
      def remove_index(table : String | Symbol, columns : Array(String | Symbol), if_exists : Bool = false, algorithm : Symbol? = nil, *, name : String? = nil) : Nil
        remove_index_impl(table, name, columns, if_exists, algorithm)
      end

      def remove_index(table : String | Symbol, *, column : String | Symbol | Array(String | Symbol) | Nil = nil, name : String? = nil, if_exists : Bool = false, algorithm : Symbol? = nil) : Nil
        remove_index_impl(table, name, column, if_exists, algorithm)
      end

      private def remove_index_impl(table : String | Symbol, name : String?, column : String | Symbol | Array(String | Symbol) | Nil, if_exists : Bool, algorithm : Symbol?) : Nil
        if @inverting
          raise IrreversibleMigration.new("Cannot auto-invert remove_index #{name || column}; define up/down instead of change.")
        end
        ad = Record.adapter_of(@db)
        list = case column
               when Nil   then nil
               when Array then column.map(&.to_s)
               else            [column.to_s]
               end
        index_name = if n = name
                       n
                     elsif l = list
                       "index_#{table}_on_#{l.join("_and_")}"
                     else
                       raise ArgumentError.new("remove_index #{table}: give an index name or column:/columns:")
                     end
        if if_exists
          unless Introspection.index_exists?(@db, table, list, name: index_name)
            return
          end
        end
        Record.exec_compat(@db, Migration.drop_index_sql(ad, table, index_name, if_exists: if_exists, algorithm: algorithm))
      end

      # Renames an index. PostgreSQL/MySQL rename in place; SQLite has no
      # such statement, so the index definition is introspected and
      # recreated under the new name.
      def rename_index(table : String | Symbol, old_name : String | Symbol, new_name : String | Symbol) : Nil
        ad = Record.adapter_of(@db)
        tbl, old_s, new_s = table.to_s, old_name.to_s, new_name.to_s
        if ad == :sqlite
          idx = Introspection.indexes(@db, tbl).find { |i| i.name == old_s }
          unless idx
            raise ArgumentError.new("rename_index #{tbl}: index #{old_s.inspect} does not exist")
          end
          Record.exec_compat(@db, Migration.create_index_sql(ad, tbl, idx.columns, new_s, unique: idx.unique))
          Record.exec_compat(@db, Migration.drop_index_sql(ad, tbl, old_s, if_exists: true))
        else
          Record.exec_compat(@db, Migration.rename_index_sql(ad, tbl, old_s, new_s))
        end
      end

      # Adds a foreign key between existing tables. Same `ADD CONSTRAINT`
      # syntax on PostgreSQL and MySQL (InnoDB assumed). On SQLite raises:
      # SQLite parses FOREIGN KEYs at CREATE TABLE time only, so a later
      # `add_foreign_key` cannot take effect — declare it inside
      # `create_table` via `t.references ... foreign_key: true` or
      # `t.foreign_key` instead (a full table rebuild is out of scope).
      # Auto-inverts on rollback (drops the constraint).
      def add_foreign_key(from_table : String | Symbol, to_table : String | Symbol, column : String | Symbol | Nil = nil, on_delete : Symbol? = nil, name : String? = nil, deferrable : Symbol? = nil, validate : Bool = true, if_not_exists : Bool = false) : Nil
        ad = Record.adapter_of(@db)
        from, to = from_table.to_s, to_table.to_s
        col = (column || Migration.fk_default_column(to)).to_s
        cname = name || Migration.fk_constraint_name(from, col)
        if if_not_exists && Introspection.foreign_key_exists?(@db, from, name: cname)
          return
        end
        if @inverting
          drop_sql = Migration.remove_fk_sql(ad, from, cname)
          @inverse_ops << -> { Record.exec_compat(@db, drop_sql); nil }
          return
        end
        if ad == :sqlite
          raise ArgumentError.new("add_foreign_key #{from}.#{col} -> #{to} is not supported on SQLite (FOREIGN KEYs are parsed at CREATE TABLE time only; use t.references ... foreign_key: true or t.foreign_key inside create_table — table rebuild is out of scope)")
        end
        Record.exec_compat(@db, Migration.add_fk_sql(ad, from, to, col, on_delete, cname, deferrable, validate))
      end

      # Drops a foreign key constraint. Resolve by explicit `name:` or by
      # `column:`/`to_table:` (defaulting to the `fk_<from>_on_<column>`
      # convention). Raises `IrreversibleMigration` on rollback (the
      # original `on_delete` is unknown) — use `up`/`down`. On SQLite
      # raises (nothing to drop: standalone FKs were never creatable).
      def remove_foreign_key(from_table : String | Symbol, to_table : String | Symbol | Nil = nil, column : String | Symbol | Nil = nil, name : String? = nil, if_exists : Bool = false) : Nil
        if @inverting
          raise IrreversibleMigration.new("Cannot auto-invert remove_foreign_key #{from_table}; define up/down instead of change.")
        end
        ad = Record.adapter_of(@db)
        if ad == :sqlite
          raise ArgumentError.new("remove_foreign_key #{from_table} is not supported on SQLite (FOREIGN KEYs exist only as CREATE TABLE clauses; table rebuild is out of scope)")
        end
        from = from_table.to_s
        col = (column || (to_table ? Migration.fk_default_column(to_table.to_s) : nil))
        cname = name || (col ? Migration.fk_constraint_name(from, col) : nil) ||
                raise ArgumentError.new("remove_foreign_key #{from}: give name: or column:/to_table: so the constraint can be identified")
        if if_exists && !Introspection.foreign_key_exists?(@db, from, name: cname)
          return
        end
        Record.exec_compat(@db, Migration.remove_fk_sql(ad, from, cname))
      end

      # Renames a table (`ALTER TABLE <old> RENAME TO <new>` on all three
      # adapters; SQLite supports this since 3.25). Auto-inverts.
      def rename_table(old_name : String | Symbol, new_name : String | Symbol) : Nil
        ad = Record.adapter_of(@db)
        old_s, new_s = old_name.to_s, new_name.to_s
        if @inverting
          back = Migration.rename_table_sql(ad, new_s, old_s)
          @inverse_ops << -> { Record.exec_compat(@db, back); nil }
          return
        end
        Record.exec_compat(@db, Migration.rename_table_sql(ad, old_s, new_s))
      end

      # Renames a column (`ALTER TABLE <t> RENAME COLUMN <old> TO <new>` on
      # all three adapters: PostgreSQL, MySQL 8+, SQLite ≥ 3.25).
      # Auto-inverts.
      def rename_column(table : String | Symbol, old_name : String | Symbol, new_name : String | Symbol) : Nil
        ad = Record.adapter_of(@db)
        tbl, old_s, new_s = table.to_s, old_name.to_s, new_name.to_s
        if @inverting
          back = Migration.rename_column_sql(ad, tbl, new_s, old_s)
          @inverse_ops << -> { Record.exec_compat(@db, back); nil }
          return
        end
        Record.exec_compat(@db, Migration.rename_column_sql(ad, tbl, old_s, new_s))
      end

      # Changes a column's type/null/default. PostgreSQL uses
      # `ALTER COLUMN TYPE ... USING <col>::<type>` plus null/default
      # adjusts; MySQL uses `MODIFY COLUMN <full definition>` (InnoDB
      # assumed). On SQLite raises (no in-place type change; a table
      # rebuild is out of scope — recreate the table instead). Does NOT
      # auto-invert: raises `IrreversibleMigration` on rollback, like
      # `drop_table` — use `up`/`down`.
      def change_column(table : String | Symbol, column : String | Symbol, type : Symbol, null : Bool = true, default : Value = nil) : Nil
        if @inverting
          raise IrreversibleMigration.new("Cannot auto-invert change_column #{table}.#{column}; define up/down instead of change.")
        end
        ad = Record.adapter_of(@db)
        Migration.change_column_sqls(ad, table, column, type, null, default).each do |sql|
          Record.exec_compat(@db, sql)
        end
      end
    end

    # Tracks applied migrations in `schema_migrations` and runs pending
    # ones in the given order. Rollback order derives from the manifest
    # array (reverse of application order) — portable across adapters
    # (`rowid` is SQLite-only).
    module Migrator
      SCHEMA_TABLE = "schema_migrations"

      def self.migrate(db : DB::Database | DB::Connection, migrations : Array(Migration.class)) : Array(String)
        ad = Record.adapter_of(db)
        tbl = Record.quote(SCHEMA_TABLE, ad)
        ensure_schema_table(db)
        applied = applied_names(db).to_set
        ran = [] of String
        migrations.each do |mklass|
          name = mklass.name
          next if applied.includes?(name)
          # NOTE: the runner deliberately does not wrap migrations in a
          # transaction. `disable_ddl_transaction!` is exposed as metadata
          # for app runners (and for PostgreSQL concurrent index safety);
          # wrapping here would hide the adapter from `Record.adapter_of`
          # (it only knows Saci-registered connections) and break
          # SQLite's per-connection `PRAGMA foreign_keys`.
          mklass.new(db).up
          Record.exec_compat(db, "INSERT INTO #{tbl} (#{Record.quote("name", ad)}) VALUES (?)", [name] of Value)
          ran << name
        end
        ran
      end

      def self.rollback(db : DB::Database | DB::Connection, migrations : Array(Migration.class), steps : Int32 = 1) : Array(String)
        ad = Record.adapter_of(db)
        tbl = Record.quote(SCHEMA_TABLE, ad)
        ensure_schema_table(db)
        applied = applied_names(db).to_set
        todo = migrations.reverse.select { |m| applied.includes?(m.name) }.first(steps)
        undone = [] of String
        todo.each do |mklass|
          mklass.new(db).down
          Record.exec_compat(db, "DELETE FROM #{tbl} WHERE #{Record.quote("name", ad)} = ?", [mklass.name] of Value)
          undone << mklass.name
        end
        undone
      end

      def self.applied_names(db : DB::Database | DB::Connection) : Array(String)
        ad = Record.adapter_of(db)
        tbl = Record.quote(SCHEMA_TABLE, ad)
        ensure_schema_table(db)
        names = [] of String
        Record.query_compat(db, "SELECT #{Record.quote("name", ad)} FROM #{tbl}") do |rs|
          rs.each { names << rs.read(String) }
        end
        names
      end

      private def self.ensure_schema_table(db : DB::Database | DB::Connection) : Nil
        ad = Record.adapter_of(db)
        tbl = Record.quote(SCHEMA_TABLE, ad)
        Record.exec_compat(db, "CREATE TABLE IF NOT EXISTS #{tbl} (#{Record.quote("name", ad)} VARCHAR(255) PRIMARY KEY)")
      end
    end
  end
end

# Extended DSL + introspection are required here (rather than centrally in
# `record.cr`, which this file does not own) so `require "saci"` exposes
# them automatically. Both reopen `Saci::Record` classes/modules.
require "./introspection"
require "./migration_extras"
