module Saci
  module Record
    # Read-only database introspection used by migrations and the schema
    # tooling. All statements go through `Record.query_compat`, so
    # placeholders adapt per adapter and `sqlite3`/`pg`/`mysql` drivers are
    # never required by this file itself.
    #
    # Adapter backing:
    # * SQLite — `sqlite_master` + `PRAGMA table_xinfo/index_list/
    #   index_info/foreign_key_list`; CHECK constraints are parsed from
    #   the stored CREATE TABLE SQL (SQLite has no pragma for them).
    # * PostgreSQL — `information_schema` / `pg_indexes` / `pg_index`.
    # * MySQL — `information_schema`.
    #
    # The migration DSL exposes shortcuts with the same names and an
    # optional database argument (`Saci::Record.table_exists?(:users)`).
    module Introspection
      # One column. `type` is the logical migration type (same vocabulary
      # as `ColumnDef#logical_type`); `generated_as` is set when the
      # adapter reports a generated-column expression.
      struct ColumnInfo
        getter name : String
        getter type : Symbol
        getter null : Bool
        getter default : Value
        getter primary_key : Bool
        getter generated : Bool
        getter generated_as : String?
        getter subtype : Symbol?
        getter size : Int32?
        # Raw SQL default for expression defaults (e.g. CURRENT_TIMESTAMP)
        # so SQLite table rebuilds can preserve them verbatim.
        getter default_sql : String?
        # Generated columns: expression is nil when the adapter cannot
        # report it (SQLite < 3.31 or an unparsable CREATE statement).
        getter stored : Bool

        def initialize(@name : String, @type : Symbol, @null : Bool, @default : Value, @primary_key : Bool, @generated : Bool = false, @generated_as : String? = nil, @subtype : Symbol? = nil, @size : Int32? = nil, @default_sql : String? = nil, @stored : Bool = false)
        end

        # Alias matching `ColumnDef#logical_type`.
        def logical_type : Symbol
          @type
        end
      end

      struct IndexInfo
        getter name : String
        getter columns : Array(String)
        getter unique : Bool

        def initialize(@name : String, @columns : Array(String), @unique : Bool)
        end
      end

      struct ForeignKeyInfo
        getter name : String
        getter column : String
        getter to_table : String
        getter to_column : String
        getter on_delete : String?
        getter deferrable : Symbol?

        def initialize(@name : String, @column : String, @to_table : String, @to_column : String, @on_delete : String? = nil, @deferrable : Symbol? = nil)
        end
      end

      struct CheckConstraintInfo
        getter name : String?
        getter expression : String

        def initialize(@name : String?, @expression : String)
        end
      end

      struct ViewInfo
        getter name : String
        # SELECT body (the part after `AS`) so the schema dumper can emit
        # adapter-neutral `create_view` calls.
        getter sql : String

        def initialize(@name : String, @sql : String)
        end
      end

      # -- existence checks ---------------------------------------------

      def self.table_exists?(db : DB::Database | DB::Connection, table : String | Symbol) : Bool
        name = table.to_s
        case Record.adapter_of(db)
        when :postgres
          exists?(db, "SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = ? AND table_type = 'BASE TABLE'", name)
        when :mysql
          exists?(db, "SELECT 1 FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = ? AND table_type = 'BASE TABLE'", name)
        else
          exists?(db, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", name)
        end
      end

      def self.view_exists?(db : DB::Database | DB::Connection, view : String | Symbol) : Bool
        name = view.to_s
        case Record.adapter_of(db)
        when :postgres
          exists?(db, "SELECT 1 FROM information_schema.views WHERE table_schema = 'public' AND table_name = ?", name)
        when :mysql
          exists?(db, "SELECT 1 FROM information_schema.views WHERE table_schema = DATABASE() AND table_name = ?", name)
        else
          exists?(db, "SELECT 1 FROM sqlite_master WHERE type = 'view' AND name = ?", name)
        end
      end

      def self.data_source_exists?(db : DB::Database | DB::Connection, name : String | Symbol) : Bool
        table_exists?(db, name) || view_exists?(db, name)
      end

      def self.column_exists?(db : DB::Database | DB::Connection, table : String | Symbol, column : String | Symbol) : Bool
        columns(db, table).any? { |c| c.name == column.to_s }
      end

      # Matches by explicit `name:` and/or column list. A single column
      # token also matches an index *name* (Rails-style convenience).
      def self.index_exists?(db : DB::Database | DB::Connection, table : String | Symbol, columns : String | Symbol | Array(String | Symbol) | Nil = nil, name : String? = nil) : Bool
        list = case columns
               when Nil   then nil
               when Array then columns.map(&.to_s)
               else            [columns.to_s]
               end
        indexes(db, table).any? do |idx|
          name_ok = name.nil? || idx.name == name
          cols_ok = if list.nil?
                      true
                    elsif list.size == 1
                      idx.name == list[0] || idx.columns == list
                    else
                      idx.columns == list
                    end
          name_ok && cols_ok
        end
      end

      def self.foreign_key_exists?(db : DB::Database | DB::Connection, from_table : String | Symbol, to_table : String | Symbol | Nil = nil, column : String | Symbol | Nil = nil, name : String? = nil) : Bool
        foreign_keys(db, from_table).any? do |fk|
          (name.nil? || fk.name == name) &&
            (to_table.nil? || fk.to_table == to_table.to_s) &&
            (column.nil? || fk.column == column.to_s)
        end
      end

      # -- column / index / FK listings ---------------------------------

      def self.columns(db : DB::Database | DB::Connection, table : String | Symbol) : Array(ColumnInfo)
        case Record.adapter_of(db)
        when :postgres then pg_columns(db, table.to_s)
        when :mysql    then mysql_columns(db, table.to_s)
        else                sqlite_columns(db, table.to_s)
        end
      end

      def self.indexes(db : DB::Database | DB::Connection, table : String | Symbol) : Array(IndexInfo)
        case Record.adapter_of(db)
        when :postgres then pg_indexes(db, table.to_s)
        when :mysql    then mysql_indexes(db, table.to_s)
        else                sqlite_indexes(db, table.to_s)
        end
      end

      def self.foreign_keys(db : DB::Database | DB::Connection, table : String | Symbol) : Array(ForeignKeyInfo)
        case Record.adapter_of(db)
        when :postgres then pg_foreign_keys(db, table.to_s)
        when :mysql    then mysql_foreign_keys(db, table.to_s)
        else                sqlite_foreign_keys(db, table.to_s)
        end
      end

      def self.check_constraints(db : DB::Database | DB::Connection, table : String | Symbol) : Array(CheckConstraintInfo)
        case Record.adapter_of(db)
        when :postgres then pg_checks(db, table.to_s)
        when :mysql    then mysql_checks(db, table.to_s)
        else                sqlite_checks(db, table.to_s)
        end
      end

      def self.views(db : DB::Database | DB::Connection) : Array(ViewInfo)
        names = [] of String
        sql = case Record.adapter_of(db)
              when :postgres
                "SELECT table_name FROM information_schema.views WHERE table_schema = 'public' ORDER BY table_name"
              when :mysql
                "SELECT table_name FROM information_schema.views WHERE table_schema = DATABASE() ORDER BY table_name"
              else
                "SELECT name FROM sqlite_master WHERE type = 'view' AND name NOT LIKE 'sqlite_%' ORDER BY name"
              end
        Record.query_compat(db, sql) do |rs|
          rs.each { names << (str(rs.read) || next) }
        end
        names.map { |n| ViewInfo.new(n, view_body(db, n)) }
      end

      # -- helpers -------------------------------------------------------

      private def self.exists?(db : DB::Database | DB::Connection, sql : String, arg : String) : Bool
        found = false
        Record.query_compat(db, sql, [arg] of Value) do |rs|
          rs.each { found = true }
        end
        found
      end

      private def self.str(v) : String?
        case v
        when Nil    then nil
        when String then v
        when Bytes  then String.new(v)
        else             v.to_s
        end
      end

      private def self.i64(v) : Int64
        case v
        when Nil    then 0_i64
        when Bool   then v ? 1_i64 : 0_i64
        when Number then v.to_i64
        when String then v.strip.to_i64? || 0_i64
        else             0_i64
        end
      end

      private def self.bool(v) : Bool
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

      # -- SQLite --------------------------------------------------------

      private def self.sqlite_columns(db : DB::Database | DB::Connection, table : String) : Array(ColumnInfo)
        qt = table.gsub('"', "\"\"")
        generated = sqlite_generated_columns(sqlite_table_sql(db, table) || "")
        out = [] of ColumnInfo
        # table_xinfo has a 7th `hidden` column (0 normal, 2/3 generated).
        Record.query_compat(db, "PRAGMA table_xinfo(\"#{qt}\")") do |rs|
          rs.each do
            rs.read # cid
            name = str(rs.read) || "col#{out.size}"
            decltype = str(rs.read) || "TEXT"
            notnull = bool(rs.read)
            dflt_raw = rs.read
            pk = i64(rs.read) != 0
            hidden = i64(rs.read)
            unless hidden == 1 # hidden virtual-table column
              logical = TypeMapping.sqlite_logical(decltype, pk)
              is_generated = hidden == 2 || hidden == 3
              gen = generated[name]?
              out << sqlite_column_info(name, logical, !notnull && !pk, sqlite_default(dflt_raw), pk, is_generated,
                gen, sqlite_expression_default(dflt_raw))
            end
          end
        end
        out
      end

      # Constructor isolated from the PRAGMA block to avoid a Crystal
      # codegen issue with long `ColumnInfo.new` calls in result-set
      # closures (ResultSet virtual downcast).
      private def self.sqlite_column_info(name : String, logical : Symbol, null : Bool, default : Value, primary : Bool, is_generated : Bool, gen : Tuple(String, Bool)?, default_sql : String?) : ColumnInfo
        ColumnInfo.new(name, logical, null, default, primary, is_generated,
          gen.try(&.[0]), nil, nil, default_sql, gen.try(&.[1]) || false)
      end

      private def self.sqlite_table_sql(db : DB::Database | DB::Connection, table : String) : String?
        sql = nil
        Record.query_compat(db, "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?", [table] of Value) do |rs|
          rs.each { sql = str(rs.read) }
        end
        sql
      end

      # Extracts `{column => {expression, stored?}}` from CREATE TABLE SQL.
      # Generated columns are invisible to `PRAGMA table_info` (they only
      # appear in `table_xinfo`) and SQLite exposes no pragma for their
      # expression, so the stored DDL is the only source.
      def self.sqlite_generated_columns(sql : String) : Hash(String, Tuple(String, Bool))
        result = {} of String => Tuple(String, Bool)
        paren_open = sql.index('(')
        paren_close = sql.rindex(')')
        return result unless paren_open && paren_close && paren_close > paren_open
        split_top_level(sql[(paren_open + 1)...paren_close]).each do |part|
          text = part.strip
          next if text.empty?
          name = leading_identifier(text)
          next unless name
          next if {"CONSTRAINT", "PRIMARY", "FOREIGN", "UNIQUE", "CHECK"}.includes?(name.upcase)
          if m = text.match(/\bAS\s*\(/i)
            start = text.index('(', m.begin(0))
            next unless start
            finish = matching_paren(text, start)
            next unless finish
            expr = text[(start + 1)...finish].strip
            stored = text[(finish + 1)..].downcase.includes?("stored")
            result[name] = {expr, stored}
          end
        end
        result
      end

      private def self.split_top_level(body : String) : Array(String)
        parts = [] of String
        depth = 0
        quote = nil
        start = 0
        i = 0
        while i < body.size
          ch = body[i]
          if q = quote
            if ch == q
              quote = nil if i + 1 >= body.size || body[i + 1] != q
              i += 1 if i + 1 < body.size && body[i + 1] == q
            end
          else
            case ch
            when '\'', '"', '`'
              quote = ch
            when '['
              quote = ']'
            when '('
              depth += 1
            when ')'
              depth -= 1
            when ','
              if depth == 0
                parts << body[start...i]
                start = i + 1
              end
            end
          end
          i += 1
        end
        parts << body[start..]
        parts
      end

      private def self.leading_identifier(text : String) : String?
        return nil if text.empty?
        case text[0]
        when '"', '`', '['
          close = text[0] == '[' ? ']' : text[0]
          if idx = text.index(close, 1)
            return text[1...idx]
          end
          nil
        else
          if m = text.match(/\A([A-Za-z_][A-Za-z0-9_$]*)/)
            m[1]
          end
        end
      end

      # Raw SQL for defaults that are expressions (CURRENT_TIMESTAMP, …);
      # nil for literals (which `sqlite_default` already decoded).
      private def self.sqlite_expression_default(raw) : String?
        return nil unless raw.is_a?(String)
        s = raw.strip
        return nil if s.empty? || s.upcase == "NULL"
        return nil if s.size >= 2 && ((s.starts_with?("'") && s.ends_with?("'")) || (s.starts_with?("\"") && s.ends_with?("\"")))
        return nil if s.to_i64? || s.to_f64? || {"TRUE", "FALSE"}.includes?(s.upcase)
        s
      end

      private def self.sqlite_default(raw) : Value
        case raw
        when Nil    then nil
        when Bool   then raw
        when Float  then raw.to_f64
        when Number then raw.to_i64
        when String
          s = raw.strip
          return nil if s.empty? || s.upcase == "NULL"
          if s.size >= 2 && s.starts_with?("'") && s.ends_with?("'")
            return s[1..-2].gsub("''", "'")
          end
          if s.size >= 2 && s.starts_with?("\"") && s.ends_with?("\"")
            return s[1..-2]
          end
          return true if s.upcase == "TRUE"
          return false if s.upcase == "FALSE"
          return s.to_i64 if s.to_i64?
          return s.to_f64 if s.to_f64?
          s
        else
          nil
        end
      end

      private def self.sqlite_indexes(db : DB::Database | DB::Connection, table : String) : Array(IndexInfo)
        qt = table.gsub('"', "\"\"")
        raw = [] of Tuple(String, Bool)
        Record.query_compat(db, "PRAGMA index_list(\"#{qt}\")") do |rs|
          rs.each do
            rs.read # seq
            name = str(rs.read) || ""
            unique = bool(rs.read)
            origin = str(rs.read) || ""
            rs.read # partial
            next if name.empty? || origin == "pk" || name.starts_with?("sqlite_autoindex_")
            raw << {name, unique}
          end
        end
        raw.map do |(name, unique)|
          qi = name.gsub('"', "\"\"")
          ordered = [] of Tuple(Int32, String)
          Record.query_compat(db, "PRAGMA index_info(\"#{qi}\")") do |irs|
            irs.each do
              seqno = i64(irs.read).to_i32
              cid = i64(irs.read)
              col = str(irs.read)
              ordered << {seqno, col} if col && cid != -2
            end
          end
          IndexInfo.new(name, ordered.sort_by(&.[0]).map(&.[1]), unique)
        end.sort_by!(&.name)
      end

      private def self.sqlite_foreign_keys(db : DB::Database | DB::Connection, table : String) : Array(ForeignKeyInfo)
        qt = table.gsub('"', "\"\"")
        out = [] of ForeignKeyInfo
        Record.query_compat(db, "PRAGMA foreign_key_list(\"#{qt}\")") do |rs|
          rs.each do
            rs.read # id
            rs.read # seq
            to_table = str(rs.read) || ""
            from = str(rs.read) || ""
            to = str(rs.read) || "id"
            rs.read # on_update
            on_delete = str(rs.read)
            rs.read # match
            out << ForeignKeyInfo.new(Migration.fk_constraint_name(table, from), from, to_table, to, on_delete)
          end
        end
        out
      end

      private def self.sqlite_checks(db : DB::Database | DB::Connection, table : String) : Array(CheckConstraintInfo)
        sql = nil
        Record.query_compat(db, "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?", [table] of Value) do |rs|
          rs.each { sql = str(rs.read) }
        end
        sql ? parse_check_constraints(sql) : [] of CheckConstraintInfo
      end

      # Extracts `[CONSTRAINT name] CHECK (expr)` clauses from CREATE TABLE
      # SQL, honouring nested parentheses and quoted identifiers.
      private def self.parse_check_constraints(sql : String) : Array(CheckConstraintInfo)
        out = [] of CheckConstraintInfo
        offset = 0
        while (idx = sql.index(/CHECK\s*\(/i, offset))
          open = sql.index('(', idx)
          break unless open
          close = matching_paren(sql, open)
          unless close
            offset = idx + 1
            next
          end
          expr = sql[(open + 1)...close].strip
          prefix = sql[0...idx]
          name = nil
          if m = prefix.match(/\bCONSTRAINT\s+(?:"([^"]+)"|`([^`]+)`|\[([^\]]+)\]|([A-Za-z_][A-Za-z0-9_$]*))\s*\z/i)
            name = m[1]? || m[2]? || m[3]? || m[4]?
          end
          out << CheckConstraintInfo.new(name, expr)
          offset = close + 1
        end
        out
      end

      # Index of the `)` matching the `(` at `open`, skipping quoted
      # strings/identifiers. Returns nil when unbalanced.
      private def self.matching_paren(sql : String, open : Int32) : Int32?
        depth = 0
        quote = nil
        i = open
        while i < sql.size
          ch = sql[i]
          if q = quote
            if ch == q
              # doubled quote escapes
              quote = nil if i + 1 >= sql.size || sql[i + 1] != q
              i += 1 if i + 1 < sql.size && sql[i + 1] == q
            end
          else
            case ch
            when '\'', '"', '`'
              quote = ch
            when '('
              depth += 1
            when ')'
              depth -= 1
              return i if depth == 0
            end
          end
          i += 1
        end
        nil
      end

      # -- PostgreSQL ----------------------------------------------------

      private def self.pg_columns(db : DB::Database | DB::Connection, table : String) : Array(ColumnInfo)
        pk_cols = Set(String).new
        escaped = table.gsub("'", "''")
        Record.query_compat(db, "SELECT a.attname FROM pg_index ix JOIN pg_attribute a ON a.attrelid = ix.indrelid AND a.attnum = ANY(ix.indkey) WHERE ix.indrelid = '#{escaped}'::regclass AND ix.indisprimary") do |rs|
          rs.each { pk_cols << (str(rs.read) || next) }
        end
        out = [] of ColumnInfo
        Record.query_compat(db, "SELECT column_name, data_type, udt_name, is_nullable, column_default, is_generated, generation_expression, character_maximum_length FROM information_schema.columns WHERE table_schema = 'public' AND table_name = ? ORDER BY ordinal_position", [table] of Value) do |rs|
          rs.each do
            name = str(rs.read) || next
            data_type = (str(rs.read) || "text").downcase
            udt_name = (str(rs.read) || "").downcase
            nullable = (str(rs.read) || "YES").upcase == "YES"
            dflt_raw = str(rs.read)
            is_generated = (str(rs.read) || "NEVER").upcase
            generation = str(rs.read)
            max_len = rs.read
            primary = pk_cols.includes?(name)
            logical, subtype = TypeMapping.pg_logical(data_type, udt_name, dflt_raw, primary)
            generated = is_generated == "ALWAYS"
            size = (logical == :bit || logical == :bit_varying) ? (max_len.nil? ? nil : i64(max_len).to_i32) : nil
            out << ColumnInfo.new(name, logical, nullable && !primary, pg_default(dflt_raw), primary, generated, generation, subtype, size, nil, generated)
          end
        end
        out
      end

      private def self.pg_default(raw : String?) : Value
        return nil if raw.nil? || raw.empty?
        s = raw.strip
        return nil if s.starts_with?("nextval")
        return true if s == "true"
        return false if s == "false"
        if s.starts_with?("'")
          if m = s.match(/\A'(.*)'::[\w ]+\z/m)
            return m[1].gsub("''", "'")
          end
        end
        return s.to_i64 if s.to_i64?
        return s.to_f64 if s.to_f64?
        s
      end

      private def self.pg_indexes(db : DB::Database | DB::Connection, table : String) : Array(IndexInfo)
        out = [] of IndexInfo
        Record.query_compat(db, "SELECT indexname, indexdef FROM pg_indexes WHERE schemaname = 'public' AND tablename = ?", [table] of Value) do |rs|
          rs.each do
            name = str(rs.read) || next
            indexdef = str(rs.read) || next
            next if name == "#{table}_pkey"
            cols = pg_index_columns(indexdef)
            next unless cols
            out << IndexInfo.new(name, cols, indexdef.upcase.starts_with?("CREATE UNIQUE INDEX"))
          end
        end
        out.sort_by!(&.name)
      end

      private def self.pg_index_columns(indexdef : String) : Array(String)?
        o = indexdef.rindex('(')
        c = indexdef.rindex(')')
        return nil unless o && c && c > o
        inner = indexdef[(o + 1)...c].strip
        return nil if inner.starts_with?("(")
        cols = inner.split(",").map do |part|
          token = part.strip.split(" ")[0]
          if token.size >= 2 && token.starts_with?("\"") && token.ends_with?("\"")
            token[1..-2]
          else
            token
          end
        end
        return nil if cols.any?(&.empty?) || cols.any? { |col| col.includes?("(") || col.includes?(")") }
        cols
      end

      private def self.pg_foreign_keys(db : DB::Database | DB::Connection, table : String) : Array(ForeignKeyInfo)
        out = [] of ForeignKeyInfo
        Record.query_compat(db, <<-SQL, [table] of Value) do |rs|
          SELECT tc.constraint_name, kcu.column_name, ccu.table_name,
                 ccu.column_name, rc.delete_rule, rc.is_deferrable,
                 rc.initially_deferred
          FROM information_schema.table_constraints tc
          JOIN information_schema.key_column_usage kcu
            ON kcu.constraint_schema = tc.constraint_schema
           AND kcu.constraint_name = tc.constraint_name
           AND kcu.table_name = tc.table_name
          JOIN information_schema.constraint_column_usage ccu
            ON ccu.constraint_schema = tc.constraint_schema
           AND ccu.constraint_name = tc.constraint_name
          LEFT JOIN information_schema.referential_constraints rc
            ON rc.constraint_schema = tc.constraint_schema
           AND rc.constraint_name = tc.constraint_name
          WHERE tc.constraint_type = 'FOREIGN KEY'
            AND tc.table_schema = 'public'
            AND tc.table_name = ?
          ORDER BY tc.constraint_name, kcu.ordinal_position
          SQL
          rs.each do
            name = str(rs.read) || next
            col = str(rs.read) || next
            to_table = str(rs.read) || next
            to_col = str(rs.read) || "id"
            on_delete = str(rs.read)
            deferrable = (str(rs.read) || "NO").upcase == "YES" ? ((str(rs.read) || "NO").upcase == "DEFERRED" ? :deferred : :immediate) : nil
            out << ForeignKeyInfo.new(name, col, to_table, to_col, on_delete, deferrable)
          end
        end
        out
      end

      private def self.pg_checks(db : DB::Database | DB::Connection, table : String) : Array(CheckConstraintInfo)
        out = [] of CheckConstraintInfo
        Record.query_compat(db, <<-SQL, [table] of Value) do |rs|
          SELECT tc.constraint_name, cc.check_clause
          FROM information_schema.table_constraints tc
          JOIN information_schema.check_constraints cc
            ON cc.constraint_schema = tc.constraint_schema
           AND cc.constraint_name = tc.constraint_name
          WHERE tc.table_schema = 'public'
            AND tc.table_name = ?
            AND tc.constraint_type = 'CHECK'
          ORDER BY tc.constraint_name
          SQL
          rs.each do
            name = str(rs.read)
            expr = str(rs.read) || next
            # PostgreSQL 12+ exposes NOT NULL constraints as CHECKs.
            next if name && name.ends_with?("_not_null")
            out << CheckConstraintInfo.new(name, expr)
          end
        end
        out
      end

      # -- MySQL ---------------------------------------------------------

      private def self.mysql_columns(db : DB::Database | DB::Connection, table : String) : Array(ColumnInfo)
        pk_cols = Set(String).new
        Record.query_compat(db, "SELECT column_name FROM information_schema.statistics WHERE table_schema = DATABASE() AND table_name = ? AND index_name = 'PRIMARY' ORDER BY seq_in_index", [table] of Value) do |rs|
          rs.each { pk_cols << (str(rs.read) || next) }
        end
        out = [] of ColumnInfo
        Record.query_compat(db, "SELECT column_name, column_type, data_type, is_nullable, column_default, extra, generation_expression FROM information_schema.columns WHERE table_schema = DATABASE() AND table_name = ? ORDER BY ordinal_position", [table] of Value) do |rs|
          rs.each do
            name = str(rs.read) || next
            column_type = (str(rs.read) || "").downcase
            data_type = (str(rs.read) || "").downcase
            nullable = (str(rs.read) || "YES").upcase == "YES"
            dflt_raw = str(rs.read)
            extra = (str(rs.read) || "").downcase
            generation = str(rs.read)
            primary = pk_cols.includes?(name)
            logical = TypeMapping.mysql_logical(column_type, data_type, extra, primary)
            generated = extra.includes?("generated") || !generation.nil?
            size = logical == :bit ? mysql_type_size(column_type) : nil
            out << ColumnInfo.new(name, logical, nullable && !primary, mysql_default(dflt_raw, logical, extra), primary, generated, generation, nil, size, nil, extra.includes?("stored"))
          end
        end
        out
      end

      private def self.mysql_type_size(column_type : String) : Int32?
        if m = column_type.match(/\Abit\((\d+)\)\z/)
          m[1].to_i32?
        end
      end

      private def self.mysql_default(raw : String?, logical : Symbol, extra : String) : Value
        return nil if raw.nil?
        s = raw.strip
        return nil if s.empty? || s.upcase == "NULL" || extra.includes?("auto_increment")
        up = s.upcase
        return nil if up.starts_with?("CURRENT_TIMESTAMP") || {"CURRENT_DATE", "CURRENT_TIME", "NOW()", "CURDATE()"}.includes?(up)
        unquoted = if s.size >= 2 && s.starts_with?("'") && s.ends_with?("'")
                     s[1..-2].gsub("''", "'").gsub("\\\\", "\\")
                   else
                     s
                   end
        case logical
        when :boolean
          return false if {"0", "b'0'", "false"}.includes?(unquoted.downcase)
          return true if {"1", "b'1'", "true"}.includes?(unquoted.downcase)
        when :integer, :bigint
          return unquoted.to_i64 if unquoted.to_i64?
        when :float, :decimal
          return unquoted.to_f64 if unquoted.to_f64?
        end
        unquoted
      end

      private def self.mysql_indexes(db : DB::Database | DB::Connection, table : String) : Array(IndexInfo)
        grouped = {} of String => NamedTuple(unique: Bool, cols: Array(Tuple(Int64, String)))
        Record.query_compat(db, "SELECT index_name, non_unique, seq_in_index, column_name FROM information_schema.statistics WHERE table_schema = DATABASE() AND table_name = ? AND index_name != 'PRIMARY' ORDER BY index_name, seq_in_index", [table] of Value) do |rs|
          rs.each do
            name = str(rs.read) || next
            non_unique = i64(rs.read) != 0
            seq = i64(rs.read)
            col = str(rs.read) || next
            entry = grouped[name]? || {unique: !non_unique, cols: [] of Tuple(Int64, String)}
            entry[:cols] << {seq, col}
            grouped[name] = {unique: entry[:unique], cols: entry[:cols]}
          end
        end
        grouped.map { |name, entry| IndexInfo.new(name, entry[:cols].sort_by(&.[0]).map(&.[1]), entry[:unique]) }.sort_by!(&.name)
      end

      private def self.mysql_foreign_keys(db : DB::Database | DB::Connection, table : String) : Array(ForeignKeyInfo)
        out = [] of ForeignKeyInfo
        Record.query_compat(db, <<-SQL, [table] of Value) do |rs|
          SELECT kcu.constraint_name, kcu.column_name,
                 kcu.referenced_table_name, kcu.referenced_column_name,
                 rc.delete_rule
          FROM information_schema.key_column_usage kcu
          LEFT JOIN information_schema.referential_constraints rc
            ON rc.constraint_schema = kcu.constraint_schema
           AND rc.constraint_name = kcu.constraint_name
          WHERE kcu.table_schema = DATABASE()
            AND kcu.table_name = ?
            AND kcu.referenced_table_name IS NOT NULL
          ORDER BY kcu.constraint_name, kcu.ordinal_position
          SQL
          rs.each do
            name = str(rs.read) || next
            col = str(rs.read) || next
            to_table = str(rs.read) || next
            to_col = str(rs.read) || "id"
            out << ForeignKeyInfo.new(name, col, to_table, to_col, str(rs.read))
          end
        end
        out
      end

      private def self.mysql_checks(db : DB::Database | DB::Connection, table : String) : Array(CheckConstraintInfo)
        out = [] of CheckConstraintInfo
        Record.query_compat(db, <<-SQL, [table] of Value) do |rs|
          SELECT tc.constraint_name, cc.check_clause
          FROM information_schema.table_constraints tc
          JOIN information_schema.check_constraints cc
            ON cc.constraint_schema = tc.constraint_schema
           AND cc.constraint_name = tc.constraint_name
          WHERE tc.table_schema = DATABASE()
            AND tc.table_name = ?
            AND tc.constraint_type = 'CHECK'
          ORDER BY tc.constraint_name
          SQL
          rs.each do
            name = str(rs.read)
            expr = str(rs.read) || next
            out << CheckConstraintInfo.new(name, expr)
          end
        end
        out
      end

      # -- views ---------------------------------------------------------

      private def self.view_body(db : DB::Database | DB::Connection, name : String) : String
        case Record.adapter_of(db)
        when :postgres
          body = ""
          Record.query_compat(db, "SELECT view_definition FROM information_schema.views WHERE table_schema = 'public' AND table_name = ?", [name] of Value) do |rs|
            rs.each { body = str(rs.read) || "" }
          end
          body
        when :mysql
          body = ""
          Record.query_compat(db, "SELECT view_definition FROM information_schema.views WHERE table_schema = DATABASE() AND table_name = ?", [name] of Value) do |rs|
            rs.each { body = str(rs.read) || "" }
          end
          body
        else
          sql = ""
          Record.query_compat(db, "SELECT sql FROM sqlite_master WHERE type = 'view' AND name = ?", [name] of Value) do |rs|
            rs.each { sql = str(rs.read) || "" }
          end
          strip_view_create(sql)
        end
      end

      private def self.strip_view_create(sql : String) : String
        if m = sql.match(/\ACREATE\s+(?:TEMP(?:ORARY)?\s+)?VIEW\s+(?:IF\s+NOT\s+EXISTS\s+)?(?:"[^"]+"|`[^`]+`|\[[^\]]+\]|\S+)(?:\s*\([^)]*\))?\s+AS\s+(.*)\z/mi)
          m[1]
        else
          sql
        end
      end
    end

    # -- module-level convenience API -----------------------------------
    # The database argument is optional and defaults to the primary
    # connection, so migrations and console sessions can ask
    # `Saci::Record.table_exists?(:users)`.

    def self.table_exists?(table : String | Symbol, db : DB::Database | DB::Connection = connection) : Bool
      Introspection.table_exists?(db, table)
    end

    def self.view_exists?(view : String | Symbol, db : DB::Database | DB::Connection = connection) : Bool
      Introspection.view_exists?(db, view)
    end

    def self.data_source_exists?(name : String | Symbol, db : DB::Database | DB::Connection = connection) : Bool
      Introspection.data_source_exists?(db, name)
    end

    def self.column_exists?(table : String | Symbol, column : String | Symbol, db : DB::Database | DB::Connection = connection) : Bool
      Introspection.column_exists?(db, table, column)
    end

    def self.index_exists?(table : String | Symbol, columns : String | Symbol | Array(String | Symbol) | Nil = nil, db : DB::Database | DB::Connection = connection, name : String? = nil) : Bool
      Introspection.index_exists?(db, table, columns, name)
    end

    def self.foreign_key_exists?(from_table : String | Symbol, to_table : String | Symbol | Nil = nil, column : String | Symbol | Nil = nil, db : DB::Database | DB::Connection = connection, name : String? = nil) : Bool
      Introspection.foreign_key_exists?(db, from_table, to_table, column, name)
    end

    def self.columns(table : String | Symbol, db : DB::Database | DB::Connection = connection) : Array(Introspection::ColumnInfo)
      Introspection.columns(db, table)
    end

    def self.indexes(table : String | Symbol, db : DB::Database | DB::Connection = connection) : Array(Introspection::IndexInfo)
      Introspection.indexes(db, table)
    end

    def self.foreign_keys(table : String | Symbol, db : DB::Database | DB::Connection = connection) : Array(Introspection::ForeignKeyInfo)
      Introspection.foreign_keys(db, table)
    end

    def self.check_constraints(table : String | Symbol, db : DB::Database | DB::Connection = connection) : Array(Introspection::CheckConstraintInfo)
      Introspection.check_constraints(db, table)
    end

    def self.views(db : DB::Database | DB::Connection = connection) : Array(Introspection::ViewInfo)
      Introspection.views(db)
    end

    # -- db-first overloads (same shape as `Schema.introspect(db)` and
    # `Introspection.*`) so callers can use either argument order.
    def self.table_exists?(db : DB::Database | DB::Connection, table : String | Symbol) : Bool
      Introspection.table_exists?(db, table)
    end

    def self.view_exists?(db : DB::Database | DB::Connection, view : String | Symbol) : Bool
      Introspection.view_exists?(db, view)
    end

    def self.data_source_exists?(db : DB::Database | DB::Connection, name : String | Symbol) : Bool
      Introspection.data_source_exists?(db, name)
    end

    def self.column_exists?(db : DB::Database | DB::Connection, table : String | Symbol, column : String | Symbol) : Bool
      Introspection.column_exists?(db, table, column)
    end

    def self.index_exists?(db : DB::Database | DB::Connection, table : String | Symbol, columns : String | Symbol | Array(String | Symbol) | Nil = nil, name : String? = nil) : Bool
      Introspection.index_exists?(db, table, columns, name)
    end

    # Keyword form: `Record.index_exists?(:users, column: :email)`.
    def self.index_exists?(table : String | Symbol, *, column : String | Symbol | Array(String | Symbol) | Nil = nil, name : String? = nil, db : DB::Database | DB::Connection = connection) : Bool
      Introspection.index_exists?(db, table, column, name)
    end

    def self.foreign_key_exists?(db : DB::Database | DB::Connection, from_table : String | Symbol, to_table : String | Symbol | Nil = nil, column : String | Symbol | Nil = nil, name : String? = nil) : Bool
      Introspection.foreign_key_exists?(db, from_table, to_table, column, name)
    end

    def self.columns(db : DB::Database | DB::Connection, table : String | Symbol) : Array(Introspection::ColumnInfo)
      Introspection.columns(db, table)
    end

    def self.indexes(db : DB::Database | DB::Connection, table : String | Symbol) : Array(Introspection::IndexInfo)
      Introspection.indexes(db, table)
    end

    def self.foreign_keys(db : DB::Database | DB::Connection, table : String | Symbol) : Array(Introspection::ForeignKeyInfo)
      Introspection.foreign_keys(db, table)
    end

    def self.check_constraints(db : DB::Database | DB::Connection, table : String | Symbol) : Array(Introspection::CheckConstraintInfo)
      Introspection.check_constraints(db, table)
    end
  end
end
