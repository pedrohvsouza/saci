require "json"
require "./record"

module Saci
  # Lightweight audit trail (G305).
  #
  # `include Saci::Auditable` + `audited only: [...]` records create/update/
  # destroy snapshots into the `saci_audits` table. The framework does not
  # assume a particular user/tenant model: pass whichever records you use
  # through the fiber-local context, or set the ids directly.
  #
  # ```
  # class Post < Saci::Record::Base
  #   include Saci::Auditable
  #   audited only: [:title, :status]
  # end
  #
  # Saci::Audit.with_context(user: current_user, tenant: current_tenant) do
  #   post = Post.create!(title: "Hello")
  #   post.update!(title: "Hello again")
  #   post.audits        # => [create, update]
  #   post.audit_changes # => changes from the last save
  #   post.latest_audit  # => Audit::Entry
  # end
  # ```
  #
  # Entries are deliberately a small read model (`Saci::Audit::Entry`) built
  # with direct SQL instead of a `Record::Base` subclass. A framework model
  # would self-register in `Saci::Record.models` and make schema-drift checks
  # warn on applications that never opted into auditing.
  #
  # Create the table from a migration:
  #
  # ```
  # class CreateSaciAudits < Saci::Record::Migration
  #   def change
  #     Saci::Audit.create_table(self)
  #   end
  # end
  # ```
  #
  # Or at boot with `Saci::Audit.ensure_schema!`. Equivalent SQL
  # (SQLite/PostgreSQL flavored; MySQL uses BIGINT/AUTO_INCREMENT):
  #
  # ```sql
  # CREATE TABLE saci_audits (
  #   id INTEGER PRIMARY KEY AUTOINCREMENT,
  #   auditable_type VARCHAR(255) NOT NULL,
  #   auditable_id BIGINT,
  #   action VARCHAR(255) NOT NULL,
  #   changes TEXT,
  #   user_id BIGINT,
  #   tenant_id BIGINT,
  #   metadata TEXT,
  #   created_at TEXT NOT NULL
  # );
  # CREATE INDEX index_saci_audits_on_auditable ON saci_audits (auditable_type, auditable_id);
  # CREATE INDEX index_saci_audits_on_user_id ON saci_audits (user_id);
  # ```
  module Audit
    TABLE            = "saci_audits"
    DEFAULT_EXCLUDED = ["id", "created_at", "updated_at"]

    # Fiber-local audit context. Each request/fiber gets its own slot.
    class Context
      property user : Saci::Record::Base?
      property user_id : Int64?
      property tenant : Saci::Record::Base?
      property tenant_id : Int64?
      property metadata : Hash(String, JSON::Any)

      def initialize(
        @user : Saci::Record::Base? = nil,
        @user_id : Int64? = nil,
        @tenant : Saci::Record::Base? = nil,
        @tenant_id : Int64? = nil,
        @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
      )
      end
    end

    @@contexts = {} of UInt64 => Context
    @@context_mutex = Mutex.new

    # One immutable audit row. `changes` is a field => {before, after} map,
    # matching the shape used by the `audited` Ruby gem.
    class Entry
      getter id : Int64
      getter auditable_type : String
      getter auditable_id : Int64?
      getter action : String
      getter changes : Hash(String, JSON::Any)
      getter user_id : Int64?
      getter tenant_id : Int64?
      getter metadata : Hash(String, JSON::Any)
      getter created_at : Time?

      def initialize(
        @id : Int64,
        @auditable_type : String,
        @auditable_id : Int64?,
        @action : String,
        @changes : Hash(String, JSON::Any),
        @user_id : Int64?,
        @tenant_id : Int64?,
        @metadata : Hash(String, JSON::Any),
        @created_at : Time?,
      )
      end

      def create? : Bool
        @action == "create"
      end

      def update? : Bool
        @action == "update"
      end

      def destroy? : Bool
        @action == "destroy"
      end

      def audit_changes : Hash(String, JSON::Any)
        @changes
      end

      def changed_field?(field : String | Symbol) : Bool
        @changes.has_key?(field.to_s)
      end

      def before_changes : Hash(String, JSON::Any)
        extract("before")
      end

      def after_changes : Hash(String, JSON::Any)
        extract("after")
      end

      def field_before(field : String | Symbol) : JSON::Any?
        @changes[field.to_s]?.try(&.as_h?).try(&.["before"]?)
      end

      def field_after(field : String | Symbol) : JSON::Any?
        @changes[field.to_s]?.try(&.as_h?).try(&.["after"]?)
      end

      # Re-applies the `before` side of this update to `record` and saves it.
      # Returns false for non-update entries (there is no meaningful
      # "restore" for a create, and a destroy needs a new record).
      def restore!(record : Saci::Record::Base) : Bool
        return false unless update?
        types = record.class.__saci_column_names.to_h
        before_changes.each do |field, value|
          next if field == record.class.__saci_primary_key
          type = types[field]?
          next unless type
          record.__saci_set_attr(field, Audit.decode_value(type, value))
        end
        record.save
      end

      def as_json : Hash(String, JSON::Any)
        {
          "id"             => JSON::Any.new(@id),
          "auditable_type" => JSON::Any.new(@auditable_type),
          "auditable_id"   => JSON::Any.new(@auditable_id),
          "action"         => JSON::Any.new(@action),
          "changes"        => JSON::Any.new(@changes),
          "user_id"        => JSON::Any.new(@user_id),
          "tenant_id"      => JSON::Any.new(@tenant_id),
          "metadata"       => JSON::Any.new(@metadata),
          "created_at"     => JSON::Any.new(@created_at.try(&.to_rfc3339)),
        }
      end

      def to_json : String
        as_json.to_json
      end

      private def extract(side : String) : Hash(String, JSON::Any)
        result = {} of String => JSON::Any
        @changes.each do |field, pair|
          if hash = pair.as_h?
            result[field] = hash[side]? || JSON::Any.new(nil)
          end
        end
        result
      end
    end

    # -- context ---------------------------------------------------------

    def self.context : Context
      key = Fiber.current.object_id
      @@context_mutex.synchronize { @@contexts[key] ||= Context.new }
    end

    def self.current_user : Saci::Record::Base?
      context.user
    end

    def self.current_user=(user : Saci::Record::Base?) : Nil
      context.user = user
    end

    def self.current_user_id : Int64?
      ctx = context
      ctx.user_id || id_of(ctx.user)
    end

    def self.current_user_id=(id : Int64?) : Nil
      context.user_id = id
    end

    def self.current_tenant : Saci::Record::Base?
      context.tenant
    end

    def self.current_tenant=(tenant : Saci::Record::Base?) : Nil
      context.tenant = tenant
    end

    def self.current_tenant_id : Int64?
      ctx = context
      ctx.tenant_id || id_of(ctx.tenant)
    end

    def self.current_tenant_id=(id : Int64?) : Nil
      context.tenant_id = id
    end

    def self.metadata : Hash(String, JSON::Any)
      context.metadata
    end

    def self.metadata=(metadata : Hash(String, JSON::Any)) : Nil
      context.metadata = metadata
    end

    # Scoped context. Restores the previous user/tenant/metadata even when
    # the block raises. Omitted values inherit the current context; explicit
    # ids win over ids derived from the user/tenant records.
    def self.with_context(
      *,
      user : Saci::Record::Base? = current_user,
      tenant : Saci::Record::Base? = current_tenant,
      user_id : Int64? = nil,
      tenant_id : Int64? = nil,
      metadata : Hash(String, JSON::Any)? = nil,
      &block : -> T
    ) : T forall T
      ctx = context
      previous_user = ctx.user
      previous_user_id = ctx.user_id
      previous_tenant = ctx.tenant
      previous_tenant_id = ctx.tenant_id
      previous_metadata = ctx.metadata
      ctx.user = user
      ctx.user_id = user_id || id_of(user)
      ctx.tenant = tenant
      ctx.tenant_id = tenant_id || id_of(tenant)
      ctx.metadata = metadata if metadata
      begin
        yield
      ensure
        ctx.user = previous_user
        ctx.user_id = previous_user_id
        ctx.tenant = previous_tenant
        ctx.tenant_id = previous_tenant_id
        ctx.metadata = previous_metadata
      end
    end

    def self.clear_context! : Nil
      key = Fiber.current.object_id
      @@context_mutex.synchronize { @@contexts.delete(key) }
    end

    def self.id_of(record : Saci::Record::Base?) : Int64?
      return nil if record.nil?
      pk = record.class.__saci_primary_key
      Saci::Record.to_i64(record.__saci_get_attr(pk))
    end

    # -- schema ----------------------------------------------------------

    # Adds the audit table to a migration. Call from `change`:
    # `Saci::Audit.create_table(self)`.
    def self.create_table(migration : Saci::Record::Migration) : Nil
      migration.create_table(TABLE) do |t|
        t.string "auditable_type", null: false
        t.bigint "auditable_id"
        t.string "action", null: false
        t.json "changes"
        t.bigint "user_id"
        t.bigint "tenant_id"
        t.json "metadata"
        t.datetime "created_at", null: false
      end
      migration.add_index(TABLE, ["auditable_type", "auditable_id"], name: "index_saci_audits_on_auditable")
      migration.add_index(TABLE, "user_id", name: "index_saci_audits_on_user_id")
      migration.add_index(TABLE, "tenant_id", name: "index_saci_audits_on_tenant_id")
    end

    # Boot-time idempotent table creation (mirrors `Saci::Job::Db`). Use this
    # in small apps/tests; production apps should prefer the migration helper.
    def self.ensure_schema!(db : DB::Database | DB::Connection = Saci::Record.connection) : Nil
      ad = Saci::Record.adapter_of(db)
      q = ->(name : String) { Saci::Record.quote(name, ad) }
      id_def = case ad
               when :postgres then "#{q.call("id")} BIGSERIAL PRIMARY KEY"
               when :mysql    then "#{q.call("id")} BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY"
               else                "#{q.call("id")} INTEGER PRIMARY KEY AUTOINCREMENT"
               end
      text = Saci::Record.db_type(:text, ad)
      big = Saci::Record.db_type(:bigint, ad)
      created = Saci::Record.db_type(:datetime, ad)
      Saci::Record.exec_compat(db, <<-SQL)
        CREATE TABLE IF NOT EXISTS #{q.call(TABLE)} (
          #{id_def},
          #{q.call("auditable_type")} VARCHAR(255) NOT NULL,
          #{q.call("auditable_id")} #{big},
          #{q.call("action")} VARCHAR(255) NOT NULL,
          #{q.call("changes")} #{text},
          #{q.call("user_id")} #{big},
          #{q.call("tenant_id")} #{big},
          #{q.call("metadata")} #{text},
          #{q.call("created_at")} #{created} NOT NULL
        )
        SQL
    end

    # -- writes ----------------------------------------------------------

    # Inserts one audit row. Public so applications can add custom actions
    # (`"publish"`, `"approve"`, ...) from service objects.
    def self.record(
      record : Saci::Record::Base,
      action : String,
      changes : Hash(String, JSON::Any),
      metadata : Hash(String, JSON::Any)? = nil,
    ) : Int64?
      return nil if action == "update" && changes.empty?
      db = Saci::Record.connection
      ad = Saci::Record.adapter_of(db)
      ctx = context
      extra = ctx.metadata.dup
      metadata.try { |m| m.each { |k, v| extra[k] = v } }
      meta_json = extra.empty? ? nil : extra.to_json
      now = Time.utc
      cols = ["auditable_type", "auditable_id", "action", "changes", "user_id", "tenant_id", "metadata", "created_at"]
      names = cols.map { |name| Saci::Record.quote(name, ad) }.join(", ")
      placeholders = cols.map { "?" }.join(", ")
      values = [
        record.class.name,
        id_of(record),
        action,
        changes.to_json,
        current_user_id,
        current_tenant_id,
        meta_json,
        Saci::Record.to_db(now, ad),
      ] of Saci::Record::Value
      sql = "INSERT INTO #{Saci::Record.quote(TABLE, ad)} (#{names}) VALUES (#{placeholders})"
      if ad == :postgres
        new_id = nil
        Saci::Record.query_compat(db, "#{sql} RETURNING #{Saci::Record.quote("id", ad)}", values) do |rs|
          rs.each { new_id = rs.read(Int64) }
        end
        new_id
      else
        Saci::Record.exec_compat(db, sql, values).last_insert_id
      end
    end

    # -- reads -----------------------------------------------------------

    def self.for(record : Saci::Record::Base) : Array(Entry)
      type = record.class.name
      id = id_of(record)
      return [] of Entry if id.nil?
      query_entries(type, id, ascending: true)
    end

    def self.for_record(type : String, id : Int64) : Array(Entry)
      query_entries(type, id, ascending: true)
    end

    def self.latest_for(record : Saci::Record::Base) : Entry?
      id = id_of(record)
      return nil if id.nil?
      query_entries(record.class.name, id, ascending: false, limit: 1).first?
    end

    def self.count_for(record : Saci::Record::Base) : Int64
      type = record.class.name
      id = id_of(record)
      return 0_i64 if id.nil?
      ad = Saci::Record.adapter_of(Saci::Record.connection)
      Saci::Record.scalar_compat(
        Saci::Record.connection,
        "SELECT COUNT(*) FROM #{Saci::Record.quote(TABLE, ad)} " \
        "WHERE #{Saci::Record.quote("auditable_type", ad)} = ? AND #{Saci::Record.quote("auditable_id", ad)} = ?",
        [type, id] of Saci::Record::Value
      ).as(Int64)
    end

    private def self.query_entries(type : String, id : Int64, ascending : Bool, limit : Int32? = nil) : Array(Entry)
      ad = Saci::Record.adapter_of(Saci::Record.connection)
      q = ->(name : String) { Saci::Record.quote(name, ad) }
      sql = "SELECT #{q.call("id")}, #{q.call("auditable_type")}, #{q.call("auditable_id")}, " \
            "#{q.call("action")}, #{q.call("changes")}, #{q.call("user_id")}, #{q.call("tenant_id")}, " \
            "#{q.call("metadata")}, #{q.call("created_at")} " \
            "FROM #{q.call(TABLE)} WHERE #{q.call("auditable_type")} = ? AND #{q.call("auditable_id")} = ? " \
            "ORDER BY #{q.call("id")} #{ascending ? "ASC" : "DESC"}"
      sql += " LIMIT #{limit.to_i}" if limit
      entries = [] of Entry
      Saci::Record.query_compat(
        Saci::Record.connection,
        sql,
        [type, id] of Saci::Record::Value
      ) do |rs|
        rs.each do
          entry_id = rs.read(Int64)
          auditable_type = rs.read(String)
          auditable_id = rs.read(Int64?)
          action = rs.read(String)
          raw_changes = rs.read(String?)
          user_id = rs.read(Int64?)
          tenant_id = rs.read(Int64?)
          raw_metadata = rs.read(String?)
          raw_created = rs.read
          created_at = case raw_created
                       when Time   then raw_created
                       when String then Saci::Record.parse_time(raw_created)
                       else             nil
                       end
          entries << Entry.new(
            entry_id,
            auditable_type,
            auditable_id,
            action,
            parse_json_hash(raw_changes),
            user_id,
            tenant_id,
            parse_json_hash(raw_metadata),
            created_at,
          )
        end
      end
      entries
    end

    def self.parse_json_hash(raw : String?) : Hash(String, JSON::Any)
      return {} of String => JSON::Any if raw.nil? || raw.strip.empty?
      parsed = JSON.parse(raw)
      parsed.as_h? || {} of String => JSON::Any
    rescue JSON::ParseException
      {} of String => JSON::Any
    end

    # JSON value -> `Record::Value` using the model column's logical type.
    def self.decode_value(type : String, any : JSON::Any) : Saci::Record::Value
      raw = any.raw
      value = case raw
              when Nil     then nil
              when String  then raw
              when Int64   then raw
              when Int32   then raw
              when Float64 then raw
              when Bool    then raw
              when Array   then raw.map(&.to_s)
              else              raw.to_s
              end
      case type
      when "Int64"   then Saci::Record.to_i64(value)
      when "Int32"   then Saci::Record.to_i32(value)
      when "Float64" then Saci::Record.to_f64(value)
      when "Bool"    then Saci::Record.to_bool(value)
      when "Time"
        case value
        when Time   then value
        when String then Saci::Record.parse_time(value)
        else             nil
        end
      when "Array(String)" then Saci::Record.to_string_array(value)
      when "Bytes"
        value.is_a?(Bytes) ? value : nil
      else
        value.nil? ? nil : value.to_s
      end
    end

    # Convert a column value into JSON for the `changes` payload.
    def self.dump_value(value : Saci::Record::Value?) : JSON::Any
      case v = value
      when Nil
        JSON::Any.new(nil)
      when Time
        JSON::Any.new(v.to_rfc3339)
      when Bool
        JSON::Any.new(v)
      when Int32
        JSON::Any.new(v.to_i64)
      when Int64
        JSON::Any.new(v)
      when Float32
        JSON::Any.new(v.to_f64)
      when Float64
        JSON::Any.new(v)
      when String
        JSON::Any.new(v)
      when Array(String)
        JSON::Any.new(v.map { |item| JSON::Any.new(item) }.to_a)
      when Bytes
        JSON::Any.new(v.map { |byte| JSON::Any.new(byte.to_i64) }.to_a)
      else
        JSON::Any.new(v.to_s)
      end
    end
  end
end

# Small DSL mixed into models. `audited` expands the callback chain and the
# read helpers on the model; models that never call it are untouched.
module Saci::Auditable
  macro audited(only = nil, except = nil)
    {% only_names = [] of String %}
    {% if only %}
      {% if only.is_a?(ArrayLiteral) %}
        {% for name in only %}
          {% only_names << name.id.stringify %}
        {% end %}
      {% else %}
        {% only_names << only.id.stringify %}
      {% end %}
    {% end %}
    {% except_names = [] of String %}
    {% if except %}
      {% if except.is_a?(ArrayLiteral) %}
        {% for name in except %}
          {% except_names << name.id.stringify %}
        {% end %}
      {% else %}
        {% except_names << except.id.stringify %}
      {% end %}
    {% end %}

    @__saci_audit_before : Hash(String, Saci::Record::Value)? = nil
    @__saci_audit_last_changes : Hash(String, ::JSON::Any) = {} of String => ::JSON::Any

    def __saci_audit_only : Array(String)
      [{% for name in only_names %}{{name}},{% end %}] of String
    end

    def __saci_audit_except : Array(String)
      [{% for name in except_names %}{{name}},{% end %}] of String
    end

    def __saci_audit_columns : Array(String)
      only = __saci_audit_only
      except = __saci_audit_except
      columns = self.class.__saci_column_names.map(&.[0])
      if only.empty?
        columns.reject { |name| ::Saci::Audit::DEFAULT_EXCLUDED.includes?(name) || except.includes?(name) }
      else
        columns.select { |name| only.includes?(name) && !except.includes?(name) }
      end
    end

    def __saci_audit_snapshot : Hash(String, Saci::Record::Value)
      snapshot = {} of String => Saci::Record::Value
      __saci_audit_columns.each { |name| snapshot[name] = __saci_get_attr(name) }
      snapshot
    end

    # Reads the persisted row's audited columns. `before_save` runs after
    # `assign` has already mutated the in-memory record (Saci has no dirty
    # tracking), so the only reliable "before" image for an update is the
    # database row. One extra SELECT per audited save.
    def __saci_audit_db_snapshot : Hash(String, Saci::Record::Value)
      snapshot = {} of String => Saci::Record::Value
      columns = __saci_audit_columns
      return snapshot if columns.empty?
      pk = self.class.__saci_primary_key
      id = __saci_get_attr(pk)
      return snapshot if id.nil?
      types = self.class.__saci_column_names.to_h
      connection = self.class.connection
      adapter = Saci::Record.adapter_of(connection)
      names = columns.map { |name| Saci::Record.quote(name, adapter) }.join(", ")
      sql = "SELECT #{names} FROM #{Saci::Record.quote(self.class.table_name, adapter)} " \
            "WHERE #{Saci::Record.quote(pk, adapter)} = ?"
      Saci::Record.query_compat(connection, sql, [id] of Saci::Record::Value) do |rs|
        # `while` + index instead of `columns.each` inside `rs.each`: the
        # nested-block form trips a Crystal 1.22 codegen bug
        # (DB::ResultSet virtual downcast).
        if rs.move_next
          index = 0
          while index < columns.size
            name = columns[index]
            snapshot[name] = Saci::Record.read_typed(rs, types[name], adapter)
            index += 1
          end
        end
      end
      snapshot
    end

    def __saci_audit_changes(before : Hash(String, Saci::Record::Value)?) : Hash(String, ::JSON::Any)
      current = __saci_audit_snapshot
      changes = {} of String => ::JSON::Any
      __saci_audit_columns.each do |name|
        now = current[name]?
        old = before.try { |hash| hash[name]? }
        next if before && old == now
        changes[name] = ::JSON::Any.new({
          "before" => ::Saci::Audit.dump_value(old),
          "after"  => ::Saci::Audit.dump_value(now),
        })
      end
      changes
    end

    def __saci_audit_changes_on_destroy : Hash(String, ::JSON::Any)
      current = __saci_audit_snapshot
      changes = {} of String => ::JSON::Any
      __saci_audit_columns.each do |name|
        changes[name] = ::JSON::Any.new({
          "before" => ::Saci::Audit.dump_value(current[name]?),
          "after"  => ::JSON::Any.new(nil),
        })
      end
      changes
    end

    def __saci_audit_before_save : Nil
      @__saci_audit_before = new_record? ? nil : __saci_audit_db_snapshot
    end

    def __saci_audit_after_save : Nil
      before = @__saci_audit_before
      @__saci_audit_before = nil
      if before
        changes = __saci_audit_changes(before)
        return if changes.empty?
        ::Saci::Audit.record(self, "update", changes)
        @__saci_audit_last_changes = changes
      else
        changes = __saci_audit_changes(nil)
        ::Saci::Audit.record(self, "create", changes)
        @__saci_audit_last_changes = changes
      end
    end

    def __saci_audit_after_destroy : Nil
      changes = __saci_audit_changes_on_destroy
      ::Saci::Audit.record(self, "destroy", changes)
      @__saci_audit_last_changes = changes
    end

    def __saci_before_save : Nil
      previous_def
      __saci_audit_before_save
    end

    def __saci_after_save : Nil
      previous_def
      __saci_audit_after_save
    end

    def __saci_after_destroy : Nil
      previous_def
      __saci_audit_after_destroy
    end

    def audits : Array(::Saci::Audit::Entry)
      ::Saci::Audit.for(self)
    end

    def latest_audit : ::Saci::Audit::Entry?
      ::Saci::Audit.latest_for(self)
    end

    def audit_changes : Hash(String, ::JSON::Any)
      @__saci_audit_last_changes
    end

    def restore_from!(entry : ::Saci::Audit::Entry) : Bool
      entry.restore!(self)
    end
  end
end

class Saci::Record::Base
  include Saci::Auditable
end
