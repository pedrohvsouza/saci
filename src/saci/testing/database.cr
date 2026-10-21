require "file_utils"

module Saci
  module Testing
    # Test database lifecycle: create a SQLite test database, run the
    # registered migrations, load an optional schema file, and clean tables
    # between runs.
    #
    # Environment variables:
    # * `SACI_TEST_DATABASE_URL` — full connection URL (highest priority).
    # * `DATABASE_URL` — used when the above is unset.
    # * `SACI_TEST_DB` — SQLite file path used to build the default URL
    #   (`sqlite3://./tmp/saci_test.db` when unset).
    # * `SACI_TEST_WORKER` — worker index for `Saci::Testing.parallelize`
    #   (see `parallel.cr`).
    #
    # ```
    # Spec.before_suite do
    #   Saci::Testing.prepare_database!(fresh: true)
    # end
    #
    # Spec.before_each do
    #   Saci::Testing.clean_database!
    # end
    # ```
    #
    # Migrations self-register when `saci/testing` is required before the
    # migration classes are defined. Migrations defined earlier (or loaded
    # conditionally) can be registered explicitly:
    #
    # ```
    # Saci::Testing.register_migrations(CreateUsers, CreatePosts)
    # ```
    @@opened_url : String? = nil
    @@opened_db : DB::Database? = nil
    @@db_mutex = Mutex.new

    # Connection URL for the test database (see env vars above).
    def self.database_url : String
      ENV["SACI_TEST_DATABASE_URL"]? || ENV["DATABASE_URL"]? || sqlite_url_for(default_database_path)
    end

    def self.default_database_path : String
      ENV["SACI_TEST_DB"]? || "tmp/saci_test.db"
    end

    def self.sqlite_url_for(path : String) : String
      return path if path.starts_with?("sqlite3://")
      if Path[path].absolute?
        "sqlite3://#{path}"
      else
        "sqlite3://./#{path}"
      end
    end

    def self.sqlite_path_from_url(url : String) : String?
      return nil unless url.starts_with?("sqlite3://")
      path = url.sub("sqlite3://", "")
      path = path.split('?', 2)[0]
      return nil if path.empty? || path == ":memory:"
      path
    end

    # Opens (or reuses) the test database and makes it the ORM's primary
    # connection.
    #
    # * `fresh: true` deletes an existing SQLite file first (ignored for
    #   non-SQLite URLs — never point `fresh: true` at a database you care
    #   about).
    # * `migrations:` defaults to every self-registered migration.
    # * `schema:` is an optional path to a `.sql` file executed after
    #   migrations (idempotent only if the SQL is).
    # * `clean: true` truncates all tables after setup.
    def self.prepare_database!(url : String? = nil, migrations : Array(Record::Migration.class)? = nil,
                               schema : String? = nil, clean : Bool = false, fresh : Bool = false) : DB::Database
      url = url || database_url
      @@db_mutex.synchronize do
        if fresh || url != @@opened_url
          close_opened_database_unlocked!
          if fresh
            if path = sqlite_path_from_url(url)
              delete_sqlite_files(path)
            end
          end
          if path = sqlite_path_from_url(url)
            dir = File.dirname(path)
            Dir.mkdir_p(dir) unless dir.empty? || dir == "."
          end
          db = Record.connect(url)
          @@opened_url = url
          @@opened_db = db
          Fixtures.reset_schema_cache!
          Fixtures.clear_rows!
        end
      end

      # Other specs may have replaced the global primary connection; restore
      # the database this helper owns so lifecycle tests stay isolated in a
      # full-suite run.
      db = @@opened_db || Record.database("primary")
      ensure_primary_connection!(db)
      migrate!(db, migrations || Record::Migration.test_migrations)
      load_schema!(schema) if schema
      Record.clean_database! if clean
      db
    end

    # Ensures the schema is up to date without dropping data. Returns the
    # names of migrations applied by this call.
    def self.maintain_test_schema!(url : String? = nil, migrations : Array(Record::Migration.class)? = nil) : Array(String)
      url = url || @@opened_url || database_url
      if @@opened_url != url
        prepare_database!(url)
      end
      db = @@opened_db || Record.database("primary")
      ensure_primary_connection!(db)
      migrate!(db, migrations || Record::Migration.test_migrations)
    end

    # Restores the helper-owned database as the global primary connection
    # when another spec replaced it.
    private def self.ensure_primary_connection!(db : DB::Database) : Nil
      current = begin
        Record.database("primary")
      rescue
        nil
      end
      Record.connection = db unless current == db
    end

    # Runs a `.sql` schema file (statement splitting understands quotes and
    # `--` comments; stored procedures are out of scope).
    def self.load_schema!(path : String) : Nil
      unless File.exists?(path)
        raise ArgumentError.new("Saci::Testing.load_schema!: file not found: #{path}")
      end
      load_schema_sql!(File.read(path))
    end

    def self.load_schema_sql!(sql : String) : Nil
      db = Record.database("primary")
      split_sql_statements(sql).each do |statement|
        Record.exec_compat(db, statement)
      end
    end

    # Explicit registration for migrations defined before `saci/testing`
    # was required.
    macro register_migrations(*classes)
      {% for klass in classes %}
        Saci::Record::Migration.register_test_migration({{klass}})
      {% end %}
    end

    # Names of migrations currently registered for the test database.
    def self.registered_migrations : Array(String)
      Record::Migration.test_migrations.map(&.name)
    end

    def self.migrate!(db : DB::Database, migrations : Array(Record::Migration.class)) : Array(String)
      return [] of String if migrations.empty?
      Record::Migrator.migrate(db, migrations)
    end

    # Closes a connection previously opened by `prepare_database!`.
    def self.close_opened_database! : Nil
      @@db_mutex.synchronize { close_opened_database_unlocked! }
    end

    private def self.close_opened_database_unlocked! : Nil
      if @@opened_url
        begin
          Record.database("primary").close
        rescue
          # Nothing to close / already closed.
        end
        @@opened_url = nil
      end
    end

    def self.opened_url : String?
      @@opened_url
    end

    private def self.delete_sqlite_files(path : String) : Nil
      [path, "#{path}-wal", "#{path}-shm"].each do |file|
        File.delete(file) if File.exists?(file)
      rescue
        # Locked files are best-effort; SQLite will recreate them.
      end
    end

    # Splits a schema dump into statements. Semicolons inside single/double
    # quotes or backticks do not terminate a statement; `--` comments are
    # skipped.
    def self.split_sql_statements(sql : String) : Array(String)
      statements = [] of String
      current = IO::Memory.new
      quote : Char? = nil
      i = 0
      while i < sql.size
        ch = sql[i]
        if q = quote
          current << ch
          if ch == q
            if sql[i + 1]? == q
              current << sql[i + 1]
              i += 2
              next
            end
            quote = nil
          end
        elsif ch == '\'' || ch == '"' || ch == '`'
          quote = ch
          current << ch
        elsif ch == '-' && sql[i + 1]? == '-'
          newline = sql.index('\n', i)
          i = newline || sql.size
          current << '\n'
          next
        elsif ch == ';'
          statement = current.to_s.strip
          statements << statement unless statement.empty?
          current = IO::Memory.new
        else
          current << ch
        end
        i += 1
      end
      statement = current.to_s.strip
      statements << statement unless statement.empty?
      statements
    end
  end
end
