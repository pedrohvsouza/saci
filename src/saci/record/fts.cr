module Saci
  module Record
    # SQLite FTS5 full-text search (Lobsters `Story.search` equivalent).
    #
    # ```
    # Saci::Record::FTS.setup(Story, [:title, :description, :tags])
    # Story.search_fts("crystal").where(story_type: "link").limit(10).to_a
    # Story.where(is_deleted: false).search_fts("crystal").to_a
    # ```
    #
    # `setup` creates a `<table>_fts` virtual table plus AFTER INSERT / UPDATE
    # / DELETE triggers, so the index stays in sync with normal saves (no
    # model-callback changes needed) and backfills existing rows. `search_fts`
    # returns a chainable `Query` (JOIN + `MATCH ?` bind + `ORDER BY rank`, so
    # further `where`/`limit`/`order` chaining works).
    #
    # SQLite-only: FTS5 is a SQLite extension. `setup` and `search_fts` raise
    # a clear `ArgumentError` on PostgreSQL/MySQL (use `tsvector` /
    # `FULLTEXT` there instead). The query string is passed through as a bind
    # parameter (no SQL interpolation), but it IS FTS5 MATCH syntax — callers
    # should treat it as user search syntax, not a plain substring.
    module FTS
      @@indexed = {} of String => Array(String)
      @@mutex = Mutex.new

      # Guard used by `setup`/`search_fts` (public so specs can assert the
      # non-SQLite error without a live PG/MySQL server).
      def self.ensure_sqlite!(adapter : Adapter) : Nil
        unless adapter == :sqlite
          raise ArgumentError.new(
            "Saci::Record::FTS is SQLite-only (FTS5); got #{adapter}. " \
            "Use PostgreSQL tsvector (to_tsvector / plainto_tsquery) or MySQL FULLTEXT indexes instead."
          )
        end
      end

      def self.fts_table_name(model) : String
        "#{model.table_name}_fts"
      end

      # Columns registered via `setup` (nil when the model has no index).
      def self.indexed_columns(model) : Array(String)?
        @@mutex.synchronize { @@indexed[model.name]?.try(&.dup) }
      end

      def self.setup(model, columns : Array) : Nil
        setup_columns(model, columns.to_a.map(&.to_s))
      end

      def self.setup(model, *columns) : Nil
        setup_columns(model, columns.to_a.map(&.to_s))
      end

      private def self.setup_columns(model, columns : Array(String)) : Nil
        raise ArgumentError.new("FTS.setup requires at least one column") if columns.empty?
        known = model.__saci_column_names.map(&.[0])
        columns.each do |col|
          unless known.includes?(col)
            raise ArgumentError.new("FTS.setup: unknown column #{col.inspect} for #{model.name} (known: #{known.inspect})")
          end
        end
        conn = model.connection
        ad = Record.adapter_of(conn)
        ensure_sqlite!(ad)
        table = model.table_name
        pk = model.__saci_primary_key
        fts = fts_table_name(model)
        q = ->(name : String) { Record.quote(name, ad) }
        cols_sql = columns.map { |c| q.call(c) }.join(", ")
        Record.exec_compat(conn, "CREATE VIRTUAL TABLE IF NOT EXISTS #{q.call(fts)} USING fts5(#{cols_sql})")
        ["ai", "ad", "au"].each do |suffix|
          Record.exec_compat(conn, "DROP TRIGGER IF EXISTS #{q.call("#{table}_fts_#{suffix}")}")
        end
        new_vals = columns.map { |c| "new.#{q.call(c)}" }.join(", ")
        # Plain `DELETE ... WHERE rowid =` (not the 'delete' magic command):
        # this index stores its own content, so row deletes apply directly.
        Record.exec_compat(conn, <<-SQL)
          CREATE TRIGGER #{q.call("#{table}_fts_ai")} AFTER INSERT ON #{q.call(table)} BEGIN
            INSERT INTO #{q.call(fts)}(rowid, #{cols_sql}) VALUES (new.#{q.call(pk)}, #{new_vals});
          END
          SQL
        Record.exec_compat(conn, <<-SQL)
          CREATE TRIGGER #{q.call("#{table}_fts_ad")} AFTER DELETE ON #{q.call(table)} BEGIN
            DELETE FROM #{q.call(fts)} WHERE rowid = old.#{q.call(pk)};
          END
          SQL
        Record.exec_compat(conn, <<-SQL)
          CREATE TRIGGER #{q.call("#{table}_fts_au")} AFTER UPDATE ON #{q.call(table)} BEGIN
            DELETE FROM #{q.call(fts)} WHERE rowid = old.#{q.call(pk)};
            INSERT INTO #{q.call(fts)}(rowid, #{cols_sql}) VALUES (new.#{q.call(pk)}, #{new_vals});
          END
          SQL
        @@mutex.synchronize { @@indexed[model.name] = columns.dup }
        rebuild!(model)
      end

      # Re-reads every base-table row into the FTS index (also used by
      # `setup` to backfill rows that predate the triggers).
      def self.rebuild!(model) : Nil
        cols = indexed_columns(model) || raise ArgumentError.new("FTS.rebuild!: #{model.name} has no FTS index — call Saci::Record::FTS.setup first")
        conn = model.connection
        ad = Record.adapter_of(conn)
        ensure_sqlite!(ad)
        q = ->(name : String) { Record.quote(name, ad) }
        fts = fts_table_name(model)
        cols_sql = cols.map { |c| q.call(c) }.join(", ")
        base_cols = ([model.__saci_primary_key] + cols).map { |c| "#{q.call(model.table_name)}.#{q.call(c)}" }.join(", ")
        Record.exec_compat(conn, "DELETE FROM #{q.call(fts)}")
        Record.exec_compat(conn, "INSERT INTO #{q.call(fts)}(rowid, #{cols_sql}) SELECT #{base_cols} FROM #{q.call(model.table_name)}")
      end

      # Drops the triggers + virtual table and unregisters the model (spec
      # isolation; base-table rows are untouched).
      def self.teardown(model) : Nil
        conn = model.connection
        ad = Record.adapter_of(conn)
        ensure_sqlite!(ad)
        q = ->(name : String) { Record.quote(name, ad) }
        table = model.table_name
        ["ai", "ad", "au"].each do |suffix|
          Record.exec_compat(conn, "DROP TRIGGER IF EXISTS #{q.call("#{table}_fts_#{suffix}")}")
        end
        Record.exec_compat(conn, "DROP TABLE IF EXISTS #{q.call(fts_table_name(model))}")
        @@mutex.synchronize { @@indexed.delete(model.name) }
      end

      # Builds the ranked search scope onto an existing query (powers both
      # `Model.search_fts` and `Query#search_fts`).
      def self.apply_scope(scope : Query(T), klass, query : String) : Query(T) forall T
        ensure_sqlite!(Record.adapter_of(klass.connection))
        unless indexed_columns(klass)
          raise ArgumentError.new("search_fts: #{klass.name} has no FTS index — call Saci::Record::FTS.setup(#{klass.name}, [...]) first")
        end
        return scope.where("1 = 0") if query.strip.empty?
        ad = Record.adapter_of(klass.connection)
        fts = fts_table_name(klass)
        qfts = Record.quote(fts, ad)
        qbase = Record.quote(klass.table_name, ad)
        qpk = Record.quote(klass.__saci_primary_key, ad)
        scope
          .joins("INNER JOIN #{qfts} ON #{qfts}.rowid = #{qbase}.#{qpk}")
          .where("#{qfts} MATCH ?", query)
          .order_raw("#{qfts}.rank")
      end
    end

    # `Model.search_fts("query")` — ranked, chainable; blank queries match
    # nothing (empty MATCH syntax would raise in SQLite).
    class Base
      def self.search_fts(query : String) : Query(self)
        FTS.apply_scope(all, self, query)
      end
    end

    # `Model.where(...).search_fts("query")` — same scope, existing
    # conditions preserved.
    class Query(T)
      def search_fts(query : String) : Query(T)
        FTS.apply_scope(self, @klass, query)
      end
    end
  end
end
