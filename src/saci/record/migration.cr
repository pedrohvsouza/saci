module Saci
  module Record
    # Column definition used by `TableDefinition` and `add_column`.
    # Stores the *logical* type; SQL renders per adapter (`to_sql`).
    # `enum_values` serves `:enum` columns; `precision` (0..6) serves
    # `:datetime`. `to_sql` takes the owning table so PostgreSQL enum
    # columns can reference their standalone type
    # (`Migration.enum_type_name`).
    struct ColumnDef
      getter name : String
      getter logical_type : Symbol
      getter null : Bool
      getter default_value : Value
      getter primary_key : Bool
      getter enum_values : Array(String)?
      getter precision : Int32?

      def initialize(@name, @logical_type, @null, @default_value, @primary_key, @enum_values : Array(String)? = nil, @precision : Int32? = nil)
      end

      def to_sql(adapter : Adapter = :sqlite, table : String? = nil) : String
        String.build do |s|
          enum_type = table ? Migration.enum_type_name(table, @name) : nil
          s << "#{Record.quote(@name, adapter)} #{Record.db_type(@logical_type, adapter, @enum_values, enum_type, @precision)}"
          if @primary_key
            case adapter
            when :postgres then s << " PRIMARY KEY"
            when :mysql    then s << " AUTO_INCREMENT PRIMARY KEY"
            else                s << " PRIMARY KEY AUTOINCREMENT"
            end
          end
          s << " NOT NULL" unless @null
          if d = Record.column_default_sql(@default_value, adapter)
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

      def initialize(@column, @to_table, @on_delete, @name)
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

      def initialize
        @columns = [] of ColumnDef
        @foreign_keys = [] of TableForeignKey
        @pending_indexes = [] of String
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

      def decimal(name : String | Symbol, null : Bool = true, default : Value = nil)
        add(name, :decimal, null, default)
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
      def references(name : String | Symbol, foreign_key : Bool | Symbol | Nil = false, null : Bool = true, index : Bool = true, to_table : String | Symbol | Nil = nil, on_delete : Symbol? = nil)
        col = "#{name}_id"
        add(col, :bigint, null, nil)
        @pending_indexes << col if index
        if fk = foreign_key
          target = to_table ? to_table.to_s : (fk.is_a?(Symbol) ? fk.to_s : Record::Inflector.pluralize(name.to_s))
          @foreign_keys << TableForeignKey.new(col, target, on_delete, nil)
        end
      end

      # Block-form foreign key: `t.foreign_key :users, column: :user_id`.
      # Works on all three adapters (emitted inside `CREATE TABLE`, which is
      # the only place SQLite parses FKs). `on_delete:` as in `references`.
      def foreign_key(to_table : String | Symbol, column : String | Symbol, on_delete : Symbol? = nil, name : String? = nil)
        @foreign_keys << TableForeignKey.new(column.to_s, to_table.to_s, on_delete, name)
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

      # -- pure SQL builders (per adapter; no DB needed, spec-covered) -----

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
      def self.add_fk_sql(adapter : Adapter, from_table : String | Symbol, to_table : String | Symbol, column : String | Symbol, on_delete : Symbol? = nil, name : String? = nil) : String
        from, to, col = from_table.to_s, to_table.to_s, column.to_s
        cname = name || fk_constraint_name(from, col)
        sql = "ALTER TABLE #{Record.quote(from, adapter)} ADD CONSTRAINT #{Record.quote(cname, adapter)} FOREIGN KEY (#{Record.quote(col, adapter)}) REFERENCES #{Record.quote(to, adapter)} (#{Record.quote("id", adapter)})"
        sql += " ON DELETE #{on_delete_sql(on_delete)}" if on_delete
        sql
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
        sql
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
          stmts = ["ALTER TABLE #{Record.quote(tbl, adapter)} ALTER COLUMN #{Record.quote(col, adapter)} TYPE #{Record.db_type(type, adapter)} USING #{Record.quote(col, adapter)}::#{Record.db_type(type, adapter)}"]
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

      def create_table(name : String | Symbol, id : Bool = true, & : TableDefinition ->) : Nil
        ad = Record.adapter_of(@db)
        tbl = name.to_s
        t = TableDefinition.new
        if id
          t.columns << ColumnDef.new("id", :serial, false, nil, true)
        end
        yield t
        enum_cols = t.columns.select { |c| c.logical_type == :enum }
        if @inverting
          @inverse_ops << -> {
            Record.exec_compat(@db, "DROP TABLE #{Record.quote(tbl, ad)}")
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
        all_sql = ([cols_sql] + fk_sql).reject(&.empty?).join(", ")
        Record.exec_compat(@db, "CREATE TABLE #{Record.quote(tbl, ad)} (#{all_sql})")
        t.pending_indexes.each do |col|
          index_name = "index_#{tbl}_on_#{col}"
          Record.exec_compat(@db, "CREATE INDEX #{Record.quote(index_name, ad)} ON #{Record.quote(tbl, ad)} (#{Record.quote(col, ad)})")
        end
      end

      def drop_table(name : String | Symbol) : Nil
        if @inverting
          raise IrreversibleMigration.new("Cannot auto-invert drop_table #{name}; define up/down instead of change.")
        end
        ad = Record.adapter_of(@db)
        Record.exec_compat(@db, "DROP TABLE #{Record.quote(name, ad)}")
      end

      def add_column(table : String | Symbol, name : String | Symbol, type : Symbol, null : Bool = true, default : Value = nil, values : Array(String)? = nil, precision : Int32? = nil) : Nil
        ad = Record.adapter_of(@db)
        tbl, col = table.to_s, name.to_s
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
        Record.exec_compat(@db, "ALTER TABLE #{Record.quote(tbl, ad)} ADD COLUMN #{ColumnDef.new(col, type, null, default, false, values, precision).to_sql(ad, tbl)}")
      end

      def remove_column(table : String | Symbol, name : String | Symbol) : Nil
        if @inverting
          raise IrreversibleMigration.new("Cannot auto-invert remove_column #{table}.#{name}; define up/down instead of change.")
        end
        ad = Record.adapter_of(@db)
        Record.exec_compat(@db, "ALTER TABLE #{Record.quote(table, ad)} DROP COLUMN #{Record.quote(name, ad)}")
      end

      def add_index(table : String | Symbol, cols : String | Symbol | Array(String | Symbol), name : String? = nil, unique : Bool = false) : Nil
        ad = Record.adapter_of(@db)
        list = cols.is_a?(Array) ? cols.map(&.to_s) : [cols.to_s]
        index_name = name || "index_#{table}_on_#{list.join("_and_")}"
        if @inverting
          # MySQL drops indexes per table (`DROP INDEX x ON t`).
          drop_sql = ad == :mysql ? "DROP INDEX #{Record.quote(index_name, ad)} ON #{Record.quote(table, ad)}" : "DROP INDEX #{Record.quote(index_name, ad)}"
          @inverse_ops << -> { Record.exec_compat(@db, drop_sql); nil }
          return
        end
        uniq = unique ? "UNIQUE " : ""
        Record.exec_compat(@db, "CREATE #{uniq}INDEX #{Record.quote(index_name, ad)} ON #{Record.quote(table, ad)} (#{list.map { |c| Record.quote(c, ad) }.join(", ")})")
      end

      def remove_index(table : String | Symbol, name : String | Symbol) : Nil
        if @inverting
          raise IrreversibleMigration.new("Cannot auto-invert remove_index #{name}; define up/down instead of change.")
        end
        ad = Record.adapter_of(@db)
        drop_sql = ad == :mysql ? "DROP INDEX #{Record.quote(name, ad)} ON #{Record.quote(table, ad)}" : "DROP INDEX #{Record.quote(name, ad)}"
        Record.exec_compat(@db, drop_sql)
      end

      # Adds a foreign key between existing tables. Same `ADD CONSTRAINT`
      # syntax on PostgreSQL and MySQL (InnoDB assumed). On SQLite raises:
      # SQLite parses FOREIGN KEYs at CREATE TABLE time only, so a later
      # `add_foreign_key` cannot take effect — declare it inside
      # `create_table` via `t.references ... foreign_key: true` or
      # `t.foreign_key` instead (a full table rebuild is out of scope).
      # Auto-inverts on rollback (drops the constraint).
      def add_foreign_key(from_table : String | Symbol, to_table : String | Symbol, column : String | Symbol | Nil = nil, on_delete : Symbol? = nil, name : String? = nil) : Nil
        ad = Record.adapter_of(@db)
        from, to = from_table.to_s, to_table.to_s
        col = (column || Migration.fk_default_column(to)).to_s
        cname = name || Migration.fk_constraint_name(from, col)
        if @inverting
          drop_sql = Migration.remove_fk_sql(ad, from, cname)
          @inverse_ops << -> { Record.exec_compat(@db, drop_sql); nil }
          return
        end
        if ad == :sqlite
          raise ArgumentError.new("add_foreign_key #{from}.#{col} -> #{to} is not supported on SQLite (FOREIGN KEYs are parsed at CREATE TABLE time only; use t.references ... foreign_key: true or t.foreign_key inside create_table — table rebuild is out of scope)")
        end
        Record.exec_compat(@db, Migration.add_fk_sql(ad, from, to, col, on_delete, cname))
      end

      # Drops a foreign key constraint. Resolve by explicit `name:` or by
      # `column:`/`to_table:` (defaulting to the `fk_<from>_on_<column>`
      # convention). Raises `IrreversibleMigration` on rollback (the
      # original `on_delete` is unknown) — use `up`/`down`. On SQLite
      # raises (nothing to drop: standalone FKs were never creatable).
      def remove_foreign_key(from_table : String | Symbol, to_table : String | Symbol | Nil = nil, column : String | Symbol | Nil = nil, name : String? = nil) : Nil
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
