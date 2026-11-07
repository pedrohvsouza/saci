require "spec"
require "file"
require "../src/saci"

class CreateCoreProducts < Saci::Record::Migration
  def change
    create_table :core_products do |t|
      t.string :name
      t.decimal :price, precision: 15, scale: 2
      t.decimal :fee, default: 1.25
      t.integer :stock, default: 0
      t.boolean :active, default: false
      t.integer :status, default: 0
      t.json :meta
      t.string_array :tags
      t.date :released_on
      t.timestamps
    end
  end
end

# Alias/qualified-type coverage: `Decimal`, `Saci::Record::Decimal` and
# `BigDecimal` all map to the exact BigDecimal-backed column.
class CoreLedger < Saci::Record::Base
  column id : Int64, primary: true
  column amount : Saci::Record::Decimal
  column other : BigDecimal
end

class CoreProduct < Saci::Record::Base
  column id : Int64, primary: true
  column name : String
  column price : Decimal
  column fee : Decimal
  column stock : Int32, default: 0
  column active : Bool, default: false
  column status : Int32, default: 0
  column meta : JSON
  column tags : Array(String)
  column released_on : Date
  timestamps

  validates :name, presence: true

  model_enum status: {draft: 0, live: 1}

  @__saci_callback_count : Int32 = 0

  def save_callback_count : Int32
    @__saci_callback_count
  end

  before_save { @__saci_callback_count += 1 }
end

ORM_CORE_DB_PATH = "/tmp/opencode/saci_orm_core_test.db"

def core_db : DB::Database
  Saci::Record::Base.connection.as(DB::Database)
end

describe "Saci::Record ORM core gaps" do
  before_all do
    File.delete(ORM_CORE_DB_PATH) if File.exists?(ORM_CORE_DB_PATH)
    Saci::Record::Base.connection = DB.open("sqlite3://#{ORM_CORE_DB_PATH}")
    Saci::Record::Migrator.migrate(core_db, [CreateCoreProducts] of Saci::Record::Migration.class)
  end

  after_all do
    core_db.close
  end

  describe "dirty tracking (G10)" do
    it "tracks mass-assignment changes until save" do
      p = CoreProduct.new(name: "Widget")
      p.changed?.should be_true
      p.changed.should eq(["name"])
      p.changed_attributes["name"].should be_nil
      p.name_changed?.should be_true
      p.name_was.should be_nil
      p.will_save_change_to_name?.should be_true
      p.name_change.should eq([nil, "Widget"])
      p.changes_to_save.should eq(p.changes)
      p.has_changes_to_save?.should be_true
      p.previous_changes.should be_empty
      p.saved_changes?.should be_false
      p.saved_change_to_name?.should be_false
      # No prior save: `previously_was` falls back to the current value.
      p.name_previously_was.should eq("Widget")
    end

    it "snapshots after create and keeps previous_changes until the next save" do
      p = CoreProduct.create!(name: "Created", price: BigDecimal.new("10.25"))
      p.changed?.should be_false
      p.changes.should be_empty
      p.saved_changes?.should be_true
      p.previous_changes["name"][0].should be_nil
      p.previous_changes["name"][1].should eq("Created")
      p.saved_changes["name"][1].should eq("Created")
      p.saved_change_to_name?.should be_true
      p.saved_change_to_name.should eq([nil, "Created"])
      p.name_previously_was.should be_nil
      p.attribute_before_last_save("name").should be_nil
      p.previously_new_record?.should be_true
      p.previously_persisted?.should be_false

      p.name = "Updated"
      p.changed?.should be_true
      # previous_changes still describes the create until the next save.
      p.saved_change_to_name.should eq([nil, "Created"])
      p.previous_changes["name"][1].should eq("Created")
      p.save.should be_true

      p.changed?.should be_false
      p.previous_changes["name"].should eq(["Created", "Updated"])
      p.name_was.should eq("Updated")
      p.name_previously_was.should eq("Created")
      p.name_previously_was.should eq("Created")
      p.attribute_before_last_save("name").should eq("Created")
      p.previously_new_record?.should be_false
      p.previously_persisted?.should be_true
    end

    it "assigning an equal value stays clean, including explicit attribute=" do
      p = CoreProduct.create!(name: "Stable")
      p.name = p.name
      p.name_changed?.should be_false
      p.changed?.should be_false

      p.assign({name: "Stable"})
      p.name_changed?.should be_false

      p.name = "Different"
      p.name_changed?.should be_true
      p.name = "Stable"
      p.name_changed?.should be_false
      p.changed?.should be_false
      p.changes.should be_empty
    end

    it "does not commit changes on failed validation and keeps previous_changes" do
      p = CoreProduct.create!(name: "Original")
      p.name = ""
      p.save.should be_false
      p.changed?.should be_true
      p.name_changed?.should be_true
      p.name_change.should eq(["Original", ""])
      p.previous_changes["name"].should eq([nil, "Original"])
      p.saved_change_to_name?.should be_true
      p.name_previously_was.should be_nil

      p.save.should be_false
      p.changed?.should be_true
      p.previous_changes["name"].should eq([nil, "Original"])

      p.name = "Fixed"
      p.save.should be_true
      p.previous_changes["name"].should eq(["Original", "Fixed"])
      p.changed?.should be_false
    end

    it "clears changes and previous_changes on reload" do
      p = CoreProduct.create!(name: "Reloadable")
      p.name = "Unsaved"
      p.changed?.should be_true
      p.saved_changes?.should be_true

      p.reload
      p.changed?.should be_false
      p.previous_changes.should be_empty
      p.saved_changes?.should be_false
      p.name.should eq("Reloadable")
      p.previously_new_record?.should be_false
      p.previously_persisted?.should be_true
    end

    it "tracks Decimal, Date, JSON and array attributes" do
      p = CoreProduct.create!(name: "Types")
      p.price = BigDecimal.new("0.1") + BigDecimal.new("0.2")
      p.released_on = Time.utc(2024, 6, 1)
      p.meta_json = JSON.parse(%({"a":[1,2]}))
      p.tags = ["one", "two"]

      p.price_changed?.should be_true
      p.price_was.should be_nil
      p.released_on_changed?.should be_true
      p.meta_changed?.should be_true
      p.tags_changed?.should be_true
      p.tags_change.should eq([nil, ["one", "two"]])

      p.save.should be_true
      p.reload
      p.price.not_nil!.to_s.should eq("0.3")
      p.released_on.not_nil!.year.should eq(2024)
      p.meta_json.not_nil!["a"][1].should eq(2)
      p.tags.should eq(["one", "two"])
    end
  end

  describe "exact decimal (G297)" do
    it "uses TEXT_DECIMAL on SQLite and native NUMERIC/DECIMAL elsewhere" do
      type = core_db.scalar(
        "SELECT type FROM pragma_table_info('core_products') WHERE name = 'price'"
      ).as(String)
      type.should eq("TEXT_DECIMAL")

      Saci::Record.db_type(:decimal, :sqlite).should eq("TEXT_DECIMAL")
      Saci::Record.db_type(:decimal, :postgres).should eq("NUMERIC(38,18)")
      Saci::Record.db_type(:decimal, :mysql).should eq("DECIMAL(38,18)")
      Saci::Record.db_type(:decimal, :postgres, precision: 15, scale: 2).should eq("NUMERIC(15,2)")
      Saci::Record.db_type(:decimal, :mysql, precision: 15, scale: 2).should eq("DECIMAL(15,2)")
    end

    it "round-trips 0.1 + 0.2 and large money values exactly" do
      p = CoreProduct.create!(name: "Money")
      p.price = BigDecimal.new("0.1") + BigDecimal.new("0.2")
      p.save.should be_true

      raw = core_db.scalar(
        "SELECT price FROM core_products WHERE id = ?", p.id.not_nil!
      ).as(String)
      raw.should eq("0.3")
      CoreProduct.find(p.id.not_nil!).price.not_nil!.to_s.should eq("0.3")

      big = BigDecimal.new("123456789012345.67")
      p.price = big
      p.save.should be_true
      raw = core_db.scalar(
        "SELECT price FROM core_products WHERE id = ?", p.id.not_nil!
      ).as(String)
      raw.should eq("123456789012345.67")

      loaded = CoreProduct.find(p.id.not_nil!)
      loaded.price.should eq(big)
      loaded.price.not_nil!.to_s.should eq("123456789012345.67")
    end

    it "accepts Float/Int input and DB decimal defaults" do
      p = CoreProduct.create!(name: "Float input", price: 12.5)
      p.price.should be_a(BigDecimal)
      p.price.should eq(12.5)
      p.fee.should be_nil # not loaded yet: insert skipped the nil column

      p.reload
      p.price.not_nil!.to_s.should eq("12.5")
      p.fee.not_nil!.to_s.should eq("1.25")

      p.price = 7
      p.price.not_nil!.to_s.should eq("7.0")
    end

    it "supports Decimal alias, qualified Decimal and BigDecimal column types" do
      l = CoreLedger.new(amount: BigDecimal.new("1.50"), other: 2.25)
      l.amount.should be_a(BigDecimal)
      l.other.should be_a(BigDecimal)
      l.amount.not_nil!.to_s.should eq("1.5")
      l.other.not_nil!.to_s.should eq("2.25")
      l.amount = 4
      l.amount.not_nil!.to_s.should eq("4.0")
      CoreLedger.__saci_column_names.map(&.[1]).should eq(["Int64", "Decimal", "Decimal"])
    end

    it "introspects TEXT_DECIMAL as :decimal in schema dumps" do
      tables = Saci::Record::Schema.introspect(core_db)
      products = tables.find! { |t| t.name == "core_products" }
      price = products.columns.find! { |c| c.name == "price" }
      price.logical_type.should eq(:decimal)
      fee = products.columns.find! { |c| c.name == "fee" }
      fee.logical_type.should eq(:decimal)
      fee.default_value.should eq(BigDecimal.new("1.25"))

      dump = Saci::Record::Schema.dump(core_db, "sqlite3://#{ORM_CORE_DB_PATH}")
      dump.should contain(":decimal")
      dump.should contain("BigDecimal.new(\"1.25\")")

      fresh_path = "/tmp/opencode/saci_orm_core_schema.db"
      File.delete(fresh_path) if File.exists?(fresh_path)
      fresh = DB.open("sqlite3://#{fresh_path}")
      begin
        Saci::Record::Schema.load(fresh, tables)
        reloaded = Saci::Record::Schema.introspect(fresh)
        reloaded_products = reloaded.find! { |t| t.name == "core_products" }
        reloaded_products.columns.find! { |c| c.name == "price" }.logical_type.should eq(:decimal)
        reloaded_products.columns.find! { |c| c.name == "fee" }.default_value.should eq(BigDecimal.new("1.25"))
        dump_body = dump.lines.reject(&.starts_with?("# db/schema.cr")).join
        redump_body = Saci::Record::Schema.dump(fresh, "sqlite3://#{ORM_CORE_DB_PATH}")
          .lines.reject(&.starts_with?("# db/schema.cr")).join
        redump_body.should eq(dump_body)
      ensure
        fresh.close
        File.delete(fresh_path) if File.exists?(fresh_path)
      end
    end
  end

  describe "assigned timestamps (G299)" do
    it "preserves explicit created_at/updated_at on create" do
      created = Time.utc(2020, 1, 2, 3, 4, 5)
      updated = Time.utc(2021, 2, 3, 4, 5, 6)

      p = CoreProduct.create!(name: "Assigned", created_at: created, updated_at: updated)
      p.reload.created_at.should eq(created)
      p.reload.updated_at.should eq(updated)
    end

    it "fills only the missing timestamp on create" do
      created = Time.utc(2020, 5, 6, 7, 8, 9)
      p = CoreProduct.create!(name: "Half", created_at: created)
      p.reload.created_at.should eq(created)
      p.reload.updated_at.not_nil!.year.should eq(Time.utc.year)

      updated = Time.utc(2022, 7, 8, 9, 10, 11)
      q = CoreProduct.create!(name: "Other half", updated_at: updated)
      q.reload.updated_at.should eq(updated)
      q.reload.created_at.not_nil!.year.should eq(Time.utc.year)
    end

    it "does not overwrite explicitly assigned updated_at on update" do
      p = CoreProduct.create!(name: "Updatable")
      original_created = p.created_at

      explicit = Time.utc(2019, 9, 9, 9, 9, 9)
      p.name = "Changed"
      p.updated_at = explicit
      p.save.should be_true
      p.reload.updated_at.should eq(explicit)
      p.created_at.not_nil!.to_unix.should eq(original_created.not_nil!.to_unix)

      p.update!(name: "Bumped")
      p.reload.updated_at.not_nil!.year.should eq(Time.utc.year)
      p.reload.updated_at.not_nil!.should be > explicit
    end
  end

  describe "persistence helpers (G294)" do
    it "update_attribute skips validations but runs callbacks" do
      p = CoreProduct.create!(name: "Valid")
      before = p.save_callback_count

      p.update_attribute(:name, "").should be_true
      p.name.should eq("")
      p.save_callback_count.should eq(before + 1)
      p.reload.name.should eq("")

      expect_raises(Saci::Record::UnknownAttributeError) do
        p.update_attribute(:bogus, "x")
      end
    end

    it "update_column skips validations/callbacks and cleans dirty state" do
      p = CoreProduct.create!(name: "Column")
      before = p.save_callback_count

      p.update_column(:name, "Direct").should be_true
      p.name.should eq("Direct")
      p.name_changed?.should be_false
      p.changed?.should be_false
      p.save_callback_count.should eq(before)
      p.reload.name.should eq("Direct")

      expect_raises(Saci::Record::RecordNotSaved) do
        CoreProduct.new(name: "New").update_column(:name, "x")
      end
      expect_raises(ArgumentError) { p.update_column(:id, 99_i64) }
    end

    it "keeps update_columns working and clean" do
      p = CoreProduct.create!(name: "Columns")
      p.update_columns({name: "Bulk", stock: 4}).should be_true
      p.name.should eq("Bulk")
      p.stock.should eq(4)
      p.changed?.should be_false
      p.reload.name.should eq("Bulk")
    end

    it "increments, decrements and toggles" do
      p = CoreProduct.create!(name: "Counters", stock: 2, active: false)
      p.increment!(:stock, 3).should be(p)
      p.stock.should eq(5)
      p.reload.stock.should eq(5)

      p.decrement!(:stock, 2)
      p.reload.stock.should eq(3)

      p.increment!(:price, 5)
      p.reload.price.not_nil!.to_s.should eq("5.0")

      p.toggle!(:active)
      p.reload.active.should be_true
      p.toggle!(:active)
      p.reload.active.should be_false
    end

    it "destroy! returns self or raises" do
      p = CoreProduct.create!(name: "Doomed")
      p.destroy!.should be(p)
      p.destroyed?.should be_true
      expect_raises(Saci::Record::RecordNotDestroyed) { p.destroy! }
      expect_raises(Saci::Record::RecordNotDestroyed) do
        CoreProduct.new(name: "Never saved").destroy!
      end
    end

    it "tracks previously_new_record? / previously_persisted?" do
      p = CoreProduct.create!(name: "Lifecycle")
      p.previously_new_record?.should be_true
      p.previously_persisted?.should be_false

      p.update!(name: "Lifecycle 2")
      p.previously_new_record?.should be_false
      p.previously_persisted?.should be_true

      p.reload
      p.previously_new_record?.should be_false
      p.previously_persisted?.should be_true
    end
  end

  describe "model enum (G13)" do
    it "generates predicates, bang methods, status_value and a class hash" do
      p = CoreProduct.new(name: "Enum")
      p.status.should eq(0)
      p.draft?.should be_true
      p.live?.should be_false
      p.status_value.should eq(0)

      CoreProduct.statuses.should eq(
        {"draft" => 0, "live" => 1} of String => Saci::Record::Value
      )

      p.live!.should be(p)
      p.persisted?.should be_true
      p.live?.should be_true
      p.draft?.should be_false
      p.status_value.should eq(1)
      p.reload.status.should eq(1)
    end

    it "generates scopes and an inclusion validation" do
      live = CoreProduct.create!(name: "Live", status: 1)
      draft = CoreProduct.create!(name: "Draft", status: 0)

      CoreProduct.live.to_a.map(&.id).should contain(live.id)
      CoreProduct.live.to_a.map(&.id).should_not contain(draft.id)
      CoreProduct.draft.to_a.map(&.id).should contain(draft.id)

      live.status = 99
      live.valid?.should be_false
      live.errors["status"].should contain("is not included in the list")
      live.status = 1
      live.valid?.should be_true
    end
  end
end
