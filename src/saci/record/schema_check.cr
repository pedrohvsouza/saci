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

    # `has_and_belongs_to_many` join tables, registered by the macro as
    # `{owner, name}` (the name is resolved lazily: `table` may come later).
    @@habtm_join_tables = [] of {Base.class, Proc(String)}

    # Records a HABTM join table declared on `owner`. Called from
    # `has_and_belongs_to_many`.
    def self.register_habtm_join_table(owner : Base.class, &name : -> String) : Nil
      @@models_mutex.synchronize { @@habtm_join_tables << {owner, name} }
    end

    # Join tables declared via `has_and_belongs_to_many` on `models`.
    def self.habtm_join_tables(models : Array(Base.class) = models) : Array(String)
      entries = @@models_mutex.synchronize { @@habtm_join_tables.dup }
      entries.select { |(owner, _)| models.includes?(owner) }.map(&.[1].call).uniq
    end

    # Shadow-table suffixes SQLite creates for each virtual table module
    # (FTS5, FTS3/4, R*Tree).
    VIRTUAL_SHADOW_SUFFIXES = Introspection::SQLITE_SHADOW_SUFFIXES

    # SQLite virtual tables plus those of their shadow tables listed in
    # `tables` (empty on other adapters). They are internal to the module
    # that owns them, so they need no model.
    def self.virtual_tables(db : DB::Database | DB::Connection, tables : Enumerable(String)) : Array(String)
      return [] of String unless adapter_of(db) == :sqlite
      virtual = Introspection.sqlite_virtual_tables(db)
      shadows = virtual.flat_map(&.shadow_tables).to_set
      virtual.map(&.name) + tables.select { |t| shadows.includes?(t) }
    end

    # Tables the drift check never reports (no models by design: migration
    # bookkeeping and the durable job queue).
    SCHEMA_CHECK_SKIP_TABLES = ["schema_migrations", "saci_jobs", "saci_dead_jobs"]

    # Framework-owned tables (DB-backed jobs, cache, cable, mailbox...) are
    # created by the feature that uses them, never by an app migration.
    FRAMEWORK_TABLE_PREFIX = "saci_"

    # Models Saci itself defines (`Saci::Mailbox::InboundEmail`,
    # `Saci::Storage::Blob`, ...). They are registered just by being
    # compiled in, whether or not the app uses the feature, so a missing
    # table means "feature not set up", not drift.
    def self.framework_model?(model : Base.class) : Bool
      model.name.starts_with?("Saci::")
    end

    # Compares the database against the registered models and returns one
    # warning string per mismatch (never raises on drift):
    #
    # * table in the DB with no registered model (SQLite virtual tables,
    #   their shadow tables and HABTM join tables are known),
    # * model whose table is missing from the DB,
    # * DB column with no mapping in the model,
    # * model column missing from the DB table.
    #
    # Comparison is adapter-agnostic (table/column NAMES only — types are
    # intentionally ignored). Column-less models (e.g. `ApplicationRecord`
    # intermediates) are skipped: they own no table by design. Framework
    # models are only checked once their table exists, and `saci_*` tables
    # without a model belong to framework features, so neither shows up as
    # drift in an app that never enabled the feature.
    #
    # Only the models living in the checked database are compared (their
    # `connects_to` name, `"primary"` without one), so a multi-database app
    # gets no cross-database noise. `database_name` defaults to the name `db`
    # is registered under (`"primary"` when it is not registered).
    #
    # ```
    # Saci::Record.check_schema!.each { |w| STDERR.puts "warning: #{w}" }
    # Saci::Record.check_schema!(Saci::Record.database("platform"))
    # ```
    def self.check_schema!(db : DB::Database | DB::Connection = connection, models : Array(Base.class) = models, database_name : String? = nil) : Array(String)
      database_name ||= database_name_of(db) || "primary"
      models = models.select { |m| m.__saci_database_name == database_name }
      warnings = [] of String
      db_tables = db_tables(db)
      by_table = {} of String => Base.class
      models.each do |m|
        next if m.__saci_column_names.empty?
        by_table[m.table_name] ||= m
      end
      known = habtm_join_tables(models) + virtual_tables(db, db_tables.keys)
      db_tables.each_key do |t|
        next if SCHEMA_CHECK_SKIP_TABLES.includes?(t) || known.includes?(t)
        unless by_table.has_key?(t) || t.starts_with?(FRAMEWORK_TABLE_PREFIX)
          warnings << "Table #{t.inspect} exists in the database but has no registered model (missing model?)"
        end
      end
      by_table.each do |t, m|
        db_cols = db_tables[t]?
        if db_cols.nil?
          next if framework_model?(m)
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

    # Name a database is registered under (`establish_connection`/`connect`),
    # nil for an unregistered database or a transaction connection.
    def self.database_name_of(db : DB::Database | DB::Connection) : String?
      @@databases_mutex.synchronize { @@databases.find { |_, d| d.same?(db) }.try(&.[0]) }
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
