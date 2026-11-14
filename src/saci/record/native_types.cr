module Saci
  module Record
    # Extended column types used by migrations beyond the original
    # `:string`/`:text`/numeric/`:json`/`:datetime` set.
    #
    # Portable philosophy: PostgreSQL gets the richest available native
    # type, while SQLite and MySQL fall back to a storage type that keeps
    # the value round-tripping through the matching Crystal type:
    #
    # | logical        | PostgreSQL       | SQLite       | MySQL          |
    # |----------------|------------------|--------------|----------------|
    # | `:uuid`        | `UUID`           | `TEXT`       | `CHAR(36)`     |
    # | `:binary`      | `BYTEA`          | `BLOB`       | `BLOB`         |
    # | `:hstore`      | `HSTORE`         | `TEXT`       | `TEXT`         |
    # | `:inet`        | `INET`           | `TEXT`       | `TEXT`         |
    # | `:cidr`        | `CIDR`           | `TEXT`       | `TEXT`         |
    # | `:macaddr`     | `MACADDR`        | `TEXT`       | `TEXT`         |
    # | `:interval`    | `INTERVAL`       | `TEXT`       | `TEXT`         |
    # | `:money`       | `MONEY`          | `TEXT`       | `DECIMAL(19,4)`|
    # | `:bit`         | `BIT(1)`         | `INTEGER`    | `BIT(1)`       |
    # | `:bit_varying` | `BIT VARYING(n)` | `TEXT`       | `TEXT`         |
    # | `:point`       | `POINT`          | `TEXT`       | `TEXT`         |
    # | `:range`       | `INT4RANGE` etc. | `TEXT`       | `TEXT`         |
    # | `:xml`         | `XML`            | `TEXT`       | `TEXT`         |
    # | `:oid`         | `OID`            | `INTEGER`    | `BIGINT UNSIGNED` |
    #
    # `:range` takes `subtype:` (`:int4`, `:int8`, `:num`, `:ts`, `:tstz`,
    # `:date`); the PG range type follows. On SQLite/MySQL the range is
    # stored as text (write the range literal, e.g. `"[1,10)"`). `:bit`
    # and `:bit_varying` accept `size:`.
    #
    # UUID primary keys created with `create_table :x, id: :uuid` get
    # `DEFAULT gen_random_uuid()` on PostgreSQL (built in since PG 13;
    # older servers need the `pgcrypto` extension — `enable_extension`
    # below). SQLite and MySQL do not generate UUIDs at the database
    # level: assign a string UUID in the application (the column stores
    # it as TEXT / CHAR(36)).
    #
    # IMPORTANT: the historical `Record.db_type` mapping (including
    # `:decimal`/`:numeric`) is intentionally untouched. Extended types
    # are rendered through `NativeTypes.db_type` from
    # `ColumnDef#to_sql`; use `Record.native_db_type` in new code.
    module NativeTypes
      # Logical types handled by this module (not by `Record.db_type`).
      EXTENDED = {
        :uuid, :binary, :bytea, :hstore, :inet, :cidr, :macaddr, :interval,
        :money, :bit, :bit_varying, :point, :range, :xml, :oid,
      }

      # True when `logical` is rendered by this module.
      def self.extended?(logical : Symbol) : Bool
        EXTENDED.includes?(logical)
      end

      # SQL type name per adapter. `subtype` is only used by `:range`;
      # `size` by `:bit`/`:bit_varying`.
      def self.db_type(logical : Symbol, adapter : Adapter, subtype : Symbol? = nil, size : Int32? = nil) : String
        case logical
        when :uuid
          adapter == :postgres ? "UUID" : (adapter == :mysql ? "CHAR(36)" : "TEXT")
        when :binary, :bytea
          case adapter
          when :postgres then "BYTEA"
          when :mysql    then "BLOB"
          else                "BLOB"
          end
        when :hstore, :inet, :cidr, :macaddr, :interval, :xml
          adapter == :postgres ? logical.to_s.upcase : "TEXT"
        when :money
          case adapter
          when :postgres then "MONEY"
          when :mysql    then "DECIMAL(19,4)"
          else                "TEXT"
          end
        when :bit
          case adapter
          when :postgres, :mysql then "BIT(#{size || 1})"
          else                        "INTEGER"
          end
        when :bit_varying
          if adapter == :postgres
            size ? "BIT VARYING(#{size})" : "BIT VARYING"
          else
            "TEXT"
          end
        when :point
          adapter == :postgres ? "POINT" : "TEXT"
        when :range
          adapter == :postgres ? range_type(subtype) : "TEXT"
        when :oid
          case adapter
          when :postgres then "OID"
          when :mysql    then "BIGINT UNSIGNED"
          else                "INTEGER"
          end
        else
          raise ArgumentError.new("Unknown extended column type #{logical}")
        end
      end

      # PostgreSQL range type for a logical subtype. Defaults to INT4RANGE
      # (the least surprising `t.range` default).
      def self.range_type(subtype : Symbol?) : String
        case subtype || :int4
        when :int4, :integer, :int    then "INT4RANGE"
        when :int8, :bigint           then "INT8RANGE"
        when :num, :numeric, :decimal then "NUMRANGE"
        when :ts, :timestamp          then "TSRANGE"
        when :tstz, :timestamptz      then "TSTZRANGE"
        when :date                    then "DATERANGE"
        else
          raise ArgumentError.new("Unknown range subtype #{subtype.inspect} (expected :int4, :int8, :num, :ts, :tstz or :date)")
        end
      end

      # Inverse of `range_type` — used by schema introspection.
      def self.range_subtype(pg_type : String) : Symbol?
        case pg_type.downcase
        when "int4range" then :int4
        when "int8range" then :int8
        when "numrange"  then :num
        when "tsrange"   then :ts
        when "tstzrange" then :tstz
        when "daterange" then :date
        else                  nil
        end
      end
    end

    # Reverse type mappings shared by schema dumping and introspection.
    # Kept in one place so an introspected table can always be reloaded
    # with the same logical type it was dumped from.
    module TypeMapping
      # SQLite `PRAGMA table_info` decltype -> logical type. SQLite shares
      # storage across logical types, so this is deliberately lossy (the
      # existing documented normalization).
      def self.sqlite_logical(decltype : String, primary : Bool) : Symbol
        base = decltype.strip.upcase.split("(")[0].strip
        int_like = {"INTEGER", "INT", "BIGINT", "SMALLINT", "MEDIUMINT", "TINYINT"}.includes?(base)
        text_like = {"TEXT", "VARCHAR", "CHARACTER VARYING", "CHAR", "CLOB"}.includes?(base)
        if primary
          return :serial if int_like
          return :uuid if text_like
          return :binary if base == "BLOB"
        end
        case base
        when "VARCHAR", "CHARACTER VARYING", "CHAR", "CHARACTER", "NCHAR", "NVARCHAR", "CLOB"  then :string
        when "TEXT", "DATE", "DATETIME", "TIMESTAMP"                                           then :text
        when "INTEGER", "INT", "BIGINT", "SMALLINT", "MEDIUMINT", "TINYINT", "BOOLEAN", "BOOL" then :integer
        when "TEXT_DECIMAL"                                                                    then :decimal
        when "REAL", "FLOAT", "DOUBLE", "DOUBLE PRECISION", "DECIMAL", "NUMERIC"               then :float
        when "BLOB"                                                                            then :binary
        else                                                                                        :text
        end
      end

      # PostgreSQL `information_schema.columns` -> `{logical, subtype}`.
      # `column_default` is used to recognise serial columns; `subtype`
      # is set for range types so `t.range subtype:` survives a dump.
      def self.pg_logical(data_type : String, udt_name : String, column_default : String?, primary : Bool) : Tuple(Symbol, Symbol?)
        if primary && !!(column_default.try(&.starts_with?("nextval")))
          return {:serial, nil}
        end
        case data_type
        when "bigint"                         then {:bigint, nil}
        when "integer"                        then {:integer, nil}
        when "character varying", "character" then {:string, nil}
        when "text"                           then {:text, nil}
        when "double precision", "real"       then {:float, nil}
        when "numeric"                        then {:decimal, nil}
        when "date"                           then {:date, nil}
        when "jsonb", "json"                  then {:json, nil}
        when "boolean"                        then {:boolean, nil}
        when "timestamp without time zone", "timestamp with time zone",
             "timestamp" then {:datetime, nil}
        when "uuid"                then {:uuid, nil}
        when "bytea"               then {:binary, nil}
        when "hstore"              then {:hstore, nil}
        when "inet"                then {:inet, nil}
        when "cidr"                then {:cidr, nil}
        when "macaddr", "macaddr8" then {:macaddr, nil}
        when "interval"            then {:interval, nil}
        when "money"               then {:money, nil}
        when "bit"                 then {:bit, nil}
        when "bit varying"         then {:bit_varying, nil}
        when "point"               then {:point, nil}
        when "xml"                 then {:xml, nil}
        when "oid"                 then {:oid, nil}
        when "int4range", "int8range", "numrange", "tsrange", "tstzrange", "daterange"
          {:range, NativeTypes.range_subtype(data_type)}
        when "ARRAY"
          if udt_name == "_text" || udt_name == "_varchar"
            {:string_array, nil}
          else
            {:text, nil}
          end
        else
          # USER-DEFINED types report their real name in `udt_name`
          # (hstore, citext, extensions, …). Ranges may land here too.
          if sub = NativeTypes.range_subtype(udt_name)
            {:range, sub}
          elsif udt_name == "jsonb"
            {:json, nil}
          elsif udt_name == "uuid"
            {:uuid, nil}
          elsif udt_name == "hstore"
            {:hstore, nil}
          elsif udt_name == "inet"
            {:inet, nil}
          elsif udt_name == "cidr"
            {:cidr, nil}
          elsif udt_name == "macaddr" || udt_name == "macaddr8"
            {:macaddr, nil}
          else
            {:text, nil}
          end
        end
      end

      # MySQL `information_schema.columns` -> logical type. Matches our
      # forward maps: JSON is TEXT (crystal-mysql cannot decode the native
      # wire type), CHAR(36) reloads as `:uuid`, BLOB family as `:binary`.
      def self.mysql_logical(column_type : String, data_type : String, extra : String, primary : Bool) : Symbol
        return :serial if primary && extra.includes?("auto_increment")
        case data_type
        when "bigint"                               then :bigint
        when "int", "mediumint", "smallint", "year" then :integer
        when "varchar", "char"
          data_type == "char" && column_type == "char(36)" ? :uuid : :string
        when "text", "mediumtext", "longtext", "tinytext", "json"                then :text
        when "double", "float"                                                   then :float
        when "decimal", "numeric", "newdecimal"                                  then :decimal
        when "date"                                                              then :date
        when "datetime", "timestamp"                                             then :datetime
        when "tinyint"                                                           then column_type.starts_with?("tinyint(1)") ? :boolean : :integer
        when "boolean", "bool"                                                   then :boolean
        when "binary", "varbinary", "blob", "tinyblob", "mediumblob", "longblob" then :binary
        when "bit"                                                               then :bit
        else                                                                          :text
        end
      end
    end

    # Renders any logical column type: extended types (`:uuid`, `:binary`,
    # `:hstore`, …) through `NativeTypes`, everything else through the
    # historical `Record.db_type` mapping (which stays untouched —
    # `:decimal`/`:numeric` included).
    #
    # ```
    # Saci::Record.native_db_type(:uuid, :postgres) # => "UUID"
    # Saci::Record.native_db_type(:binary, :sqlite) # => "BLOB"
    # ```
    def self.native_db_type(logical : Symbol, adapter : Adapter, subtype : Symbol? = nil, size : Int32? = nil) : String
      if NativeTypes.extended?(logical)
        NativeTypes.db_type(logical, adapter, subtype, size)
      else
        db_type(logical, adapter)
      end
    end

    def self.extended_db_type(logical : Symbol, adapter : Adapter, subtype : Symbol? = nil, size : Int32? = nil) : String
      native_db_type(logical, adapter, subtype, size)
    end
  end
end
