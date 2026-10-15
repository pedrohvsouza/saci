require "spec"
require "db"
require "sqlite3"
require "../src/saci"

# -- schema-check fixtures (custom table names, like real apps) ---------------

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

SC_WIDGET_TABLE = "CREATE TABLE \"sc_widgets\" (\"id\" INTEGER PRIMARY KEY AUTOINCREMENT, \"name\" VARCHAR(255), \"created_at\" TEXT NOT NULL, \"updated_at\" TEXT NOT NULL)"
SC_GADGET_TABLE  = "CREATE TABLE \"sc_gadgets\" (\"id\" INTEGER PRIMARY KEY AUTOINCREMENT, \"code\" VARCHAR(255))"

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
end
