require "spec"
require "file"
require "../src/saci"
require "../src/saci/record/bulk"
require "../src/saci/record/finders"
require "../src/saci/record/dialect"

# -- schema -----------------------------------------------------------------

QX_DB_PATH = "/tmp/opencode/saci_orm_query_extras.db"

def extras_db : DB::Database
  Saci::Record::Base.connection.as(DB::Database)
end

def bulk_count(res : Int64 | Array(Hash(String, Saci::Record::Value))) : Int64
  res.as(Int64)
end

class QxGroup < Saci::Record::Base
  column id : Int64, primary: true
  column label : String
  timestamps

  has_many :qx_items
end

class QxItem < Saci::Record::Base
  column id : Int64, primary: true
  column name : String
  column sku : String
  column category : String
  column qty : Int32
  column published : Bool
  column qx_group_id : Int64
  timestamps

  belongs_to :qx_group
  define_finders :sku, :name
end

# Custom string primary key (G12 batching must honor it).
class QxCode < Saci::Record::Base
  column code : String, primary: true
  column label : String
end

describe "Saci::Record query/bulk extras" do
  before_all do
    File.delete(QX_DB_PATH) if File.exists?(QX_DB_PATH)
    Saci::Record.connection = DB.open("sqlite3://#{QX_DB_PATH}")
    db = extras_db
    db.exec("CREATE TABLE qx_groups (id INTEGER PRIMARY KEY AUTOINCREMENT, label TEXT, created_at TEXT, updated_at TEXT)")
    db.exec("CREATE TABLE qx_items (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, sku TEXT UNIQUE, category TEXT, qty INTEGER DEFAULT 0, published INTEGER DEFAULT 0, qx_group_id INTEGER, created_at TEXT, updated_at TEXT)")
    db.exec("CREATE TABLE qx_codes (code TEXT PRIMARY KEY, label TEXT)")
  end

  after_all do
    # NOTE: intentionally not closing the SQLite handle: crystal-sqlite3
    # re-raises a prior constraint error from `finalize` when a failed
    # `insert_all!` statement is closed, which would turn a passing
    # expectation into an after-suite error. The OS closes the file.
  end

  before_each do
    extras_db.exec("DELETE FROM qx_items")
    extras_db.exec("DELETE FROM qx_groups")
    extras_db.exec("DELETE FROM qx_codes")
  end

  # -- G11 bulk writes ------------------------------------------------------

  describe "insert_all / upsert_all" do
    it "inserts multiple named-tuple rows and fills timestamps" do
      res = QxItem.insert_all([
        {name: "alpha", sku: "a", category: "x", qty: 1},
        {name: "beta", sku: "b", category: "x", qty: 2},
      ])
      bulk_count(res).should eq(2_i64)
      QxItem.count.should eq(2_i64)
      row = QxItem.find_by(sku: "a").not_nil!
      row.name.should eq("alpha")
      row.created_at.should_not be_nil
      row.updated_at.should_not be_nil
    end

    it "accepts Hash rows with string keys" do
      rows = [
        {"name" => "hashy", "sku" => "h1"} of String => String,
        {"name" => "hashy2", "sku" => "h2"} of String => String,
      ]
      bulk_count(QxItem.insert_all(rows)).should eq(2_i64)
      QxItem.find_by(sku: "h1").not_nil!.name.should eq("hashy")
    end

    it "returns 0 for an empty batch without touching the database" do
      bulk_count(QxItem.insert_all([] of Hash(String, Saci::Record::Value))).should eq(0_i64)
      QxItem.insert_all([] of Hash(String, Saci::Record::Value), returning: :id).as(Array(Hash(String, Saci::Record::Value))).should be_empty
    end

    it "skips conflicts with insert_all and raises with insert_all!" do
      bulk_count(QxItem.insert_all([{name: "one", sku: "dup"}])).should eq(1_i64)
      bulk_count(QxItem.insert_all([{name: "two", sku: "dup"}])).should eq(0_i64)
      QxItem.count.should eq(1_i64)
      expect_raises(Exception) do
        QxItem.insert_all!([{name: "three", sku: "dup"}])
      end
      QxItem.count.should eq(1_i64)
    end

    it "honors unique_by and returns requested columns" do
      QxItem.insert_all([{name: "base", sku: "ret", category: "c", qty: 3}])
      res = QxItem.insert_all(
        [{name: "returned", sku: "ret2", category: "c", qty: 4}],
        unique_by: :sku,
        returning: [:id, :sku]
      )
      rows = res.as(Array(Hash(String, Saci::Record::Value)))
      rows.size.should eq(1)
      rows.first["sku"].should eq("ret2")
      rows.first["id"].should_not be_nil
    end

    it "upserts on unique_by, updates columns and preserves created_at" do
      earlier = Time.utc(2020, 1, 1, 0, 0, 0)
      QxItem.insert_all([{name: "old", sku: "u1", category: "old", qty: 1, created_at: earlier, updated_at: earlier}])
      before = QxItem.find_by(sku: "u1").not_nil!
      created = before.created_at
      before.updated_at.should eq(earlier)
      bulk_count(QxItem.upsert_all(
        [{name: "new", sku: "u1", category: "new", qty: 9}],
        unique_by: :sku
      )).should eq(1_i64)
      after = QxItem.find_by(sku: "u1").not_nil!
      after.name.should eq("new")
      after.qty.should eq(9)
      after.created_at.should eq(created)
      after.updated_at.not_nil!.should be > earlier
      QxItem.count.should eq(1_i64)
    end

    it "upsert_all returns rows when asked on SQLite" do
      res = QxItem.upsert_all(
        [{name: "up-ret", sku: "ur", qty: 2}],
        unique_by: :sku,
        returning: :id
      )
      rows = res.as(Array(Hash(String, Saci::Record::Value)))
      rows.size.should eq(1)
      rows.first["id"].should_not be_nil
    end
  end

  # -- G12 batching ---------------------------------------------------------

  describe "bulk SQL per adapter (string level)" do
    it "builds multi-row ON CONFLICT DO NOTHING for SQLite/PostgreSQL" do
      sql = QxItem.__saci_bulk_sql(:insert, "\"qx_items\"", ["name", "sku"], 2, ["sku"], true, :postgres)
      sql.should eq("INSERT INTO \"qx_items\" (\"name\", \"sku\") VALUES (?, ?), (?, ?) ON CONFLICT (\"sku\") DO NOTHING")
      QxItem.__saci_bulk_sql(:insert, "\"qx_items\"", ["sku"], 1, ["id"], false, :sqlite)
        .should eq("INSERT INTO \"qx_items\" (\"sku\") VALUES (?) ON CONFLICT DO NOTHING")
    end

    it "uses INSERT IGNORE and ON DUPLICATE KEY UPDATE on MySQL" do
      QxItem.__saci_bulk_sql(:insert, "`qx_items`", ["name", "sku"], 1, ["sku"], true, :mysql)
        .should eq("INSERT IGNORE INTO `qx_items` (`name`, `sku`) VALUES (?, ?)")
      up = QxItem.__saci_bulk_sql(:upsert, "`qx_items`", ["name", "sku", "created_at", "updated_at"], 1, ["id"], false, :mysql)
      up.should contain("ON DUPLICATE KEY UPDATE `name` = VALUES(`name`), `sku` = VALUES(`sku`), `updated_at` = VALUES(`updated_at`)")
      up.should_not contain("`created_at` = VALUES")
    end

    it "builds PostgreSQL upserts with excluded.*" do
      up = QxItem.__saci_bulk_sql(:upsert, "\"qx_items\"", ["name", "sku", "created_at", "updated_at"], 1, ["sku"], true, :postgres)
      up.should eq("INSERT INTO \"qx_items\" (\"name\", \"sku\", \"created_at\", \"updated_at\") VALUES (?, ?, ?, ?) ON CONFLICT (\"sku\") DO UPDATE SET \"name\" = excluded.\"name\", \"updated_at\" = excluded.\"updated_at\"")
    end

    it "insert_all! emits a plain INSERT" do
      QxItem.__saci_bulk_sql(:insert_bang, "\"qx_items\"", ["sku"], 1, ["id"], false, :postgres)
        .should eq("INSERT INTO \"qx_items\" (\"sku\") VALUES (?)")
    end
  end

  describe "batching" do
    before_each do
      QxItem.insert_all((1..7).map { |i| {name: "n#{i}", sku: "s#{i}", qty: i, category: i.odd? ? "odd" : "even"} })
    end

    it "find_in_batches yields arrays in primary-key order" do
      sizes = [] of Int32
      seen = [] of Int32
      QxItem.find_in_batches(batch_size: 3) do |batch|
        sizes << batch.size
        seen.concat(batch.map(&.qty.not_nil!))
      end
      sizes.should eq([3, 3, 1])
      seen.should eq([1, 2, 3, 4, 5, 6, 7])
    end

    it "find_each yields every record, optionally starting at a primary key" do
      all = [] of String
      QxItem.find_each(batch_size: 2) { |item| all << item.sku.not_nil! }
      all.size.should eq(7)

      start_id = QxItem.order(:id).to_a[3].id.not_nil!
      tail = [] of String
      QxItem.find_each(batch_size: 2, start: start_id) { |item| tail << item.sku.not_nil! }
      tail.size.should eq(4)
      tail.first.should eq("s4")
    end

    it "in_batches yields relations supporting each_record, update_all, pluck, delete_all" do
      batch_sizes = [] of Int32
      QxItem.in_batches(batch_size: 3).each do |batch|
        batch_sizes << batch.to_a.size
        batch.pluck(:sku).size.should eq(batch.to_a.size)
      end
      batch_sizes.should eq([3, 3, 1])

      records = [] of Int32
      QxItem.in_batches(batch_size: 2).each_record { |item| records << item.qty.not_nil! }
      records.should eq([1, 2, 3, 4, 5, 6, 7])

      QxItem.in_batches(batch_size: 3).update_all(published: true).should eq(7_i64)
      QxItem.where(published: true).count.should eq(7_i64)

      QxItem.where(category: "odd").in_batches(batch_size: 2).delete_all.should eq(4_i64)
      QxItem.count.should eq(3_i64)
    end

    it "preserves custom order" do
      qty = QxItem.order(qty: :desc).in_batches(batch_size: 2).pluck(:qty)
      qty.map(&.as(Int64).to_i32).should eq([7, 6, 5, 4, 3, 2, 1])
    end

    it "honors a custom primary key" do
      QxCode.insert_all([
        {code: "c1", label: "one"},
        {code: "c2", label: "two"},
        {code: "c3", label: "three"},
      ])
      codes = [] of String
      QxCode.find_each(batch_size: 2) { |c| codes << c.code.not_nil! }
      codes.should eq(["c1", "c2", "c3"])
      QxCode.in_batches(batch_size: 2).pluck(:code).map(&.to_s).should eq(["c1", "c2", "c3"])
    end
  end

  # -- G27 relation depth ---------------------------------------------------

  describe "relation depth" do
    before_each do
      QxItem.insert_all([
        {name: "a", sku: "a", category: "red", qty: 1, published: true},
        {name: "b", sku: "b", category: "red", qty: 2, published: false},
        {name: "c", sku: "c", category: "blue", qty: 3, published: true},
      ])
    end

    it "none is a database-free empty relation" do
      n = QxItem.where(category: "red").none
      n.to_a.should be_empty
      n.count.should eq(0_i64)
      n.exists?.should be_false
      n.pluck(:id).should be_empty
      n.any?.should be_false
      n.one?.should be_false
      n.many?.should be_false
      n.none?.should be_true
      n.update_all(qty: 99).should eq(0_i64)
      n.delete_all.should eq(0_i64)
      n.explain.should contain("no SQL executed")
      QxItem.count.should eq(3_i64)
    end

    it "merge combines conditions and takes the other scope" do
      merged = QxItem.where(published: true).merge(QxItem.where(category: "red").order(qty: :desc))
      merged.pluck(:sku).map(&.to_s).should eq(["a"])
      merged.to_a.first.sku.should eq("a")
    end

    it "rewhere replaces conditions; unscope clears parts" do
      q = QxItem.where(category: "red").where(published: true)
      q.rewhere(category: "blue").count.should eq(1_i64)
      q.unscope(:where).count.should eq(3_i64)
      QxItem.order(qty: :desc).limit(1).unscope(:order, :limit).count.should eq(3_i64)
    end

    it "invert_where negates and and(...) ANDs another relation" do
      QxItem.where(category: "red").invert_where.pluck(:sku).map(&.to_s).should eq(["c"])
      QxItem.where(published: true).and(QxItem.where(category: "red")).pluck(:sku).map(&.to_s).should eq(["a"])
    end

    it "supports associated/missing/left joins" do
      g = QxGroup.create!(label: "g1")
      QxItem.where(sku: "a").update_all(qx_group_id: g.id)
      QxItem.joins(:qx_group).count.should eq(1_i64)
      QxItem.left_joins(:qx_group).count.should eq(3_i64)
      QxItem.left_outer_joins(:qx_group).count.should eq(3_i64)
      QxItem.associated(:qx_group).pluck(:sku).map(&.to_s).should eq(["a"])
      QxItem.missing(:qx_group_id).count.should eq(2_i64)
    end

    it "supports pick / ids / in_order_of / excluding" do
      QxItem.pick(:name).should eq("a")
      QxItem.pick(:id, :name).as(Array(Saci::Record::Value)).size.should eq(2)
      QxItem.ids.size.should eq(3)
      QxItem.order(:id).in_order_of(:qty, [3, 1]).pluck(:sku).map(&.to_s).should eq(["c", "a", "b"])
      two = QxItem.order(:id).limit(2).to_a
      QxItem.excluding(two).pluck(:sku).map(&.to_s).should eq(["c"])
    end

    it "supports from/reselect/regroup/annotate/readonly/lock/optimizer_hints/references" do
      QxItem.from("qx_items").where(published: true).count.should eq(2_i64)
      partial = QxItem.select(:id).reselect(:name).first.not_nil!
      partial.name.should_not be_nil
      partial.id.should be_nil
      QxItem.regroup(:category).to_a.size.should be >= 1
      QxItem.annotate("load all").explain(analyze: true).should contain("/* load all */")
      QxItem.readonly.lock.optimizer_hints("INDEX(qx_items idx)").references(:qx_group).to_a.size.should eq(3)
      QxItem.lock.explain.should_not contain("FOR UPDATE")
    end

    it "supports preload/eager_load/without as documented" do
      g = QxGroup.create!(label: "g2")
      QxItem.where(sku: "a").update_all(qx_group_id: g.id)
      preloaded = QxItem.preload(:qx_group).where(sku: "a").to_a
      preloaded.first.qx_group.not_nil!.label.should eq("g2")
      eager = QxItem.eager_load(:qx_group).to_a
      eager.size.should eq(1)
      eager.first.qx_group.not_nil!.label.should eq("g2")
      QxItem.includes(:qx_group).without(:qx_group).to_a.size.should eq(3)
    end

    it "supports having with grouped aggregates" do
      QxItem.insert_all([{name: "d", sku: "d", category: "red", qty: 4}])
      grouped = QxItem.group(:category).having("COUNT(*) > ?", 1)
      grouped.count["red"].should eq(3_i64)
    end

    it "supports find_or_create_by / find_or_initialize_by / create_or_find_by" do
      created = QxItem.find_or_create_by(sku: "new1")
      created.persisted?.should be_true
      QxItem.find_or_create_by(sku: "new1").id.should eq(created.id)

      initialized = QxItem.find_or_initialize_by(sku: "new2", name: "pending")
      initialized.persisted?.should be_false
      initialized.name.should eq("pending")
      QxItem.find_by(sku: "new2").should be_nil

      first = QxItem.find_or_create_by(sku: "race")
      second = QxItem.create_or_find_by(sku: "race")
      second.id.should eq(first.id)
      QxItem.where(sku: "race").count.should eq(1_i64)
    end

    it "supports sole / find_sole_by" do
      QxItem.find_sole_by(sku: "a").name.should eq("a")
      expect_raises(Saci::Record::RecordNotFound) { QxItem.find_sole_by(sku: "missing") }
      expect_raises(Saci::Record::SoleRecordExceeded) { QxItem.where(category: "red").sole }
    end
  end

  # -- G291/G292/G293 predicates, ids, ordinals -----------------------------

  describe "predicates, ids and ordinals" do
    before_each do
      QxItem.insert_all((1..4).map { |i| {name: "o#{i}", sku: "o#{i}", qty: i} })
    end

    it "answers any?/many?/one?/none? from SQL" do
      QxItem.any?.should be_true
      QxItem.many?.should be_true
      QxItem.one?.should be_false
      QxItem.none?.should be_false
      QxItem.where(sku: "o1").one?.should be_true
      QxItem.where(sku: "o1").many?.should be_false
      QxItem.where(sku: "nope").none?.should be_true
      QxItem.where(sku: "nope").any?.should be_false
    end

    it "ids returns primary keys without loading models" do
      QxItem.order(:id).ids.should eq(QxItem.order(:id).pluck(:id))
      QxItem.none.ids.should be_empty
    end

    it "supports ordinal finders" do
      QxItem.order(:id).second.not_nil!.sku.should eq("o2")
      QxItem.order(:id).third.not_nil!.sku.should eq("o3")
      QxItem.order(:id).fourth.not_nil!.sku.should eq("o4")
      QxItem.order(:id).fifth.should be_nil
      QxItem.order(:id).forty_two.should be_nil
      QxItem.order(:id).second_to_last.not_nil!.sku.should eq("o3")
      QxItem.order(:id).third_to_last.not_nil!.sku.should eq("o2")
      QxItem.order(:id).find_nth(1).not_nil!.sku.should eq("o2")
      QxItem.order(:id).take(2).size.should eq(2)
      QxItem.order(:id).last.not_nil!.sku.should eq("o4")
      QxItem.order(:id).last(2).map(&.sku).should eq(["o3", "o4"])
      QxItem.last.not_nil!.sku.should eq("o4")
    end
  end

  # -- G28 explain ----------------------------------------------------------

  describe "explain" do
    it "returns a readable SQLite query plan" do
      QxItem.insert_all([{name: "plan", sku: "plan"}])
      out = QxItem.where(sku: "plan").explain
      out.should contain("EXPLAIN QUERY PLAN")
      out.should contain("qx_items")
      out.should contain(" | ")
      QxItem.explain.should contain("EXPLAIN QUERY PLAN")
    end
  end

  # -- G233 dynamic finders -------------------------------------------------

  describe "define_finders" do
    it "generates find_by_<attr>, bang and find_or_initialize variants" do
      QxItem.insert_all([{name: "finder", sku: "f1"}])
      QxItem.find_by_sku("f1").not_nil!.name.should eq("finder")
      QxItem.find_by_name("finder").not_nil!.sku.should eq("f1")
      expect_raises(Saci::Record::RecordNotFound) { QxItem.find_by_sku!("missing") }
      fresh = QxItem.find_or_initialize_by_sku("f2")
      fresh.persisted?.should be_false
      fresh.sku.should eq("f2")
    end
  end

  # -- G311 dialect ---------------------------------------------------------

  describe "Dialect" do
    it "builds EXTRACT fragments per adapter" do
      Saci::Record::Dialect.extract(:year, "created_at", :mysql).should eq("EXTRACT(YEAR FROM created_at)")
      Saci::Record::Dialect.extract(:month, "created_at", :postgres).should eq("EXTRACT(MONTH FROM created_at)")
      Saci::Record::Dialect.extract(:year, "created_at", :sqlite).should eq("CAST(strftime('%Y', created_at) AS INTEGER)")
      Saci::Record::Dialect.extract(:quarter, "created_at", :sqlite).should contain("+ 2) / 3")
      expect_raises(ArgumentError) { Saci::Record::Dialect.extract(:fortnight, "created_at", :sqlite) }
    end

    it "builds TIMESTAMPDIFF fragments per adapter" do
      Saci::Record::Dialect.timestampdiff(:day, "a", "b", :mysql).should eq("TIMESTAMPDIFF(DAY, a, b)")
      Saci::Record::Dialect.timestampdiff(:hour, "a", "b", :sqlite).should contain("julianday")
      Saci::Record::Dialect.timestampdiff(:year, "a", "b", :postgres).should contain("age(b, a)")
      QxItem.insert_all([{name: "d1", sku: "d1"}])
      expr = Saci::Record::Dialect.extract(:year, "created_at", :sqlite)
      Saci::Record.scalar_compat(extras_db, "SELECT #{expr} FROM qx_items LIMIT 1").as(Int64).should eq(Time.utc.year.to_i64)
    end

    it "builds JSON_EXTRACT fragments per adapter" do
      Saci::Record::Dialect.json_extract("meta.color", "meta", :mysql).should eq("JSON_EXTRACT(meta, '$.meta.color')")
      Saci::Record::Dialect.json_extract("color", "meta", :sqlite).should eq("JSON_EXTRACT(meta, '$.color')")
      Saci::Record::Dialect.json_extract(["a", "b"], "doc", :postgres).should eq("doc #>> '{a,b}'")
    end

    it "builds CONVERT_TZ fragments per adapter" do
      Saci::Record::Dialect.convert_tz("created_at", "UTC", "America/Sao_Paulo", :mysql).should eq("CONVERT_TZ(created_at, 'UTC', 'America/Sao_Paulo')")
      Saci::Record::Dialect.convert_tz("created_at", "UTC", "UTC", :postgres).should contain("AT TIME ZONE 'UTC'")
      Saci::Record::Dialect.convert_tz("created_at", "UTC", "UTC", :sqlite).should eq("datetime(created_at)")
    end
  end
end
