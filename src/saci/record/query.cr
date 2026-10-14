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

      def initialize(@klass : T.class, @conditions : Array(String) = [] of String, @params : Array(Value) = [] of Value, @order : Array(String) = [] of String, @limit : Int32? = nil, @offset : Int32? = nil)
      end

      # Adapter of the model's database (resolved per call so
      # `connected_to` switches and transactions behave).
      private def adapter : Adapter
        Record.adapter_of(@klass.connection)
      end

      # `where(title: "x", published: true)` — nil becomes `IS NULL`.
      def where(**conds : Object) : Query(T)
        ad = adapter
        new_conds = @conditions.dup
        new_params = @params.dup
        conds.each do |key, value|
          if value.nil?
            new_conds << "#{Record.quote(key, ad)} IS NULL"
          else
            new_conds << "#{Record.quote(key, ad)} = ?"
            new_params << Record.to_db(value, ad)
          end
        end
        Query(T).new(@klass, new_conds, new_params, @order.dup, @limit, @offset)
      end

      # `where("views > ?", 10)`
      def where(sql : String, *args : Object) : Query(T)
        ad = adapter
        converted = args.to_a.map { |a| Record.to_db(a, ad) }
        Query(T).new(@klass, @conditions.dup + ["(#{sql})"], @params.dup + converted, @order.dup, @limit, @offset)
      end

      # `where("published IS NOT NULL")` — raw condition without binds.
      def where(sql : String) : Query(T)
        Query(T).new(@klass, @conditions.dup + ["(#{sql})"], @params.dup, @order.dup, @limit, @offset)
      end

      def order(field : Symbol | String, dir : Symbol = :asc) : Query(T)
        direction = dir.to_s.upcase == "DESC" ? "DESC" : "ASC"
        Query(T).new(@klass, @conditions.dup, @params.dup, @order.dup + ["#{Record.quote(field, adapter)} #{direction}"], @limit, @offset)
      end

      # `order(created_at: :desc, title: :asc)`
      def order(**opts : Object) : Query(T)
        q = self
        ad = adapter
        opts.each do |field, dir|
          direction = dir.to_s.upcase == "DESC" ? "DESC" : "ASC"
          q = Query(T).new(q.@klass, q.@conditions.dup, q.@params.dup, q.@order.dup + ["#{Record.quote(field, ad)} #{direction}"], q.@limit, q.@offset)
        end
        q
      end

      # Raw SQL ordering, e.g. `order_raw("RANDOM()")`.
      def order_raw(sql : String) : Query(T)
        Query(T).new(@klass, @conditions.dup, @params.dup, @order.dup + [sql], @limit, @offset)
      end

      def limit(n : Int) : Query(T)
        Query(T).new(@klass, @conditions.dup, @params.dup, @order.dup, n.to_i32, @offset)
      end

      def offset(n : Int) : Query(T)
        Query(T).new(@klass, @conditions.dup, @params.dup, @order.dup, @limit, n.to_i32)
      end

      def to_a : Array(T)
        ad = adapter
        conn = @klass.connection
        sql = select_sql(ad)
        results = [] of T
        Record.query_compat(conn, sql, @params) do |rs|
          rs.each do
            results << @klass.load_row(rs, ad)
          end
        end
        results
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
        limit(1).to_a.first?
      end

      def first! : T
        first || raise RecordNotFound.new("Couldn't find #{@klass.name}")
      end

      def count : Int64
        conn = @klass.connection
        Record.scalar_compat(conn, count_sql(adapter), @params).as(Int64)
      end

      def exists? : Bool
        count > 0
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
        values = [] of Value
        Record.query_compat(@klass.connection, "SELECT #{Record.quote(col, ad)} FROM #{Record.quote(@klass.table_name, ad)}#{where_sql}", @params) do |rs|
          rs.each do
            values << Record.read_typed(rs, col_type, ad)
          end
        end
        values
      end

      # -- SQL fragments -----------------------------------------------------

      private def where_sql : String
        @conditions.empty? ? "" : " WHERE #{@conditions.join(" AND ")}"
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
        cols = @klass.__saci_column_names.map { |(n, _)| Record.quote(n, ad) }.join(", ")
        "SELECT #{cols} FROM #{Record.quote(@klass.table_name, ad)}#{where_sql}#{order_sql}#{limit_sql(ad)}"
      end

      private def count_sql(ad : Adapter) : String
        "SELECT COUNT(*) FROM #{Record.quote(@klass.table_name, ad)}#{where_sql}"
      end

      private def update_sql(ad : Adapter, sets : String) : String
        "UPDATE #{Record.quote(@klass.table_name, ad)} SET #{sets}#{where_sql}"
      end

      private def delete_sql(ad : Adapter) : String
        "DELETE FROM #{Record.quote(@klass.table_name, ad)}#{where_sql}"
      end
    end
  end
end
