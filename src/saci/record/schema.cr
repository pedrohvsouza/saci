module Saci
  module Record
    # Rails `schema.rb` equivalent: introspect a live database into a
    # canonical, adapter-aware snapshot (`dump` / `introspect`) and
    # recreate it (`load`). One `db/schema.cr` loads on SQLite,
    # PostgreSQL and MySQL because it carries *data* (column/index/check
    # definitions) plus a loader call — column/index DDL is never raw SQL.
    # Database views are the exception: their SELECT body is inherently
    # SQL, so it is stored verbatim and rendered through `create_view`.
    #
    # Table choice: every table is dumped EXCEPT `schema_migrations`
    # (rebuilt by the Migrator on each database) and SQLite internals
    # (`sqlite_%`). Durable queue tables (`saci_jobs`, `saci_dead_jobs`)
    # ARE included so a schema-loaded database boots queue workers
    # without extra steps.
    #
    # SQLite normalization (documented, byte-stable): SQLite shares one
    # storage type across several logical types, so BOOLEAN/DATE/
    # DATETIME/JSON map back to :integer/:text, DECIMAL/BIGINT to
    # :float/:integer, and only single-column integer primary keys map
    # back to :serial. `t.timestamps` (created_at + updated_at, both
    # NOT NULL without defaults) is detected and re-emitted.
    # Re-dumping a loaded database is byte-stable. Defaults that cannot
    # round-trip exactly are normalized to no default and reported as
    # `# NOTE:` lines in the generated file.
    #
    # Driver-free: introspection uses only the generic `DB` API plus
    # `Record.query_compat` (catalog queries return text/int/nil on all
    # three drivers), so requiring this file never pulls in pg/mysql.
    module Schema
      struct IndexInfo
        getter name : String
        getter columns : Array(String)
        getter unique : Bool

        def initialize(@name : String, @columns : Array(String), @unique : Bool)
        end
      end

      # A CHECK constraint snapshot (name may be nil for unnamed SQLite
      # constraints).
      struct CheckInfo
        getter name : String?
        getter expression : String

        def initialize(@name : String?, @expression : String)
        end
      end

      # Table snapshot. `timestamps` means created_at + updated_at (both
      # NOT NULL, no defaults) were detected and are re-emitted by the
      # loader instead of two plain columns. `checks` are re-emitted inside
      # CREATE TABLE so SQLite reloads them too.
      struct TableInfo
        getter name : String
        getter columns : Array(ColumnDef)
        getter indexes : Array(IndexInfo)
        getter timestamps : Bool
        getter checks : Array(CheckInfo)

        def initialize(@name : String, @columns : Array(ColumnDef), @indexes : Array(IndexInfo) = [] of IndexInfo, @timestamps : Bool = false, @checks : Array(CheckInfo) = [] of CheckInfo)
        end
      end

      # A database view snapshot. `sql` is the SELECT body (after `AS`),
      # rendered adapter-aware by `Migration.create_view_sql` on load.
      struct ViewInfo
        getter name : String
        getter sql : String

        def initialize(@name : String, @sql : String)
        end
      end

      # A non-primary database section of a `--all` dump (name, handle,
      # and the `DATABASE_URL_<NAME>` fallback baked into schema.cr).
      struct DatabaseDump
        getter name : String
        getter db : DB::Database | DB::Connection
        getter url_default : String

        def initialize(@name : String, @db : DB::Database | DB::Connection, @url_default : String)
        end
      end

      # Migration bookkeeping is rebuilt by the Migrator on every
      # database, so it is never part of the snapshot.
      SKIP_TABLES = ["schema_migrations"]

      # Canonical snapshot of every kept table (sorted by name).
      def self.introspect(db : DB::Database | DB::Connection) : Array(TableInfo)
        tables, _ = introspect_with_notes(db)
        tables
      end

      # Recreates snapshot tables on any adapter: drops (so loading is
      # repeatable on a fresh database) then CREATE TABLE + indexes
      # through adapter-aware DDL. Check constraints are emitted inside
      # CREATE TABLE (SQLite only parses them there).
      def self.load(db : DB::Database | DB::Connection, tables : Array(TableInfo)) : Nil
        ad = Record.adapter_of(db)
        # Views may depend on tables that are about to be recreated; drop
        # them first so loading is repeatable even when views exist.
        drop_views(db, views(db))
        tables.each do |t|
          cols = t.columns.map(&.to_sql(ad))
          if t.timestamps
            cols << ColumnDef.new("created_at", :datetime, false, nil, false).to_sql(ad)
            cols << ColumnDef.new("updated_at", :datetime, false, nil, false).to_sql(ad)
          end
          t.checks.each do |c|
            prefix = c.name ? "CONSTRAINT #{Record.quote(c.name.not_nil!, ad)} " : ""
            cols << "#{prefix}CHECK (#{c.expression})"
          end
          Record.exec_compat(db, "DROP TABLE IF EXISTS #{Record.quote(t.name, ad)}")
          Record.exec_compat(db, "CREATE TABLE #{Record.quote(t.name, ad)} (#{cols.join(", ")})")
          t.indexes.each do |ix|
            uniq = ix.unique ? "UNIQUE " : ""
            Record.exec_compat(db, "CREATE #{uniq}INDEX #{Record.quote(ix.name, ad)} ON #{Record.quote(t.name, ad)} (#{ix.columns.map { |c| Record.quote(c, ad) }.join(", ")})")
          end
        end
      end

      # Snapshot of live views, sorted by name.
      def self.views(db : DB::Database | DB::Connection) : Array(ViewInfo)
        Introspection.views(db).map { |v| ViewInfo.new(v.name, v.sql) }.sort_by!(&.name)
      end

      # Drops the given views (generated schema files call this before
      # `load`, because a view can depend on a table that is recreated).
      def self.drop_views(db : DB::Database | DB::Connection, views : Array(ViewInfo)) : Nil
        ad = Record.adapter_of(db)
        views.each do |v|
          Record.exec_compat(db, Migration.drop_view_sql(ad, v.name, if_exists: true))
        end
      end

      # Recreates view snapshots (adapter-aware `CREATE VIEW`).
      def self.load_views(db : DB::Database | DB::Connection, views : Array(ViewInfo)) : Nil
        ad = Record.adapter_of(db)
        views.each do |v|
          Record.exec_compat(db, Migration.create_view_sql(ad, v.name, v.sql, or_replace: true))
        end
      end

      # Renders a standalone runnable `db/schema.cr`: connects via
      # `DATABASE_URL`-or-default (same convention as the migrate
      # runner), then calls `load` with the embedded snapshot.
      # `url_default` is embedded verbatim (it usually carries a
      # `#{env_name}` interpolation the generated file resolves).
      def self.dump(db : DB::Database | DB::Connection, url_default : String = "sqlite3://./db/development.db", others : Array(DatabaseDump) = [] of DatabaseDump) : String
        primary_tables, notes = introspect_with_notes(db)
        primary_views = views(db)
        rest = others.map do |o|
          other_tables, other_notes = introspect_with_notes(o.db)
          {o, other_tables, other_notes, views(o.db)}
        end
        String.build do |io|
          io << "# db/schema.cr — auto-generated by `saci db:schema:dump` (stable output).\n"
          io << "# Rails schema.rb equivalent: canonical snapshot, portable across\n"
          io << "# adapters (SQLite / PostgreSQL / MySQL) through adapter-aware DDL.\n"
          io << "# Load with: saci db:schema:load   (or: crystal run db/schema.cr)\n"
          io << "#\n"
          io << "# Table choice: every table EXCEPT `schema_migrations` (rebuilt by the\n"
          io << "# Migrator on each database) and SQLite internals (`sqlite_%`). Durable\n"
          io << "# queue tables (`saci_jobs`, `saci_dead_jobs`) ARE included so a\n"
          io << "# schema-loaded database boots queue workers without extra steps.\n"
          io << "#\n"
          io << "# SQLite normalization: SQLite shares storage across logical types, so\n"
          io << "# BOOLEAN/DATE/DATETIME/JSON reload as :integer/:text and DECIMAL/BIGINT\n"
          io << "# as :float/:integer; only single-column integer primary keys reload as\n"
          io << "# :serial (TEXT primary keys reload as :uuid, BLOB as :binary). Generated\n"
          io << "# columns, CHECK constraints and views are included. `t.timestamps`\n"
          io << "# (created_at + updated_at, both NOT NULL without defaults) is detected\n"
          io << "# and re-emitted. Re-dumping a loaded database is byte-stable; defaults\n"
          io << "# that cannot round-trip exactly are normalized to no default (noted below).\n"
          notes.each { |n| io << "# NOTE: " << n << "\n" }
          rest.each do |o, _, other_notes, _|
            other_notes.each { |n| io << "# NOTE: [" << o.name << "] " << n << "\n" }
          end
          pg = url_default.includes?("postgres") || rest.any? { |o, _, _, _| o.url_default.includes?("postgres") }
          mysql = url_default.includes?("mysql") || rest.any? { |o, _, _, _| o.url_default.includes?("mysql") }
          io << "require \"pg\"\n" if pg
          io << "require \"mysql\"\n" if mysql
          io << "require \"saci\"\n"
          io << "require \"file_utils\"\n"
          io << "\n"
          io << "FileUtils.mkdir_p(\"db\")\n"
          io << "env_name = ENV.fetch(\"APP_ENV\", \"development\")\n"
          io << "db_url = ENV.fetch(\"DATABASE_URL\", \"" << url_default << "\")\n"
          io << "Saci::Record.connect(db_url)\n"
          io << "db = Saci::Record.database(\"primary\")\n"
          io << "\n"
          io << "SCHEMA_TABLES = [\n"
          primary_tables.each { |t| emit_table(io, t) }
          io << "] of Saci::Record::Schema::TableInfo\n"
          unless primary_views.empty?
            io << "\n"
            io << "SCHEMA_VIEWS = [\n"
            primary_views.each { |v| emit_view(io, v) }
            io << "] of Saci::Record::Schema::ViewInfo\n"
            io << "Saci::Record::Schema.drop_views(db, SCHEMA_VIEWS)\n"
          end
          io << "\n"
          io << "Saci::Record::Schema.load(db, SCHEMA_TABLES)\n"
          io << "Saci::Record::Schema.load_views(db, SCHEMA_VIEWS)\n" unless primary_views.empty?
          rest.each do |o, other_tables, _, other_views|
            const = "SCHEMA_TABLES_" + o.name.upcase.gsub(/[^A-Z0-9_]/, "_")
            views_const = "SCHEMA_VIEWS_" + o.name.upcase.gsub(/[^A-Z0-9_]/, "_")
            db_expr = "Saci::Record.database(" + o.name.inspect + ")"
            io << "\n"
            io << "Saci::Record.establish_connection(" << o.name.inspect << ", ENV.fetch(" << ("DATABASE_URL_" + o.name.upcase).inspect << ", \"" << crystal_escape(o.url_default) << "\"))\n"
            io << const << " = [\n"
            other_tables.each { |t| emit_table(io, t) }
            io << "] of Saci::Record::Schema::TableInfo\n"
            unless other_views.empty?
              io << views_const << " = [\n"
              other_views.each { |v| emit_view(io, v) }
              io << "] of Saci::Record::Schema::ViewInfo\n"
              io << "Saci::Record::Schema.drop_views(" << db_expr << ", " << views_const << ")\n"
            end
            io << "\n"
            io << "Saci::Record::Schema.load(" << db_expr << ", " << const << ")\n"
            io << "Saci::Record::Schema.load_views(" << db_expr << ", " << views_const << ")\n" unless other_views.empty?
          end
        end
      end

      private def self.emit_table(io : IO, t : TableInfo) : Nil
        io << "  Saci::Record::Schema::TableInfo.new(\n"
        io << "    " << t.name.inspect << ",\n"
        io << "    [\n"
        t.columns.each do |c|
          io << "      Saci::Record::ColumnDef.new(" << c.name.inspect << ", :" << c.logical_type.to_s << ", " << c.null.to_s << ", " << value_literal(c.default_value) << ", " << c.primary_key.to_s
          io << ", subtype: :" << c.subtype.to_s if c.subtype
          io << ", size: " << c.size.to_s if c.size
          if ga = c.generated_as
            io << ", generated_as: " << ga.inspect << ", stored: " << c.stored.to_s
          end
          io << "),\n"
        end
        io << "    ] of Saci::Record::ColumnDef,\n"
        io << "    [\n"
        t.indexes.each do |ix|
          cols = ix.columns.map(&.inspect).join(", ")
          io << "      Saci::Record::Schema::IndexInfo.new(" << ix.name.inspect << ", [" << cols << "] of String, " << ix.unique.to_s << "),\n"
        end
        io << "    ] of Saci::Record::Schema::IndexInfo,\n"
        io << "    " << t.timestamps.to_s << ", # t.timestamps (created_at/updated_at, NOT NULL)\n" if t.timestamps
        io << "    false,\n" unless t.timestamps
        unless t.checks.empty?
          io << "    [\n"
          t.checks.each do |c|
            io << "      Saci::Record::Schema::CheckInfo.new(" << c.name.inspect << ", " << c.expression.inspect << "),\n"
          end
          io << "    ] of Saci::Record::Schema::CheckInfo,\n"
        end
        io << "  ),\n"
      end

      private def self.emit_view(io : IO, v : ViewInfo) : Nil
        io << "  Saci::Record::Schema::ViewInfo.new(" << v.name.inspect << ", " << v.sql.inspect << "),\n"
      end

      private def self.parse_decimal(s : String) : Saci::Record::Decimal?
        Saci::Record::Decimal.new(s)
      rescue
        nil
      end

      private def self.value_literal(v : Value) : String
        case v
        when Nil              then "nil"
        when Bool             then v ? "true" : "false"
        when Int32, Int64     then "#{v}_i64"
        when Float32, Float64 then v.to_s
        when Saci::Record::Decimal then "BigDecimal.new(#{v.to_s.inspect})"
        when String           then v.inspect
        else                       "nil"
        end
      end

      # Escapes a baked URL for embedding in double quotes. `#{...}`
      # sequences pass through untouched (the primary default carries a
      # `#{env_name}` interpolation the generated file must resolve).
      private def self.crystal_escape(s : String) : String
        s.gsub("\\", "\\\\").gsub("\"", "\\\"")
      end

      private def self.introspect_with_notes(db : DB::Database | DB::Connection) : Tuple(Array(TableInfo), Array(String))
        notes = [] of String
        tables = case Record.adapter_of(db)
                 when :postgres then introspect_postgres(db, notes)
                 when :mysql    then introspect_mysql(db, notes)
                 else                introspect_sqlite(db, notes)
                 end
        {tables, notes}
      end

      private def self.keep_table?(name : String) : Bool
        !SKIP_TABLES.includes?(name) && !name.starts_with?("sqlite_")
      end

      # `t.timestamps` detection: created_at + updated_at, both NOT NULL
      # without defaults (exactly what `t.timestamps` generates). The
      # pair is removed from the column list and re-emitted by the loader.
      private def self.extract_timestamps(cols : Array(ColumnDef)) : Tuple(Array(ColumnDef), Bool)
        ca = cols.index { |c| c.name == "created_at" }
        ua = cols.index { |c| c.name == "updated_at" }
        if ca && ua
          c1, c2 = cols[ca], cols[ua]
          if !c1.null && !c2.null && c1.default_value.nil? && c2.default_value.nil? && !c1.primary_key && !c2.primary_key
            return {cols.reject { |c| c.name == "created_at" || c.name == "updated_at" }, true}
          end
        end
        {cols, false}
      end

      private def self.any_to_str(v) : String?
        case v
        when Nil    then nil
        when String then v
        when Bytes  then String.new(v)
        else             v.to_s
        end
      end

      private def self.any_to_i64(v) : Int64
        case v
        when Nil    then 0_i64
        when Bool   then v ? 1_i64 : 0_i64
        when Number then v.to_i64
        when String then v.strip.to_i64? || 0_i64
        when Time   then v.to_unix
        else             0_i64
        end
      end

      private def self.any_to_bool(v) : Bool
        case v
        when Nil    then false
        when Bool   then v
        when Number then v != 0
        when String
          s = v.strip.downcase
          s == "1" || {"t", "true", "y", "yes"}.includes?(s)
        else false
        end
      end

      private def self.introspect_sqlite(db : DB::Database | DB::Connection, notes : Array(String)) : Array(TableInfo)
        names = [] of String
        Record.query_compat(db, "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name != 'schema_migrations' ORDER BY name") do |rs|
          rs.each { names << rs.read(String) }
        end
        names.select { |n| keep_table?(n) }.map { |n| introspect_sqlite_table(db, n, notes) }
      end

      private def self.introspect_sqlite_table(db : DB::Database | DB::Connection, table : String, notes : Array(String)) : TableInfo
        qt = table.gsub('"', "\"\"")
        create_sql = ""
        Record.query_compat(db, "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?", [table] of Value) do |rs|
          rs.each { create_sql = any_to_str(rs.read) || "" }
        end
        generated = create_sql.empty? ? ({} of String => Tuple(String, Bool)) : Introspection.sqlite_generated_columns(create_sql)
        col_names = {} of Int64 => String
        cols = [] of ColumnDef
        Record.query_compat(db, "PRAGMA table_xinfo(\"#{qt}\")") do |rs|
          rs.each do
            cid = any_to_i64(rs.read)
            name = any_to_str(rs.read) || "col#{cid}"
            decltype = any_to_str(rs.read) || "TEXT"
            notnull = any_to_bool(rs.read)
            dflt_raw = rs.read
            pk = any_to_i64(rs.read) != 0
            hidden = any_to_i64(rs.read)
            unless hidden == 1
              col_names[cid] = name
              logical = sqlite_reverse_type(decltype, pk)
              default, note = sqlite_parse_default(table, name, dflt_raw, logical)
              notes << note if note
              gen = generated[name]?
              cols << sqlite_column_def(name, logical, !notnull && !pk, default, pk, gen)
            end
          end
        end
        raw_indexes = [] of Tuple(String, Bool)
        Record.query_compat(db, "PRAGMA index_list(\"#{qt}\")") do |rs|
          rs.each do
            rs.read # seq
            name = any_to_str(rs.read) || ""
            unique = any_to_bool(rs.read)
            origin = any_to_str(rs.read) || ""
            rs.read # partial
            next if name.empty? || origin == "pk" || name.starts_with?("sqlite_autoindex_")
            raw_indexes << {name, unique}
          end
        end
        idxs = raw_indexes.map do |(name, unique)|
          qi = name.gsub('"', "\"\"")
          ordered = [] of Tuple(Int32, String)
          Record.query_compat(db, "PRAGMA index_info(\"#{qi}\")") do |irs|
            irs.each do
              seqno = any_to_i64(irs.read).to_i32
              cid = any_to_i64(irs.read)
              if col = col_names[cid]?
                ordered << {seqno, col}
              end
            end
          end
          ordered.sort_by!(&.[0])
          IndexInfo.new(name, ordered.map(&.[1]), unique)
        end
        idxs.sort_by!(&.name)
        columns, timestamps = extract_timestamps(cols)
        checks = Introspection.check_constraints(db, table).map { |c| CheckInfo.new(c.name, c.expression) }
        TableInfo.new(table, columns, idxs, timestamps, checks)
      end

      # Builds a SQLite ColumnDef, optionally carrying a parsed generated
      # expression. Kept as a helper (rather than a long `ColumnDef.new`
      # call inside the PRAGMA block) to keep the codegen simple.
      private def self.sqlite_column_def(name : String, logical : Symbol, null : Bool, default : Value, primary : Bool, gen : Tuple(String, Bool)?) : ColumnDef
        if gen
          ColumnDef.new(name, logical, null, default, primary, nil, nil, generated_as: gen[0], stored: gen[1])
        else
          ColumnDef.new(name, logical, null, default, primary)
        end
      end

      # Matches `Record.db_type` forward maps exactly; SQLite shares
      # storage across logical types (see module docs), so several kinds
      # collapse here — the collapse is stable across dump/load cycles.
      private def self.sqlite_reverse_type(decltype : String, primary : Bool) : Symbol
        TypeMapping.sqlite_logical(decltype, primary)
      end

      private def self.sqlite_parse_default(table : String, column : String, raw, logical : Symbol = :text) : Tuple(Value, String?)
        case raw
        when Nil    then {nil, nil}
        when Bool   then {raw, nil}
        when Float  then {raw.to_f64, nil}
        when Number then {raw.to_i64, nil}
        when Time   then {nil, "#{table}.#{column}: datetime default does not round-trip; normalized to no default"}
        when String
          s = raw.strip
          return {nil, nil} if s.empty? || s.upcase == "NULL"
          if s.size >= 2 && s.starts_with?("'") && s.ends_with?("'")
            inner = s[1..-2].gsub("''", "'")
            if logical == :decimal
              if decimal = parse_decimal(inner)
                return {decimal, nil}
              end
            end
            return {inner, nil}
          end
          if s.size >= 2 && s.starts_with?("\"") && s.ends_with?("\"")
            inner = s[1..-2]
            if logical == :decimal
              if decimal = parse_decimal(inner)
                return {decimal, nil}
              end
            end
            return {inner, nil}
          end
          up = s.upcase
          return {true, nil} if up == "TRUE"
          return {false, nil} if up == "FALSE"
          if {"CURRENT_TIMESTAMP", "CURRENT_DATE", "CURRENT_TIME"}.includes?(up)
            return {nil, "#{table}.#{column}: default #{s} does not round-trip; normalized to no default"}
          end
          if logical == :decimal
            if decimal = parse_decimal(s)
              return {decimal, nil}
            end
          end
          return {s.to_i64, nil} if s.to_i64?
          return {s.to_f64, nil} if s.to_f64?
          {nil, "#{table}.#{column}: default #{raw.inspect} does not round-trip; normalized to no default"}
        else
          {nil, "#{table}.#{column}: default does not round-trip; normalized to no default"}
        end
      end

      private def self.introspect_postgres(db : DB::Database | DB::Connection, notes : Array(String)) : Array(TableInfo)
        names = [] of String
        Record.query_compat(db, "SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND tablename != 'schema_migrations' ORDER BY tablename") do |rs|
          rs.each { names << (any_to_str(rs.read) || next) }
        end
        names.select { |n| keep_table?(n) }.map { |n| introspect_postgres_table(db, n, notes) }
      end

      private def self.introspect_postgres_table(db : DB::Database | DB::Connection, table : String, notes : Array(String)) : TableInfo
        pk_cols = Set(String).new
        escaped = table.gsub("'", "''")
        Record.query_compat(db, "SELECT a.attname FROM pg_index ix JOIN pg_attribute a ON a.attrelid = ix.indrelid AND a.attnum = ANY(ix.indkey) WHERE ix.indrelid = '#{escaped}'::regclass AND ix.indisprimary") do |rs|
          rs.each { pk_cols << (any_to_str(rs.read) || next) }
        end
        cols = [] of ColumnDef
        Record.query_compat(db, "SELECT column_name, data_type, udt_name, is_nullable, column_default, is_generated, generation_expression, character_maximum_length FROM information_schema.columns WHERE table_schema = 'public' AND table_name = ? ORDER BY ordinal_position", [table] of Value) do |rs|
          rs.each do
            name = any_to_str(rs.read) || next
            data_type = (any_to_str(rs.read) || "text").downcase
            udt_name = (any_to_str(rs.read) || "").downcase
            nullable = (any_to_str(rs.read) || "YES").upcase == "YES"
            dflt_raw = any_to_str(rs.read)
            generated = (any_to_str(rs.read) || "NEVER").upcase == "ALWAYS"
            generation = any_to_str(rs.read)
            max_len = rs.read
            primary = pk_cols.includes?(name)
            logical, subtype = pg_reverse_type(data_type, udt_name, dflt_raw, primary)
            default, note = pg_parse_default(table, name, logical, dflt_raw)
            notes << note if note
            size = (logical == :bit || logical == :bit_varying) && max_len ? any_to_i64(max_len).to_i32 : nil
            cols << ColumnDef.new(name, logical, nullable && !primary, default, primary, nil, nil,
              subtype: subtype, size: size, generated_as: generated ? generation : nil, stored: generated)
          end
        end
        idxs = [] of IndexInfo
        Record.query_compat(db, "SELECT indexname, indexdef FROM pg_indexes WHERE schemaname = 'public' AND tablename = ?", [table] of Value) do |rs|
          rs.each do
            name = any_to_str(rs.read) || next
            indexdef = any_to_str(rs.read) || next
            next if name == "#{table}_pkey"
            list = pg_index_columns(indexdef)
            next unless list
            idxs << IndexInfo.new(name, list, indexdef.upcase.starts_with?("CREATE UNIQUE INDEX"))
          end
        end
        idxs.sort_by!(&.name)
        columns, timestamps = extract_timestamps(cols)
        checks = Introspection.check_constraints(db, table).map { |c| CheckInfo.new(c.name, c.expression) }
        TableInfo.new(table, columns, idxs, timestamps, checks)
      end

      # Returns `{logical, subtype}`; subtype is only set for PG range
      # types so `t.range subtype:` survives a dump. `numeric` remains
      # `:decimal` (the historical mapping); Saci's own forward map writes
      # `DOUBLE PRECISION`, which reads back as `:float` exactly as before.
      private def self.pg_reverse_type(data_type : String, udt_name : String, column_default : String?, primary : Bool) : Tuple(Symbol, Symbol?)
        TypeMapping.pg_logical(data_type, udt_name, column_default, primary)
      end

      private def self.pg_parse_default(table : String, column : String, logical : Symbol, raw : String?) : Tuple(Value, String?)
        return {nil, nil} if raw.nil? || raw.empty?
        s = raw.strip
        return {nil, nil} if s.starts_with?("nextval")
        return {true, nil} if s == "true"
        return {false, nil} if s == "false"
        if s.starts_with?("'")
          if m = s.match(/\A'(.*)'::[\w ]+\z/m)
            value = m[1].gsub("''", "'")
            return {parse_decimal(value) || value, nil} if logical == :decimal
            return {value, nil}
          end
          return {s, nil} if logical == :string || logical == :text
        end
        if logical == :decimal
          if decimal = parse_decimal(s)
            return {decimal, nil}
          end
        end
        if i = s.to_i64?
          return {logical == :boolean ? (i != 0) : i, nil}
        end
        if f = s.to_f64?
          return {f, nil}
        end
        if {"CURRENT_TIMESTAMP", "CURRENT_DATE", "NOW()", "CURRENT_TIME"}.includes?(s.upcase)
          return {nil, "#{table}.#{column}: default #{s} does not round-trip; normalized to no default"}
        end
        {nil, "#{table}.#{column}: default #{raw.inspect} does not round-trip; normalized to no default"}
      end

      private def self.pg_index_columns(indexdef : String) : Array(String)?
        o = indexdef.rindex('(')
        c = indexdef.rindex(')')
        return nil unless o && c && c > o
        inner = indexdef[o + 1, c - o - 1].strip
        return nil if inner.starts_with?("(")
        cols = inner.split(",").map do |part|
          token = part.strip.split(" ")[0]
          if token.size >= 2 && token.starts_with?("\"") && token.ends_with?("\"")
            token[1..-2]
          else
            token
          end
        end
        return nil if cols.any?(&.empty?) || cols.any? { |c| c.includes?("(") || c.includes?(")") }
        cols
      end

      private def self.introspect_mysql(db : DB::Database | DB::Connection, notes : Array(String)) : Array(TableInfo)
        names = [] of String
        Record.query_compat(db, "SELECT table_name FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name != 'schema_migrations' AND table_type = 'BASE TABLE' ORDER BY table_name") do |rs|
          rs.each { names << (any_to_str(rs.read) || next) }
        end
        names.select { |n| keep_table?(n) }.map { |n| introspect_mysql_table(db, n, notes) }
      end

      private def self.introspect_mysql_table(db : DB::Database | DB::Connection, table : String, notes : Array(String)) : TableInfo
        pk_cols = Set(String).new
        Record.query_compat(db, "SELECT column_name FROM information_schema.statistics WHERE table_schema = DATABASE() AND table_name = ? AND index_name = 'PRIMARY' ORDER BY seq_in_index", [table] of Value) do |rs|
          rs.each { pk_cols << (any_to_str(rs.read) || next) }
        end
        cols = [] of ColumnDef
        Record.query_compat(db, "SELECT column_name, column_type, data_type, is_nullable, column_default, extra, generation_expression FROM information_schema.columns WHERE table_schema = DATABASE() AND table_name = ? ORDER BY ordinal_position", [table] of Value) do |rs|
          rs.each do
            name = any_to_str(rs.read) || next
            column_type = (any_to_str(rs.read) || "").downcase
            data_type = (any_to_str(rs.read) || "").downcase
            nullable = (any_to_str(rs.read) || "YES").upcase == "YES"
            dflt_raw = any_to_str(rs.read)
            extra = (any_to_str(rs.read) || "").downcase
            generation = any_to_str(rs.read)
            primary = pk_cols.includes?(name)
            logical = mysql_reverse_type(column_type, data_type, extra, primary)
            default, note = mysql_parse_default(table, name, logical, dflt_raw, extra)
            notes << note if note
            generated = extra.includes?("generated") || !(generation.nil? || generation.empty?)
            size = nil
            if logical == :bit
              if m = column_type.match(/\Abit\((\d+)\)\z/)
                size = m[1].to_i32
              end
            end
            cols << ColumnDef.new(name, logical, nullable && !primary, default, primary, nil, nil,
              size: size, generated_as: generated ? generation : nil, stored: extra.includes?("stored"))
          end
        end
        grouped = {} of String => NamedTuple(unique: Bool, cols: Array(Tuple(Int64, String)))
        Record.query_compat(db, "SELECT index_name, non_unique, seq_in_index, column_name FROM information_schema.statistics WHERE table_schema = DATABASE() AND table_name = ? AND index_name != 'PRIMARY' ORDER BY index_name, seq_in_index", [table] of Value) do |rs|
          rs.each do
            name = any_to_str(rs.read) || next
            non_unique = any_to_i64(rs.read) != 0
            seq = any_to_i64(rs.read)
            col = any_to_str(rs.read) || next
            entry = grouped[name]? || {unique: !non_unique, cols: [] of Tuple(Int64, String)}
            entry[:cols] << {seq, col}
            grouped[name] = {unique: entry[:unique], cols: entry[:cols]}
          end
        end
        idxs = grouped.map do |name, entry|
          IndexInfo.new(name, entry[:cols].sort_by(&.[0]).map(&.[1]), entry[:unique])
        end.sort_by!(&.name)
        columns, timestamps = extract_timestamps(cols)
        checks = Introspection.check_constraints(db, table).map { |c| CheckInfo.new(c.name, c.expression) }
        TableInfo.new(table, columns, idxs, timestamps, checks)
      end

      # Matches `Record.db_type` forward maps: MySQL stores JSON as TEXT
      # (crystal-mysql cannot decode the native JSON wire type), so a
      # native `json` column maps back to :text exactly like our DDL does.
      # `:uuid`/`:binary` are our forward maps for CHAR(36)/BLOB.
      private def self.mysql_reverse_type(column_type : String, data_type : String, extra : String, primary : Bool) : Symbol
        TypeMapping.mysql_logical(column_type, data_type, extra, primary)
      end

      private def self.mysql_parse_default(table : String, column : String, logical : Symbol, raw : String?, extra : String) : Tuple(Value, String?)
        return {nil, nil} if raw.nil?
        s = raw.strip
        return {nil, nil} if s.empty? || s.upcase == "NULL"
        if extra.includes?("auto_increment")
          return {nil, nil}
        end
        up = s.upcase
        if {"CURRENT_TIMESTAMP", "CURRENT_DATE", "CURRENT_TIME", "NOW()", "CURDATE()"}.includes?(up) || up.starts_with?("CURRENT_TIMESTAMP(")
          return {nil, "#{table}.#{column}: default #{s} does not round-trip; normalized to no default"}
        end
        unquoted = if s.size >= 2 && s.starts_with?("'") && s.ends_with?("'")
                     s[1..-2].gsub("''", "'").gsub("\\\\", "\\")
                   else
                     s
                   end
        case logical
        when :boolean
          return {false, nil} if {"0", "b'0'", "false"}.includes?(unquoted.downcase)
          return {true, nil} if {"1", "b'1'", "true"}.includes?(unquoted.downcase)
        when :integer, :bigint
          return {unquoted.to_i64, nil} if unquoted.to_i64?
        when :decimal
          if decimal = parse_decimal(unquoted)
            return {decimal, nil}
          end
        when :float
          return {unquoted.to_f64, nil} if unquoted.to_f64?
        when :string, :text
          return {unquoted, nil}
        end
        if i = unquoted.to_i64?
          return {i, nil}
        end
        if f = unquoted.to_f64?
          return {f, nil}
        end
        {unquoted, nil}
      end
    end
  end
end
