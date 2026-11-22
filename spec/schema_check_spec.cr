require "spec"
require "db"
require "sqlite3"
require "../src/saci"

class SchemaCheckWidget < Saci::Record::Base
  table "sc_widgets"

  column id : Int64, primary: true
  column name : String
  timestamps
end

class SchemaCheckGadget < Saci::Record::Base
  table "sc_gadgets"

  column id : Int64, primary: true
  column code : String
end

# Column-less intermediate (the ApplicationRecord pattern) — registered like
# any model but skipped by the check (no columns = no table by design).
class SchemaCheckAbstract < Saci::Record::Base
end

class SchemaCheckTag < Saci::Record::Base
  table "sc_tags"

  column id : Int64, primary: true
end

class SchemaCheckPost < Saci::Record::Base
  table "sc_posts"

  column id : Int64, primary: true
  has_and_belongs_to_many :schema_check_tags, class_name: SchemaCheckTag
  has_and_belongs_to_many :labels, class_name: SchemaCheckTag, join_table: "sc_post_labels"
end

# Multi-database: an abstract base pinned to a named database (the
# `PlatformRecord` pattern); its subclasses inherit the database.
abstract class SchemaCheckPlatformRecord < Saci::Record::Base
  connects_to database: "sc_platform"
end

class SchemaCheckAccount < SchemaCheckPlatformRecord
  table "sc_accounts"

  column id : Int64, primary: true
  has_and_belongs_to_many :schema_check_roles, class_name: SchemaCheckRole
end

class SchemaCheckRole < SchemaCheckPlatformRecord
  table "sc_roles"

  column id : Int64, primary: true
end

SC_WIDGET_TABLE = "CREATE TABLE \"sc_widgets\" (\"id\" INTEGER PRIMARY KEY AUTOINCREMENT, \"name\" VARCHAR(255), \"created_at\" TEXT NOT NULL, \"updated_at\" TEXT NOT NULL)"
SC_GADGET_TABLE = "CREATE TABLE \"sc_gadgets\" (\"id\" INTEGER PRIMARY KEY AUTOINCREMENT, \"code\" VARCHAR(255))"

def sc_models(*klasses : Saci::Record::Base.class) : Array(Saci::Record::Base.class)
  out = [] of Saci::Record::Base.class
  klasses.each { |k| out << k }
  out
end

def with_sc_db(statements : Array(String), & : DB::Database -> T) : T forall T
  path = "/tmp/opencode/saci_schema_check_#{Random.rand(1_000_000_000)}.db"
  File.delete(path) if File.exists?(path)
  db = DB.open("sqlite3://#{path}")
  begin
    statements.each { |sql| db.exec(sql) }
    yield db
  ensure
    db.close
    File.delete(path) if File.exists?(path)
  end
end

describe "Saci::Record.check_schema!" do
  it "auto-populates the model registry (deduped)" do
    Saci::Record.models.should contain(SchemaCheckWidget)
    Saci::Record.models.should contain(SchemaCheckGadget)
    Saci::Record.models.should contain(SchemaCheckAbstract)
    Saci::Record.models.select { |m| m == SchemaCheckWidget }.size.should eq(1)
  end

  it "is silent when the database matches the models" do
    with_sc_db([
      SC_WIDGET_TABLE,
      SC_GADGET_TABLE,
      "CREATE TABLE \"schema_migrations\" (\"name\" VARCHAR(255) PRIMARY KEY)",
      "CREATE TABLE \"saci_jobs\" (\"id\" INTEGER PRIMARY KEY AUTOINCREMENT)",
      "CREATE TABLE \"saci_dead_jobs\" (\"id\" INTEGER PRIMARY KEY AUTOINCREMENT)",
    ]) do |db|
      # Queue + migration bookkeeping tables have no models by design and
      # must not warn; the column-less intermediate owns no table either.
      Saci::Record.check_schema!(db, sc_models(SchemaCheckWidget, SchemaCheckGadget, SchemaCheckAbstract)).should be_empty
    end
  end

  it "warns about tables with no registered model" do
    with_sc_db([
      SC_WIDGET_TABLE,
      "CREATE TABLE \"sc_orphans\" (\"id\" INTEGER PRIMARY KEY AUTOINCREMENT)",
    ]) do |db|
      warnings = Saci::Record.check_schema!(db, sc_models(SchemaCheckWidget))
      warnings.size.should eq(1)
      warnings.first.should contain("sc_orphans")
      warnings.first.should contain("no registered model")
    end
  end

  it "warns about models whose table is missing from the database" do
    with_sc_db(["CREATE TABLE \"schema_migrations\" (\"name\" VARCHAR(255) PRIMARY KEY)"]) do |db|
      warnings = Saci::Record.check_schema!(db, sc_models(SchemaCheckWidget, SchemaCheckGadget))
      warnings.size.should eq(2)
      warnings.any? { |w| w.includes?("SchemaCheckWidget") && w.includes?("sc_widgets") }.should be_true
      warnings.any? { |w| w.includes?("SchemaCheckGadget") && w.includes?("sc_gadgets") }.should be_true
    end
  end

  it "warns about database columns with no model mapping" do
    with_sc_db([
      "CREATE TABLE \"sc_widgets\" (\"id\" INTEGER PRIMARY KEY AUTOINCREMENT, \"name\" VARCHAR(255), \"created_at\" TEXT NOT NULL, \"updated_at\" TEXT NOT NULL, \"stray\" TEXT)",
    ]) do |db|
      warnings = Saci::Record.check_schema!(db, sc_models(SchemaCheckWidget))
      warnings.size.should eq(1)
      warnings.first.should contain("stray")
      warnings.first.should contain("SchemaCheckWidget")
    end
  end

  it "warns about model columns missing from the database table" do
    with_sc_db([
      "CREATE TABLE \"sc_widgets\" (\"id\" INTEGER PRIMARY KEY AUTOINCREMENT, \"created_at\" TEXT NOT NULL, \"updated_at\" TEXT NOT NULL)",
    ]) do |db|
      warnings = Saci::Record.check_schema!(db, sc_models(SchemaCheckWidget))
      warnings.size.should eq(1)
      warnings.first.should contain("\"name\"")
      warnings.first.should contain("SchemaCheckWidget")
    end
  end

  it "ignores framework models whose feature was never set up" do
    with_sc_db([SC_WIDGET_TABLE]) do |db|
      models = sc_models(SchemaCheckWidget, Saci::Mailbox::InboundEmail)
      Saci::Record.check_schema!(db, models).should be_empty
    end
  end

  it "still checks a framework model once its table exists" do
    with_sc_db([
      SC_WIDGET_TABLE,
      "CREATE TABLE \"saci_inbound_emails\" (\"id\" INTEGER PRIMARY KEY AUTOINCREMENT)",
    ]) do |db|
      warnings = Saci::Record.check_schema!(db, sc_models(SchemaCheckWidget, Saci::Mailbox::InboundEmail))
      warnings.should_not be_empty
      warnings.all?(&.includes?("saci_inbound_emails")).should be_true
    end
  end

  it "ignores framework-owned saci_* tables without a model" do
    with_sc_db([
      SC_WIDGET_TABLE,
      "CREATE TABLE \"saci_cable_messages\" (\"id\" INTEGER PRIMARY KEY AUTOINCREMENT)",
      "CREATE TABLE \"saci_job_processes\" (\"id\" INTEGER PRIMARY KEY AUTOINCREMENT)",
    ]) do |db|
      Saci::Record.check_schema!(db, sc_models(SchemaCheckWidget)).should be_empty
    end
  end

  it "reports every drift kind at once" do
    with_sc_db([
      "CREATE TABLE \"sc_widgets\" (\"id\" INTEGER PRIMARY KEY AUTOINCREMENT, \"created_at\" TEXT NOT NULL, \"updated_at\" TEXT NOT NULL, \"stray\" TEXT)",
      "CREATE TABLE \"sc_orphans\" (\"id\" INTEGER PRIMARY KEY AUTOINCREMENT)",
    ]) do |db|
      warnings = Saci::Record.check_schema!(db, sc_models(SchemaCheckWidget, SchemaCheckGadget))
      warnings.size.should eq(4)
      warnings.any?(&.includes?("sc_orphans")).should be_true
      warnings.any?(&.includes?("sc_gadgets")).should be_true
      warnings.any?(&.includes?("stray")).should be_true
      warnings.any? { |w| w.includes?("\"name\"") }.should be_true
    end
  end

  it "ignores SQLite virtual tables and their shadow tables" do
    with_sc_db([
      SC_WIDGET_TABLE,
      "CREATE VIRTUAL TABLE \"sc_search\" USING fts5(body)",
      "CREATE VIRTUAL TABLE \"sc_legacy\" USING fts4(body)",
      "CREATE VIRTUAL TABLE \"sc_boxes\" USING rtree(id, min_x, max_x)",
    ]) do |db|
      Saci::Record.check_schema!(db, sc_models(SchemaCheckWidget)).should be_empty
    end
  end

  it "still warns about a plain table named like a shadow table" do
    with_sc_db([
      SC_WIDGET_TABLE,
      "CREATE VIRTUAL TABLE \"sc_search\" USING fts5(body)",
      "CREATE TABLE \"sc_widgets_data\" (\"id\" INTEGER PRIMARY KEY AUTOINCREMENT)",
    ]) do |db|
      warnings = Saci::Record.check_schema!(db, sc_models(SchemaCheckWidget))
      warnings.size.should eq(1)
      warnings.first.should contain("sc_widgets_data")
    end
  end

  it "treats has_and_belongs_to_many join tables as known" do
    with_sc_db([
      "CREATE TABLE \"sc_tags\" (\"id\" INTEGER PRIMARY KEY AUTOINCREMENT)",
      "CREATE TABLE \"sc_posts\" (\"id\" INTEGER PRIMARY KEY AUTOINCREMENT)",
      "CREATE TABLE \"sc_posts_sc_tags\" (\"sc_post_id\" INTEGER, \"sc_tag_id\" INTEGER)",
      "CREATE TABLE \"sc_post_labels\" (\"sc_post_id\" INTEGER, \"sc_tag_id\" INTEGER)",
    ]) do |db|
      Saci::Record.check_schema!(db, sc_models(SchemaCheckPost, SchemaCheckTag)).should be_empty
      # Only join tables of the checked models count as known.
      Saci::Record.check_schema!(db, sc_models(SchemaCheckTag)).size.should eq(3)
    end
  end

  it "checks each model only against its own database (connects_to)" do
    models = sc_models(SchemaCheckWidget, SchemaCheckPlatformRecord, SchemaCheckAccount, SchemaCheckRole, SchemaCheckPost, SchemaCheckTag)
    SchemaCheckWidget.__saci_database_name.should eq("primary")
    SchemaCheckAccount.__saci_database_name.should eq("sc_platform")
    with_sc_db([
      SC_WIDGET_TABLE,
      "CREATE TABLE \"sc_tags\" (\"id\" INTEGER PRIMARY KEY AUTOINCREMENT)",
      "CREATE TABLE \"sc_posts\" (\"id\" INTEGER PRIMARY KEY AUTOINCREMENT)",
      "CREATE TABLE \"sc_posts_sc_tags\" (\"sc_post_id\" INTEGER, \"sc_tag_id\" INTEGER)",
    ]) do |primary|
      path = "/tmp/opencode/saci_schema_check_platform_#{Random.rand(1_000_000_000)}.db"
      platform = Saci::Record.establish_connection("sc_platform", "sqlite3://#{path}")
      begin
        platform.exec("CREATE TABLE \"sc_accounts\" (\"id\" INTEGER PRIMARY KEY AUTOINCREMENT)")
        platform.exec("CREATE TABLE \"sc_accounts_sc_roles\" (\"sc_account_id\" INTEGER, \"sc_role_id\" INTEGER)")

        # An unregistered database counts as primary; a registered one is
        # resolved by name. Neither reports the other database's models.
        Saci::Record.check_schema!(primary, models).should be_empty
        Saci::Record.check_schema!(platform, models).should eq([
          "Model SchemaCheckRole (table \"sc_roles\") has no matching table in the database (missing migration?)",
        ])
        platform.exec("CREATE TABLE \"sc_roles\" (\"id\" INTEGER PRIMARY KEY AUTOINCREMENT)")
        Saci::Record.check_schema!(platform, models).should be_empty

        # A join table is known only in its owner's database.
        primary.exec("CREATE TABLE \"sc_accounts_sc_roles\" (\"sc_account_id\" INTEGER, \"sc_role_id\" INTEGER)")
        Saci::Record.check_schema!(primary, models).should eq([
          "Table \"sc_accounts_sc_roles\" exists in the database but has no registered model (missing model?)",
        ])
        platform.exec("CREATE TABLE \"sc_posts_sc_tags\" (\"sc_post_id\" INTEGER, \"sc_tag_id\" INTEGER)")
        Saci::Record.check_schema!(platform, models).should eq([
          "Table \"sc_posts_sc_tags\" exists in the database but has no registered model (missing model?)",
        ])

        # An explicit database name wins over the registry lookup.
        Saci::Record.check_schema!(primary, models, database_name: "sc_platform").should contain(
          "Model SchemaCheckRole (table \"sc_roles\") has no matching table in the database (missing migration?)")
      ensure
        Saci::Record.remove_connection("sc_platform")
        File.delete(path) if File.exists?(path)
      end
    end
  end
end
