module Saci
  module Record
    # SQLite FTS5 full-text search (Lobsters `Story.search` equivalent).
    #
    # ```
    # # migration (reversible: rollback drops the triggers + table)
    # create_fts_table :stories, [:title, :description],
    #   tokenize: "unicode61 remove_diacritics 2", external_content: true
    #
    # class Story < Saci::Record::Base
    #   fts_search [:title, :description] # registration only, no DDL
    # end
    #
    # Story.search_fts("crystal").where(story_type: "link").limit(10).to_a
    # Story.where(is_deleted: false).search_fts("crystal").to_a
    # ```
    #
    # `FTS.setup(Story, [...])` still does both at runtime (DDL plus a full
    # rebuild on every call). Either way the index is a `<table>_fts`
    # virtual table plus AFTER INSERT / UPDATE / DELETE triggers, so it
    # stays in sync with normal saves (no model-callback changes needed);
    # existing rows are backfilled. `search_fts` returns a chainable
    # `Query` (JOIN + `MATCH ?` bind + `ORDER BY rank`, so
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

      # Runtime registration only (no DDL, no rebuild): enables
      # `search_fts` for a model whose `<table>_fts` index was created by
      # the `create_fts_table` migration helper. Cheap enough for boot.
      def self.register(model, columns : Array) : Nil
        cols = validate_columns!(model, columns.to_a.map(&.to_s))
        @@mutex.synchronize { @@indexed[model.name] = cols }
      end

      # Runtime DDL + backfill (kept for compatibility). Prefer the
      # `create_fts_table` migration helper plus `fts_search` on the model:
      # `setup` reindexes the whole table on every call.
      def self.setup(model, columns : Array, tokenize : String? = nil, external_content : Bool = false) : Nil
        setup_columns(model, columns.to_a.map(&.to_s), tokenize, external_content)
      end

      def self.setup(model, *columns, tokenize : String? = nil, external_content : Bool = false) : Nil
        setup_columns(model, columns.to_a.map(&.to_s), tokenize, external_content)
      end

      private def self.validate_columns!(model, columns : Array(String)) : Array(String)
        raise ArgumentError.new("FTS.setup requires at least one column") if columns.empty?
        known = model.__saci_column_names.map(&.[0])
        columns.each do |col|
          unless known.includes?(col)
            raise ArgumentError.new("FTS.setup: unknown column #{col.inspect} for #{model.name} (known: #{known.inspect})")
          end
        end
        columns
      end

      private def self.setup_columns(model, columns : Array(String), tokenize : String?, external_content : Bool) : Nil
        validate_columns!(model, columns)
        conn = model.connection
        ad = Record.adapter_of(conn)
        ensure_sqlite!(ad)
        create_sql(ad, model.table_name, columns, model.__saci_primary_key, tokenize, external_content, if_not_exists: true)
          .each { |sql| Record.exec_compat(conn, sql) }
        @@mutex.synchronize { @@indexed[model.name] = columns.dup }
        rebuild!(model)
      end

      # DDL for `<table>_fts` plus the AFTER INSERT / DELETE / UPDATE sync
      # triggers. `tokenize:` is the FTS5 tokenizer spec (e.g.
      # `"unicode61 remove_diacritics 2"`, `"porter unicode61"`,
      # `"trigram"`). `external_content: true` makes the index read text
      # from the base table (`content=`/`content_rowid=`) instead of
      # storing its own copy; its triggers then use the FTS5 `'delete'`
      # command with the old values.
      def self.create_sql(ad : Adapter, table : String, columns : Array(String), pk : String = "id", tokenize : String? = nil, external_content : Bool = false, if_not_exists : Bool = false) : Array(String)
        raise ArgumentError.new("FTS: at least one column is required") if columns.empty?
        q = ->(name : String) { Record.quote(name, ad) }
        lit = ->(v : String) { "'#{v.gsub("'", "''")}'" }
        fts = "#{table}_fts"
        cols_sql = columns.map { |c| q.call(c) }.join(", ")
        opts = columns.map { |c| q.call(c) }
        opts << "tokenize=#{lit.call(tokenize)}" if tokenize
        if external_content
          opts << "content=#{lit.call(table)}"
          opts << "content_rowid=#{lit.call(pk)}"
        end
        new_vals = columns.map { |c| "new.#{q.call(c)}" }.join(", ")
        old_vals = columns.map { |c| "old.#{q.call(c)}" }.join(", ")
        insert_new = "INSERT INTO #{q.call(fts)}(rowid, #{cols_sql}) VALUES (new.#{q.call(pk)}, #{new_vals});"
        # External content: the index cannot read the old text back from
        # the (already changed) base row, so deletes go through the
        # 'delete' command with the old values. Own-content indexes apply
        # a plain row delete.
        remove_old = if external_content
                       "INSERT INTO #{q.call(fts)}(#{q.call(fts)}, rowid, #{cols_sql}) VALUES ('delete', old.#{q.call(pk)}, #{old_vals});"
                     else
                       "DELETE FROM #{q.call(fts)} WHERE rowid = old.#{q.call(pk)};"
                     end
        stmts = ["CREATE VIRTUAL TABLE #{if_not_exists ? "IF NOT EXISTS " : ""}#{q.call(fts)} USING fts5(#{opts.join(", ")})"]
        stmts.concat(drop_triggers_sql(ad, table))
        stmts << "CREATE TRIGGER #{q.call("#{table}_fts_ai")} AFTER INSERT ON #{q.call(table)} BEGIN #{insert_new} END"
        stmts << "CREATE TRIGGER #{q.call("#{table}_fts_ad")} AFTER DELETE ON #{q.call(table)} BEGIN #{remove_old} END"
        stmts << "CREATE TRIGGER #{q.call("#{table}_fts_au")} AFTER UPDATE ON #{q.call(table)} BEGIN #{remove_old} #{insert_new} END"
        stmts
      end

      # Triggers + virtual table, in drop order.
      def self.drop_sql(ad : Adapter, table : String) : Array(String)
        drop_triggers_sql(ad, table) + ["DROP TABLE IF EXISTS #{Record.quote("#{table}_fts", ad)}"]
      end

      private def self.drop_triggers_sql(ad : Adapter, table : String) : Array(String)
        ["ai", "ad", "au"].map { |suffix| "DROP TRIGGER IF EXISTS #{Record.quote("#{table}_fts_#{suffix}", ad)}" }
      end

      # Backfill statements: FTS5 `'rebuild'` for external content (reads
      # the base table itself), DELETE + INSERT ... SELECT otherwise.
      def self.rebuild_sql(ad : Adapter, table : String, columns : Array(String), pk : String, external_content : Bool) : Array(String)
        q = ->(name : String) { Record.quote(name, ad) }
        fts = q.call("#{table}_fts")
        return ["INSERT INTO #{fts}(#{fts}) VALUES ('rebuild')"] if external_content
        cols_sql = columns.map { |c| q.call(c) }.join(", ")
        base_cols = ([pk] + columns).map { |c| "#{q.call(table)}.#{q.call(c)}" }.join(", ")
        ["DELETE FROM #{fts}", "INSERT INTO #{fts}(rowid, #{cols_sql}) SELECT #{base_cols} FROM #{q.call(table)}"]
      end

      # True when `<table>_fts` was declared with `content='...'`.
      def self.external_content?(conn : DB::Database | DB::Connection, table : String) : Bool
        sql = conn.query_one?("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?", "#{table}_fts", as: String)
        !!sql.try(&.matches?(/\bcontent\s*=\s*'[^']/i))
      end

      # Re-reads every base-table row into the FTS index (also used by
      # `setup` to backfill rows that predate the triggers).
      def self.rebuild!(model) : Nil
        cols = indexed_columns(model) || raise ArgumentError.new("FTS.rebuild!: #{model.name} has no FTS index — call Saci::Record::FTS.setup first")
        conn = model.connection
        ad = Record.adapter_of(conn)
        ensure_sqlite!(ad)
        table = model.table_name
        rebuild_sql(ad, table, cols, model.__saci_primary_key, external_content?(conn, table))
          .each { |sql| Record.exec_compat(conn, sql) }
      end

      # Drops the triggers + virtual table and unregisters the model (spec
      # isolation; base-table rows are untouched).
      def self.teardown(model) : Nil
        conn = model.connection
        ad = Record.adapter_of(conn)
        ensure_sqlite!(ad)
        drop_sql(ad, model.table_name).each { |sql| Record.exec_compat(conn, sql) }
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
      # `fts_search [:title, :body]` in the model body: registers the
      # columns of an index created by `create_fts_table` (no DDL).
      def self.fts_search(columns : Array) : Nil
        FTS.register(self, columns)
      end

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
