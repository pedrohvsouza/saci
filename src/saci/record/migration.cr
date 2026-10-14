module Saci
  module Record
    # Column definition used by `TableDefinition` and `add_column`.
    # Stores the *logical* type; SQL renders per adapter (`to_sql`).
    struct ColumnDef
      getter name : String
      getter logical_type : Symbol
      getter null : Bool
      getter default_value : Value
      getter primary_key : Bool

      def initialize(@name, @logical_type, @null, @default_value, @primary_key)
      end

      def to_sql(adapter : Adapter = :sqlite) : String
        String.build do |s|
          s << "#{Record.quote(@name, adapter)} #{Record.db_type(@logical_type, adapter)}"
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

      def initialize
        @columns = [] of ColumnDef
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

      def boolean(name : String | Symbol, null : Bool = true, default : Value = nil)
        add(name, :boolean, null, default)
      end

      def datetime(name : String | Symbol, null : Bool = true, default : Value = nil)
        add(name, :datetime, null, default)
      end

      # Rails-like `t.timestamps` (NOT NULL, ORM maintains them on save).
      def timestamps
        @columns << ColumnDef.new("created_at", :datetime, false, nil, false)
        @columns << ColumnDef.new("updated_at", :datetime, false, nil, false)
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
    # `add_column`, `add_index`) for automatic rollback, or `up`/`down`
    # for full control. `drop_table`/`remove_column`/`remove_index` inside
    # `change` make rollback raise `IrreversibleMigration`.
    # NOTE: intentionally not abstract — `Migrator` instantiates migrations
    # through the `Migration.class` metaclass, which abstract classes forbid.
    class Migration
      @inverting : Bool = false
      @inverse_ops : Array(-> Nil) = [] of (-> Nil)

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
        if @inverting
          @inverse_ops << -> { Record.exec_compat(@db, "DROP TABLE #{Record.quote(tbl, ad)}"); nil }
          return
        end
        t = TableDefinition.new
        if id
          t.columns << ColumnDef.new("id", :serial, false, nil, true)
        end
        yield t
        cols_sql = t.columns.map(&.to_sql(ad)).join(", ")
        Record.exec_compat(@db, "CREATE TABLE #{Record.quote(tbl, ad)} (#{cols_sql})")
      end

      def drop_table(name : String | Symbol) : Nil
        if @inverting
          raise IrreversibleMigration.new("Cannot auto-invert drop_table #{name}; define up/down instead of change.")
        end
        ad = Record.adapter_of(@db)
        Record.exec_compat(@db, "DROP TABLE #{Record.quote(name, ad)}")
      end

      def add_column(table : String | Symbol, name : String | Symbol, type : Symbol, null : Bool = true, default : Value = nil) : Nil
        ad = Record.adapter_of(@db)
        tbl, col = table.to_s, name.to_s
        if @inverting
          @inverse_ops << -> { Record.exec_compat(@db, "ALTER TABLE #{Record.quote(tbl, ad)} DROP COLUMN #{Record.quote(col, ad)}"); nil }
          return
        end
        Record.exec_compat(@db, "ALTER TABLE #{Record.quote(tbl, ad)} ADD COLUMN #{ColumnDef.new(col, type, null, default, false).to_sql(ad)}")
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
