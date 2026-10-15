require "spec"
require "file_utils"
require "../src/saci"
require "../src/saci/cli/util"
require "../src/saci/cli/new_command"
require "../src/saci/cli/generate_command"
require "../src/saci/cli/serve_command"
require "../src/saci/cli/test_command"
require "../src/saci/cli/secret_command"
require "../src/saci/cli/credentials_command"
require "../src/saci/cli/schema_command"
require "../src/saci/cli/schema_check_command"
require "../src/saci/cli"

{% if env("PG_URL") %}
require "pg"
{% end %}
{% if env("MYSQL_URL") %}
require "mysql"
{% end %}

# SQLite round-trip migrations (raw DB handles, never registered — the
# suite's global connection state is untouched).
class SchemaCreateWidgets < Saci::Record::Migration
  def change
    create_table :schema_widgets do |t|
      t.string :title, null: false
      t.text :body
      t.string :nick, default: "bob"
      t.integer :views, default: 0
      t.float :score, default: 1.5
      t.boolean :active, default: true
      t.datetime :published_at
      t.timestamps
    end
    add_index :schema_widgets, :title, unique: true
    add_index :schema_widgets, [:active, :views]
  end
end

class SchemaCreateGadgets < Saci::Record::Migration
  def change
    create_table :schema_gadgets, id: false do |t|
      t.string :sku, null: false
      t.integer :qty
      t.datetime :created_at
    end
  end
end

SCHEMA_SQLITE_PATH = "/tmp/opencode/saci_schema_test.db"

def schema_sqlite_db : DB::Database
  [SCHEMA_SQLITE_PATH, "#{SCHEMA_SQLITE_PATH}-wal", "#{SCHEMA_SQLITE_PATH}-shm"].each do |p|
    File.delete(p) if File.exists?(p)
  end
  DB.open("sqlite3://#{SCHEMA_SQLITE_PATH}")
end

def schema_drop_all(db : DB::Database) : Nil
  names = [] of String
  db.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'") do |rs|
    rs.each { names << rs.read(String) }
  end
  names.each { |n| db.exec("DROP TABLE \"#{n}\"") }
end

def schema_col(tables : Array(Saci::Record::Schema::TableInfo), table : String, column : String) : Saci::Record::ColumnDef
  t = tables.find! { |x| x.name == table }
  t.columns.find! { |c| c.name == column }
end

describe "Saci::Record::Schema (SQLite)" do
  it "introspects tables, columns, indexes and detects timestamps" do
    db = schema_sqlite_db
    begin
      Saci::Record::Migrator.migrate(db, [SchemaCreateWidgets, SchemaCreateGadgets] of Saci::Record::Migration.class)
      tables = Saci::Record::Schema.introspect(db)
      tables.map(&.name).should eq(["schema_gadgets", "schema_widgets"])
      tables.none? { |t| t.name == "schema_migrations" }.should be_true

      widgets = tables.find! { |t| t.name == "schema_widgets" }
      widgets.timestamps.should be_true
      widgets.columns.map(&.name).should eq(["id", "title", "body", "nick", "views", "score", "active", "published_at"])

      schema_col(tables, "schema_widgets", "id").logical_type.should eq(:serial)
      schema_col(tables, "schema_widgets", "id").primary_key.should be_true
      schema_col(tables, "schema_widgets", "title").logical_type.should eq(:string)
      schema_col(tables, "schema_widgets", "title").null.should be_false
      schema_col(tables, "schema_widgets", "body").logical_type.should eq(:text)
      schema_col(tables, "schema_widgets", "body").null.should be_true
      schema_col(tables, "schema_widgets", "nick").default_value.should eq("bob")
      schema_col(tables, "schema_widgets", "views").default_value.should eq(0_i64)
      schema_col(tables, "schema_widgets", "score").default_value.should eq(1.5)
      # Documented SQLite collapse: BOOLEAN shares INTEGER storage, so a
      # boolean default round-trips as :integer.
      schema_col(tables, "schema_widgets", "active").logical_type.should eq(:integer)
      schema_col(tables, "schema_widgets", "active").default_value.should eq(1_i64)
      # Same collapse for DATETIME (shares TEXT storage).
      schema_col(tables, "schema_widgets", "published_at").logical_type.should eq(:text)

      widgets.indexes.map(&.name).should eq(["index_schema_widgets_on_active_and_views", "index_schema_widgets_on_title"])
      title_ix = widgets.indexes.find! { |ix| ix.name == "index_schema_widgets_on_title" }
      title_ix.unique.should be_true
      title_ix.columns.should eq(["title"])
      comp_ix = widgets.indexes.find! { |ix| ix.name == "index_schema_widgets_on_active_and_views" }
      comp_ix.unique.should be_false
      comp_ix.columns.should eq(["active", "views"])

      # Nullable created_at alone is not t.timestamps.
      gadgets = tables.find! { |t| t.name == "schema_gadgets" }
      gadgets.timestamps.should be_false
      gadgets.columns.map(&.name).should eq(["sku", "qty", "created_at"])
      gadgets.columns.none?(&.primary_key).should be_true
    ensure
      db.close
    end
  end

  it "includes durable queue tables but never schema_migrations" do
    db = schema_sqlite_db
    begin
      Saci::Record::Migrator.migrate(db, [SchemaCreateWidgets] of Saci::Record::Migration.class)
      Saci::Job::Db.ensure_schema!(db)
      names = Saci::Record::Schema.introspect(db).map(&.name)
      names.should contain("saci_jobs")
      names.should contain("saci_dead_jobs")
      names.should contain("schema_widgets")
      names.none? { |n| n == "schema_migrations" }.should be_true
    ensure
      db.close
    end
  end

  it "dumps a standalone runnable schema.cr (data + loader, no raw SQL)" do
    db = schema_sqlite_db
    begin
      Saci::Record::Migrator.migrate(db, [SchemaCreateWidgets, SchemaCreateGadgets] of Saci::Record::Migration.class)
      src = Saci::Record::Schema.dump(db, "sqlite3://./db/demo_development.db")
      src.should contain("require \"saci\"")
      src.should contain("ENV.fetch(\"DATABASE_URL\", \"sqlite3://./db/demo_development.db\")")
      src.should contain("SCHEMA_TABLES")
      src.should contain("Saci::Record::Schema.load(db, SCHEMA_TABLES)")
      src.should contain("TableInfo.new(\n    \"schema_widgets\",")
      src.should contain("ColumnDef.new(\"title\", :string, false, nil, false)")
      src.should contain("ColumnDef.new(\"views\", :integer, true, 0_i64, false)")
      src.should contain("ColumnDef.new(\"score\", :float, true, 1.5, false)")
      src.should contain("IndexInfo.new(\"index_schema_widgets_on_title\", [\"title\"] of String, true)")
      src.should contain("true, # t.timestamps")
      src.should_not contain("\"schema_migrations\"")
      src.should_not contain("CREATE TABLE")
    ensure
      db.close
    end
  end

  it "round-trips dump -> wipe -> load with a byte-stable dump" do
    db = schema_sqlite_db
    begin
      Saci::Record::Migrator.migrate(db, [SchemaCreateWidgets, SchemaCreateGadgets] of Saci::Record::Migration.class)
      tables = Saci::Record::Schema.introspect(db)
      first = Saci::Record::Schema.dump(db)
      Saci::Record::Schema.dump(db).should eq(first)

      schema_drop_all(db)
      Saci::Record::Schema.introspect(db).should be_empty
      Saci::Record::Schema.load(db, tables)

      Saci::Record::Schema.dump(db).should eq(first)
      names = Saci::Record::Schema.introspect(db).map(&.name)
      names.should eq(["schema_gadgets", "schema_widgets"])

      # Data-less: structure is back, rows are not, constraints enforced.
      db.scalar("SELECT COUNT(*) FROM \"schema_widgets\"").should eq(0)
      db.exec("INSERT INTO \"schema_widgets\" (\"title\", \"created_at\", \"updated_at\") VALUES (?, ?, ?)", "x", "2024-01-01", "2024-01-02")
      expect_raises(Exception, /nique/i) do
        db.exec("INSERT INTO \"schema_widgets\" (\"title\", \"created_at\", \"updated_at\") VALUES (?, ?, ?)", "x", "2024-01-01", "2024-01-02")
      end
    ensure
      begin
        db.close
      rescue SQLite3::Exception
        # crystal-sqlite3 quirk: sqlite3_finalize echoes a failed step's
        # sticky error, so closing after the (asserted) UNIQUE violation
        # above re-raises it from the pooled statement cache.
      end
    end
  end
end

describe "Saci::CLI::Schema" do
  it "parses --all and crystal flags like Db" do
    parsed = Saci::CLI::Schema.parse(["--all"])
    parsed[:all].should be_true
    parsed[:script_args].should eq(["--all"])
    parsed[:crystal_flags].should be_empty

    parsed = Saci::CLI::Schema.parse(["--", "--link-flags=-Lx"])
    parsed[:all].should be_false
    parsed[:crystal_flags].should eq(["--link-flags=-Lx"])
  end

  it "extracts the DATABASE_URL default from db/migrate.cr" do
    dir = File.join("/tmp/opencode", "saci-schema-cli-#{Random.rand(1_000_000)}")
    begin
      Dir.mkdir_p(File.join(dir, "db"))
      File.write(File.join(dir, "shard.yml"), "name: demo\n")
      File.write(File.join(dir, "db", "migrate.cr"), "db_url = ENV.fetch(\"DATABASE_URL\", \"sqlite3://./db/demo_\#{env_name}.db\")\n")
      Saci::CLI::Schema.migrate_url_default(dir).should eq("sqlite3://./db/demo_\#{env_name}.db")
      File.delete(File.join(dir, "db", "migrate.cr"))
      Saci::CLI::Schema.migrate_url_default(dir).should be_nil
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "renders a temp dump runner that connects like db/migrate.cr" do
    src = Saci::CLI::Schema.dump_runner_source("sqlite3://./db/demo_\#{env_name}.db")
    src.should contain("require \"saci\"")
    src.should contain("ENV.fetch(\"DATABASE_URL\", \"sqlite3://./db/demo_\#{env_name}.db\")")
    src.should contain("DATABASE_URL_")
    src.should contain("Saci::Record::Schema.dump")
    src.should contain("File.write(\"db/schema.cr\", content)")
  end

  it "documents db:schema commands in help" do
    Saci::CLI.run(["help", "db:schema:dump"]).should eq(0)
    Saci::CLI.run(["help", "db:schema:load"]).should eq(0)
    Saci::CLI.help_text(nil).should contain("db:schema:dump")
    Saci::CLI.help_text(nil).should contain("db:schema:load")
  end
end

# -- live round-trips (compile-time URL gate; pending with reason otherwise)
#
# The `require "pg"` / `require "mysql"` lines compile in only when the
# matching URL env var is present at COMPILE time, so the default
# `crystal spec` stays driver-free. Run live with e.g.:
#   PG_URL=postgres://saci:saci@127.0.0.1:55432/saci_test \
#   MYSQL_URL=mysql://saci:saci@127.0.0.1:53306/saci_test \
#   crystal spec spec/schema_spec.cr [--link-flags=".../live/ossl_shim.o"]

class SchemaPgCreateThings < Saci::Record::Migration
  def change
    create_table :schema_pg_things do |t|
      t.string :title, null: false, default: "hi"
      t.text :body
      t.integer :count, default: 3
      t.bigint :big
      t.float :score, default: 1.5
      t.decimal :amount, default: 2.5
      t.date :day
      t.json :meta
      t.boolean :flag, default: true
      t.datetime :at
      t.timestamps
    end
    add_index :schema_pg_things, :title, unique: true
    add_index :schema_pg_things, [:flag, :count]
  end
end

class SchemaMyCreateThings < Saci::Record::Migration
  def change
    create_table :schema_my_things do |t|
      t.string :title, null: false, default: "hi"
      t.text :body
      t.integer :count, default: 3
      t.bigint :big
      t.float :score, default: 1.5
      t.decimal :amount, default: 2.5
      t.date :day
      t.json :meta
      t.boolean :flag, default: true
      t.datetime :at
      t.timestamps
    end
    add_index :schema_my_things, :title, unique: true
    add_index :schema_my_things, [:flag, :count]
  end
end

def schema_tables_equal(a : Array(Saci::Record::Schema::TableInfo), b : Array(Saci::Record::Schema::TableInfo)) : Nil
  a.map(&.name).sort.should eq(b.map(&.name).sort)
  a.each do |ta|
    tb = b.find! { |x| x.name == ta.name }
    tb.timestamps.should eq(ta.timestamps)
    tb.columns.map { |c| {c.name, c.logical_type, c.null, c.default_value, c.primary_key} }.should eq(
      ta.columns.map { |c| {c.name, c.logical_type, c.null, c.default_value, c.primary_key} })
    tb.indexes.map { |ix| {ix.name, ix.columns, ix.unique} }.should eq(
      ta.indexes.map { |ix| {ix.name, ix.columns, ix.unique} })
  end
end

{% if env("PG_URL") %}
describe "Saci::Record::Schema (live PostgreSQL)" do
  it "round-trips every column type, defaults and indexes" do
    url = ENV["PG_URL"]?
    next if url.nil?
    db : DB::Database? = nil
    begin
      db = Saci::Record.establish_connection("schema_spec_pg", url)
    rescue
      next
    end
    db = db.as(DB::Database)
    begin
      # Cleanup-first: a previous run's `ensure` drops tables but keeps
      # its schema_migrations row, which would make `migrate` skip DDL.
      begin
        Saci::Record.exec_compat(db, "DELETE FROM \"schema_migrations\" WHERE \"name\" = ?", ["SchemaPgCreateThings"] of Saci::Record::Value)
      rescue
      end
      db.exec("DROP TABLE IF EXISTS \"schema_pg_things\"")
      Saci::Record::Migrator.migrate(db, [SchemaPgCreateThings] of Saci::Record::Migration.class)
      tables = Saci::Record::Schema.introspect(db)
      things = tables.find! { |t| t.name == "schema_pg_things" }
      things.timestamps.should be_true
      schema_col(tables, "schema_pg_things", "id").logical_type.should eq(:serial)
      schema_col(tables, "schema_pg_things", "id").primary_key.should be_true
      schema_col(tables, "schema_pg_things", "title").logical_type.should eq(:string)
      schema_col(tables, "schema_pg_things", "title").default_value.should eq("hi")
      schema_col(tables, "schema_pg_things", "body").logical_type.should eq(:text)
      schema_col(tables, "schema_pg_things", "count").logical_type.should eq(:integer)
      schema_col(tables, "schema_pg_things", "count").default_value.should eq(3_i64)
      schema_col(tables, "schema_pg_things", "big").logical_type.should eq(:bigint)
      schema_col(tables, "schema_pg_things", "score").logical_type.should eq(:float)
      schema_col(tables, "schema_pg_things", "score").default_value.should eq(1.5)
      # The adapter forward map stores :decimal as DOUBLE PRECISION on
      # PostgreSQL (Float64-backed), so it reads back as :float.
      schema_col(tables, "schema_pg_things", "amount").logical_type.should eq(:float)
      schema_col(tables, "schema_pg_things", "amount").default_value.should eq(2.5)
      schema_col(tables, "schema_pg_things", "day").logical_type.should eq(:date)
      schema_col(tables, "schema_pg_things", "meta").logical_type.should eq(:json)
      schema_col(tables, "schema_pg_things", "flag").logical_type.should eq(:boolean)
      schema_col(tables, "schema_pg_things", "flag").default_value.should eq(true)
      schema_col(tables, "schema_pg_things", "at").logical_type.should eq(:datetime)
      things.indexes.map(&.name).sort.should eq(["index_schema_pg_things_on_flag_and_count", "index_schema_pg_things_on_title"])
      things.indexes.find! { |ix| ix.name == "index_schema_pg_things_on_title" }.unique.should be_true

      first = Saci::Record::Schema.dump(db, url)
      db.exec("DROP TABLE IF EXISTS \"schema_pg_things\"")
      Saci::Record::Schema.load(db, tables)
      schema_tables_equal(tables, Saci::Record::Schema.introspect(db))
      Saci::Record::Schema.dump(db, url).should eq(first)
    ensure
      begin
        db.exec("DROP TABLE IF EXISTS \"schema_pg_things\"")
      rescue
      end
      db.close
    end
  end
end
{% else %}
pending "round-trips on live PostgreSQL (set PG_URL at compile time, e.g. postgres://saci:saci@127.0.0.1:55432/saci_test)" do
  raise "needs PG_URL"
end
{% end %}

{% if env("MYSQL_URL") %}
describe "Saci::Record::Schema (live MySQL)" do
  it "round-trips every column type, defaults and indexes" do
    url = ENV["MYSQL_URL"]?
    next if url.nil?
    db : DB::Database? = nil
    begin
      db = Saci::Record.establish_connection("schema_spec_mysql", url)
    rescue
      next
    end
    db = db.as(DB::Database)
    begin
      # Cleanup-first: a previous run's `ensure` drops tables but keeps
      # its schema_migrations row, which would make `migrate` skip DDL.
      begin
        Saci::Record.exec_compat(db, "DELETE FROM `schema_migrations` WHERE `name` = ?", ["SchemaMyCreateThings"] of Saci::Record::Value)
      rescue
      end
      db.exec("DROP TABLE IF EXISTS `schema_my_things`")
      Saci::Record::Migrator.migrate(db, [SchemaMyCreateThings] of Saci::Record::Migration.class)
      tables = Saci::Record::Schema.introspect(db)
      things = tables.find! { |t| t.name == "schema_my_things" }
      things.timestamps.should be_true
      schema_col(tables, "schema_my_things", "id").logical_type.should eq(:serial)
      schema_col(tables, "schema_my_things", "id").primary_key.should be_true
      schema_col(tables, "schema_my_things", "title").logical_type.should eq(:string)
      schema_col(tables, "schema_my_things", "title").default_value.should eq("hi")
      schema_col(tables, "schema_my_things", "body").logical_type.should eq(:text)
      schema_col(tables, "schema_my_things", "count").logical_type.should eq(:integer)
      schema_col(tables, "schema_my_things", "count").default_value.should eq(3_i64)
      schema_col(tables, "schema_my_things", "big").logical_type.should eq(:bigint)
      schema_col(tables, "schema_my_things", "score").logical_type.should eq(:float)
      # Documented MySQL normalization: the forward map stores both
      # :decimal and :json as DOUBLE/TEXT, so they read back as
      # :float/:text (same as the adapter's own forward map).
      schema_col(tables, "schema_my_things", "amount").logical_type.should eq(:float)
      schema_col(tables, "schema_my_things", "amount").default_value.should eq(2.5)
      schema_col(tables, "schema_my_things", "day").logical_type.should eq(:date)
      schema_col(tables, "schema_my_things", "meta").logical_type.should eq(:text)
      schema_col(tables, "schema_my_things", "flag").logical_type.should eq(:boolean)
      schema_col(tables, "schema_my_things", "flag").default_value.should eq(true)
      schema_col(tables, "schema_my_things", "at").logical_type.should eq(:datetime)
      things.indexes.map(&.name).sort.should eq(["index_schema_my_things_on_flag_and_count", "index_schema_my_things_on_title"])
      things.indexes.find! { |ix| ix.name == "index_schema_my_things_on_title" }.unique.should be_true

      first = Saci::Record::Schema.dump(db, url)
      db.exec("DROP TABLE IF EXISTS `schema_my_things`")
      Saci::Record::Schema.load(db, tables)
      schema_tables_equal(tables, Saci::Record::Schema.introspect(db))
      Saci::Record::Schema.dump(db, url).should eq(first)
    ensure
      begin
        db.exec("DROP TABLE IF EXISTS `schema_my_things`")
      rescue
      end
      db.close
    end
  end
end
{% else %}
pending "round-trips on live MySQL (set MYSQL_URL at compile time, e.g. mysql://saci:saci@127.0.0.1:53306/saci_test)" do
  raise "needs MYSQL_URL"
end
{% end %}
