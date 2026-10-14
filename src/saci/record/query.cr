module Saci
  module Record
    # Chainable, Rails-relation-like query builder.
    #
    # ```
    # Post.where(published: true).where("views > ?", 10)
    #   .order(created_at: :desc).limit(5).offset(10).to_a
    # ```
    class Query(T)
      include Enumerable(T)

      def initialize(@klass : T.class, @conditions : Array(String) = [] of String, @params : Array(Value) = [] of Value, @order : Array(String) = [] of String, @limit : Int32? = nil, @offset : Int32? = nil, @select_cols : Array(String)? = nil, @distinct_flag : Bool = false, @joins : Array(String) = [] of String, @group_cols : Array(String) = [] of String, @includes : Array(String) = [] of String, @records : Array(T)? = nil)
      end

      # Adapter of the model's database (resolved per call so
      # `connected_to` switches and transactions behave).
      private def adapter : Adapter
        Record.adapter_of(@klass.connection)
      end

      # `"table"."col"` — base-table references stay unambiguous under `joins`.
      private def qualified(col : String | Symbol) : String
        ad = adapter
        "#{Record.quote(@klass.table_name, ad)}.#{Record.quote(col.to_s, ad)}"
      end

      # Clone with overrides — every chain method funnels through here so
      # `select`/`distinct`/`joins`/`group`/`includes` survive chaining.
      # Any scope change drops preloaded `@records` (fresh SQL scope).
      private def spawn(conditions : Array(String) = @conditions.dup, params : Array(Value) = @params.dup, order : Array(String) = @order.dup, limit : Int32? = @limit, offset : Int32? = @offset, select_cols : Array(String)? = @select_cols.try(&.dup), distinct_flag : Bool = @distinct_flag, joins : Array(String) = @joins.dup, group_cols : Array(String) = @group_cols.dup, includes : Array(String) = @includes.dup, records : Array(T)? = nil) : Query(T)
        Query(T).new(@klass, conditions, params, order, limit, offset, select_cols, distinct_flag, joins, group_cols, includes, records)
      end

      # `where(title: "x", published: true)` — nil becomes `IS NULL`, a
      # `Range` becomes a bounded comparison (`>=`/`<=`, `<` for exclusive
      # ends; open ends emit a single bound).
      def where(**conds : Object) : Query(T)
        ad = adapter
        new_conds = @conditions.dup
        new_params = @params.dup
        conds.each do |key, value|
          col = Record.quote(key, ad)
          if value.nil?
            new_conds << "#{col} IS NULL"
          elsif value.is_a?(Range)
            b = value.begin
            e = value.end
            if b.nil? && e.nil?
              # Unbounded — matches everything.
            elsif b.nil?
              new_conds << (value.excludes_end? ? "#{col} < ?" : "#{col} <= ?")
              new_params << Record.to_db(e, ad)
            elsif e.nil?
              new_conds << "#{col} >= ?"
              new_params << Record.to_db(b, ad)
            else
              new_conds << "#{col} >= ?"
              new_params << Record.to_db(b, ad)
              new_conds << (value.excludes_end? ? "#{col} < ?" : "#{col} <= ?")
              new_params << Record.to_db(e, ad)
            end
          else
            new_conds << "#{col} = ?"
            new_params << Record.to_db(value, ad)
          end
        end
        spawn(new_conds, new_params)
      end

      # `where("views > ?", 10)`
      def where(sql : String, *args : Object) : Query(T)
        ad = adapter
        converted = args.to_a.map { |a| Record.to_db(a, ad) }
        spawn(@conditions.dup + ["(#{sql})"], @params.dup + converted)
      end

      # `where` with an explicit bind array (dynamic-length `IN (...)` lists,
      # which splats cannot express — splats require tuples).
      def where(sql : String, args : Array(Value)) : Query(T)
        ad = adapter
        converted = args.map { |a| Record.to_db(a, ad) }
        spawn(@conditions.dup + ["(#{sql})"], @params.dup + converted)
      end

      # `where("published IS NOT NULL")` — raw condition without binds.
      def where(sql : String) : Query(T)
        spawn(@conditions.dup + ["(#{sql})"], @params.dup)
      end

      # `where.not(title: "x")` — hash negation (`nil` becomes `IS NOT NULL`).
      def not(**conds : Object) : Query(T)
        ad = adapter
        new_conds = @conditions.dup
        new_params = @params.dup
        conds.each do |key, value|
          col = Record.quote(key, ad)
          if value.nil?
            new_conds << "#{col} IS NOT NULL"
          elsif value.is_a?(Range)
            raise ArgumentError.new("where.not does not support Range values (#{key}); use explicit SQL")
          else
            new_conds << "#{col} != ?"
            new_params << Record.to_db(value, ad)
          end
        end
        spawn(new_conds, new_params)
      end

      # `Post.where(a: 1).or(Post.where(b: 2))` — ORs another query's
      # conditions (and binds) into this one. Scoping (`select`, `joins`,
      # `order`, ...) comes from the receiver.
      def or(other : Query(T)) : Query(T)
        left = @conditions.empty? ? "1 = 1" : @conditions.map { |c| "(#{c})" }.join(" AND ")
        right = other.@conditions.empty? ? "1 = 1" : other.@conditions.map { |c| "(#{c})" }.join(" AND ")
        spawn(["((#{left}) OR (#{right}))"], @params.dup + other.@params)
      end

      # `select(:title)` / `select(:id, :title)` / `select("COUNT(*) AS n")`.
      # Symbols load partial models (unselected attributes stay nil);
      # raw-SQL expressions are readable via `read_attribute` / `#[]`.
      def select : Query(T)
        raise ArgumentError.new("select requires at least one column")
      end

      def select(*cols : String | Symbol) : Query(T)
        raise ArgumentError.new("select requires at least one column") if cols.empty?
        frags = cols.to_a.map { |c| c.is_a?(Symbol) ? qualified(c.to_s) : c.to_s }
        spawn(@conditions.dup, @params.dup, @order.dup, @limit, @offset, frags)
      end

      # `distinct` — `SELECT DISTINCT ...`.
      def distinct : Query(T)
        spawn(@conditions.dup, @params.dup, @order.dup, @limit, @offset, @select_cols.try(&.dup), true)
      end

      # `group(:tag_id)` — returns a `GroupedQuery` with Rails-style
      # `count` / `sum` / `average` / `minimum` / `maximum` hashes.
      def group : GroupedQuery(T)
        raise ArgumentError.new("group requires at least one column")
      end

      def group(*cols : String | Symbol) : GroupedQuery(T)
        raise ArgumentError.new("group requires at least one column") if cols.empty?
        quoted = cols.to_a.map { |c| c.is_a?(Symbol) ? qualified(c.to_s) : c.to_s }
        GroupedQuery(T).new(spawn(@conditions.dup, @params.dup, @order.dup, @limit, @offset, @select_cols.try(&.dup), @distinct_flag, @joins.dup, quoted))
      end

      # `joins("INNER JOIN stories ON stories.id = comments.story_id")` —
      # raw SQL appended after FROM (accumulates across calls).
      def joins(sql : String) : Query(T)
        spawn(@conditions.dup, @params.dup, @order.dup, @limit, @offset, @select_cols.try(&.dup), @distinct_flag, @joins.dup + [sql])
      end

      # `includes(:user, :posts)` — preloads `belongs_to` / `has_many` /
      # `has_one` in one extra query each (kills N+1). Unknown association
      # names raise immediately; `has_many :through` raises at execution.
      def includes : Query(T)
        self
      end

      def includes(*names : Symbol) : Query(T)
        names.each do |n|
          unless @klass.__saci_assoc_kinds.has_key?(n.to_s)
            raise ArgumentError.new("Unknown association '#{n}' for includes on #{@klass.name}")
          end
        end
        spawn(@conditions.dup, @params.dup, @order.dup, @limit, @offset, @select_cols.try(&.dup), @distinct_flag, @joins.dup, @group_cols.dup, @includes.dup + names.to_a.map(&.to_s))
      end

      def order(field : Symbol | String, dir : Symbol = :asc) : Query(T)
        direction = dir.to_s.upcase == "DESC" ? "DESC" : "ASC"
        spawn(@conditions.dup, @params.dup, @order.dup + ["#{qualified(field)} #{direction}"])
      end

      # `order(created_at: :desc, title: :asc)`
      def order(**opts : Object) : Query(T)
        q = self
        ad = adapter
        opts.each do |field, dir|
          direction = dir.to_s.upcase == "DESC" ? "DESC" : "ASC"
          tbl = Record.quote(q.@klass.table_name, ad)
          q = Query(T).new(q.@klass, q.@conditions.dup, q.@params.dup, q.@order.dup + ["#{tbl}.#{Record.quote(field, ad)} #{direction}"], q.@limit, q.@offset, q.@select_cols.try(&.dup), q.@distinct_flag, q.@joins.dup, q.@group_cols.dup, q.@includes.dup)
        end
        q
      end

      # Raw SQL ordering, e.g. `order_raw("RANDOM()")`.
      def order_raw(sql : String) : Query(T)
        spawn(@conditions.dup, @params.dup, @order.dup + [sql])
      end

      def limit(n : Int) : Query(T)
        spawn(@conditions.dup, @params.dup, @order.dup, n.to_i32, @offset)
      end

      def offset(n : Int) : Query(T)
        spawn(@conditions.dup, @params.dup, @order.dup, @limit, n.to_i32)
      end

      def to_a : Array(T)
        if r = @records
          return r.dup
        end
        ad = adapter
        conn = @klass.connection
        col_types = {} of String => String
        @klass.__saci_column_names.each { |(n, t)| col_types[n] = t }
        results = [] of T
        Record.query_compat(conn, select_sql(ad), @params) do |rs|
          rs.each do
            results << load_indexed_row(rs, ad, col_types)
          end
        end
        unless @includes.empty? || results.empty?
          preloaded = [] of Saci::Record::Base
          results.each { |r| preloaded << r }
          @includes.each { |name| @klass.__saci_preload_assoc(preloaded, name) }
        end
        results
      end

      # Loads one result row by column name (plain method, not a closure:
      # iterating `column_count` inside a query block ICEs this compiler,
      # so row iteration lives here where `rs` is an ordinary parameter).
      # Unknown columns become extras (`read_attribute`); repeated names
      # keep the first value (later ones are still consumed).
      private def load_indexed_row(rs : DB::ResultSet, ad : Adapter, col_types : Hash(String, String)) : T
        obj = @klass.new
        seen = {} of String => Bool
        i = 0
        total = rs.column_count
        while i < total
          name = rs.column_name(i)
          if t = col_types[name]?
            if seen[name]?
              Record.read_generic(rs)
            else
              seen[name] = true
              obj.__saci_set_attr(name, Record.read_typed(rs, t, ad))
            end
          else
            obj.__saci_push_extra(name, Record.read_generic(rs))
          end
          i += 1
        end
        obj.__saci_mark_persisted!
        obj
      end

      def each(& : T ->) : Nil
        to_a.each { |r| yield r }
      end

      def find_each(batch_size : Int32 = 1000, & : T ->) : Nil
        off = 0
        loop do
          batch = limit(batch_size).offset(off).to_a
          break if batch.empty?
          batch.each { |r| yield r }
          break if batch.size < batch_size
          off += batch_size
        end
      end

      def first : T?
        if r = @records
          return r.first?
        end
        limit(1).to_a.first?
      end

      def first! : T
        first || raise RecordNotFound.new("Couldn't find #{@klass.name}")
      end

      def count : Int64
        if r = @records
          return r.size.to_i64
        end
        conn = @klass.connection
        Record.scalar_compat(conn, count_sql(adapter), @params).as(Int64)
      end

      def exists? : Bool
        if r = @records
          return !r.empty?
        end
        count > 0
      end

      # Scalar aggregates (WHERE + JOINs apply; `ORDER`/`LIMIT` do not).
      def sum(col : String | Symbol) : Float64
        v = scalar_aggregate("SUM", col.to_s)
        v.is_a?(Number) ? v.to_f64 : 0.0
      end

      def average(col : String | Symbol) : Float64?
        v = scalar_aggregate("AVG", col.to_s)
        v.is_a?(Number) ? v.to_f64 : nil
      end

      def avg(col : String | Symbol) : Float64?
        average(col)
      end

      def minimum(col : String | Symbol) : Value
        scalar_aggregate("MIN", col.to_s)
      end

      def maximum(col : String | Symbol) : Value
        scalar_aggregate("MAX", col.to_s)
      end

      def update_all(attrs : NamedTuple) : Int64
        ad = adapter
        sets = [] of String
        vals = [] of Value
        attrs.each do |k, v|
          sets << "#{Record.quote(k, ad)} = ?"
          vals << Record.to_db(v, ad)
        end
        return 0_i64 if sets.empty?
        res = Record.exec_compat(@klass.connection, "#{update_sql(ad, sets.join(", "))}", vals + @params)
        res.rows_affected
      end

      def delete_all : Int64
        res = Record.exec_compat(@klass.connection, delete_sql(adapter), @params)
        res.rows_affected
      end

      def pluck(col : String | Symbol) : Array(Value)
        ad = adapter
        col_type = @klass.__saci_column_names.find { |(n, _)| n == col.to_s }.try(&.[1]) || "String"
        d = @distinct_flag ? "DISTINCT " : ""
        values = [] of Value
        Record.query_compat(@klass.connection, "SELECT #{d}#{qualified(col)} FROM #{Record.quote(@klass.table_name, ad)}#{joins_sql}#{where_sql}", @params) do |rs|
          rs.each do
            values << Record.read_typed(rs, col_type, ad)
          end
        end
        values
      end

      # -- internal (association preloading, grouped aggregates) -------------

      # Attaches preloaded records to this (already scoped) query. Terminal
      # reads use them; further chaining re-queries. Used by `has_many`
      # getters when the association was eager-loaded.
      def __saci_with_records(records : Array(T)) : Query(T)
        @records = records
        self
      end

      # Group columns for `GroupedQuery` (empty on plain queries).
      def __saci_group_cols : Array(String)
        @group_cols.dup
      end

      # Runs `SELECT <groups>, <expr> ... GROUP BY <groups>`, one generic
      # row per group (`[key..., value]`). A single plain-column group key
      # is read with its column type (so `Bool`/`Time` keys match model
      # values); anything else stays a raw value.
      def __saci_grouped_rows(expr : String) : Array(Array(Value))
        ad = adapter
        groups = @group_cols.join(", ")
        key_type : String? = nil
        if @group_cols.size == 1
          frag = @group_cols.first
          @klass.__saci_column_names.each do |(n, t)|
            if Record.quote(n, ad) == frag || "#{Record.quote(@klass.table_name, ad)}.#{Record.quote(n, ad)}" == frag
              key_type = t
              break
            end
          end
        end
        sql = "SELECT #{groups}, #{expr} FROM #{Record.quote(@klass.table_name, ad)}#{joins_sql}#{where_sql} GROUP BY #{groups}"
        rows = [] of Array(Value)
        Record.query_compat(@klass.connection, sql, @params) do |rs|
          rs.each do
            rows << read_grouped_row(rs, ad, key_type)
          end
        end
        rows
      end

      # Reads one grouped row (plain method — see `load_indexed_row`).
      private def read_grouped_row(rs : DB::ResultSet, ad : Adapter, key_type : String?) : Array(Value)
        row = [] of Value
        i = 0
        total = rs.column_count
        coerce = !key_type.nil? && @group_cols.size == 1
        while i < total
          if i == 0 && coerce
            row << Record.read_typed(rs, key_type.as(String), ad)
          else
            row << Record.read_generic(rs)
          end
          i += 1
        end
        row
      end

      # Grouped aggregate with a model column (`GroupedQuery` entry point).
      def __saci_grouped_aggregate(func : String, col : String) : Array(Array(Value))
        __saci_grouped_rows("#{func}(#{qualified(col)})")
      end

      # -- SQL fragments -----------------------------------------------------

      private def scalar_aggregate(func : String, col : String) : Value
        ad = adapter
        result : Value = nil
        Record.query_compat(@klass.connection, "SELECT #{func}(#{qualified(col)}) FROM #{Record.quote(@klass.table_name, ad)}#{joins_sql}#{where_sql}", @params) do |rs|
          rs.each { result = Record.read_generic(rs) }
        end
        result
      end

      private def where_sql : String
        @conditions.empty? ? "" : " WHERE #{@conditions.join(" AND ")}"
      end

      private def joins_sql : String
        @joins.empty? ? "" : " " + @joins.join(" ")
      end

      private def group_sql : String
        @group_cols.empty? ? "" : " GROUP BY #{@group_cols.join(", ")}"
      end

      private def order_sql : String
        @order.empty? ? "" : " ORDER BY #{@order.join(", ")}"
      end

      private def limit_sql(ad : Adapter) : String
        if l = @limit
          @offset ? " LIMIT #{l} OFFSET #{@offset}" : " LIMIT #{l}"
        elsif o = @offset
          # MySQL has no `LIMIT -1` — use the maximum unsigned BIGINT.
          ad == :mysql ? " LIMIT 18446744073709551615 OFFSET #{o}" : " LIMIT -1 OFFSET #{o}"
        else
          ""
        end
      end

      private def select_sql(ad : Adapter) : String
        cols = begin
          if s = @select_cols
            s.join(", ")
          else
            table = Record.quote(@klass.table_name, ad)
            @klass.__saci_column_names.map { |(n, _)| "#{table}.#{Record.quote(n, ad)}" }.join(", ")
          end
        end
        d = @distinct_flag ? "DISTINCT " : ""
        "SELECT #{d}#{cols} FROM #{Record.quote(@klass.table_name, ad)}#{joins_sql}#{where_sql}#{group_sql}#{order_sql}#{limit_sql(ad)}"
      end

      private def count_sql(ad : Adapter) : String
        "SELECT COUNT(*) FROM #{Record.quote(@klass.table_name, ad)}#{joins_sql}#{where_sql}"
      end

      private def update_sql(ad : Adapter, sets : String) : String
        "UPDATE #{Record.quote(@klass.table_name, ad)} SET #{sets}#{where_sql}"
      end

      private def delete_sql(ad : Adapter) : String
        "DELETE FROM #{Record.quote(@klass.table_name, ad)}#{where_sql}"
      end
    end

    # Result of `Query#group` — Rails-style grouped aggregates plus the
    # underlying grouped relation (`where` / `order` / `to_a` / ...).
    #
    # ```
    # Post.group(:published).count        # => {true => 2, false => 1}
    # Post.group(:published).sum(:views)  # => {true => 550.0, ...}
    # ```
    class GroupedQuery(T)
      include Enumerable(T)

      def initialize(@query : Query(T))
      end

      def where(**conds : Object) : GroupedQuery(T)
        GroupedQuery(T).new(@query.where(**conds))
      end

      def where(sql : String, *args : Object) : GroupedQuery(T)
        GroupedQuery(T).new(@query.where(sql, *args))
      end

      def where(sql : String) : GroupedQuery(T)
        GroupedQuery(T).new(@query.where(sql))
      end

      def order(field : Symbol | String, dir : Symbol = :asc) : GroupedQuery(T)
        GroupedQuery(T).new(@query.order(field, dir))
      end

      def order(**opts : Object) : GroupedQuery(T)
        GroupedQuery(T).new(@query.order(**opts))
      end

      def limit(n : Int) : GroupedQuery(T)
        GroupedQuery(T).new(@query.limit(n))
      end

      def offset(n : Int) : GroupedQuery(T)
        GroupedQuery(T).new(@query.offset(n))
      end

      def to_a : Array(T)
        @query.to_a
      end

      def each(& : T ->) : Nil
        @query.each { |r| yield r }
      end

      def first : T?
        @query.first
      end

      def first! : T
        @query.first!
      end

      # `{group_key => count}` (single group column keys keep their type;
      # multi-column groups key on the values joined by `"\u0000"`).
      def count : Hash(Value, Int64)
        h = {} of Value => Int64
        @query.__saci_grouped_rows("COUNT(*)").each do |row|
          h[group_key(row[0...-1])] = Record.to_i64(row.last) || 0_i64
        end
        h
      end

      def sum(col : String | Symbol) : Hash(Value, Float64)
        h = {} of Value => Float64
        @query.__saci_grouped_aggregate("SUM", col.to_s).each do |row|
          v = row.last
          h[group_key(row[0...-1])] = v.is_a?(Number) ? v.to_f64 : 0.0
        end
        h
      end

      def average(col : String | Symbol) : Hash(Value, Float64)
        h = {} of Value => Float64
        @query.__saci_grouped_aggregate("AVG", col.to_s).each do |row|
          v = row.last
          h[group_key(row[0...-1])] = v.is_a?(Number) ? v.to_f64 : 0.0
        end
        h
      end

      def avg(col : String | Symbol) : Hash(Value, Float64)
        average(col)
      end

      def minimum(col : String | Symbol) : Hash(Value, Value)
        h = {} of Value => Value
        @query.__saci_grouped_aggregate("MIN", col.to_s).each do |row|
          h[group_key(row[0...-1])] = row.last
        end
        h
      end

      def maximum(col : String | Symbol) : Hash(Value, Value)
        h = {} of Value => Value
        @query.__saci_grouped_aggregate("MAX", col.to_s).each do |row|
          h[group_key(row[0...-1])] = row.last
        end
        h
      end

      private def group_key(vals : Array(Value)) : Value
        vals.size == 1 ? vals[0] : vals.map(&.to_s).join("\u0000")
      end
    end
  end
end
