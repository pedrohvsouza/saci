module Saci
  module Record
    # Bulk-write class methods (ActiveRecord G11): `insert_all`,
    # `insert_all!` and `upsert_all`.
    #
    # Rows may be `Array(NamedTuple)` or `Array(Hash)` (String or Symbol
    # keys). Missing keys in a partially heterogeneous batch are inserted
    # as `NULL`; columns are the ordered union of all row keys.
    #
    # Return contract:
    # * `returning:` omitted → `Int64` number of rows affected.
    # * `returning:` given (String/Symbol/Array) on SQLite or PostgreSQL →
    #   `Array(Hash(String, Value))` with only the requested columns.
    # * MySQL has no `RETURNING` clause; `returning:` is ignored there and
    #   the method returns `Int64`.
    #
    # Conflict handling:
    # * `insert_all` skips existing rows (`ON CONFLICT DO NOTHING`, or
    #   `INSERT IGNORE` on MySQL; `unique_by:` narrows the conflict target).
    # * `insert_all!` uses a plain INSERT and raises on any conflict.
    # * `upsert_all` updates on conflict (`ON CONFLICT (...) DO UPDATE` on
    #   SQLite/PostgreSQL, `ON DUPLICATE KEY UPDATE` on MySQL). Conflict
    #   target defaults to the primary key; pass `unique_by:` for a unique
    #   index such as `:email`. `created_at` is never overwritten,
    #   `updated_at` is bumpable, and conflict-key columns are not updated.
    #
    # `created_at` / `updated_at` are filled with `Time.utc` for models
    # declaring `timestamps` when a row omits them (explicit values are
    # honored). Validations and callbacks are skipped, like Rails.
    #
    # Limitation: rows are sent in one statement (no automatic chunking),
    # so very large batches can hit adapter parameter limits.
    class Base
      def self.insert_all(rows : Array, unique_by : String | Symbol | Array(String | Symbol)? = nil, returning : String | Symbol | Array(String | Symbol)? = nil) : Int64 | Array(Hash(String, Value))
        __saci_bulk_write(:insert, rows, unique_by, returning)
      end

      def self.insert_all!(rows : Array, unique_by : String | Symbol | Array(String | Symbol)? = nil, returning : String | Symbol | Array(String | Symbol)? = nil) : Int64 | Array(Hash(String, Value))
        __saci_bulk_write(:insert_bang, rows, unique_by, returning)
      end

      def self.upsert_all(rows : Array, unique_by : String | Symbol | Array(String | Symbol)? = nil, returning : String | Symbol | Array(String | Symbol)? = nil) : Int64 | Array(Hash(String, Value))
        __saci_bulk_write(:upsert, rows, unique_by, returning)
      end

      # Shared implementation for the three bulk entry points. Public-ish
      # (double underscore) because Crystal has no file-private class
      # methods and the bulk spec exercises it indirectly.
      def self.__saci_bulk_write(mode : Symbol, rows : Array, unique_by : String | Symbol | Array(String | Symbol)?, returning : String | Symbol | Array(String | Symbol)?) : Int64 | Array(Hash(String, Value))
        ret_cols = __saci_bulk_columns(returning)
        return(ret_cols.empty? ? 0_i64 : [] of Hash(String, Value)) if rows.empty?

        normalized = __saci_bulk_normalize_rows(rows)
        cols_meta = __saci_column_names.map(&.[0])
        normalized.each do |row|
          row.each_key do |key|
            unless cols_meta.includes?(key)
              raise UnknownAttributeError.new("unknown attribute '#{key}' for #{self.name}")
            end
          end
        end

        if __saci_timestamps?
          now = Time.utc
          normalized.each do |row|
            row["created_at"] = now unless row.has_key?("created_at")
            row["updated_at"] = now unless row.has_key?("updated_at")
          end
        end

        columns = [] of String
        normalized.each do |row|
          row.each_key { |k| columns << k unless columns.includes?(k) }
        end
        return(ret_cols.empty? ? 0_i64 : [] of Hash(String, Value)) if columns.empty?

        conn = connection
        ad = Record.adapter_of(conn)
        table = Record.quote(table_name, ad)
        target = __saci_bulk_columns(unique_by)
        target = [__saci_primary_key] if target.empty?

        sql = __saci_bulk_sql(mode, table, columns, normalized.size, target, !unique_by.nil?, ad)

        values = [] of Value
        normalized.each do |row|
          columns.each do |col|
            values << (row.has_key?(col) ? Record.to_db(row[col], ad) : nil)
          end
        end

        if ret_cols.empty?
          res = Record.exec_compat(conn, sql, values)
          return res.rows_affected
        end

        if ad == :mysql
          # MySQL has no RETURNING; fall back to the affected count.
          res = Record.exec_compat(conn, sql, values)
          return res.rows_affected
        end

        ret_sql = ret_cols.map { |c| Record.quote(c, ad) }.join(", ")
        returned = [] of Hash(String, Value)
        Record.query_compat(conn, "#{sql} RETURNING #{ret_sql}", values) do |rs|
          __saci_bulk_read_returned(rs, ret_cols, returned)
        end
        returned
      end

      # Builds the multi-row INSERT for one mode/adapter. Exposed with a
      # double underscore so adapter branches (PostgreSQL/MySQL) can be
      # pinned with string specs without a live server.
      def self.__saci_bulk_sql(mode : Symbol, table : String, columns : Array(String), row_count : Int32, target : Array(String), unique_by_given : Bool, ad : Adapter) : String
        names = columns.map { |c| Record.quote(c, ad) }
        row_ph = "(" + Array(String).new(columns.size, "?").join(", ") + ")"
        placeholders = Array(String).new(row_count, row_ph).join(", ")
        prefix = "INSERT INTO"
        suffix = ""
        case mode
        when :insert
          if ad == :mysql
            prefix = "INSERT IGNORE INTO"
          else
            suffix = target_sql(ad, target, " DO NOTHING", !unique_by_given)
          end
        when :insert_bang
          # Plain INSERT: conflicts raise.
        when :upsert
          updates = __saci_bulk_update_columns(columns, target)
          if ad == :mysql
            if updates.empty?
              pkq = Record.quote(__saci_primary_key, ad)
              suffix = " ON DUPLICATE KEY UPDATE #{pkq} = #{pkq}"
            else
              parts = updates.map { |c| "#{Record.quote(c, ad)} = VALUES(#{Record.quote(c, ad)})" }
              suffix = " ON DUPLICATE KEY UPDATE #{parts.join(", ")}"
            end
          else
            if updates.empty?
              suffix = target_sql(ad, target, " DO NOTHING", false)
            else
              sets = updates.map { |c| "#{Record.quote(c, ad)} = excluded.#{Record.quote(c, ad)}" }
              suffix = target_sql(ad, target, " DO UPDATE SET #{sets.join(", ")}", false)
            end
          end
        else
          raise ArgumentError.new("__saci_bulk_write: unknown mode #{mode.inspect}")
        end
        "#{prefix} #{table} (#{names.join(", ")}) VALUES #{placeholders}#{suffix}"
      end

      # `ON CONFLICT [(cols)] <action>`; `any_conflict` omits the target.
      private def self.target_sql(ad : Adapter, target : Array(String), action : String, any_conflict : Bool) : String
        return " ON CONFLICT#{action}" if any_conflict
        cols = target.map { |c| Record.quote(c, ad) }.join(", ")
        " ON CONFLICT (#{cols})#{action}"
      end

      private def self.__saci_bulk_columns(value : String | Symbol | Array(String | Symbol)?) : Array(String)
        case value
        when Nil    then [] of String
        when String then [value]
        when Symbol then [value.to_s]
        else             value.map(&.to_s)
        end
      end

      private def self.__saci_bulk_normalize_rows(rows : Array) : Array(Hash(String, Value))
        normalized = [] of Hash(String, Value)
        rows.each do |row|
          h = {} of String => Value
          case row
          when NamedTuple
            row.each { |k, v| h[k.to_s] = v.as(Value) }
          when Hash
            row.each do |k, v|
              h[k.to_s] = v.as(Value)
            end
          else
            raise ArgumentError.new("insert_all/upsert_all rows must be NamedTuple or Hash (got #{row.class})")
          end
          normalized << h
        end
        normalized
      end

      # Columns updated on conflict: everything except the primary key,
      # conflict target and `created_at` (Rails preserves creation time).
      private def self.__saci_bulk_update_columns(columns : Array(String), target : Array(String)) : Array(String)
        columns.reject do |c|
          c == __saci_primary_key || c == "created_at" || target.includes?(c)
        end
      end

      private def self.__saci_bulk_read_returned(rs : DB::ResultSet, cols : Array(String), into : Array(Hash(String, Value))) : Nil
        total = rs.column_count
        rs.each do
          row = {} of String => Value
          i = 0
          while i < total
            name = i < cols.size ? cols[i] : rs.column_name(i)
            row[name] = Record.read_generic(rs)
            i += 1
          end
          into << row
        end
      end
    end
  end
end
