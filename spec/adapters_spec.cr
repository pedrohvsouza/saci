require "spec"
require "../src/saci"

# Adapter support (SQLite live; PostgreSQL/MySQL via SQL-generation specs —
# no servers are available in this environment, and their drivers require
# app-level opt-in. See `Saci::Record` docs and README).
describe "database adapters" do
  it "detects adapters from URL schemes" do
    Saci::Record.adapter_for_url("sqlite3://./db/app.db").should eq(:sqlite)
    Saci::Record.adapter_for_url("postgres://localhost/app").should eq(:postgres)
    Saci::Record.adapter_for_url("postgresql://u:p@h:5432/app").should eq(:postgres)
    Saci::Record.adapter_for_url("mysql://root@localhost/old").should eq(:mysql)
    expect_raises(ArgumentError, /nknown database adapter/) do
      Saci::Record.adapter_for_url("postgress://localhost/app")
    end
  end

  it "rejects unknown schemes before opening anything" do
    expect_raises(ArgumentError, /nknown database adapter/) do
      Saci::Record.establish_connection("bogus_#{Random::Secure.hex(4)}", "oracle://localhost/x")
    end
  end

  it "records the adapter on connect" do
    path = "/tmp/opencode/saci_adapter_probe.db"
    File.delete(path) if File.exists?(path)
    Saci::Record.connect("sqlite3://#{path}")
    begin
      Saci::Record.adapter_for_name("primary").should eq(:sqlite)
      Saci::Record.adapter_of(Saci::Record.database("primary")).should eq(:sqlite)
    ensure
      Saci::Record.database("primary").close
      File.delete(path) if File.exists?(path)
    end
  end

  it "quotes identifiers per adapter" do
    Saci::Record.quote("users", :sqlite).should eq(%("users"))
    Saci::Record.quote("users", :postgres).should eq(%("users"))
    Saci::Record.quote("users", :mysql).should eq("`users`")
  end

  it "rewrites placeholders for PostgreSQL only" do
    sql = %(SELECT "a" FROM "t" WHERE "x" = ? AND "y" = ?)
    Saci::Record.apply_placeholders(sql, :postgres).should eq(
      %(SELECT "a" FROM "t" WHERE "x" = $1 AND "y" = $2))
    Saci::Record.apply_placeholders(sql, :sqlite).should eq(sql)
    Saci::Record.apply_placeholders(sql, :mysql).should eq(sql)
  end

  it "leaves question marks inside string literals alone" do
    sql = %(SELECT * FROM "t" WHERE "note" = 'really?' AND "x" = ?)
    Saci::Record.apply_placeholders(sql, :postgres).should eq(
      %(SELECT * FROM "t" WHERE "note" = 'really?' AND "x" = $1))
  end

  it "maps logical column types per adapter" do
    Saci::Record.db_type(:string, :sqlite).should eq("VARCHAR(255)")
    Saci::Record.db_type(:bigint, :sqlite).should eq("INTEGER")
    Saci::Record.db_type(:bigint, :postgres).should eq("BIGINT")
    Saci::Record.db_type(:bigint, :mysql).should eq("BIGINT")
    Saci::Record.db_type(:float, :sqlite).should eq("REAL")
    Saci::Record.db_type(:float, :postgres).should eq("DOUBLE PRECISION")
    Saci::Record.db_type(:float, :mysql).should eq("DOUBLE")
    Saci::Record.db_type(:boolean, :sqlite).should eq("INTEGER")
    Saci::Record.db_type(:boolean, :postgres).should eq("BOOLEAN")
    Saci::Record.db_type(:boolean, :mysql).should eq("BOOLEAN")
    Saci::Record.db_type(:datetime, :sqlite).should eq("TEXT")
    Saci::Record.db_type(:datetime, :postgres).should eq("TIMESTAMP")
    Saci::Record.db_type(:datetime, :mysql).should eq("DATETIME")
    Saci::Record.db_type(:serial, :sqlite).should eq("INTEGER")
    Saci::Record.db_type(:serial, :postgres).should eq("BIGSERIAL")
    Saci::Record.db_type(:serial, :mysql).should eq("BIGINT")
    expect_raises(ArgumentError, /nknown column type/) do
      Saci::Record.db_type(:fancy, :sqlite)
    end
  end

  it "renders primary keys and defaults per adapter" do
    id = Saci::Record::ColumnDef.new("id", :serial, false, nil, true)
    id.to_sql(:sqlite).should eq(%("id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL))
    id.to_sql(:postgres).should eq(%("id" BIGSERIAL PRIMARY KEY NOT NULL))
    id.to_sql(:mysql).should eq("`id` BIGINT AUTO_INCREMENT PRIMARY KEY NOT NULL")

    flag = Saci::Record::ColumnDef.new("admin", :boolean, true, false, false)
    flag.to_sql(:sqlite).should contain("DEFAULT 0")
    flag.to_sql(:postgres).should contain("DEFAULT FALSE")
    flag.to_sql(:mysql).should contain("DEFAULT 0")

    title = Saci::Record::ColumnDef.new("title", :string, false, "hi", false)
    title.to_sql(:postgres).should eq(%("title" VARCHAR(255) NOT NULL DEFAULT 'hi'))
  end

  it "renders whole tables per adapter" do
    t = Saci::Record::TableDefinition.new
    t.string :title, null: false
    t.boolean :published, default: false
    t.timestamps
    sqlite = (Saci::Record::ColumnDef.new("id", :serial, false, nil, true).to_sql(:sqlite) + ", " +
      t.columns.map(&.to_sql(:sqlite)).join(", "))
    sqlite.should contain(%("created_at" TEXT NOT NULL))
    pg_cols = t.columns.map(&.to_sql(:postgres)).join(", ")
    pg_cols.should contain(%("published" BOOLEAN DEFAULT FALSE))
    pg_cols.should contain(%("created_at" TIMESTAMP NOT NULL))
    mysql_cols = t.columns.map(&.to_sql(:mysql)).join(", ")
    mysql_cols.should contain("`published` BOOLEAN DEFAULT 0")
    mysql_cols.should contain("`created_at` DATETIME NOT NULL")
  end

  it "rolls back in reverse manifest order without rowid" do
    path = "/tmp/opencode/saci_rollback_probe.db"
    File.delete(path) if File.exists?(path)
    db = DB.open("sqlite3://#{path}")
    begin
      ran = Saci::Record::Migrator.migrate(db, [AdapterProbeM1, AdapterProbeM2, AdapterProbeM3] of Saci::Record::Migration.class)
      ran.should eq(["AdapterProbeM1", "AdapterProbeM2", "AdapterProbeM3"])
      undone = Saci::Record::Migrator.rollback(db, [AdapterProbeM1, AdapterProbeM2, AdapterProbeM3], 2)
      undone.should eq(["AdapterProbeM3", "AdapterProbeM2"])
      Saci::Record::Migrator.applied_names(db).should eq(["AdapterProbeM1"])
    ensure
      db.close
      File.delete(path) if File.exists?(path)
    end
  end
end

class AdapterProbeM1 < Saci::Record::Migration
  def change
    create_table :adapter_probe_things do |t|
      t.string :name
    end
  end
end

class AdapterProbeM2 < Saci::Record::Migration
  def change
    add_column :adapter_probe_things, :extra, :string
  end
end

class AdapterProbeM3 < Saci::Record::Migration
  def change
    add_index :adapter_probe_things, :name
  end
end
