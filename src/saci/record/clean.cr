module Saci
  module Record
    # Deletes every row from every table except `schema_migrations`.
    # Test helper — call in `before_each` for a clean slate (generated
    # apps do; multidb apps use `clean_all!`).
    #
    # Per adapter:
    # * SQLite — virtual tables and their shadow tables (FTS5 `_data`,
    #   `_idx`, `_config`, …, FTS3/4, R*Tree) are never deleted from
    #   directly: wiping `<fts>_config`/`<fts>_data` destroys the index
    #   structure, so every later connection fails with `vtable constructor
    #   failed`. Base tables are emptied first with `DELETE` (FTS sync
    #   triggers keep their indexes in step), then each virtual table is
    #   emptied through its module: own-content FTS and R*Tree with
    #   `DELETE`, external-content FTS with the `'rebuild'` command (now an
    #   empty, consistent index even without triggers) and contentless FTS5
    #   with `'delete-all'`. Foreign keys are switched off on the cleaning
    #   connection (outside any transaction, the pragma is a no-op inside
    #   one) and restored afterwards, so table order and `RESTRICT` /
    #   self-references do not matter. Inside an open transaction they are
    #   deferred instead and tables are deleted children first.
    #   `AUTOINCREMENT` counters (`sqlite_sequence`) are kept.
    # * PostgreSQL — one `TRUNCATE ... CASCADE` over every `public` table.
    #   Identity/serial sequences are not restarted (like the previous
    #   `DELETE`), so ids keep growing across examples.
    # * MySQL — `DELETE` per base table with `FOREIGN_KEY_CHECKS` off for
    #   the cleaning connection (restored afterwards); `AUTO_INCREMENT`
    #   counters are kept.
    def self.clean_database! : Nil
      clean_database!(connection)
      nil
    end

    # Same as `clean_database!` on the given database. Returns the number
    # of tables emptied (virtual tables count once, shadow tables never).
    def self.clean_database!(db : DB::Database | DB::Connection) : Int32
      case adapter_of(db)
      when :postgres then clean_postgres!(db)
      when :mysql    then with_cleaning_connection(db) { |conn| clean_mysql!(conn) }
      else                with_cleaning_connection(db) { |conn| clean_sqlite!(conn) }
      end
    end

    # Session settings (foreign key pragmas) need one connection for the
    # whole clean.
    private def self.with_cleaning_connection(db : DB::Database | DB::Connection, & : DB::Connection -> Int32) : Int32
      if db.is_a?(DB::Connection)
        yield db
      else
        db.using_connection { |conn| yield conn }
      end
    end

    private def self.clean_postgres!(db : DB::Database | DB::Connection) : Int32
      tables = [] of String
      query_compat(db, "SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND tablename != 'schema_migrations' ORDER BY tablename") do |rs|
        rs.each { tables << rs.read(String) }
      end
      return 0 if tables.empty?
      exec_compat(db, "TRUNCATE TABLE #{tables.map { |t| quote(t, :postgres) }.join(", ")} CASCADE")
      tables.size
    end

    private def self.clean_mysql!(conn : DB::Connection) : Int32
      tables = [] of String
      query_compat(conn, "SELECT table_name FROM information_schema.tables WHERE table_schema = DATABASE() AND table_type = 'BASE TABLE' AND table_name != 'schema_migrations'") do |rs|
        rs.each { tables << rs.read(String) }
      end
      checks = scalar_compat(conn, "SELECT @@SESSION.foreign_key_checks").to_s != "0"
      exec_compat(conn, "SET FOREIGN_KEY_CHECKS = 0") if checks
      begin
        tables.each { |t| exec_compat(conn, "DELETE FROM #{quote(t, :mysql)}") }
      ensure
        exec_compat(conn, "SET FOREIGN_KEY_CHECKS = 1") if checks
      end
      tables.size
    end

    private def self.clean_sqlite!(conn : DB::Connection) : Int32
      virtual = Introspection.sqlite_virtual_tables(conn)
      skip = virtual.flat_map { |v| [v.name] + v.shadow_tables }.to_set
      base = [] of String
      query_compat(conn, "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name != 'schema_migrations' ORDER BY rowid") do |rs|
        rs.each do
          name = rs.read(String)
          base << name unless skip.includes?(name)
        end
      end
      cleaned = virtual.select { |v| sqlite_virtual_clean_sql(v) }

      enforced = sqlite_pragma_on?(conn, "foreign_keys")
      exec_compat(conn, "PRAGMA foreign_keys = OFF") if enforced
      # Still on: a transaction is open on this connection (the pragma is
      # a no-op there), so defer the checks to its commit and delete
      # children before parents.
      deferred = enforced && sqlite_pragma_on?(conn, "foreign_keys")
      was_deferred = deferred && sqlite_pragma_on?(conn, "defer_foreign_keys")
      begin
        # SAVEPOINT opens a transaction when none is active and nests
        # otherwise, so the clean is atomic either way.
        exec_compat(conn, "SAVEPOINT saci_clean_database")
        begin
          if deferred
            exec_compat(conn, "PRAGMA defer_foreign_keys = ON")
            base = sqlite_children_first(conn, base)
          end
          base.each { |t| exec_compat(conn, "DELETE FROM #{quote(t, :sqlite)}") }
          cleaned.each { |v| exec_compat(conn, sqlite_virtual_clean_sql(v).not_nil!) }
          exec_compat(conn, "PRAGMA defer_foreign_keys = OFF") if deferred && !was_deferred
          exec_compat(conn, "RELEASE saci_clean_database")
        rescue ex
          exec_compat(conn, "ROLLBACK TO saci_clean_database") rescue nil
          exec_compat(conn, "RELEASE saci_clean_database") rescue nil
          raise ex
        end
      ensure
        exec_compat(conn, "PRAGMA foreign_keys = ON") if enforced && !deferred
      end
      base.size + cleaned.size
    end

    # Statement that empties a virtual table through its module, or nil
    # for modules that cannot be emptied safely (left untouched).
    private def self.sqlite_virtual_clean_sql(v : Introspection::VirtualTableInfo) : String?
      q = quote(v.name, :sqlite)
      case v.module_name
      when "fts5", "fts4", "fts3"
        content = v.fts_content
        if content.nil?
          "DELETE FROM #{q}"
        elsif content.empty?
          # Contentless: rows cannot be deleted one by one (FTS4 has no
          # equivalent command, so it is left as is).
          v.module_name == "fts5" ? "INSERT INTO #{q}(#{q}) VALUES('delete-all')" : nil
        elsif v.module_name == "fts3"
          nil # FTS3 has no external content
        else
          # External content: base rows are gone (and the sync triggers
          # already removed them from the index); rebuilding from the
          # empty content table also repairs an index without triggers.
          "INSERT INTO #{q}(#{q}) VALUES('rebuild')"
        end
      when "rtree", "rtree_i32", "geopoly"
        "DELETE FROM #{q}"
      end
    end

    private def self.sqlite_pragma_on?(conn : DB::Connection, pragma : String) : Bool
      scalar_compat(conn, "PRAGMA #{pragma}").to_s == "1"
    end

    # `tables` ordered so every table comes after the tables that
    # reference it (cycles and self-references: best effort).
    private def self.sqlite_children_first(conn : DB::Connection, tables : Array(String)) : Array(String)
      children = Hash(String, Array(String)).new { |h, k| h[k] = [] of String }
      tables.each do |t|
        query_compat(conn, "PRAGMA foreign_key_list(#{quote(t, :sqlite)})") do |rs|
          rs.each do
            2.times { rs.read } # id, seq
            parent = rs.read(String)
            5.times { rs.read } # from, to, on_update, on_delete, match
            children[parent] << t unless parent == t
          end
        end
      end
      order = [] of String
      seen = Set(String).new
      tables.each { |t| sqlite_visit_children(t, tables, children, seen, order) }
      order
    end

    private def self.sqlite_visit_children(table : String, tables : Array(String), children : Hash(String, Array(String)), seen : Set(String), order : Array(String)) : Nil
      return if seen.includes?(table)
      seen << table
      children[table]?.try &.each { |c| sqlite_visit_children(c, tables, children, seen, order) if tables.includes?(c) }
      order << table
    end
  end
end
