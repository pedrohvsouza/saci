require "spec"
require "file"
require "../src/saci"

class CreateStiTables < Saci::Record::Migration
  def change
    create_table :sti_vehicles do |t|
      t.string :type
      t.string :name
      t.integer :doors
      t.integer :payload
    end
    create_table :sti_animals do |t|
      t.string :kind
      t.string :name
    end
    create_table :sti_plain_rows do |t|
      t.string :type
      t.string :name
    end
    create_table :sti_special_plain_rows do |t|
      t.string :type
      t.string :name
    end
  end
end

abstract class StiRecord < Saci::Record::Base
end

class StiVehicle < StiRecord
  column id : Int64, primary: true
  column type : String
  column name : String
  column doors : Int32

  validates :name, uniqueness: true

  def describe : String
    "vehicle #{name}"
  end
end

class StiCar < StiVehicle
  validates :doors, presence: true

  def describe : String
    "car #{name} (#{doors} doors)"
  end
end

class StiSportsCar < StiCar
end

class StiTruck < StiVehicle
  column payload : Int32
end

class StiAnimal < StiRecord
  inheritance_column :kind
  column id : Int64, primary: true
  column kind : String
  column name : String
end

class StiDog < StiAnimal
end

# A `type` column with STI turned off: the subclass keeps its own table.
class StiPlainRow < StiRecord
  inheritance_column nil
  column id : Int64, primary: true
  column type : String
  column name : String
end

class StiSpecialPlainRow < StiPlainRow
end

STI_DB_PATH = "/tmp/saci_record_sti_test_#{Process.pid}.db"

private def sti_db : DB::Database
  Saci::Record::Base.connection.as(DB::Database)
end

describe "Saci::Record single-table inheritance" do
  before_all do
    File.delete(STI_DB_PATH) if File.exists?(STI_DB_PATH)
    Saci::Record::Base.connection = DB.open("sqlite3://#{STI_DB_PATH}")
    Saci::Record::Migrator.migrate(sti_db, [CreateStiTables] of Saci::Record::Migration.class)
  end

  after_all do
    sti_db.close
    File.delete(STI_DB_PATH) if File.exists?(STI_DB_PATH)
  end

  before_each do
    StiVehicle.delete_all
    StiAnimal.delete_all
    StiPlainRow.delete_all
    StiSpecialPlainRow.delete_all
  end

  it "shares the base table and stores the class name in type" do
    StiCar.table_name.should eq("sti_vehicles")
    StiSportsCar.table_name.should eq("sti_vehicles")
    StiTruck.table_name.should eq("sti_vehicles")

    StiCar.new.type.should eq("StiCar")
    StiVehicle.new.type.should be_nil

    car = StiCar.create!(name: "Fusca", doors: 2)
    car.persisted?.should be_true
    sti_db.scalar("SELECT type FROM sti_vehicles WHERE id = ?", car.id).should eq("StiCar")
    StiVehicle.create!(name: "Carroça").type.should be_nil
  end

  it "loads each row as the class its type names" do
    StiVehicle.create!(name: "Carroça")
    StiCar.create!(name: "Fusca", doors: 2)
    StiSportsCar.create!(name: "Puma", doors: 2)
    StiTruck.create!(name: "FNM", payload: 9000)

    all = StiVehicle.order(:id).to_a
    all.map(&.class).should eq([StiVehicle, StiCar, StiSportsCar, StiTruck])
    all.map(&.describe).should eq(["vehicle Carroça", "car Fusca (2 doors)", "car Puma (2 doors)", "vehicle FNM"])
    all[3].as(StiTruck).payload.should eq(9000)

    StiVehicle.find(all[1].id).should be_a(StiCar)
    StiVehicle.find_by(name: "Puma").should be_a(StiSportsCar)
    StiVehicle.where(name: "FNM").first.should be_a(StiTruck)
  end

  it "scopes subclass queries to the subclass and its descendants" do
    StiVehicle.create!(name: "Carroça")
    StiCar.create!(name: "Fusca", doors: 2)
    StiSportsCar.create!(name: "Puma", doors: 2)
    truck = StiTruck.create!(name: "FNM", payload: 9000)

    StiVehicle.count.should eq(4)
    StiCar.count.should eq(2)
    StiCar.order(:id).to_a.map(&.name).should eq(["Fusca", "Puma"])
    StiSportsCar.all.to_a.map(&.name).should eq(["Puma"])
    StiTruck.pluck(:name).should eq(["FNM"] of Saci::Record::Value)
    StiCar.where(name: "FNM").exists?.should be_false
    expect_raises(Saci::Record::RecordNotFound) { StiCar.find(truck.id) }
    StiCar.sti_names.should eq(["StiCar", "StiSportsCar"])

    # The type filter is part of the base relation, so `unscoped` keeps it.
    StiCar.unscoped.count.should eq(2)
    StiVehicle.unscoped.count.should eq(4)

    StiCar.delete_all.should eq(2)
    StiVehicle.pluck(:name).sort_by(&.to_s).should eq(["Carroça", "FNM"] of Saci::Record::Value)
  end

  it "updates and destroys through the subclass" do
    car = StiCar.create!(name: "Fusca", doors: 2)
    loaded = StiVehicle.find(car.id).as(StiCar)
    loaded.doors = 4
    loaded.save.should be_true
    StiCar.find(car.id).doors.should eq(4)
    loaded.reload.doors.should eq(4)
    loaded.destroy
    StiVehicle.count.should eq(0)
  end

  it "runs subclass validations and checks uniqueness across the whole table" do
    StiCar.new(name: "Sem portas").valid?.should be_false
    StiVehicle.new(name: "Sem portas").valid?.should be_true

    StiTruck.create!(name: "Comum", payload: 1)
    car = StiCar.new(name: "Comum", doors: 2)
    car.valid?.should be_false
    car.errors["name"].should eq(["has already been taken"])
  end

  it "raises SubclassNotFound for an unknown type" do
    sti_db.exec("INSERT INTO sti_vehicles (type, name) VALUES ('Spaceship', 'X')")
    expect_raises(Saci::Record::SubclassNotFound, /Spaceship/) { StiVehicle.all.to_a }
  end

  it "rejects a type that is not a subclass of the queried class" do
    # A row tagged with another model's name, reached through a raw where.
    sti_db.exec("INSERT INTO sti_vehicles (type, name) VALUES ('StiDog', 'Rex')")
    expect_raises(Saci::Record::SubclassNotFound, /not a subclass of StiVehicle/) { StiVehicle.all.to_a }
  end

  it "honors a custom inheritance column" do
    StiDog.table_name.should eq("sti_animals")
    dog = StiDog.create!(name: "Rex")
    dog.kind.should eq("StiDog")
    StiAnimal.create!(name: "Mimi")
    StiAnimal.order(:id).to_a.map(&.class).should eq([StiDog, StiAnimal])
    StiDog.count.should eq(1)
  end

  it "leaves models alone when the inheritance column is turned off" do
    StiPlainRow.__saci_sti?.should be_false
    StiSpecialPlainRow.table_name.should eq("sti_special_plain_rows")
    StiPlainRow.create!(type: "anything", name: "a")
    StiPlainRow.all.to_a.first.class.should eq(StiPlainRow)
    StiSpecialPlainRow.new.type.should be_nil
  end
end
