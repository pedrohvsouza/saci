require "spec"
require "file_utils"
require "../src/saci"

MULTI_PRIMARY   = "/tmp/opencode/saci_multi_primary.db"
MULTI_ANALYTICS = "/tmp/opencode/saci_multi_analytics.db"

class MultiUser < Saci::Record::Base
  column id : Int64, primary: true
  column name : String
end

class MultiEvent < Saci::Record::Base
  connects_to database: "analytics"

  column id : Int64, primary: true
  column name : String
end

class MultiThing < Saci::Record::Base
  column id : Int64, primary: true
  column name : String
end

describe "multidatabase" do
  before_all do
    [MULTI_PRIMARY, MULTI_ANALYTICS].each do |path|
      File.delete(path) if File.exists?(path)
    end
    Saci::Record::Base.connection = DB.open("sqlite3://#{MULTI_PRIMARY}")
    Saci::Record.establish_connection("analytics", "sqlite3://#{MULTI_ANALYTICS}")
    Saci::Record.database("primary").exec(
      "CREATE TABLE \"#{MultiUser.table_name}\" (\"id\" INTEGER PRIMARY KEY AUTOINCREMENT, \"name\" TEXT)"
    )
    Saci::Record.database("primary").exec(
      "CREATE TABLE \"#{MultiThing.table_name}\" (\"id\" INTEGER PRIMARY KEY AUTOINCREMENT, \"name\" TEXT)"
    )
    Saci::Record.database("analytics").exec(
      "CREATE TABLE \"#{MultiEvent.table_name}\" (\"id\" INTEGER PRIMARY KEY AUTOINCREMENT, \"name\" TEXT)"
    )
    Saci::Record.database("analytics").exec(
      "CREATE TABLE \"#{MultiThing.table_name}\" (\"id\" INTEGER PRIMARY KEY AUTOINCREMENT, \"name\" TEXT)"
    )
  end

  after_all do
    Saci::Record.database("primary").close
    Saci::Record.database("analytics").close
  end

  before_each do
    MultiUser.delete_all
    MultiEvent.delete_all
    Saci::Record.connected_to("primary") { MultiThing.delete_all }
    Saci::Record.connected_to("analytics") { MultiThing.delete_all }
  end

  it "registers named databases" do
    Saci::Record.configuration_names.sort.should eq(["analytics", "primary"])
    expect_raises(Exception, /nknown database/) do
      Saci::Record.database("nope")
    end
  end

  it "isolates connects_to models on their database" do
    MultiUser.create!(name: "u1")
    MultiEvent.create!(name: "e1")
    MultiUser.count.should eq(1)
    MultiEvent.count.should eq(1)
    Saci::Record.database("primary").scalar("SELECT COUNT(*) FROM sqlite_master WHERE name = ?", MultiEvent.table_name).should eq(0)
    Saci::Record.database("analytics").scalar("SELECT COUNT(*) FROM sqlite_master WHERE name = ?", MultiUser.table_name).should eq(0)
  end

  it "routes default models via connected_to blocks" do
    MultiThing.create!(name: "in-primary")
    Saci::Record.connected_to("analytics") do
      MultiThing.create!(name: "in-analytics")
      MultiThing.count.should eq(1)
      Saci::Record.current_database_name.should eq("analytics")
    end
    Saci::Record.current_database_name.should eq("primary")
    MultiThing.count.should eq(1)
    MultiThing.first.not_nil!.name.should eq("in-primary")
  end

  it "rejects unknown databases in connected_to" do
    expect_raises(Exception, /nknown database/) do
      Saci::Record.connected_to("nope") { }
    end
  end

  it "uses per-model transactions on the right database" do
    MultiEvent.transaction do
      MultiEvent.create!(name: "tx-event")
      raise DB::Rollback.new
    end
    MultiEvent.count.should eq(0)

    MultiUser.transaction do
      MultiUser.create!(name: "tx-user")
    end
    MultiUser.count.should eq(1)
  end
end
