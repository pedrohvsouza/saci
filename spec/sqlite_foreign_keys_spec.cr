require "spec"
require "../src/saci"

SQLITE_FK_DIR = "/tmp/opencode"

class SqliteFkCreateNodes < Saci::Record::Migration
  def change
    create_table :fkx_nodes do |t|
      t.string :name
      t.references :parent, foreign_key: :fkx_nodes, on_delete: :restrict
    end
  end
end

class SqliteFkCreateOwners < Saci::Record::Migration
  def change
    create_table :fkx_owners do |t|
      t.string :name
    end
  end
end

class SqliteFkCreatePets < Saci::Record::Migration
  def change
    create_table :fkx_pets do |t|
      t.string :name
      t.references :owner, foreign_key: :fkx_owners, on_delete: :cascade
    end
  end
end

class SqliteFkOwnerNameNotNull < Saci::Record::Migration
  def change
    change_column_null :fkx_owners, :name, false
  end
end

class SqliteFkOrphan < Saci::Record::Migration
  def up
    execute %(INSERT INTO "fkx_pets" ("name", "owner_id") VALUES ('stray', 42))
  end
end

class SqliteFkBroken < Saci::Record::Migration
  def up
    create_table :fkx_half do |t|
      t.string :name
    end
    execute "INSERT INTO nope_missing_table VALUES (1)"
  end
end

private def sqlite_fk_open(name : String, query : String = "") : DB::Database
  path = "#{SQLITE_FK_DIR}/saci_fk_#{name}.db"
  Dir.mkdir_p(SQLITE_FK_DIR)
  File.delete(path) if File.exists?(path)
  Saci::Record.establish_connection("fk_#{name}", "sqlite3://#{path}#{query}")
end

private def sqlite_fk_close(name : String) : Nil
  Saci::Record.remove_connection("fk_#{name}")
  File.delete("#{SQLITE_FK_DIR}/saci_fk_#{name}.db") if File.exists?("#{SQLITE_FK_DIR}/saci_fk_#{name}.db")
end

private def fk_pragma(conn : DB::Database | DB::Connection) : Int64
  conn.scalar("PRAGMA foreign_keys").as(Int64)
end

describe "SQLite foreign keys" do
  it "enforces foreign keys on every pooled connection by default" do
    db = sqlite_fk_open("default", "?initial_pool_size=1&max_pool_size=3")
    begin
      # Hold several connections at once so the pool opens new ones after
      # the tuning was installed.
      conns = Array.new(3) { db.pool.checkout }
      conns.each { |c| fk_pragma(c).should eq(1) }
      conns.each(&.release)

      Saci::Record::Migrator.migrate(db, [SqliteFkCreateOwners, SqliteFkCreatePets] of Saci::Record::Migration.class)
      expect_raises(Exception, /FOREIGN KEY constraint failed/) do
        db.exec(%(INSERT INTO "fkx_pets" ("name", "owner_id") VALUES ('rex', 999)))
      end
    ensure
      sqlite_fk_close("default")
    end
  end

  it "can be disabled with Record.sqlite_foreign_keys = false" do
    Saci::Record.sqlite_foreign_keys = false
    begin
      db = sqlite_fk_open("optout")
      fk_pragma(db).should eq(0)
    ensure
      Saci::Record.sqlite_foreign_keys = true
      sqlite_fk_close("optout")
    end
  end

  it "respects an explicit foreign_keys URL param" do
    db = sqlite_fk_open("urloff", "?foreign_keys=off&initial_pool_size=2")
    begin
      conns = Array.new(2) { db.pool.checkout }
      conns.each { |c| fk_pragma(c).should eq(0) }
      conns.each(&.release)
    ensure
      sqlite_fk_close("urloff")
    end
  end

  it "rolls back a self-referencing RESTRICT table that holds data" do
    db = sqlite_fk_open("selfref")
    begin
      migrations = [SqliteFkCreateNodes] of Saci::Record::Migration.class
      Saci::Record::Migrator.migrate(db, migrations)
      db.exec(%(INSERT INTO "fkx_nodes" ("id", "name", "parent_id") VALUES (1, 'root', NULL)))
      db.exec(%(INSERT INTO "fkx_nodes" ("id", "name", "parent_id") VALUES (2, 'child', 1)))
      db.exec(%(INSERT INTO "fkx_nodes" ("id", "name", "parent_id") VALUES (3, 'grandchild', 2)))
      expect_raises(Exception, /FOREIGN KEY constraint failed/) do
        db.exec(%(DELETE FROM "fkx_nodes" WHERE "id" = 1))
      end

      Saci::Record::Migrator.rollback(db, migrations).should eq(["SqliteFkCreateNodes"])
      Saci::Record::Introspection.table_exists?(db, "fkx_nodes").should be_false
      Saci::Record::Migrator.applied_names(db).should be_empty
    ensure
      sqlite_fk_close("selfref")
    end
  end

  it "defers foreign keys when migrating inside an open transaction" do
    db = sqlite_fk_open("nested")
    begin
      migrations = [SqliteFkCreateNodes] of Saci::Record::Migration.class
      Saci::Record::Migrator.migrate(db, migrations)
      db.exec(%(INSERT INTO "fkx_nodes" ("id", "name", "parent_id") VALUES (1, 'root', NULL)))
      db.exec(%(INSERT INTO "fkx_nodes" ("id", "name", "parent_id") VALUES (2, 'child', 1)))
      Saci::Record.transaction_on(db) do |conn|
        fk_pragma(conn).should eq(1)
        Saci::Record::Migrator.rollback(db, migrations).should eq(["SqliteFkCreateNodes"])
      end
      Saci::Record::Introspection.table_exists?(db, "fkx_nodes").should be_false
    ensure
      sqlite_fk_close("nested")
    end
  end

  it "rolls back a migration that leaves foreign key violations" do
    db = sqlite_fk_open("orphan")
    begin
      Saci::Record::Migrator.migrate(db, [SqliteFkCreateOwners, SqliteFkCreatePets] of Saci::Record::Migration.class)
      expect_raises(Exception, /foreign key violations: fkx_pets/) do
        Saci::Record::Migrator.migrate(db, [SqliteFkOrphan] of Saci::Record::Migration.class)
      end
      db.scalar(%(SELECT COUNT(*) FROM "fkx_pets")).should eq(0)
      Saci::Record::Migrator.applied_names(db).should_not contain("SqliteFkOrphan")
      fk_pragma(db).should eq(1)
    ensure
      sqlite_fk_close("orphan")
    end
  end

  it "keeps cascading children when a SQLite table rebuild drops the parent" do
    db = sqlite_fk_open("rebuild", "?max_pool_size=1")
    begin
      Saci::Record::Migrator.migrate(db, [SqliteFkCreateOwners, SqliteFkCreatePets] of Saci::Record::Migration.class)
      db.exec(%(INSERT INTO "fkx_owners" ("id", "name") VALUES (1, 'ann')))
      db.exec(%(INSERT INTO "fkx_pets" ("name", "owner_id") VALUES ('rex', 1)))

      Saci::Record::Migrator.migrate(db, [SqliteFkOwnerNameNotNull] of Saci::Record::Migration.class)
      db.scalar(%(SELECT COUNT(*) FROM "fkx_pets")).should eq(1)
      db.scalar(%(SELECT COUNT(*) FROM "fkx_owners")).should eq(1)
      # Re-enabled on the (only) connection the migration used.
      fk_pragma(db).should eq(1)
      expect_raises(Exception, /FOREIGN KEY constraint failed/) do
        db.exec(%(INSERT INTO "fkx_pets" ("name", "owner_id") VALUES ('ghost', 999)))
      end
    ensure
      sqlite_fk_close("rebuild")
    end
  end

  it "runs each migration in a transaction" do
    db = sqlite_fk_open("atomic")
    begin
      expect_raises(Exception, /no such table/) do
        Saci::Record::Migrator.migrate(db, [SqliteFkBroken] of Saci::Record::Migration.class)
      end
      Saci::Record::Introspection.table_exists?(db, "fkx_half").should be_false
      Saci::Record::Migrator.applied_names(db).should be_empty
    ensure
      sqlite_fk_close("atomic")
    end
  end
end
