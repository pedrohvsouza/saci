require "yaml"
require "set"

module Saci
  module Testing
    # YAML fixture loader (Rails `fixtures :users` equivalent).
    #
    # A fixture file is named after its table and contains one mapping per
    # fixture label:
    #
    # ```yaml
    # # spec/fixtures/users.yml
    # alice:
    #   name: Alice
    #   email: alice@example.com
    #   admin: false
    #   team_id: teams.alpha   # label reference (no ERB needed)
    # bob:
    #   name: Bob
    #   email: bob@example.com
    # ```
    #
    # Labels are mapped to primary keys at insert time. A value of the form
    # `table.label` in a `*_id` column is resolved to the referenced
    # fixture's id; plain `label` values infer the table from the column
    # (`user_id` → `users`). Rows may reference fixtures defined later in
    # the load set — the loader inserts everything it can and retries the
    # rest, so file order does not matter. Cycles are reported.
    #
    # Columns omitted from the YAML are omitted from the INSERT, so database
    # defaults apply. `created_at`/`updated_at` are filled automatically
    # when the table has those columns (`t.timestamps` makes them NOT NULL
    # with no DB default).
    #
    # ERB is intentionally not implemented: use plain YAML plus label
    # references instead. A `<%= ... %>` value raises a helpful error.
    module Fixtures
      class FixtureLoadError < Exception
      end

      class Row
        getter table : String
        getter label : String
        getter id : Record::Value
        getter attrs : Hash(String, Record::Value)

        def initialize(@table : String, @label : String, @id : Record::Value, @attrs : Hash(String, Record::Value))
        end
      end

      record Config, tables : Array(String), path : String?, delete_existing : Bool

      class Pending
        getter table : String
        getter label : String
        getter attrs : Hash(String, Record::Value)

        def initialize(@table : String, @label : String, @attrs : Hash(String, Record::Value))
        end
      end

      @@mutex = Mutex.new
      @@configs = [] of Config
      @@rows = {} of String => Hash(String, Row)
      @@label_ids = {} of String => Hash(String, Record::Value)
      @@columns = {} of String => Array(String)
      @@suite_hook = false

      def self.default_path : String
        ENV["SACI_FIXTURES_PATH"]? || "spec/fixtures"
      end

      # Registers a `load_fixtures` declaration. `tables` may contain
      # `"all"` to load every YAML file in `path`.
      def self.register_config(tables : Array(String), path : String?, delete_existing : Bool = true) : Nil
        @@mutex.synchronize do
          @@configs << Config.new(tables, path, delete_existing)
        end
        ensure_suite_hook!
      end

      # Installs the `Spec.before_suite` loader once per process.
      def self.ensure_suite_hook! : Nil
        already = @@mutex.synchronize do
          previous = @@suite_hook
          @@suite_hook = true
          previous
        end
        return if already
        Spec.before_suite { load_registered! }
      end

      # Loads every registered `load_fixtures` declaration.
      def self.load_registered! : Nil
        configs = @@mutex.synchronize { @@configs.dup }
        configs.each do |config|
          path = config.path || default_path
          files = if config.tables.includes?("all")
                    fixture_files(path)
                  else
                    config.tables.map { |table| {fixture_file(path, table), table} }
                  end
          load_files(files, config.delete_existing)
        end
      end

      # Loads one fixture file or a fixture directory.
      #
      # ```
      # Saci::Testing::Fixtures.load("spec/fixtures")
      # Saci::Testing::Fixtures.load("spec/fixtures/users.yml", table: "users")
      # ```
      #
      # Returns the rows inserted by this call.
      def self.load(path_or_dir : String, table : String? = nil, delete_existing : Bool = true) : Array(Row)
        files = if File.directory?(path_or_dir)
                  raise ArgumentError.new("Fixtures.load: table: is not valid with a directory") if table
                  fixture_files(path_or_dir)
                else
                  raise FixtureLoadError.new("Fixture file not found: #{path_or_dir}") unless File.exists?(path_or_dir)
                  [{path_or_dir, table || table_name_for(path_or_dir)}]
                end
        load_files(files, delete_existing)
      end

      # Re-runs every registered fixture declaration from scratch.
      def self.reload! : Nil
        clear_rows!
        load_registered!
      end

      # Fixture row for a label. Registered fixtures are loaded on first
      # access to a table, but a missing *label* in an already-loaded table
      # returns nil (reloading there would desync ids inside a rolled-back
      # transactional test).
      def self.row_for(table : String, label : String | Symbol) : Row?
        key = label.to_s
        found = @@mutex.synchronize { @@rows[table]?.try(&.[key]?) }
        return found if found

        table_loaded = @@mutex.synchronize { @@rows.has_key?(table) }
        return nil if table_loaded

        load_registered!
        @@mutex.synchronize { @@rows[table]?.try(&.[key]?) }
      end

      # Fetches the model record for a fixture label through the model's
      # primary key (`users(:alice)`-style accessors call this).
      def self.fetch(model : T.class, table : String, label : String | Symbol) : T forall T
        row = row_for(table, label) ||
              raise FixtureLoadError.new("No fixture #{table}.#{label} (loaded fixtures: #{loaded_labels.inspect})")
        model.find(row.id)
      end

      def self.fetch?(model : T.class, table : String, label : String | Symbol) : T? forall T
        row = row_for(table, label)
        row ? model.find(row.id) : nil
      end

      # The numeric/string id assigned to `table.label` (`nil` when unknown).
      def self.id_for(table : String, label : String | Symbol) : Record::Value
        @@mutex.synchronize { @@label_ids[table]?.try(&.[label.to_s]?) }
      end

      def self.rows(table : String) : Array(Row)
        @@mutex.synchronize { @@rows[table]?.try(&.values) || [] of Row }
      end

      def self.loaded? : Bool
        @@mutex.synchronize { !@@rows.empty? }
      end

      def self.loaded_labels : Hash(String, Array(String))
        @@mutex.synchronize do
          @@rows.transform_values { |rows| rows.keys.sort }
        end
      end

      # Test isolation: clears loaded rows/labels and registered configs.
      def self.reset! : Nil
        @@mutex.synchronize do
          @@configs.clear
          @@rows.clear
          @@label_ids.clear
          @@columns.clear
        end
      end

      # Clears rows but keeps registered `load_fixtures` declarations.
      def self.clear_rows! : Nil
        @@mutex.synchronize do
          @@rows.clear
          @@label_ids.clear
        end
      end

      # Schema caches are invalidated when `prepare_database!` opens a new
      # database file.
      def self.reset_schema_cache! : Nil
        @@mutex.synchronize { @@columns.clear }
      end

      private def self.fixture_files(dir : String) : Array(Tuple(String, String))
        raise FixtureLoadError.new("Fixture directory not found: #{dir}") unless Dir.exists?(dir)
        files = (Dir.glob(File.join(dir, "*.yml")) + Dir.glob(File.join(dir, "*.yaml"))).sort
        files.map { |file| {file, table_name_for(file)} }
      end

      private def self.fixture_file(dir : String, table : String) : String
        yml = File.join(dir, "#{table}.yml")
        yaml = File.join(dir, "#{table}.yaml")
        if File.exists?(yml)
          yml
        elsif File.exists?(yaml)
          yaml
        else
          raise FixtureLoadError.new("Fixture file not found for table #{table.inspect} in #{dir}")
        end
      end

      private def self.table_name_for(path : String) : String
        File.basename(path).sub(/\.ya?ml$/, "")
      end

      private def self.load_files(files : Array(Tuple(String, String)), delete_existing : Bool) : Array(Row)
        tables = files.map(&.[1]).uniq
        return [] of Row if tables.empty?

        # Parse everything before touching state: a YAML/ERB error must not
        # clear the in-memory view of the database.
        pending = [] of Pending
        files.each do |(path, table)|
          parse_file(path, table, pending)
        end

        # Reset the loaded view for the tables in this batch; other tables
        # (and their labels) stay available for cross-file references.
        @@mutex.synchronize do
          tables.each do |table|
            @@rows[table] = {} of String => Row
            @@label_ids[table] = {} of String => Record::Value
          end
        end

        tables.each do |table|
          ensure_table!(table)
          delete_rows(table) if delete_existing
        end

        # Explicit ids are known before insertion, so forward references to
        # those labels resolve immediately.
        pending.each do |row|
          if id = row.attrs["id"]?
            @@mutex.synchronize { @@label_ids[row.table][row.label] = id }
          end
        end

        inserted = [] of Row
        remaining = pending
        loop do
          progress = false
          deferred = [] of Pending
          remaining.each do |row|
            if resolve_references(row)
              inserted << insert_row(row)
              progress = true
            else
              deferred << row
            end
          end
          remaining = deferred
          break if remaining.empty? || !progress
        end

        unless remaining.empty?
          details = remaining.map { |row| "#{row.table}.#{row.label}" }.join(", ")
          raise FixtureLoadError.new("Unresolved fixture references (missing labels or cyclic dependencies): #{details}. Loaded labels: #{loaded_labels.inspect}")
        end

        inserted
      end

      private def self.parse_file(path : String, table : String, pending : Array(Pending)) : Nil
        raise FixtureLoadError.new("Fixture file not found: #{path}") unless File.exists?(path)
        doc = YAML.parse(File.read(path))
        mapping = doc.as_h?
        unless mapping
          raise FixtureLoadError.new("Fixture file #{path} must contain a mapping of label => attributes")
        end
        mapping.each do |label_any, attrs_any|
          label = label_any.as_s? || label_any.raw.to_s
          next if label.starts_with?("_") # Rails fixture metadata convention
          attrs = {} of String => Record::Value
          if raw = attrs_any.raw
            hash = attrs_any.as_h?
            unless hash
              raise FixtureLoadError.new("Fixture #{table}.#{label} in #{path} must be a mapping (or empty)")
            end
            hash.each do |key_any, value_any|
              key = key_any.as_s? || key_any.raw.to_s
              next if key.starts_with?("_")
              attrs[key] = yaml_value(value_any, table, label, key)
            end
          end
          pending << Pending.new(table, label, attrs)
        end
      rescue ex : YAML::ParseException
        raise FixtureLoadError.new("Invalid YAML in #{path}: #{ex.message}")
      end

      private def self.yaml_value(value : YAML::Any, table : String, label : String, column : String) : Record::Value
        case raw = value.raw
        when Nil
          nil
        when Bool, Int64, Float64, String, Time, Bytes
          if raw.is_a?(String) && raw.includes?("<%")
            raise FixtureLoadError.new("Fixture #{table}.#{label}.#{column}: ERB is not supported; use a plain value or a table.label reference")
          end
          raw
        when Array
          raw.map { |item| item.as_s? || item.raw.to_s }
        when Set
          raw.map { |item| item.as_s? || item.raw.to_s }
        else
          raw.to_s
        end
      end

      private def self.resolve_references(row : Pending) : Bool
        row.attrs.each do |column, value|
          next unless column.ends_with?("_id")
          next unless value.is_a?(String)
          str = value.as(String)
          if numeric = str.to_i64?
            row.attrs[column] = numeric
            next
          end

          table, label = if dot = str.index('.')
                           {str[0...dot], str[(dot + 1)..-1]}
                         else
                           {Record::Inflector.pluralize(column[0...-3]), str}
                         end
          id = @@mutex.synchronize do
            found = @@label_ids[table]?.try(&.[label]?)
            # Plain labels fall back to a unique match across loaded tables
            # (helps when fixture table names are prefixed, e.g. testing_users).
            if found.nil? && !str.includes?('.')
              matches = @@label_ids.compact_map { |candidate_table, labels| labels[label]?.try { |value| {candidate_table, value} } }
              found = matches.first[1] if matches.size == 1
            end
            found
          end
          return false if id.nil?
          row.attrs[column] = id
        end
        true
      end

      private def self.insert_row(row : Pending) : Row
        conn = Record.connection
        adapter = Record.adapter_of(conn)
        attrs = row.attrs
        columns = table_columns(row.table)
        unknown = attrs.keys.reject { |name| columns.includes?(name) }
        unless unknown.empty?
          raise FixtureLoadError.new("Fixture #{row.table}.#{row.label}: unknown column(s) #{unknown.join(", ")} (table columns: #{columns.join(", ")})")
        end

        # Saci's t.timestamps columns are NOT NULL with no DB default.
        if columns.includes?("created_at") && !attrs.has_key?("created_at")
          attrs["created_at"] = Testing.current_time
        end
        if columns.includes?("updated_at") && !attrs.has_key?("updated_at")
          attrs["updated_at"] = Testing.current_time
        end

        table_sql = Record.quote(row.table, adapter)
        names = attrs.keys.map { |name| Record.quote(name, adapter) }
        values = attrs.map { |(_, value)| Record.to_db(value, adapter) }

        id : Record::Value = attrs["id"]?
        if attrs.empty?
          # SQLite/PostgreSQL `DEFAULT VALUES`; MySQL's equivalent is `() VALUES ()`.
          base_sql = adapter == :mysql ? "INSERT INTO #{table_sql} () VALUES ()" : "INSERT INTO #{table_sql} DEFAULT VALUES"
          if adapter == :postgres
            Record.query_compat(conn, "#{base_sql} RETURNING #{Record.quote("id", adapter)}") do |rs|
              rs.each { id = rs.read(Int64?) }
            end
          else
            result = Record.exec_compat(conn, base_sql)
            id ||= result.last_insert_id
          end
        elsif adapter == :postgres
          sql = "INSERT INTO #{table_sql} (#{names.join(", ")}) VALUES (#{attrs.keys.map { "?" }.join(", ")}) RETURNING #{Record.quote("id", adapter)}"
          Record.query_compat(conn, sql, values) do |rs|
            rs.each { id = rs.read(Int64?) }
          end
        else
          result = Record.exec_compat(conn, "INSERT INTO #{table_sql} (#{names.join(", ")}) VALUES (#{attrs.keys.map { "?" }.join(", ")})", values)
          id ||= result.last_insert_id
        end

        if id.nil?
          raise FixtureLoadError.new("Fixture #{row.table}.#{row.label}: could not determine primary key (fixtures require an integer 'id' column)")
        end
        attrs["id"] = id unless attrs.has_key?("id")
        inserted = Row.new(row.table, row.label, id, attrs)
        @@mutex.synchronize do
          @@label_ids[row.table][row.label] = id
          @@rows[row.table][row.label] = inserted
        end
        inserted
      rescue ex : FixtureLoadError
        raise ex
      rescue ex
        raise FixtureLoadError.new("Fixture #{row.table}.#{row.label}: #{ex.message}")
      end

      private def self.delete_rows(table : String) : Nil
        conn = Record.connection
        adapter = Record.adapter_of(conn)
        Record.exec_compat(conn, "DELETE FROM #{Record.quote(table, adapter)}")
      rescue ex
        raise FixtureLoadError.new("Could not delete existing rows from #{table}: #{ex.message}")
      end

      private def self.ensure_table!(table : String) : Nil
        table_columns(table)
      end

      private def self.table_columns(table : String) : Array(String)
        @@mutex.synchronize do
          if cached = @@columns[table]?
            return cached
          end
        end

        conn = Record.connection
        adapter = Record.adapter_of(conn)
        columns = [] of String
        case adapter
        when :sqlite
          # The table-valued pragma exposes just one column; `PRAGMA
          # table_info(x)` returns cid/name/type/... and reading column 0 as
          # a String would hit cid first.
          Record.query_compat(conn, "SELECT name FROM pragma_table_info(?)", [table] of Record::Value) do |rs|
            rs.each { columns << rs.read(String) }
          end
        when :postgres
          Record.query_compat(conn, "SELECT column_name FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = ?", [table] of Record::Value) do |rs|
            rs.each { columns << rs.read(String) }
          end
        when :mysql
          Record.query_compat(conn, "SELECT column_name FROM information_schema.columns WHERE table_schema = DATABASE() AND table_name = ?", [table] of Record::Value) do |rs|
            rs.each { columns << rs.read(String) }
          end
        end

        if columns.empty?
          raise FixtureLoadError.new("Fixture table #{table.inspect} does not exist (run Saci::Testing.prepare_database! / migrations first)")
        end
        @@mutex.synchronize { @@columns[table] = columns }
        columns
      end
    end

    # Compile-time DSL included into the spec's top level by
    # `saci/testing.cr`.
    #
    # ```
    # load_fixtures :all   # suite hook, path: spec/fixtures
    # fixture :users, User # generates users(:alice)
    # fixture :posts, Post # generates posts(:hello)
    # ```
    #
    # `fixture` must be used at file/module scope (Crystal cannot define
    # methods inside a `describe` block). `load_fixtures` may be used inside
    # a `describe` block; it only registers a suite hook.
    module FixtureDSL
      macro load_fixtures(*tables, path = nil, delete_existing = true)
        {% names = [] of StringLiteral %}
        {% for table in tables %}{% names << table.id.stringify %}{% end %}
        Saci::Testing::Fixtures.register_config(
          [{{names.join(", ")}}],
          {{path}},
          {{delete_existing}}
        )
      end

      # Alias matching Rails' spelling.
      macro fixtures(*tables, path = nil, delete_existing = true)
        {% names = [] of StringLiteral %}
        {% for table in tables %}{% names << table.id.stringify %}{% end %}
        Saci::Testing::Fixtures.register_config(
          [{{names.join(", ")}}],
          {{path}},
          {{delete_existing}}
        )
      end

      # Defines `<table>(label)` and `<table>?(label)` accessors returning
      # strongly typed models.
      macro fixture(table, model)
        def {{table.id}}(label : String | Symbol) : {{model}}
          Saci::Testing::Fixtures.fetch({{model}}, {{table.id.stringify}}, label)
        end

        def {{table.id}}?(label : String | Symbol) : {{model}}?
          Saci::Testing::Fixtures.fetch?({{model}}, {{table.id.stringify}}, label)
        end
      end
    end
  end
end
