module Saci
  module Record
    # Raised by `sole` / `find_sole_by` when a scope contains more than one
    # record (Rails: `ActiveRecord::SoleRecordExceeded`). A missing record
    # raises `RecordNotFound` instead.
    class SoleRecordExceeded < Exception
    end

    # Chainable, Rails-relation-like query builder.
    #
    # ```
    # Post.where(published: true).where("views > ?", 10)
    #   .order(created_at: :desc).limit(5).offset(10).to_a
    # ```
    class Query(T)
      include Enumerable(T)

      # New scope flags (`none`, `having`, `from`, `lock`, ...) are optional
      # trailing parameters so existing positional `Query(T).new` calls keep
      # working. Every chain method goes through `spawn`.
      def initialize(@klass : T.class, @conditions : Array(String) = [] of String, @params : Array(Value) = [] of Value, @order : Array(String) = [] of String, @limit : Int32? = nil, @offset : Int32? = nil, @select_cols : Array(String)? = nil, @distinct_flag : Bool = false, @joins : Array(String) = [] of String, @group_cols : Array(String) = [] of String, @includes : Array(String) = [] of String, @nested_includes : Hash(String, Array(String)) = {} of String => Array(String), @records : Array(T)? = nil, @none_flag : Bool = false, @having : Array(String) = [] of String, @from_clause : String? = nil, @annotations : Array(String) = [] of String, @readonly_flag : Bool = false, @lock_clause : String? = nil, @references : Array(String) = [] of String, @having_params : Array(Value) = [] of Value)
      end

      # Owner wiring for association scopes (`author.posts.build(...)`,
      # `author.posts.create(...)`, autosave registration — G240). Kept as
      # instance state (not constructor parameters) so the long positional
      # initializer stays source-compatible.
      @__saci_owner : Saci::Record::Base? = nil
      @__saci_owner_fk : String? = nil
      @__saci_owner_assoc : String? = nil

      # HABTM collection proxy wiring (G33): lets `article.tags << tag` and
      # `article.tags.delete(tag)` operate on the join table directly.
      @__saci_habtm_owner : Saci::Record::Base? = nil
      @__saci_habtm_table : String? = nil
      @__saci_habtm_fk : String? = nil
      @__saci_habtm_afk : String? = nil

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
      private def spawn(conditions : Array(String) = @conditions.dup, params : Array(Value) = @params.dup, order : Array(String) = @order.dup, limit : Int32? = @limit, offset : Int32? = @offset, select_cols : Array(String)? = @select_cols.try(&.dup), distinct_flag : Bool = @distinct_flag, joins : Array(String) = @joins.dup, group_cols : Array(String) = @group_cols.dup, includes : Array(String) = @includes.dup, nested_includes : Hash(String, Array(String)) = @nested_includes.dup, records : Array(T)? = nil, none_flag : Bool = @none_flag, having : Array(String) = @having.dup, from_clause : String? = @from_clause, annotations : Array(String) = @annotations.dup, readonly_flag : Bool = @readonly_flag, lock_clause : String? = @lock_clause, references : Array(String) = @references.dup, having_params : Array(Value) = @having_params.dup) : Query(T)
        Query(T).new(@klass, conditions, params, order, limit, offset, select_cols, distinct_flag, joins, group_cols, includes, nested_includes, records, none_flag, having, from_clause, annotations, readonly_flag, lock_clause, references, having_params)
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

      # `Post.where(a: 1).and(Post.where(b: 2))` — ANDs another relation's
      # conditions into the receiver (Rails requires structurally
      # compatible relations; Saci keeps the receiver's other scopes).
      def and(other : Query(T)) : Query(T)
        spawn(@conditions.dup + other.@conditions, @params.dup + other.@params)
      end

      # `merge(other)` — folds another relation's scope into this one.
      #
      # Merge rules (Rails-inspired): WHERE/HAVING/JOIN conditions and
      # annotations accumulate; the *other* relation wins for `order`,
      # `limit`, `offset`, `select`, `from`, `lock` and `distinct` when it
      # actually sets them. Includes are unioned. `none` is sticky.
      def merge(other : Query(T)) : Query(T)
        merged_includes = (@includes + other.@includes).uniq
        merged_nested = @nested_includes.dup
        other.@nested_includes.each do |k, v|
          merged_nested[k] = ((merged_nested[k]? || [] of String) + v).uniq
        end
        spawn(
          conditions: @conditions + other.@conditions,
          params: @params + other.@params,
          order: other.@order.empty? ? @order.dup : other.@order.dup,
          limit: other.@limit.nil? ? @limit : other.@limit,
          offset: other.@offset.nil? ? @offset : other.@offset,
          select_cols: other.@select_cols.nil? ? @select_cols.try(&.dup) : other.@select_cols.try(&.dup),
          distinct_flag: @distinct_flag || other.@distinct_flag,
          joins: @joins + other.@joins,
          group_cols: other.@group_cols.empty? ? @group_cols.dup : other.@group_cols.dup,
          includes: merged_includes,
          nested_includes: merged_nested,
          none_flag: @none_flag || other.@none_flag,
          having: @having + other.@having,
          from_clause: other.@from_clause.nil? ? @from_clause : other.@from_clause,
          annotations: @annotations + other.@annotations,
          lock_clause: other.@lock_clause.nil? ? @lock_clause : other.@lock_clause,
          references: (@references + other.@references).uniq,
          having_params: @having_params + other.@having_params,
        )
      end

      # `rewhere(published: true)` — replaces every existing WHERE clause.
      def rewhere(**conds : Object) : Query(T)
        spawn(conditions: [] of String, params: [] of Value).where(**conds)
      end

      def rewhere(conds : NamedTuple) : Query(T)
        rewhere(**conds)
      end

      # `unscope(:order, :limit, :where, ...)` — removes the named parts.
      # Supported: `:where`, `:order`, `:limit`, `:offset`, `:select`,
      # `:group`, `:joins`, `:includes`, `:having`, `:from`, `:lock`,
      # `:annotate`, `:distinct`.
      def unscope(*parts : Symbol) : Query(T)
        conditions = @conditions.dup
        params = @params.dup
        order = @order.dup
        lim = @limit
        off = @offset
        select_cols = @select_cols.try(&.dup)
        group_cols = @group_cols.dup
        joins = @joins.dup
        includes = @includes.dup
        nested = @nested_includes.dup
        distinct_flag = @distinct_flag
        having = @having.dup
        having_params = @having_params.dup
        from_clause = @from_clause
        lock_clause = @lock_clause
        annotations = @annotations.dup
        parts.each do |part|
          case part
          when :where    then conditions = [] of String; params = [] of Value
          when :order    then order = [] of String
          when :limit    then lim = nil
          when :offset   then off = nil
          when :select   then select_cols = nil
          when :group    then group_cols = [] of String
          when :joins    then joins = [] of String
          when :includes then includes = [] of String; nested = {} of String => Array(String)
          when :having   then having = [] of String; having_params = [] of Value
          when :from     then from_clause = nil
          when :lock     then lock_clause = nil
          when :annotate then annotations = [] of String
          when :distinct then distinct_flag = false
          else
            raise ArgumentError.new("unscope: unsupported part #{part.inspect} (supported: :where, :order, :limit, :offset, :select, :group, :joins, :includes, :having, :from, :lock, :annotate, :distinct)")
          end
        end
        spawn(conditions, params, order, lim, off, select_cols, distinct_flag, joins, group_cols, includes, nested, nil, @none_flag, having, from_clause, annotations, @readonly_flag, lock_clause, @references.dup, having_params)
      end

      # `none` — a relation that never touches the database and always
      # yields no records (`to_a`, `count`, `exists?`, `pluck`,
      # `update_all` and `delete_all` short-circuit).
      def none : Query(T)
        spawn(none_flag: true)
      end

      # Negates every WHERE condition (`NOT (cond1 AND cond2)`). Binds are
      # preserved in order. An unscoped relation is returned unchanged.
      def invert_where : Query(T)
        return spawn if @conditions.empty?
        joined = @conditions.size == 1 ? @conditions.first : @conditions.map { |c| "(#{c})" }.join(" AND ")
        spawn(["NOT (#{joined})"], @params.dup)
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

      # `joins(:story)` — symbol form resolving the association's foreign
      # key (`belongs_to` → `target.pk = base.fk`, `has_many`/`has_one` →
      # `target.fk = base.pk`, polymorphic `as:` adds the type condition).
      # Unknown or unjoinable associations raise `ArgumentError`.
      def joins(*names : Symbol) : Query(T)
        frags = names.to_a.map do |n|
          frag = @klass.__saci_join_sql(n.to_s)
          if frag.nil?
            raise ArgumentError.new("Unknown association '#{n}' for joins on #{@klass.name}")
          end
          frag
        end
        spawn(@conditions.dup, @params.dup, @order.dup, @limit, @offset, @select_cols.try(&.dup), @distinct_flag, @joins.dup + frags)
      end

      # `includes(:user, :posts)` — preloads `belongs_to` / `has_many` /
      # `has_one` / through / HABTM associations in batched extra queries
      # (kills N+1; through chains use one query per level). Unknown
      # association names raise immediately.
      # Nested form `includes(story: :user)` preloads two levels:
      # top-level assocs first, then the nested assoc on each preloaded
      # record (grouped by concrete class, so polymorphic parents work).
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

      def includes(**nested) : Query(T)
        merged = @nested_includes.dup
        nested.each do |parent, children|
          pkey = parent.to_s
          unless @klass.__saci_assoc_kinds.has_key?(pkey)
            raise ArgumentError.new("Unknown association '#{pkey}' for includes on #{@klass.name}")
          end
          list = case children
                 when Symbol then [children.to_s]
                 when String then [children.to_s]
                 when Array  then children.to_a.map(&.to_s)
                 when Tuple  then children.to_a.map(&.to_s)
                 else
                   raise ArgumentError.new("includes(#{pkey}: ...) expects a Symbol or Array of Symbols (got #{children.inspect})")
                 end
          merged[pkey] = (merged[pkey]? || [] of String) + list
        end
        spawn(@conditions.dup, @params.dup, @order.dup, @limit, @offset, @select_cols.try(&.dup), @distinct_flag, @joins.dup, @group_cols.dup, @includes.dup, merged)
      end

      # `preload` is an alias of `includes` for now — Saci always preloads
      # associations in separate queries (there is no join-based preloader).
      def preload(*names : Symbol) : Query(T)
        includes(*names)
      end

      def preload(**nested) : Query(T)
        includes(**nested)
      end

      def preload : Query(T)
        self
      end

      # `eager_load(:user)` — joins the association *and* preloads it with
      # `includes` (Rails' eager_load does a single LEFT OUTER JOIN; Saci
      # documents and implements this as joins + includes, which returns
      # the same records for `belongs_to`/`has_one` and de-duplicates via
      # `distinct` only when the caller asks for it).
      def eager_load(*names : Symbol) : Query(T)
        frags = names.to_a.map do |n|
          unless @klass.__saci_assoc_kinds.has_key?(n.to_s)
            raise ArgumentError.new("Unknown association '#{n}' for eager_load on #{@klass.name}")
          end
          frag = @klass.__saci_join_sql(n.to_s)
          if frag.nil?
            raise ArgumentError.new("Association '#{n}' cannot be eager-loaded on #{@klass.name} (has_many :through is not joinable)")
          end
          frag
        end
        spawn(joins: @joins.dup + frags, includes: @includes + names.to_a.map(&.to_s))
      end

      # `left_joins(:user)` / `left_outer_joins(:user)` — association joins
      # with `LEFT OUTER JOIN` so rows without a matching association stay
      # in the result set.
      def left_joins(*names : Symbol) : Query(T)
        frags = names.to_a.map do |n|
          frag = @klass.__saci_join_sql(n.to_s)
          if frag.nil?
            raise ArgumentError.new("Unknown association '#{n}' for left_joins on #{@klass.name}")
          end
          frag.sub(/^INNER JOIN/, "LEFT OUTER JOIN")
        end
        spawn(@conditions.dup, @params.dup, @order.dup, @limit, @offset, @select_cols.try(&.dup), @distinct_flag, @joins.dup + frags)
      end

      def left_outer_joins(*names : Symbol) : Query(T)
        left_joins(*names)
      end

      # `without(:comments)` — drops eager-loaded associations from the
      # relation (top-level and nested parents). Does not affect `joins`.
      def without(*names : Symbol) : Query(T)
        drop = names.to_a.map(&.to_s)
        includes = @includes.reject { |n| drop.includes?(n) }
        nested = @nested_includes.reject { |k, _| drop.includes?(k) }
        spawn(includes: includes, nested_includes: nested)
      end

      # `references(:user)` — Rails uses this to force joined tables into
      # eager loading. Saci SQL joins are explicit strings, so this is a
      # documented no-op marker retained for API compatibility.
      def references(*names : Symbol) : Query(T)
        spawn(references: (@references + names.to_a.map(&.to_s)).uniq)
      end

      # `reselect(:title)` — replaces the SELECT list; `reselect` with no
      # arguments restores the default model columns.
      def reselect : Query(T)
        spawn(select_cols: nil)
      end

      def reselect(*cols : String | Symbol) : Query(T)
        return reselect if cols.empty?
        frags = cols.to_a.map { |c| c.is_a?(Symbol) ? qualified(c.to_s) : c.to_s }
        spawn(select_cols: frags)
      end

      # `regroup(:tag_id)` — replaces the GROUP BY list on a relation (use
      # `group(...)` when grouped aggregates are wanted).
      def regroup(*cols : String | Symbol) : Query(T)
        quoted = cols.to_a.map { |c| c.is_a?(Symbol) ? qualified(c.to_s) : c.to_s }
        spawn(group_cols: quoted)
      end

      # `annotate("load published posts")` — prefixes emitted SQL with
      # `/* ... */` comments (visible in logs / EXPLAIN output).
      def annotate(*comments : String | Symbol) : Query(T)
        spawn(annotations: @annotations + comments.to_a.map { |c| c.to_s })
      end

      # `readonly` — Rails marks loaded records read-only. Saci has no
      # per-record read-only enforcement, so this is a documented marker
      # (the flag is preserved across chaining but does not block writes).
      def readonly(value : Bool = true) : Query(T)
        spawn(readonly_flag: value)
      end

      # `lock` — on PostgreSQL appends `FOR UPDATE` (or the given raw
      # clause, e.g. `"FOR SHARE"`) to SELECTs. SQLite has no row locks and
      # MySQL is left as a documented no-op in this implementation.
      def lock(clause : String = "FOR UPDATE") : Query(T)
        spawn(lock_clause: clause)
      end

      # `from("posts PARTITION (...)")` / `from("(SELECT ...) AS posts")` —
      # replaces the FROM source for SELECT/COUNT/pluck/EXPLAIN. UPDATE and
      # DELETE always target the model's real table.
      def from(source : String) : Query(T)
        spawn(from_clause: source)
      end

      # `having("COUNT(*) > ?", 1)` — raw condition with binds, appended to
      # GROUP BY. Binds are tracked separately from WHERE binds so chaining
      # `where` after `having` keeps placeholder order correct.
      def having(sql : String, *args : Object) : Query(T)
        ad = adapter
        converted = args.to_a.map { |a| Record.to_db(a, ad) }
        spawn(having: @having + ["(#{sql})"], having_params: @having_params + converted)
      end

      def having(sql : String) : Query(T)
        spawn(having: @having + ["(#{sql})"])
      end

      def having(sql : String, args : Array(Value)) : Query(T)
        ad = adapter
        converted = args.map { |a| Record.to_db(a, ad) }
        spawn(having: @having + ["(#{sql})"], having_params: @having_params + converted)
      end

      # `having(count: 2)` — hash form (`NULL` becomes `IS NULL`).
      def having(**conds : Object) : Query(T)
        ad = adapter
        new_conds = @having.dup
        new_params = @having_params.dup
        conds.each do |key, value|
          col = Record.quote(key, ad)
          if value.nil?
            new_conds << "#{col} IS NULL"
          else
            new_conds << "#{col} = ?"
            new_params << Record.to_db(value, ad)
          end
        end
        spawn(having: new_conds, having_params: new_params)
      end

      # `optimizer_hints("INDEX(posts idx_posts_title)")` — documented
      # no-op: hints are accepted for Rails API compatibility but never
      # emitted (Saci does not parse optimizer hints per adapter).
      def optimizer_hints(*hints : String) : Query(T)
        self
      end

      # `associated(:user)` — only rows whose association exists. Implemented
      # as `joins(name)` + `distinct`, so `belongs_to`/`has_one`/`has_many`
      # work whenever `joins(name)` does (has_many :through raises, as with
      # `joins`).
      def associated(name : Symbol) : Query(T)
        joins(name).distinct
      end

      # `missing(:bio)` — rows where the column is NULL.
      def missing(col : String | Symbol) : Query(T)
        spawn(@conditions.dup + ["#{qualified(col)} IS NULL"], @params.dup)
      end

      # `excluding(record)` / `excluding(records)` — drops the given
      # records by primary key. Empty input returns the scope unchanged.
      def excluding(*records : T) : Query(T)
        excluding(records.to_a)
      end

      def excluding(records : Array(T)) : Query(T)
        return spawn if records.empty?
        ad = adapter
        pk = @klass.__saci_primary_key
        ids = records.map { |r| r.__saci_get_attr(pk) }.reject(&.nil?)
        return spawn if ids.empty?
        if ids.size == 1
          spawn(@conditions.dup + ["#{qualified(pk)} != ?"], @params.dup + [Record.to_db(ids.first, ad)] of Value)
        else
          ph = Array(String).new(ids.size, "?").join(", ")
          spawn(@conditions.dup + ["#{qualified(pk)} NOT IN (#{ph})"], @params.dup + ids.map { |v| Record.to_db(v, ad) })
        end
      end

      # `in_order_of(:status, ["draft", "live", "archived"])` — orders by
      # the position of the column value in the given list (values not in
      # the list come last). The CASE expression is prepended to any
      # existing order. Values are rendered as escaped SQL literals so no
      # bind-order issues arise with later `where` calls.
      def in_order_of(col : String | Symbol, values : Array) : Query(T)
        return spawn if values.empty?
        ad = adapter
        branches = [] of String
        values.each_with_index do |v, i|
          branches << "WHEN #{sql_literal(v, ad)} THEN #{i + 1}"
        end
        expr = "CASE #{qualified(col)} #{branches.join(" ")} ELSE #{values.size + 1} END"
        spawn(order: [expr] + @order.dup)
      end

      # Renders a value as an inline SQL literal (used by `in_order_of`,
      # where binds inside ORDER BY would interleave badly with later WHERE
      # binds). Strings single-quote-escape; everything else is numeric.
      private def sql_literal(v : Object, ad : Adapter) : String
        case v
        when Nil    then "NULL"
        when Bool   then ad == :sqlite ? (v ? "1" : "0") : (v ? "TRUE" : "FALSE")
        when Time   then "'#{v.to_rfc3339.gsub("'", "''")}'"
        when String then "'#{v.gsub("'", "''")}'"
        when Number then v.to_s
        else             "'#{v.to_s.gsub("'", "''")}'"
        end
      end

      def order(field : Symbol | String, dir : Symbol = :asc) : Query(T)
        direction = dir.to_s.upcase == "DESC" ? "DESC" : "ASC"
        spawn(@conditions.dup, @params.dup, @order.dup + ["#{qualified(field)} #{direction}"])
      end

      # `order(created_at: :desc, title: :asc)`
      def order(**opts : Object) : Query(T)
        ad = adapter
        tbl = Record.quote(@klass.table_name, ad)
        frags = opts.map do |field, dir|
          direction = dir.to_s.upcase == "DESC" ? "DESC" : "ASC"
          "#{tbl}.#{Record.quote(field, ad)} #{direction}"
        end
        spawn(order: @order.dup + frags)
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
        if @none_flag
          return [] of T
        end
        if r = @records
          return r.dup
        end
        ad = adapter
        conn = @klass.connection
        col_types = {} of String => String
        @klass.__saci_column_names.each { |(n, t)| col_types[n] = t }
        results = [] of T
        Record.query_compat(conn, select_sql(ad), @params + @having_params) do |rs|
          rs.each do
            results << load_indexed_row(rs, ad, col_types)
          end
        end
        unless (@includes.empty? && @nested_includes.empty?) || results.empty?
          preloaded = [] of Saci::Record::Base
          results.each { |r| preloaded << r }
          @includes.each { |name| @klass.__saci_preload_assoc(preloaded, name) }
          # Top-level parents for nested preloads (dedupe flat + nested).
          @nested_includes.each_key do |parent|
            unless @includes.includes?(parent)
              @klass.__saci_preload_assoc(preloaded, parent)
            end
          end
          # Second level: collect preloaded children grouped by class.
          @nested_includes.each do |parent, children|
            kids = [] of Saci::Record::Base
            preloaded.each do |rec|
              cached = rec.__saci_assoc_cache[parent]?
              case cached
              when Array(Saci::Record::Base)
                cached.each { |k| kids << k }
              when Saci::Record::Base
                kids << cached
              end
            end
            next if kids.empty?
            grouped = kids.group_by(&.class)
            grouped.each do |kclass, group|
              children.each do |child|
                unless kclass.__saci_assoc_kinds.has_key?(child)
                  raise ArgumentError.new("Unknown association '#{child}' for includes on #{kclass.name}")
                end
                kclass.__saci_preload_assoc(group, child)
              end
            end
          end
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

      # `find_each(batch_size: 1000, start: nil)` — yields records one at a
      # time in primary-key order (keyset batching when the relation has no
      # explicit `order`; offset batching when it does, preserving custom
      # order). Custom primary keys are honored.
      def find_each(batch_size : Int32 = 1000, start : Value? = nil, & : T ->) : Nil
        find_in_batches(batch_size: batch_size, start: start) { |batch| batch.each { |r| yield r } }
      end

      # `find_in_batches(batch_size: 1000, start: nil)` — yields arrays of
      # records. See `in_batches` for the underlying relation batching.
      def find_in_batches(batch_size : Int32 = 1000, start : Value? = nil, finish : Value? = nil, & : Array(T) ->) : Nil
        in_batches(batch_size: batch_size, start: start, finish: finish).each do |batch|
          yield batch.to_a
        end
      end

      # `in_batches(batch_size: 1000)` — returns a `BatchEnumerator` that
      # yields relations scoped to each batch (Rails-compatible shape).
      def in_batches(batch_size : Int32 = 1000, start : Value? = nil, finish : Value? = nil) : BatchEnumerator(T)
        raise ArgumentError.new("batch_size must be positive (got #{batch_size})") if batch_size <= 0
        BatchEnumerator(T).new(self, @klass.__saci_primary_key, adapter, !@order.empty?, batch_size, start, finish)
      end

      def first : T?
        if r = @records
          return r.first?
        end
        return nil if @none_flag
        limit(1).to_a.first?
      end

      def first! : T
        first || raise RecordNotFound.new("Couldn't find #{@klass.name}")
      end

      # `take` / `take(3)` — first record / first N records.
      def take : T?
        first
      end

      def take(n : Int32) : Array(T)
        return [] of T if @none_flag
        limit(n).to_a
      end

      def take(n : Int) : Array(T)
        take(n.to_i32)
      end

      # `last` / `last(3)` — last record(s). Without an explicit order this
      # orders by primary key descending (Rails behavior); with an order it
      # applies `LIMIT/OFFSET` to the ordered scope (or slices the loaded
      # records when a limit/offset is already present).
      def last : T?
        if r = @records
          return r.last?
        end
        return nil if @none_flag
        if @limit || @offset
          to_a.last?
        elsif @order.empty?
          order(@klass.__saci_primary_key, :desc).limit(1).first?
        else
          c = count
          c == 0 ? nil : offset(c - 1).limit(1).first?
        end
      end

      def last(n : Int32) : Array(T)
        return [] of T if @none_flag
        return to_a.last(n) if @limit || @offset || !@order.empty?
        order(@klass.__saci_primary_key, :desc).limit(n).to_a.reverse
      end

      def last(n : Int) : Array(T)
        last(n.to_i32)
      end

      # Zero-based ordinal lookup (`find_nth(0)` is `first`).
      def find_nth(index : Int32) : T?
        return nil if index < 0 || @none_flag
        offset(index).limit(1).first?
      end

      def find_nth(index : Int) : T?
        find_nth(index.to_i32)
      end

      def find_nth!(index : Int32) : T
        find_nth(index) || raise RecordNotFound.new("Couldn't find #{@klass.name} at index #{index}")
      end

      def second : T?
        find_nth(1)
      end

      def third : T?
        find_nth(2)
      end

      def fourth : T?
        find_nth(3)
      end

      def fifth : T?
        find_nth(4)
      end

      def forty_two : T?
        find_nth(41)
      end

      def second_to_last : T?
        nth_from_end(1)
      end

      def third_to_last : T?
        nth_from_end(2)
      end

      # `nth_from_end(0)` is `last`.
      def nth_from_end(index : Int32) : T?
        return nil if index < 0 || @none_flag
        recs = to_a
        recs.size > index ? recs[recs.size - 1 - index] : nil
      end

      # `ids` — primary keys without instantiating records.
      def ids : Array(Value)
        return [] of Value if @none_flag
        pluck(@klass.__saci_primary_key)
      end

      # -- relation predicates ---------------------------------------------

      def any? : Bool
        if @none_flag
          return false
        end
        if r = @records
          return !r.empty?
        end
        exists?
      end

      def many? : Bool
        if @none_flag
          return false
        end
        if r = @records
          return r.size > 1
        end
        limit(2).to_a.size > 1
      end

      def none? : Bool
        !any?
      end

      def one? : Bool
        if @none_flag
          return false
        end
        if r = @records
          return r.size == 1
        end
        limit(2).to_a.size == 1
      end

      # `pick(:title)` → first row's value; `pick(:id, :title)` → array of
      # values (nil when the scope is empty). Honors ORDER/LIMIT(1)/OFFSET.
      def pick(col : String | Symbol) : Value?
        row = pick_row([col] of String | Symbol)
        row.try(&.[0]?)
      end

      def pick(*cols : String | Symbol) : Array(Value)?
        return nil if cols.empty?
        pick_row(cols.to_a)
      end

      private def pick_row(cols : Array(String | Symbol)) : Array(Value)?
        return nil if @none_flag
        ad = adapter
        sel = cols.map { |c| qualified(c) }.join(", ")
        limit_part = @offset ? " LIMIT 1 OFFSET #{@offset}" : " LIMIT 1"
        sql = "#{annotation_sql}SELECT #{sel} FROM #{from_sql(ad)}#{joins_sql}#{where_sql}#{having_sql}#{order_sql}#{limit_part}#{lock_sql(ad)}"
        row : Array(Value)? = nil
        Record.query_compat(@klass.connection, sql, @params + @having_params) do |rs|
          rs.each do
            row = read_generic_row(rs)
            break
          end
        end
        row
      end

      # -- sole / find-or-create -------------------------------------------

      # `sole` — exactly one record or raise (`RecordNotFound` for zero,
      # `SoleRecordExceeded` for more than one).
      def sole : T
        recs = @records || limit(2).to_a
        if recs.empty?
          raise RecordNotFound.new("Couldn't find #{@klass.name} (expected exactly one)")
        elsif recs.size > 1
          raise SoleRecordExceeded.new("Found more than one #{@klass.name} (expected exactly one)")
        end
        recs.first
      end

      def find_sole_by(**conds : Object) : T
        where(**conds).sole
      end

      def find_sole_by(conds : NamedTuple) : T
        find_sole_by(**conds)
      end

      # `find_or_create_by(email: "x")` — find first, otherwise create.
      # Not race-safe (no unique-index rescue); use `create_or_find_by` for
      # the insert-first pattern.
      def find_or_create_by(**attrs : Object) : T
        where(**attrs).first || @klass.create(**attrs)
      end

      def find_or_create_by(attrs : NamedTuple) : T
        where(**attrs).first || @klass.create(**attrs)
      end

      def find_or_initialize_by(**attrs : Object) : T
        where(**attrs).first || @klass.new(**attrs)
      end

      def find_or_initialize_by(attrs : NamedTuple) : T
        where(**attrs).first || @klass.new(**attrs)
      end

      # `create_or_find_by(email: "x")` — inserts first and, on a unique
      # violation, returns the existing row. Validation errors propagate.
      def create_or_find_by(**attrs : Object) : T
        begin
          @klass.create!(**attrs)
        rescue ex : Exception
          raise ex unless unique_violation?(ex)
          where(**attrs).first || raise ex
        end
      end

      def create_or_find_by(attrs : NamedTuple) : T
        begin
          @klass.create!(**attrs)
        rescue ex : Exception
          raise ex unless unique_violation?(ex)
          where(**attrs).first || raise ex
        end
      end

      private def unique_violation?(ex : Exception) : Bool
        msg = ex.message.try(&.downcase) || ""
        msg.includes?("unique constraint") || msg.includes?("duplicate key") ||
          msg.includes?("duplicate entry") || msg.includes?("unique failed") ||
          msg.includes?("23505") || msg.includes?("constraint failed: unique")
      end

      def count : Int64
        if @none_flag
          return 0_i64
        end
        if r = @records
          return r.size.to_i64
        end
        conn = @klass.connection
        Record.scalar_compat(conn, count_sql(adapter), @params + @having_params).as(Int64)
      end

      def exists? : Bool
        if r = @records
          return !r.empty?
        end
        return false if @none_flag
        limit(1).to_a.any?
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
        return 0_i64 if @none_flag
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

      # Keyword form (`where(...).update_all(published: true)`).
      def update_all(**attrs : Object) : Int64
        update_all(attrs)
      end

      def delete_all : Int64
        return 0_i64 if @none_flag
        res = Record.exec_compat(@klass.connection, delete_sql(adapter), @params)
        res.rows_affected
      end

      # `touch_all` / `touch_all(:viewed_at)` — bumps `updated_at` (plus any
      # given timestamp columns) on every row in scope, skipping validations
      # and callbacks. `time:` overrides the timestamp (default `Time.utc`).
      # Returns the number of rows touched.
      def touch_all(*names, time : Time? = nil) : Int64
        return 0_i64 if @none_flag
        ad = adapter
        cols = [] of String
        names.each { |x| cols << x.to_s }
        cols.each do |c|
          unless @klass.__saci_column_names.any? { |(n, _)| n == c }
            raise UnknownAttributeError.new("unknown attribute '#{c}' for #{@klass.name}")
          end
        end
        stamp = time || Time.utc
        sets = [] of String
        vals = [] of Value
        if @klass.__saci_timestamps?
          sets << "#{Record.quote("updated_at", ad)} = ?"
          vals << Record.to_db(stamp, ad)
        end
        cols.each do |c|
          next if c == "updated_at" && @klass.__saci_timestamps?
          sets << "#{Record.quote(c, ad)} = ?"
          vals << Record.to_db(stamp, ad)
        end
        return 0_i64 if sets.empty?
        res = Record.exec_compat(@klass.connection, "#{update_sql(ad, sets.join(", "))}", vals + @params)
        res.rows_affected
      end

      def pluck(col : String | Symbol) : Array(Value)
        return [] of Value if @none_flag
        ad = adapter
        col_type = @klass.__saci_column_names.find { |(n, _)| n == col.to_s }.try(&.[1]) || "String"
        d = @distinct_flag ? "DISTINCT " : ""
        values = [] of Value
        sql = "#{annotation_sql}SELECT #{d}#{qualified(col)} FROM #{from_sql(ad)}#{joins_sql}#{where_sql}#{group_sql}#{having_sql}#{order_sql}#{limit_sql(ad)}"
        Record.query_compat(@klass.connection, sql, @params + @having_params) do |rs|
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

      # Wires this scope to its owner association (called by has_many
      # getters). Used by `build`/`create` and autosave registration.
      def __saci_with_owner(owner : Saci::Record::Base, fk : String, assoc : String) : Query(T)
        @__saci_owner = owner
        @__saci_owner_fk = fk
        @__saci_owner_assoc = assoc
        self
      end

      # HABTM join-table wiring (G33).
      def __saci_with_habtm(owner : Saci::Record::Base, table : String, fk : String, afk : String) : Query(T)
        @__saci_habtm_owner = owner
        @__saci_habtm_table = table
        @__saci_habtm_fk = fk
        @__saci_habtm_afk = afk
        self
      end

      # `article.tags << tag` — inserts one join row (idempotent) when this
      # query came from a `has_and_belongs_to_many` getter.
      def <<(record : T) : T
        owner = @__saci_habtm_owner
        table = @__saci_habtm_table
        fk = @__saci_habtm_fk
        afk = @__saci_habtm_afk
        if owner.nil? || table.nil? || fk.nil? || afk.nil?
          raise ArgumentError.new("<< is only available on has_and_belongs_to_many associations")
        end
        owner_pk = owner.__saci_get_attr(owner.class.__saci_primary_key)
        target_pk = record.__saci_get_attr(@klass.__saci_primary_key)
        raise RecordNotSaved.new("Cannot add to a HABTM association on an unsaved owner") if owner_pk.nil?
        raise RecordNotSaved.new("Cannot add an unsaved #{@klass} to a HABTM association") if target_pk.nil?
        ad = adapter
        tbl = Record.quote(table, ad)
        fkq = Record.quote(fk, ad)
        afkq = Record.quote(afk, ad)
        count = Record.scalar_compat(@klass.connection,
          "SELECT COUNT(*) FROM " + tbl + " WHERE " + fkq + " = ? AND " + afkq + " = ?",
          [Record.to_db(owner_pk, ad), Record.to_db(target_pk, ad)] of Value)
        unless count.as(Int64) > 0
          Record.exec_compat(@klass.connection,
            "INSERT INTO " + tbl + " (" + fkq + ", " + afkq + ") VALUES (?, ?)",
            [Record.to_db(owner_pk, ad), Record.to_db(target_pk, ad)] of Value)
        end
        record
      end

      # `article.tags.delete(tag)` — removes the join row for `tag`.
      def delete(record : T) : T
        owner = @__saci_habtm_owner
        table = @__saci_habtm_table
        fk = @__saci_habtm_fk
        afk = @__saci_habtm_afk
        if owner.nil? || table.nil? || fk.nil? || afk.nil?
          raise ArgumentError.new("delete is only available on has_and_belongs_to_many associations")
        end
        owner_pk = owner.__saci_get_attr(owner.class.__saci_primary_key)
        target_pk = record.__saci_get_attr(@klass.__saci_primary_key)
        if !owner_pk.nil? && !target_pk.nil?
          ad = adapter
          Record.exec_compat(@klass.connection,
            "DELETE FROM " + Record.quote(table, ad) +
            " WHERE " + Record.quote(fk, ad) + " = ?" +
            " AND " + Record.quote(afk, ad) + " = ?",
            [Record.to_db(owner_pk, ad), Record.to_db(target_pk, ad)] of Value)
        end
        record
      end

      # `author.posts.build(title: "x")` — new child with the owner's
      # foreign key applied when the owner is persisted. With
      # `autosave: true` the child is registered and saved with the owner.
      def build : T
        obj = @klass.new
        __saci_apply_owner(obj)
        obj
      end

      def build(attrs : NamedTuple) : T
        obj = @klass.new(attrs)
        __saci_apply_owner(obj)
        obj
      end

      def build(**attrs : Object) : T
        obj = @klass.new(attrs)
        __saci_apply_owner(obj)
        obj
      end

      # `author.posts.create(title: "x")` — builds and persists immediately.
      # Requires a persisted owner (the child needs its foreign key).
      def create(attrs : NamedTuple) : T
        obj = build(attrs)
        obj.save!
        obj
      end

      def create(**attrs : Object) : T
        create(attrs)
      end

      private def __saci_apply_owner(obj : T) : Nil
        if owner = @__saci_owner
          pk = owner.__saci_get_attr(owner.class.__saci_primary_key)
          if (fk = @__saci_owner_fk) && !pk.nil?
            obj.__saci_set_attr(fk, pk)
          end
          if assoc = @__saci_owner_assoc
            owner.__saci_autosave_register(assoc, obj.as(Saci::Record::Base))
          end
        end
      end

      # Rendered SELECT (without executing it). `ad` defaults to the model's
      # adapter; passing another adapter is how the suite pins
      # PostgreSQL/MySQL SQL strings without a live server (G21).
      def to_sql(ad : Adapter = adapter) : String
        select_sql(ad)
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
        sql = "#{annotation_sql}SELECT #{groups}, #{expr} FROM #{from_sql(ad)}#{joins_sql}#{where_sql} GROUP BY #{groups}#{having_sql}"
        rows = [] of Array(Value)
        Record.query_compat(@klass.connection, sql, @params + @having_params) do |rs|
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
        sql = "#{annotation_sql}SELECT #{func}(#{qualified(col)}) FROM #{from_sql(ad)}#{joins_sql}#{where_sql}#{having_sql}"
        Record.query_compat(@klass.connection, sql, @params + @having_params) do |rs|
          rs.each { result = Record.read_generic(rs) }
        end
        result
      end

      # `explain` / `explain(analyze: true)` — runs the relation's SELECT
      # through the adapter's plan command and returns a readable string
      # (SQL plus one plan row per line). SQLite uses `EXPLAIN QUERY PLAN`
      # (it has no ANALYZE variant); PostgreSQL uses `EXPLAIN` /
      # `EXPLAIN (ANALYZE, BUFFERS)`; MySQL uses `EXPLAIN` /
      # `EXPLAIN ANALYZE`.
      def explain(analyze : Bool = false) : String
        if @none_flag
          return "Saci::Record::Query#none — no SQL executed"
        end
        ad = adapter
        sql = select_sql(ad)
        prefix = case ad
                 when :sqlite   then "EXPLAIN QUERY PLAN "
                 when :postgres then analyze ? "EXPLAIN (ANALYZE, BUFFERS) " : "EXPLAIN "
                 when :mysql    then analyze ? "EXPLAIN ANALYZE " : "EXPLAIN "
                 else                "EXPLAIN "
                 end
        String.build do |io|
          io << prefix << sql << '\n'
          Record.query_compat(@klass.connection, prefix + sql, @params + @having_params) do |rs|
            write_explain_rows(io, rs)
          end
        end
      end

      # Writes column headers + rows for `explain` (plain method: iterating
      # column metadata inside a query block ICEs this compiler).
      private def write_explain_rows(io : IO, rs : DB::ResultSet) : Nil
        total = rs.column_count
        headers = [] of String
        i = 0
        while i < total
          headers << rs.column_name(i)
          i += 1
        end
        io << headers.join(" | ") << '\n'
        rs.each do
          vals = [] of String
          j = 0
          while j < total
            v = Record.read_generic(rs)
            vals << (v.nil? ? "NULL" : v.to_s)
            j += 1
          end
          io << vals.join(" | ") << '\n'
        end
      end

      # Reads one row of arbitrary columns (`pick`).
      private def read_generic_row(rs : DB::ResultSet) : Array(Value)
        vals = [] of Value
        i = 0
        total = rs.column_count
        while i < total
          vals << Record.read_generic(rs)
          i += 1
        end
        vals
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

      private def having_sql : String
        @having.empty? ? "" : " HAVING #{@having.join(" AND ")}"
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

      # SQL comments (`annotate`) — sanitized so a comment cannot close
      # itself early.
      private def annotation_sql : String
        return "" if @annotations.empty?
        String.build do |io|
          @annotations.each do |a|
            io << "/* " << a.gsub("*/", "* /") << " */ "
          end
        end
      end

      private def from_sql(ad : Adapter) : String
        @from_clause || Record.quote(@klass.table_name, ad)
      end

      # `FOR UPDATE` is emitted on PostgreSQL/MySQL; SQLite has no row locks
      # (documented no-op fallback, G21).
      private def lock_sql(ad : Adapter) : String
        clause = @lock_clause
        return "" if clause.nil?
        if emitted = Record.locking_clause(ad, clause)
          " #{emitted}"
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
        "#{annotation_sql}SELECT #{d}#{cols} FROM #{from_sql(ad)}#{joins_sql}#{where_sql}#{group_sql}#{having_sql}#{order_sql}#{limit_sql(ad)}#{lock_sql(ad)}"
      end

      private def count_sql(ad : Adapter) : String
        "#{annotation_sql}SELECT COUNT(*) FROM #{from_sql(ad)}#{joins_sql}#{where_sql}#{having_sql}"
      end

      private def update_sql(ad : Adapter, sets : String) : String
        "UPDATE #{Record.quote(@klass.table_name, ad)} SET #{sets}#{where_sql}"
      end

      private def delete_sql(ad : Adapter) : String
        "DELETE FROM #{Record.quote(@klass.table_name, ad)}#{where_sql}"
      end
    end

    # Batch iterator returned by `Query#in_batches`. Yields relations, one
    # per batch, each carrying the batch's loaded records (so `to_a` does
    # not re-query) and still supporting `update_all` / `delete_all` /
    # `pluck`.
    #
    # ```
    # Post.where(published: true).in_batches(batch_size: 100) do |batch|
    #   batch.update_all(seen: true)
    #   batch.each_record { |post| ... }
    # end
    # ```
    class BatchEnumerator(T)
      @pk : String
      @adapter : Adapter
      @ordered : Bool
      @batch_size : Int32
      @start : Value?
      @finish : Value?

      def initialize(@query : Query(T), @pk : String, @adapter : Adapter, @ordered : Bool, @batch_size : Int32 = 1000, @start : Value? = nil, @finish : Value? = nil)
      end

      getter batch_size : Int32

      # Yields one relation per batch. Keyset pagination (`pk > last`) is
      # used for unordered relations; explicit orders fall back to
      # LIMIT/OFFSET so the caller's ordering is preserved.
      def each(& : Query(T) ->) : Nil
        return if @batch_size <= 0
        qpk = Record.quote(@pk, @adapter)
        after = @start
        off = 0
        first = true
        loop do
          scope = @query
          if after
            scope = scope.where("#{qpk} #{first ? ">=" : ">"} ?", after)
          end
          if @ordered
            scope = scope.offset(off)
          else
            scope = scope.order(@pk, :asc)
          end
          scope = scope.where("#{qpk} <= ?", @finish) if @finish
          records = scope.limit(@batch_size).to_a
          break if records.empty?
          ids = records.map { |r| r.__saci_get_attr(@pk) }.reject(&.nil?)
          if ids.empty?
            # Model without a usable primary key: fall back to plain yields.
            yield scope.limit(@batch_size)
          else
            ph = Array(String).new(ids.size, "?").join(", ")
            rel = @query.where("#{qpk} IN (#{ph})", ids).__saci_with_records(records)
            yield rel
          end
          break if records.size < @batch_size
          first = false
          if @ordered
            off += @batch_size
          else
            after = ids.last? || break
          end
        end
      end

      # Yields individual records across all batches.
      def each_record(& : T ->) : Nil
        each { |batch| batch.each { |r| yield r } }
      end

      def update_all(attrs : NamedTuple) : Int64
        total = 0_i64
        each { |batch| total += batch.update_all(attrs) }
        total
      end

      def update_all(**attrs : Object) : Int64
        update_all(attrs)
      end

      def delete_all : Int64
        total = 0_i64
        each { |batch| total += batch.delete_all }
        total
      end

      def pluck(col : String | Symbol) : Array(Value)
        values = [] of Value
        each { |batch| values.concat(batch.pluck(col)) }
        values
      end

      def count : Int64
        total = 0_i64
        each { |batch| total += batch.count }
        total
      end
    end

    # Result of `Query#group` — Rails-style grouped aggregates plus the
    # underlying grouped relation (`where` / `order` / `to_a` / ...).
    #
    # ```
    # Post.group(:published).count       # => {true => 2, false => 1}
    # Post.group(:published).sum(:views) # => {true => 550.0, ...}
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

      def having(sql : String, *args : Object) : GroupedQuery(T)
        GroupedQuery(T).new(@query.having(sql, *args))
      end

      def having(sql : String) : GroupedQuery(T)
        GroupedQuery(T).new(@query.having(sql))
      end

      def having(**conds : Object) : GroupedQuery(T)
        GroupedQuery(T).new(@query.having(**conds))
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

# Bulk writes / class-level finders / dialect helpers live in separate
# files; requiring them here keeps `require "./record/query"` self-contained.
# The coordinator may also list them in `src/saci.cr` (requires are
# idempotent).
require "./bulk"
require "./finders"
require "./dialect"
