module Saci
  module Record
    # Extended migration DSL (G35/G36/G37/G38/G32 + UUID/native types).
    #
    # Kept in a separate file so `migration.cr` stays focused on the core
    # table/index/FK helpers. `migration.cr` requires this file at the
    # bottom, so `require "saci"` (or `require "saci/record"`) exposes
    # everything without an extra integration line.
    class Migration
      # `disable_ddl_transaction!` marks a migration so the runner can
      # skip wrapping it in a transaction (required for PostgreSQL
      # `CREATE INDEX CONCURRENTLY`, which cannot run inside one).
      macro disable_ddl_transaction!
        def self.ddl_transaction_disabled?
          true
        end
      end

      # Base default; overridden per migration by the macro above.
      def self.ddl_transaction_disabled? : Bool
        false
      end

      # Instance convenience (e.g. a runner holding a `Migration` object).
      def ddl_transaction_disabled? : Bool
        self.class.ddl_transaction_disabled?
      end

      # Renders any logical type (core or extended) for an adapter. Pure
      # SQL builder — useful in specs and `--pretend` tooling.
      def self.db_type(logical : Symbol, adapter : Adapter, subtype : Symbol? = nil, size : Int32? = nil) : String
        if NativeTypes.extended?(logical)
          NativeTypes.db_type(logical, adapter, subtype, size)
        else
          Record.db_type(logical, adapter)
        end
      end

      # Pure SQL builders for the helpers that mix introspection with DDL
      # (used by the instance methods below and by SQL-generation specs).
      def self.add_column_sql(adapter : Adapter, table : String | Symbol, column : ColumnDef, if_not_exists : Bool = false) : String
        exists_sql = (if_not_exists && adapter == :postgres) ? " IF NOT EXISTS" : ""
        "ALTER TABLE #{Record.quote(table, adapter)} ADD COLUMN#{exists_sql} #{column.to_sql(adapter, table.to_s)}"
      end

      def self.drop_column_sql(adapter : Adapter, table : String | Symbol, column : String | Symbol, if_exists : Bool = false) : String
        exists_sql = (if_exists && adapter == :postgres) ? "IF EXISTS " : ""
        "ALTER TABLE #{Record.quote(table, adapter)} DROP COLUMN #{exists_sql}#{Record.quote(column, adapter)}"
      end

      # Alias kept for symmetry with the Rails helper name.
      def self.remove_index_sql(adapter : Adapter, table : String | Symbol, name : String | Symbol, if_exists : Bool = false, algorithm : Symbol? = nil) : String
        drop_index_sql(adapter, table, name, if_exists, algorithm)
      end

      # PostgreSQL nullability DDL (`SET`/`DROP NOT NULL`). MySQL needs
      # the full column definition, so it is rendered by the instance
      # helper from live introspection instead.
      def self.change_column_null_sql(adapter : Adapter, table : String | Symbol, column : String | Symbol, null : Bool) : String
        unless adapter == :postgres
          raise ArgumentError.new("change_column_null_sql is PostgreSQL-only as a pure builder (adapter: #{adapter}); use the migration helper for MySQL/SQLite")
        end
        action = null ? "DROP NOT NULL" : "SET NOT NULL"
        "ALTER TABLE #{Record.quote(table, adapter)} ALTER COLUMN #{Record.quote(column, adapter)} #{action}"
      end

      # `ALTER COLUMN ... SET/DROP DEFAULT` (PostgreSQL/MySQL).
      def self.change_column_default_sql(adapter : Adapter, table : String | Symbol, column : String | Symbol, default : Value) : String
        unless adapter == :postgres || adapter == :mysql
          raise ArgumentError.new("change_column_default_sql is not available for SQLite as a pure builder (table rebuild required)")
        end
        if d = Record.column_default_sql(default, adapter)
          "ALTER TABLE #{Record.quote(table, adapter)} ALTER COLUMN #{Record.quote(column, adapter)} SET DEFAULT #{d}"
        else
          "ALTER TABLE #{Record.quote(table, adapter)} ALTER COLUMN #{Record.quote(column, adapter)} DROP DEFAULT"
        end
      end

      @suppress_messages : Bool = false

      # Rails `reversible` director. The migration is replayed during
      # `down`, so the `down` block is queued as an inverse operation
      # instead of running immediately.
      class Reversible
        getter up_block : Proc(Nil)?
        getter down_block : Proc(Nil)?

        def up(&block : ->) : Nil
          @up_block = block
        end

        def down(&block : ->) : Nil
          @down_block = block
        end
      end

      # Queues operations for `change_table`. All methods delegate to the
      # normal migration helpers, so inversion behavior is identical:
      # `add`/`rename`/`index` auto-revert, `remove`/`change`/`remove_index`
      # are irreversible inside `change`.
      class TableChange
        def initialize(@migration : Migration, @table : String | Symbol)
        end

        def column(name : String | Symbol, type : Symbol, null : Bool = true, default : Value = nil, values : Array(String)? = nil, precision : Int32? = nil, if_not_exists : Bool = false, *, default_sql : String? = nil, subtype : Symbol? = nil, size : Int32? = nil, generated_as : String? = nil, stored : Bool = false) : Nil
          @migration.add_column(@table, name, type, null, default, values, precision, nil, if_not_exists,
            default_sql: default_sql, subtype: subtype, size: size, generated_as: generated_as, stored: stored)
        end

        def add(name : String | Symbol, type : Symbol, null : Bool = true, default : Value = nil, values : Array(String)? = nil, precision : Int32? = nil, if_not_exists : Bool = false, *, default_sql : String? = nil, subtype : Symbol? = nil, size : Int32? = nil, generated_as : String? = nil, stored : Bool = false) : Nil
          column(name, type, null, default, values, precision, if_not_exists,
            default_sql: default_sql, subtype: subtype, size: size, generated_as: generated_as, stored: stored)
        end

        def add_column(name : String | Symbol, type : Symbol, null : Bool = true, default : Value = nil, values : Array(String)? = nil, precision : Int32? = nil, if_not_exists : Bool = false) : Nil
          column(name, type, null, default, values, precision, if_not_exists)
        end

        # `t.datetime :at, precision: 6` inside change_table.
        def datetime(name : String | Symbol, null : Bool = true, default : Value = nil, precision : Int32? = nil, if_not_exists : Bool = false) : Nil
          column(name, :datetime, null, default, nil, precision, if_not_exists)
        end

        def remove(name : String | Symbol) : Nil
          @migration.remove_column(@table, name)
        end

        def remove_column(name : String | Symbol) : Nil
          remove(name)
        end

        def rename(old_name : String | Symbol, new_name : String | Symbol) : Nil
          @migration.rename_column(@table, old_name, new_name)
        end

        def rename_column(old_name : String | Symbol, new_name : String | Symbol) : Nil
          rename(old_name, new_name)
        end

        def change(name : String | Symbol, type : Symbol, null : Bool = true, default : Value = nil) : Nil
          @migration.change_column(@table, name, type, null, default)
        end

        def change_column(name : String | Symbol, type : Symbol, null : Bool = true, default : Value = nil) : Nil
          change(name, type, null, default)
        end

        def index(cols : String | Symbol | Array(String | Symbol), name : String? = nil, unique : Bool = false, if_not_exists : Bool = false) : Nil
          @migration.add_index(@table, cols, name, unique, if_not_exists)
        end

        def add_index(cols : String | Symbol | Array(String | Symbol), name : String? = nil, unique : Bool = false, if_not_exists : Bool = false) : Nil
          index(cols, name, unique, if_not_exists)
        end

        def remove_index(name : String | Symbol, *, column : String | Symbol | Array(String | Symbol) | Nil = nil) : Nil
          @migration.remove_index(@table, name, column: column)
        end

        def remove_index(columns : Array(String | Symbol), *, name : String? = nil) : Nil
          @migration.remove_index(@table, columns, name: name)
        end

        def remove_index(*, column : String | Symbol | Array(String | Symbol), name : String? = nil) : Nil
          @migration.remove_index(@table, column: column, name: name)
        end

        # Convenience typed helpers (Rails' `change_table` block reads
        # `t.string :x`, not only `t.column :x, :string`).
        {% for type in [:string, :text, :integer, :bigint, :float, :decimal, :date, :json, :boolean, :uuid, :binary] %}
          def {{type.id}}(name : String | Symbol, null : Bool = true, default : Value = nil) : Nil
            column(name, {{type}}, null, default)
          end
        {% end %}

        def references(name : String | Symbol, foreign_key : Bool | Symbol | Nil = false, null : Bool = true, index : Bool = true, to_table : String | Symbol | Nil = nil, on_delete : Symbol? = nil, *, type : Symbol = :bigint, polymorphic : Bool = false) : Nil
          @migration.add_reference(@table, name, type: type, foreign_key: foreign_key, null: null, index: index, to_table: to_table, on_delete: on_delete, polymorphic: polymorphic)
        end
      end

      # `reversible do |dir| dir.up { ... }; dir.down { ... } end`.
      # In `up` only the up block runs. While the migration is being
      # inverted the down block is queued; a missing down block raises
      # `IrreversibleMigration` when rolling back.
      def reversible(& : Reversible ->) : Nil
        dir = Reversible.new
        yield dir
        down = dir.down_block
        if @inverting
          unless down
            raise IrreversibleMigration.new("Cannot auto-invert this reversible block: no down block was given; define up/down instead of change.")
          end
          @inverse_ops << -> { run_normal { down.call }; nil }
        else
          dir.up_block.try(&.call)
        end
      end

      # Runs raw SQL. Irreversible inside `change` (Rails behavior) — use
      # `reversible` or `up`/`down`.
      def execute(sql : String) : Nil
        if @inverting
          raise IrreversibleMigration.new("Cannot auto-invert execute(#{sql.inspect}); wrap it in reversible or define up/down.")
        end
        Record.exec_compat(@db, sql)
      end

      # Reverts another migration (runs its `down` now) or, with a block,
      # runs the block in inversion mode and applies the inverse
      # operations immediately.
      def revert(klass : Migration.class) : Nil
        if @inverting
          @inverse_ops << -> { klass.new(@db).up; nil }
        else
          klass.new(@db).down
        end
      end

      def revert(& : ->) : Nil
        if @inverting
          # The surrounding change is being inverted, so reverting a block
          # means applying it forward.
          run_normal { yield }
          return
        end
        saved = @inverse_ops
        @inverse_ops = [] of (-> Nil)
        ops = [] of (-> Nil)
        begin
          run_inverting { yield }
          ops = @inverse_ops
        ensure
          @inverse_ops = saved
        end
        ops.reverse_each(&.call)
      end

      # Prints migration progress unless `suppress_messages` is active.
      def say(message : String, subitem : Bool = false) : Nil
        return if @suppress_messages
        puts(subitem ? "   -> #{message}" : "==  #{message}")
      end

      # Silences `say` inside the block (mirrors Rails).
      def suppress_messages(& : ->) : Nil
        previous = @suppress_messages
        @suppress_messages = true
        begin
          yield
        ensure
          @suppress_messages = previous
        end
      end

      # Yields a `TableChange` for adding/removing/renaming columns and
      # indexes on an existing table:
      #
      # ```
      # change_table :users do |t|
      #   t.column :nickname, :string
      #   t.rename :email, :mail
      #   t.index :nickname, unique: true
      #   t.remove :legacy
      # end
      # ```
      def change_table(table : String | Symbol, bulk : Bool = false, & : TableChange ->) : Nil
        yield TableChange.new(self, table)
      end

      # -- column helpers -------------------------------------------------

      # Changes a column's nullability. On rollback the opposite is
      # applied automatically (the helper is reversible by construction).
      # `default:` backfills existing NULLs before adding NOT NULL.
      #
      # PostgreSQL/MySQL alter in place; SQLite rebuilds the table
      # (preserving data, indexes, foreign keys and CHECK constraints) —
      # expression indexes and generated columns are refused because the
      # rebuild cannot reproduce them faithfully.
      def change_column_null(table : String | Symbol, column : String | Symbol, null : Bool, default : Value = nil) : Nil
        ad = Record.adapter_of(@db)
        tbl, col = table.to_s, column.to_s
        target_null = @inverting ? !null : null
        if !target_null && !default.nil?
          if d = Record.column_default_sql(default, ad)
            Record.exec_compat(@db, "UPDATE #{Record.quote(tbl, ad)} SET #{Record.quote(col, ad)} = #{d} WHERE #{Record.quote(col, ad)} IS NULL")
          end
        end
        apply_change_column_null(ad, tbl, col, target_null)
      end

      # Changes a column's default. The 3-argument form is irreversible on
      # rollback; pass `from:` (the previous default) to make it
      # reversible: `change_column_default :users, :role, "member", from: nil`.
      def change_column_default(table : String | Symbol, column : String | Symbol, default : Value) : Nil
        if @inverting
          raise IrreversibleMigration.new("Cannot auto-invert change_column_default #{table}.#{column}; pass from: with the previous default or define up/down.")
        end
        apply_change_column_default(Record.adapter_of(@db), table.to_s, column.to_s, default)
      end

      def change_column_default(table : String | Symbol, column : String | Symbol, default : Value, from : Value) : Nil
        target = @inverting ? from : default
        apply_change_column_default(Record.adapter_of(@db), table.to_s, column.to_s, target)
      end

      # Rails 7 keyword form: `change_column_default :t, :c, from: "a", to: "b"`.
      def change_column_default(table : String | Symbol, column : String | Symbol, *, from : Value, to : Value) : Nil
        change_column_default(table, column, to, from)
      end

      # Adds `created_at`/`updated_at` (NOT NULL by default). Auto-inverts
      # through `add_column`.
      def add_timestamps(table : String | Symbol, null : Bool = false, precision : Int32? = nil, if_not_exists : Bool = false) : Nil
        add_column(table, :created_at, :datetime, null, nil, nil, precision, nil, if_not_exists)
        add_column(table, :updated_at, :datetime, null, nil, nil, precision, nil, if_not_exists)
      end

      # Removes `created_at`/`updated_at`; reversible (the inverse adds
      # them back with the same nullability/precision).
      def remove_timestamps(table : String | Symbol, null : Bool = false, precision : Int32? = nil) : Nil
        if @inverting
          @inverse_ops << -> { add_timestamps(table, null, precision); nil }
          return
        end
        remove_column(table, :created_at, if_exists: true)
        remove_column(table, :updated_at, if_exists: true)
      end

      # -- references / join tables ---------------------------------------

      # Rails-style `add_reference` on an existing table.
      #
      # `polymorphic: true` adds `<ref>_type` + `<ref>_id` and indexes
      # both. `foreign_key:` is explicit opt-in (see `t.references`);
      # SQLite still refuses standalone FKs, so pass `foreign_key: false`
      # there (or declare it in `create_table`).
      def add_reference(table : String | Symbol, ref : String | Symbol, *, type : Symbol = :bigint, foreign_key : Bool | Symbol | Nil = false, null : Bool = true, index : Bool = true, polymorphic : Bool = false, to_table : String | Symbol | Nil = nil, on_delete : Symbol? = nil, deferrable : Symbol? = nil) : Nil
        tbl, name = table.to_s, ref.to_s
        id_col = "#{name}_id"
        add_column(tbl, id_col, type, null: null)
        index_name = if polymorphic
                       type_col = "#{name}_type"
                       add_column(tbl, type_col, :string, null: null)
                       "index_#{tbl}_on_#{name}"
                     else
                       "index_#{tbl}_on_#{id_col}"
                     end
        add_index(tbl, polymorphic ? ["#{name}_type", id_col] : id_col, name: index_name) if index
        if fk = foreign_key
          if polymorphic
            raise ArgumentError.new("add_reference #{tbl}.#{name}: polymorphic references cannot have a foreign key")
          end
          target = to_table ? to_table.to_s : (fk.is_a?(Symbol) ? fk.to_s : Record::Inflector.pluralize(name))
          add_foreign_key(tbl, target, column: id_col, on_delete: on_delete, deferrable: deferrable)
        end
      end

      def add_belongs_to(table : String | Symbol, ref : String | Symbol, **options)
        add_reference(table, ref, **options)
      end

      # Drops the reference column(s) and their index (and FK, when
      # `foreign_key: true`). Irreversible — use `up`/`down`.
      def remove_reference(table : String | Symbol, ref : String | Symbol, *, polymorphic : Bool = false, foreign_key : Bool = false, index : Bool = true) : Nil
        if @inverting
          raise IrreversibleMigration.new("Cannot auto-invert remove_reference #{table}.#{ref}; define up/down instead of change.")
        end
        tbl, name = table.to_s, ref.to_s
        id_col = "#{name}_id"
        if foreign_key
          remove_foreign_key(tbl, column: id_col) rescue nil
        end
        if index
          index_name = polymorphic ? "index_#{tbl}_on_#{name}" : "index_#{tbl}_on_#{id_col}"
          remove_index(tbl, index_name, if_exists: true)
        end
        remove_column(tbl, "#{name}_type") if polymorphic
        remove_column(tbl, id_col)
      end

      def remove_belongs_to(table : String | Symbol, ref : String | Symbol, **options)
        remove_reference(table, ref, **options)
      end

      # `create_join_table :products, :categories` creates
      # `categories_products` (sorted) with `category_id`/`product_id`,
      # no primary key, and one index per column. `table_name:` and
      # `column_options:` (`type:`, `null:`) are supported.
      def create_join_table(table_1 : String | Symbol, table_2 : String | Symbol, table_name : String? = nil, column_options : NamedTuple = NamedTuple.new, if_not_exists : Bool = false) : Nil
        tables = [table_1.to_s, table_2.to_s].sort
        join_name = table_name || tables.join("_")
        col_type = column_options[:type]?.try(&.to_s).try(&.to_sym) || :bigint
        col_null = case v = column_options[:null]?
                   when Nil then false
                   else          v == true || v.to_s == "true"
                   end
        create_table(join_name, id: false, if_not_exists: if_not_exists) do |t|
          tables.each { |tname| t.column(Migration.join_column_name(tname), col_type, null: col_null) }
        end
        tables.each do |tname|
          add_index(join_name, Migration.join_column_name(tname), if_not_exists: if_not_exists)
        end
      end

      def drop_join_table(table_1 : String | Symbol, table_2 : String | Symbol, table_name : String? = nil, if_exists : Bool = false) : Nil
        tables = [table_1.to_s, table_2.to_s].sort
        drop_table(table_name || tables.join("_"), if_exists: if_exists)
      end

      # Column name Rails uses on join tables: singularized `<table>_id`.
      def self.join_column_name(table : String | Symbol) : String
        fk_default_column(table)
      end

      # -- checks / validation -------------------------------------------

      # Adds a CHECK constraint (PostgreSQL/MySQL). SQLite cannot add one
      # to an existing table; use `t.check_constraint` inside
      # `create_table` there. Auto-inverts on rollback.
      def add_check_constraint(table : String | Symbol, expression : String, name : String | Symbol | Nil = nil, validate : Bool = true) : Nil
        ad = Record.adapter_of(@db)
        tbl = table.to_s
        cname = name.try(&.to_s) || Migration.generated_check_name(tbl, expression)
        if @inverting
          drop_sql = Migration.remove_check_constraint_sql(ad, tbl, cname, if_exists: true)
          @inverse_ops << -> { Record.exec_compat(@db, drop_sql); nil }
          return
        end
        Record.exec_compat(@db, Migration.add_check_constraint_sql(ad, tbl, expression, cname, validate))
      end

      def remove_check_constraint(table : String | Symbol, name : String | Symbol, if_exists : Bool = false) : Nil
        if @inverting
          raise IrreversibleMigration.new("Cannot auto-invert remove_check_constraint #{table}.#{name}; define up/down instead of change.")
        end
        ad = Record.adapter_of(@db)
        if if_exists && !Introspection.check_constraints(@db, table).any? { |c| c.name == name.to_s }
          return
        end
        Record.exec_compat(@db, Migration.remove_check_constraint_sql(ad, table, name, if_exists))
      end

      # PostgreSQL: validates a `NOT VALID` FK (no-op on MySQL, whose FKs
      # are always validated; unsupported on SQLite).
      def validate_foreign_key(table : String | Symbol, name : String | Symbol | Nil = nil, column : String | Symbol | Nil = nil) : Nil
        ad = Record.adapter_of(@db)
        return if ad == :mysql
        if ad == :sqlite
          raise ArgumentError.new("validate_foreign_key #{table} is not supported on SQLite (standalone foreign keys cannot be added)")
        end
        cname = name.try(&.to_s) || column.try { |c| Migration.fk_constraint_name(table, c) } ||
                raise ArgumentError.new("validate_foreign_key #{table}: give name: or column:")
        Record.exec_compat(@db, Migration.validate_constraint_sql(ad, table, cname))
      end

      def validate_check_constraint(table : String | Symbol, name : String | Symbol) : Nil
        ad = Record.adapter_of(@db)
        return if ad == :mysql
        if ad == :sqlite
          raise ArgumentError.new("validate_check_constraint #{table} is not supported on SQLite")
        end
        Record.exec_compat(@db, Migration.validate_constraint_sql(ad, table, name))
      end

      def self.generated_check_name(table : String, expression : String) : String
        slug = expression.downcase.gsub(/[^a-z0-9]+/, "_").strip('_')
        slug = slug[0, 40] if slug.size > 40
        "chk_#{table}_#{slug}"
      end

      # -- views / extensions --------------------------------------------

      # Creates a database view from a SELECT body. SQLite supports views
      # (and `IF NOT EXISTS`); PostgreSQL/MySQL support `OR REPLACE`.
      # Auto-inverts to `drop_view`.
      def create_view(name : String | Symbol, sql : String, if_not_exists : Bool = false, or_replace : Bool = false) : Nil
        ad = Record.adapter_of(@db)
        view = name.to_s
        if @inverting
          @inverse_ops << -> {
            Record.exec_compat(@db, Migration.drop_view_sql(ad, view, if_exists: true))
            nil
          }
          return
        end
        if ad == :sqlite && or_replace && Introspection.view_exists?(@db, view)
          Record.exec_compat(@db, Migration.drop_view_sql(ad, view, if_exists: true))
        elsif if_not_exists && !or_replace && ad != :sqlite && Introspection.view_exists?(@db, view)
          # PostgreSQL/MySQL have no IF NOT EXISTS for views.
          return
        end
        Record.exec_compat(@db, Migration.create_view_sql(ad, view, sql, if_not_exists, or_replace))
      end

      def drop_view(name : String | Symbol, if_exists : Bool = false) : Nil
        if @inverting
          raise IrreversibleMigration.new("Cannot auto-invert drop_view #{name}; define up/down instead of change.")
        end
        Record.exec_compat(@db, Migration.drop_view_sql(Record.adapter_of(@db), name, if_exists))
      end

      # PostgreSQL `CREATE EXTENSION [IF NOT EXISTS]`; no-op elsewhere.
      # Useful for `pgcrypto` on PostgreSQL < 13 (UUID defaults).
      def enable_extension(name : String | Symbol, if_not_exists : Bool = true) : Nil
        return unless Record.adapter_of(@db) == :postgres
        Record.exec_compat(@db, "CREATE EXTENSION#{if_not_exists ? " IF NOT EXISTS" : ""} #{Record.quote(name, :postgres)}")
      end

      def create_extension(name : String | Symbol, if_not_exists : Bool = true) : Nil
        enable_extension(name, if_not_exists)
      end

      # -- introspection shortcuts ---------------------------------------
      def table_exists?(table : String | Symbol) : Bool
        Introspection.table_exists?(@db, table)
      end

      def view_exists?(view : String | Symbol) : Bool
        Introspection.view_exists?(@db, view)
      end

      def data_source_exists?(name : String | Symbol) : Bool
        Introspection.data_source_exists?(@db, name)
      end

      def column_exists?(table : String | Symbol, column : String | Symbol) : Bool
        Introspection.column_exists?(@db, table, column)
      end

      def index_exists?(table : String | Symbol, columns : String | Symbol | Array(String | Symbol) | Nil = nil, name : String? = nil) : Bool
        Introspection.index_exists?(@db, table, columns, name)
      end

      def foreign_key_exists?(from_table : String | Symbol, to_table : String | Symbol | Nil = nil, column : String | Symbol | Nil = nil, name : String? = nil) : Bool
        Introspection.foreign_key_exists?(@db, from_table, to_table, column, name)
      end

      def columns(table : String | Symbol) : Array(Introspection::ColumnInfo)
        Introspection.columns(@db, table)
      end

      def indexes(table : String | Symbol) : Array(Introspection::IndexInfo)
        Introspection.indexes(@db, table)
      end

      def foreign_keys(table : String | Symbol) : Array(Introspection::ForeignKeyInfo)
        Introspection.foreign_keys(@db, table)
      end

      def check_constraints(table : String | Symbol) : Array(Introspection::CheckConstraintInfo)
        Introspection.check_constraints(@db, table)
      end

      # -- private helpers ------------------------------------------------

      private def run_normal(& : ->) : Nil
        previous = @inverting
        @inverting = false
        begin
          yield
        ensure
          @inverting = previous
        end
      end

      private def run_inverting(& : ->) : Nil
        previous = @inverting
        @inverting = true
        begin
          yield
        ensure
          @inverting = previous
        end
      end

      private def apply_change_column_null(ad : Adapter, table : String, column : String, null : Bool) : Nil
        case ad
        when :postgres
          action = null ? "DROP NOT NULL" : "SET NOT NULL"
          Record.exec_compat(@db, "ALTER TABLE #{Record.quote(table, ad)} ALTER COLUMN #{Record.quote(column, ad)} #{action}")
        when :mysql
          info = Introspection.columns(@db, table).find { |c| c.name == column }
          raise ArgumentError.new("change_column_null #{table}.#{column}: column does not exist") unless info
          definition = ColumnDef.new(column, info.type, null, info.default, info.primary_key, nil, nil,
            subtype: info.subtype, size: info.size, default_sql: info.default_sql).to_sql(ad)
          Record.exec_compat(@db, "ALTER TABLE #{Record.quote(table, ad)} MODIFY COLUMN #{definition}")
        else
          sqlite_rebuild_table(table) do |cols|
            cols.map do |c|
              c.name == column ? copy_column(c, null: null) : c
            end
          end
        end
      end

      private def apply_change_column_default(ad : Adapter, table : String, column : String, default : Value) : Nil
        case ad
        when :postgres, :mysql
          if d = Record.column_default_sql(default, ad)
            Record.exec_compat(@db, "ALTER TABLE #{Record.quote(table, ad)} ALTER COLUMN #{Record.quote(column, ad)} SET DEFAULT #{d}")
          else
            Record.exec_compat(@db, "ALTER TABLE #{Record.quote(table, ad)} ALTER COLUMN #{Record.quote(column, ad)} DROP DEFAULT")
          end
        else
          sqlite_rebuild_table(table) do |cols|
            cols.map do |c|
              c.name == column ? copy_column(c, default: default, default_sql: nil) : c
            end
          end
        end
      end

      private def copy_column(c : Introspection::ColumnInfo, *, null : Bool) : Introspection::ColumnInfo
        Introspection::ColumnInfo.new(
          c.name, c.type, null, c.default, c.primary_key, c.generated,
          c.generated_as, c.subtype, c.size, c.default_sql, c.stored
        )
      end

      private def copy_column(c : Introspection::ColumnInfo, *, default : Value, default_sql : String?) : Introspection::ColumnInfo
        Introspection::ColumnInfo.new(
          c.name, c.type, c.null, default, c.primary_key, c.generated,
          c.generated_as, c.subtype, c.size, default_sql, c.stored
        )
      end

      # Rebuilds a SQLite table in place (create new + copy + drop +
      # rename + recreate indexes). This is the only way to change a
      # column's nullability/default on SQLite. Data is preserved; the
      # original CREATE TABLE is not, so generated columns and expression
      # indexes are refused rather than silently losing their definition.
      private def sqlite_rebuild_table(table : String, & : Array(Introspection::ColumnInfo) -> Array(Introspection::ColumnInfo)) : Nil
        ad = :sqlite
        original = Introspection.columns(@db, table)
        raise ArgumentError.new("sqlite rebuild #{table}: table/columns not found") if original.empty?
        if original.any?(&.generated)
          raise ArgumentError.new("sqlite rebuild #{table}: generated columns are not supported by the rebuild path; recreate the table instead")
        end
        columns = yield original
        indexes = Introspection.indexes(@db, table)
        if indexes.any? { |ix| ix.columns.empty? }
          raise ArgumentError.new("sqlite rebuild #{table}: expression indexes cannot be reproduced by the rebuild path; recreate the table instead")
        end
        fks = Introspection.foreign_keys(@db, table)
        checks = Introspection.check_constraints(@db, table)

        rebuild = "#{table}__saci_rebuild"
        Record.exec_compat(@db, "DROP TABLE IF EXISTS #{Record.quote(rebuild, ad)}")
        col_sql = columns.map do |c|
          ColumnDef.new(c.name, c.type, c.null, c.default, c.primary_key, nil, nil,
            subtype: c.subtype, size: c.size, default_sql: c.default_sql).to_sql(ad, rebuild)
        end
        fk_sql = fks.map do |fk|
          Migration.create_table_fk_sql(ad, table, TableForeignKey.new(fk.column, fk.to_table, on_delete_symbol(fk.on_delete), fk.name, fk.deferrable))
        end
        check_sql = checks.map { |c| Migration.check_clause_sql(ad, TableCheck.new(c.expression, c.name)) }
        Record.exec_compat(@db, "CREATE TABLE #{Record.quote(rebuild, ad)} (#{(col_sql + fk_sql + check_sql).join(", ")})")

        names = columns.map { |c| Record.quote(c.name, ad) }
        unless names.empty?
          Record.exec_compat(@db, "INSERT INTO #{Record.quote(rebuild, ad)} (#{names.join(", ")}) SELECT #{names.join(", ")} FROM #{Record.quote(table, ad)}")
        end
        Record.exec_compat(@db, "DROP TABLE #{Record.quote(table, ad)}")
        Record.exec_compat(@db, "ALTER TABLE #{Record.quote(rebuild, ad)} RENAME TO #{Record.quote(table, ad)}")
        indexes.each do |ix|
          Record.exec_compat(@db, Migration.create_index_sql(ad, table, ix.columns, ix.name, unique: ix.unique))
        end
      end

      private def on_delete_symbol(value : String?) : Symbol?
        case value.try(&.upcase)
        when "CASCADE"   then :cascade
        when "SET NULL"  then :nullify
        when "RESTRICT"  then :restrict
        when "NO ACTION" then :no_action
        else                  nil
        end
      end
    end
  end
end
