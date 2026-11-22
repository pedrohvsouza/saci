require "spec"
require "file_utils"
require "../src/saci"

# SQLite `STRICT` tables (`create_table :x, strict: true`). Raw DB
# handles for DDL; model round-trips go through the primary database
# (saved and restored, like spec/adapters_spec.cr).

class StrictCreateAuthors < Saci::Record::Migration
  def change
    create_table :strict_authors, strict: true do |t|
      t.string :name
    end
  end
end

class StrictCreateEverything < Saci::Record::Migration
  def change
    create_table :strict_things, strict: true do |t|
      t.string :name, null: false
      t.text :body
      t.integer :count, default: 0
      t.bigint :big
      t.float :score
      t.decimal :price, precision: 10, scale: 2
      t.date :day
      t.datetime :at
      t.boolean :active, default: false
      t.json :meta
      t.uuid :token
      t.binary :blob
      t.string_array :tags
      t.enum :status, values: ["draft", "published"]
      t.references :strict_author, foreign_key: true
      t.timestamps
    end
    add_column :strict_things, :note, :string
  end
end

class StrictCreateUuids < Saci::Record::Migration
  def change
    create_table :strict_uuids, id: :uuid, strict: true do |t|
      t.string :label
    end
  end
end

class StrictCreateLoose < Saci::Record::Migration
  def change
    create_table :strict_loose do |t|
      t.string :name
      t.decimal :price
    end
  end
end

class StrictAuthor < Saci::Record::Base
  table "strict_authors"
  column id : Int64, primary: true
  column name : String
end

class StrictThing < Saci::Record::Base
  table "strict_things"
  column id : Int64, primary: true
  column name : String
  column body : String
  column count : Int32, default: 0
  column big : Int64
  column score : Float64
  column price : Decimal
  column day : Date
  column at : Time
  column active : Bool, default: false
  column meta : JSON
  column token : String
  column blob : Bytes
  column tags : Array(String)
  column status : String
  column strict_author_id : Int64
  column note : String
  timestamps
end

STRICT_MIGRATIONS = [StrictCreateAuthors, StrictCreateEverything, StrictCreateUuids, StrictCreateLoose] of Saci::Record::Migration.class

def with_strict_db(& : DB::Database, String -> Nil) : Nil
  Dir.mkdir_p("/tmp/opencode")
  path = File.join("/tmp/opencode", "saci_strict_#{Random.rand(1_000_000_000)}.db")
  File.delete(path) if File.exists?(path)
  db = DB.open("sqlite3://#{path}")
  begin
    Saci::Record::Migrator.migrate(db, STRICT_MIGRATIONS)
    yield db, path
  ensure
    begin
      db.close
    rescue SQLite3::Exception
    end
    File.delete(path) if File.exists?(path)
  end
end

def strict_decltypes(db : DB::Database, table : String) : Hash(String, String)
  info = {} of String => String
  db.query(%(PRAGMA table_info("#{table}"))) do |rs|
    rs.each do
      rs.read(Int64); name = rs.read(String); info[name] = rs.read(String); rs.read; rs.read; rs.read
    end
  end
  info
end

def strict_table?(db : DB::Database, table : String) : Bool
  Saci::Record::Introspection.sqlite_strict?(db, table)
end

describe "SQLite STRICT tables" do
  it "maps every rendered SQLite type to a STRICT storage type" do
    m = Saci::Record::Migration
    m.sqlite_strict_type("VARCHAR(255)").should eq("TEXT")
    m.sqlite_strict_type("TEXT_DECIMAL").should eq("TEXT")
    m.sqlite_strict_type("TEXT").should eq("TEXT")
    m.sqlite_strict_type("INTEGER").should eq("INTEGER")
    m.sqlite_strict_type("REAL").should eq("REAL")
    m.sqlite_strict_type("BLOB").should eq("BLOB")
    # Non-strict rendering is unchanged.
    Saci::Record::ColumnDef.new("n", :string, true, nil, false).to_sql(:sqlite).should eq(%("n" VARCHAR(255)))
    Saci::Record::ColumnDef.new("n", :string, true, nil, false).to_sql(:sqlite, strict: true).should eq(%("n" TEXT))
    Saci::Record::ColumnDef.new("n", :string, true, nil, false).to_sql(:postgres, strict: true).should eq(%("n" VARCHAR(255)))
  end

  it "creates STRICT tables with STRICT-compatible declared types only" do
    with_strict_db do |db, _|
      strict_table?(db, "strict_things").should be_true
      strict_table?(db, "strict_uuids").should be_true
      strict_table?(db, "strict_loose").should be_false
      allowed = {"INTEGER", "INT", "REAL", "TEXT", "BLOB", "ANY"}
      strict_decltypes(db, "strict_things").each do |col, type|
        allowed.includes?(type).should(be_true, "#{col}: #{type}")
      end
      strict_decltypes(db, "strict_things")["note"].should eq("TEXT")
      strict_decltypes(db, "strict_uuids")["id"].should eq("TEXT")
      # Non-strict tables keep the historical declared types.
      strict_decltypes(db, "strict_loose")["name"].should eq("VARCHAR(255)")
      strict_decltypes(db, "strict_loose")["price"].should eq("TEXT_DECIMAL")
    end
  end

  it "rejects values of the wrong type" do
    with_strict_db do |db, _|
      expect_raises(SQLite3::Exception, /cannot store TEXT value in INTEGER column/) do
        db.exec(%(INSERT INTO strict_things (name, count, created_at, updated_at) VALUES ('x', 'abc', 'a', 'b')))
      end
      expect_raises(SQLite3::Exception, /cannot store TEXT value in REAL column/) do
        db.exec(%(INSERT INTO strict_things (name, score, created_at, updated_at) VALUES ('x', 'abc', 'a', 'b')))
      end
      expect_raises(SQLite3::Exception, /cannot store TEXT value in BLOB column/) do
        db.exec(%(INSERT INTO strict_things (name, blob, created_at, updated_at) VALUES ('x', 'abc', 'a', 'b')))
      end
      # The non-strict table happily stores the same mismatch.
      db.exec(%(INSERT INTO strict_loose (name) VALUES (42)))
    end
  end

  it "round-trips every logical type through a model on a STRICT table" do
    with_strict_db do |db, path|
      had_primary = Saci::Record.configuration_names.includes?("primary")
      prev = had_primary ? Saci::Record.database("primary") : nil
      Saci::Record::Base.connection = DB.open("sqlite3://#{path}")
      begin
        author = StrictAuthor.create!(name: "ann")
        at = Time.utc(2024, 5, 1, 12, 30, 45)
        bytes = Bytes[0, 1, 2, 255]
        thing = StrictThing.create!(
          name: "widget", body: "long text", count: 3, big: 9_000_000_000_i64,
          score: 1.5, price: BigDecimal.new("12.34"), day: Time.utc(2024, 5, 1), at: at,
          active: true, meta: %({"a":1}), token: "0b6e9b5c-3c1f-4a43-9b3e-6c2f4f3b2a10",
          blob: bytes, tags: ["a", "b"], status: "published", strict_author_id: author.id, note: "n")
        fresh = StrictThing.find(thing.id)
        fresh.name.should eq("widget")
        fresh.body.should eq("long text")
        fresh.count.should eq(3)
        fresh.big.should eq(9_000_000_000_i64)
        fresh.score.should eq(1.5)
        fresh.price.should eq(BigDecimal.new("12.34"))
        fresh.day.not_nil!.day.should eq(1)
        fresh.at.should eq(at)
        fresh.active.should be_true
        fresh.meta_json.not_nil!["a"].should eq(1)
        fresh.token.should eq("0b6e9b5c-3c1f-4a43-9b3e-6c2f4f3b2a10")
        fresh.blob.should eq(bytes)
        fresh.tags.should eq(["a", "b"])
        fresh.status.should eq("published")
        fresh.strict_author_id.should eq(author.id)
        fresh.note.should eq("n")
        fresh.created_at.should_not be_nil

        fresh.update!(active: false, score: 2.0, price: BigDecimal.new("0.10"))
        again = StrictThing.find(thing.id)
        again.active.should be_false
        again.score.should eq(2.0)
        again.price.should eq(BigDecimal.new("0.10"))
      ensure
        Saci::Record.database("primary").close
        if p = prev
          Saci::Record::Base.connection = p
        end
      end
      # UUID primary keys store as TEXT.
      db.exec(%(INSERT INTO strict_uuids (id, label) VALUES ('0b6e9b5c-3c1f-4a43-9b3e-6c2f4f3b2a10', 'x')))
      db.scalar(%(SELECT label FROM strict_uuids)).should eq("x")
    end
  end

  it "round-trips the STRICT flag through schema dump/load" do
    with_strict_db do |db, _|
      tables = Saci::Record::Schema.introspect(db)
      tables.find!(&.name.==("strict_things")).strict.should be_true
      tables.find!(&.name.==("strict_loose")).strict.should be_false
      first = Saci::Record::Schema.dump(db)
      first.should contain("strict: true")
      first.scan("strict: true").size.should eq(3)

      Saci::Record::Schema.load(db, tables)
      strict_table?(db, "strict_things").should be_true
      strict_table?(db, "strict_authors").should be_true
      strict_table?(db, "strict_loose").should be_false
      Saci::Record::Schema.dump(db).should eq(first)
      expect_raises(SQLite3::Exception, /cannot store/) do
        db.exec(%(INSERT INTO strict_things (name, count, created_at, updated_at) VALUES ('x', 'abc', 'a', 'b')))
      end
    end
  end

  it "keeps STRICT through the SQLite table rebuild (change_column_null/default)" do
    with_strict_db do |db, _|
      db.exec(%(INSERT INTO strict_authors (name) VALUES ('ann')))
      m = Saci::Record::Migration.new(db)
      m.suppress_messages do
        m.change_column_default(:strict_authors, :name, "anon")
        m.change_column_null(:strict_authors, :name, false)
      end
      strict_table?(db, "strict_authors").should be_true
      db.scalar(%(SELECT name FROM strict_authors)).should eq("ann")
      db.exec(%(INSERT INTO strict_authors DEFAULT VALUES))
      db.scalar(%(SELECT COUNT(*) FROM strict_authors WHERE name = 'anon')).should eq(1)
      expect_raises(SQLite3::Exception, /cannot store BLOB value in TEXT column/) do
        db.exec(%(INSERT INTO strict_authors (name) VALUES (x'00')))
      end
    end
  end
end
