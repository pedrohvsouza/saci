module Saci
  module Record
    # Model registry + schema drift check (DB vs models).
    #
    # Every `Saci::Record::Base` subclass self-registers through
    # `Base.inherited` (mirroring `Saci::Job.register` for jobs), so
    # `Saci::Record.models` always reflects the loaded models without any
    # manual bookkeeping.
    @@models = [] of Base.class
    @@models_mutex = Mutex.new

    # Registers one model class. Called from `Base.inherited`; safe to call
    # manually for classes defined before this file was required.
    def self.register_model(klass : Base.class) : Nil
      @@models_mutex.synchronize do
        @@models << klass unless @@models.includes?(klass)
      end
    end

    # All registered model classes (load order, deduplicated).
    def self.models : Array(Base.class)
      @@models_mutex.synchronize { @@models.dup }
    end

    # Tables the drift check never reports (no models by design: migration
    # bookkeeping and the durable job queue).
    SCHEMA_CHECK_SKIP_TABLES = ["schema_migrations", "saci_jobs", "saci_dead_jobs"]

    # Compares the database against the registered models and returns one
    # warning string per mismatch (never raises on drift):
    #
    # * table in the DB with no registered model,
    # * model whose table is missing from the DB,
    # * DB column with no mapping in the model,
    # * model column missing from the DB table.
    #
    # Comparison is adapter-agnostic (table/column NAMES only — types are
    # intentionally ignored). Column-less models (e.g. `ApplicationRecord`
    # intermediates) are skipped: they own no table by design.
    #
    # ```
    # Saci::Record.check_schema!.each { |w| STDERR.puts "warning: #{w}" }
    # ```
    def self.check_schema!(db : DB::Database | DB::Connection = connection, models : Array(Base.class) = models) : Array(String)
      warnings = [] of String
      db_tables = db_tables(db)
      by_table = {} of String => Base.class
      models.each do |m|
        next if m.__saci_column_names.empty?
        by_table[m.table_name] ||= m
      end
      db_tables.each_key do |t|
        next if SCHEMA_CHECK_SKIP_TABLES.includes?(t)
        unless by_table.has_key?(t)
          warnings << "Table #{t.inspect} exists in the database but has no registered model (missing model?)"
        end
      end
      by_table.each do |t, m|
        db_cols = db_tables[t]?
        if db_cols.nil?
          warnings << "Model #{m.name} (table #{t.inspect}) has no matching table in the database (missing migration?)"
          next
        end
        model_cols = m.__saci_column_names.map(&.[0])
        (db_cols - model_cols).each do |c|
          warnings << "Table #{t.inspect} has column #{c.inspect} with no mapping in model #{m.name} (missing column declaration?)"
        end
        (model_cols - db_cols).each do |c|
          warnings << "Model #{m.name} declares column #{c.inspect} missing from table #{t.inspect} (missing migration?)"
        end
      end
      warnings.sort
    end

    # Every table in the database mapped to its column NAMES (types are not
    # compared — the drift check is names-only). Delegates to the single
    # introspection home in `record/schema.cr`.
    def self.db_tables(db : DB::Database | DB::Connection) : Hash(String, Array(String))
      # `timestamps` means created_at/updated_at exist but are folded out of
      # `columns` for dump purposes — unfold them here; the check is names-only.
      Schema.introspect(db).to_h { |t| {t.name, t.columns.map(&.name) + (t.timestamps ? ["created_at", "updated_at"] : [] of String)} }
    end

    # Column NAMES of one table (see `db_tables`).
    def self.db_columns(db : DB::Database | DB::Connection, table : String, adapter : Adapter = adapter_of(db)) : Array(String)
      db_tables(db)[table]? || [] of String
    end
  end
end
