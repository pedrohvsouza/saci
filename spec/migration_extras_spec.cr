require "spec"
require "file"
require "../src/saci"

# Migration DSL depth, column helpers, idempotent DDL, PG concurrency,
# introspection, UUID/native types, views/checks/generated columns.
# Everything executes on SQLite; PostgreSQL/MySQL assertions cover the
# generated SQL strings (no live servers in this environment).

# -- fixtures ---------------------------------------------------------------

def with_mx_db(& : DB::Database -> T) : T forall T
  path = File.join("/tmp/opencode", "saci_mx_#{Random.rand(1_000_000_000)}.db")
  File.delete(path) if File.exists?(path)
  db = DB.open("sqlite3://#{path}")
  begin
    yield db
  ensure
    begin
      db.close
    rescue SQLite3::Exception
      # crystal-sqlite3 sticky-error quirk (see spec/schema_spec.cr).
    end
    File.delete(path) if File.exists?(path)
  end
end

def mx_col(db : DB::Database, table : String, column : String) : Saci::Record::Introspection::ColumnInfo
  Saci::Record::Introspection.columns(db, table).find! { |c| c.name == column }
end

# -- migration classes ------------------------------------------------------

class MxExecute < Saci::Record::Migration
  def change
    execute "CREATE TABLE mx_raw (id INTEGER PRIMARY KEY, name TEXT)"
  end
end

class MxReversible < Saci::Record::Migration
  def change
    create_table :mx_rv do |t|
      t.string :name
    end
    reversible do |dir|
      dir.up { execute "INSERT INTO mx_rv (name) VALUES ('up')" }
      dir.down { execute "DELETE FROM mx_rv WHERE name = 'up'" }
    end
  end
end

class MxReversibleNoDown < Saci::Record::Migration
  def change
    reversible do |dir|
      dir.up { execute "CREATE TABLE mx_rv_bad (id INTEGER)" }
    end
  end
end

class MxChangeTableAdd < Saci::Record::Migration
  def change
    change_table :mx_ct do |t|
      t.column :body, :text
      t.rename :title, :headline
      t.index :headline
    end
  end
end

class MxChangeTableRemove < Saci::Record::Migration
  def change
    create_table :mx_ct_rm do |t|
      t.string :legacy
      t.string :keep
    end
    add_index :mx_ct_rm, :legacy
    change_table :mx_ct_rm do |t|
      t.remove_index :index_mx_ct_rm_on_legacy
      t.remove :legacy
    end
  end
end

class MxRevertTarget < Saci::Record::Migration
  def change
    add_column :mx_rv_target, :extra, :string
  end
end

class MxRevertUser < Saci::Record::Migration
  def change
    revert MxRevertTarget
  end
end

class MxRevertBlock < Saci::Record::Migration
  def change
    revert do
      add_column :mx_rv_target, :block_col, :string
    end
  end
end

class MxNoDdlTx < Saci::Record::Migration
  disable_ddl_transaction!

  def change
  end
end

class MxIdempotent < Saci::Record::Migration
  def change
    create_table :mx_idem, if_not_exists: true do |t|
      t.string :name
    end
    add_column :mx_idem, :nick, :string, if_not_exists: true
    add_index :mx_idem, :name, if_not_exists: true
    drop_column :mx_idem, :missing, if_exists: true
    remove_index :mx_idem, :index_mx_idem_on_nick, if_exists: true
  end
end

class MxCreateCols < Saci::Record::Migration
  def change
    create_table :mx_cols do |t|
      t.string :name
      t.integer :count, default: 3
    end
    add_index :mx_cols, :name
    create_table :mx_cols_checked do |t|
      t.integer :price
      t.check_constraint "price >= 0", name: "price_non_negative"
      t.index :price
    end
  end
end

class MxDefaultChange < Saci::Record::Migration
  def change
    change_column_default :mx_cols, :count, 7, from: 3
  end
end

class MxGenerated < Saci::Record::Migration
  def change
    create_table :mx_gen do |t|
      t.integer :a
      t.integer :b
      t.virtual :total, type: :integer, expression: "a + b", stored: true
    end
  end
end

class MxViews < Saci::Record::Migration
  def change
    create_table :mx_view_src do |t|
      t.string :name
    end
    create_view :mx_names, "SELECT name FROM mx_view_src"
  end
end

class MxRefs < Saci::Record::Migration
  def change
    create_table :mx_ref_users do |t|
      t.string :name
    end
    create_table :mx_ref_posts do |t|
      t.string :title
    end
    add_reference :mx_ref_posts, :user, index: true
    add_reference :mx_ref_posts, :owner, polymorphic: true, index: true
  end
end

class MxJoin < Saci::Record::Migration
  def change
    create_join_table :mx_products, :mx_categories
  end
end

class MxIntro < Saci::Record::Migration
  def change
    create_table :mx_intro_parents do |t|
      t.string :name
    end
    create_table :mx_intro_children do |t|
      t.integer :parent_id
      t.string :label
      t.check_constraint "length(label) > 0", name: "label_present"
      t.foreign_key :mx_intro_parents, column: :parent_id, on_delete: :cascade
    end
    add_index :mx_intro_children, :label, unique: true
    create_view :mx_intro_view, "SELECT label FROM mx_intro_children"
  end
end

class MxUuidPk < Saci::Record::Migration
  def change
    create_table :mx_uuid_pk, id: :uuid do |t|
      t.string :name
    end
  end
end

class MxNative < Saci::Record::Migration
  def change
    create_table :mx_native do |t|
      t.uuid :token
      t.binary :payload
      t.hstore :attrs
      t.inet :ip
      t.cidr :net
      t.macaddr :mac
      t.interval :dur
      t.money :price
      t.bit :flag, size: 8
      t.bit_varying :bits, size: 16
      t.point :where
      t.range :span, subtype: :int4
      t.xml :doc
      t.oid :obj
      t.virtual :label, type: :string, expression: "'x' || token", stored: true
    end
  end
end

class MxSchemaTypes < Saci::Record::Migration
  def change
    create_table :mx_schema_types, id: :uuid do |t|
      t.string :name
      t.binary :payload
      t.virtual :label, type: :string, expression: "'x' || name", stored: true
      t.check_constraint "name IS NOT NULL", name: "name_required"
    end
    create_view :mx_schema_view, "SELECT name FROM mx_schema_types"
  end
end

class MxDefaultIrreversible < Saci::Record::Migration
  def change
    change_column_default :mx_cols, :count, 9
  end
end

class MxTimestamps < Saci::Record::Migration
  def change
    add_timestamps :mx_stamps
  end
end

class MxRemovable < Saci::Record::Migration
  def change
    create_table :mx_removable do |t|
      t.string :a
      t.string :b
      t.string :c
    end
  end
end

class MxAddIndexForRemove < Saci::Record::Migration
  def change
    add_index :mx_removable, [:a, :b]
  end
end

class MxRenameIndex < Saci::Record::Migration
  def change
    rename_index :mx_removable, "index_mx_removable_on_a_and_b", "index_mx_removable_ab"
  end
end

# -- specs ------------------------------------------------------------------

describe "migration DSL depth (G35)" do
  it "executes raw SQL and refuses to invert execute inside change" do
    with_mx_db do |db|
      Saci::Record::Migrator.migrate(db, [MxExecute] of Saci::Record::Migration.class)
      Saci::Record::Introspection.table_exists?(db, "mx_raw").should be_true
      expect_raises(Saci::Record::IrreversibleMigration, /execute/) do
        MxExecute.new(db).down
      end
    end
  end

  it "runs reversible up blocks and queues down blocks for rollback" do
    with_mx_db do |db|
      m = MxReversible.new(db)
      m.up
      db.scalar("SELECT COUNT(*) FROM mx_rv").should eq(1_i64)
      m.down
      Saci::Record::Introspection.table_exists?(db, "mx_rv").should be_false
    end
  end

  it "raises IrreversibleMigration for reversible blocks without down" do
    with_mx_db do |db|
      m = MxReversibleNoDown.new(db)
      m.up
      expect_raises(Saci::Record::IrreversibleMigration, /reversible/) { m.down }
    end
  end

  it "supports change_table add/rename/index and auto-inverts them" do
    with_mx_db do |db|
      db.exec("CREATE TABLE \"mx_ct\" (\"id\" INTEGER PRIMARY KEY AUTOINCREMENT, \"title\" VARCHAR(255))")
      m = MxChangeTableAdd.new(db)
      m.up
      names = Saci::Record::Introspection.columns(db, "mx_ct").map(&.name)
      names.should contain("headline")
      names.should contain("body")
      names.should_not contain("title")
      Saci::Record::Introspection.index_exists?(db, "mx_ct", :headline).should be_true
      m.down
      names = Saci::Record::Introspection.columns(db, "mx_ct").map(&.name)
      names.should contain("title")
      names.should_not contain("body")
      Saci::Record::Introspection.index_exists?(db, "mx_ct", :headline).should be_false
    end
  end

  it "supports change_table remove/remove_index" do
    with_mx_db do |db|
      MxChangeTableRemove.new(db).up
      names = Saci::Record::Introspection.columns(db, "mx_ct_rm").map(&.name)
      names.should eq(["id", "keep"])
      Saci::Record::Introspection.index_exists?(db, "mx_ct_rm", :legacy).should be_false
    end
  end

  it "reverts a migration class and a block" do
    with_mx_db do |db|
      db.exec("CREATE TABLE mx_rv_target (id INTEGER PRIMARY KEY)")
      MxRevertTarget.new(db).up
      Saci::Record::Introspection.column_exists?(db, "mx_rv_target", :extra).should be_true
      MxRevertUser.new(db).up
      Saci::Record::Introspection.column_exists?(db, "mx_rv_target", :extra).should be_false

      # A block reverts itself immediately: `revert { add_column }` drops
      # the column (the reverse of the block) — pre-create it here.
      db.exec(%(ALTER TABLE "mx_rv_target" ADD COLUMN "block_col" VARCHAR(255)))
      MxRevertBlock.new(db).up
      Saci::Record::Introspection.column_exists?(db, "mx_rv_target", :block_col).should be_false
    end
  end

  it "marks disable_ddl_transaction! migrations" do
    MxNoDdlTx.ddl_transaction_disabled?.should be_true
    MxExecute.ddl_transaction_disabled?.should be_false
  end

  it "prints with say and silences with suppress_messages" do
    with_mx_db do |db|
      m = MxExecute.new(db)
      m.say("hello")
      m.suppress_messages do
        m.say("quiet", subitem: true)
      end
    end
  end
end

describe "column helpers (G36)" do
  it "changes nullability on SQLite (table rebuild) with backfill and index/check preservation" do
    with_mx_db do |db|
      m = MxCreateCols.new(db)
      m.up
      db.exec("INSERT INTO mx_cols (name) VALUES (NULL)")
      m.change_column_null(:mx_cols, :name, false, default: "anon")
      db.scalar("SELECT name FROM mx_cols").should eq("anon")
      mx_col(db, "mx_cols", "name").null.should be_false
      Saci::Record::Introspection.index_exists?(db, "mx_cols", :name).should be_true

      # Reversible by construction.
      m.change_column_null(:mx_cols, :name, true)
      mx_col(db, "mx_cols", "name").null.should be_true

      # CHECK constraint survives the rebuild.
      expect_raises(Exception) do
        db.exec("INSERT INTO mx_cols_checked (price) VALUES (-1)")
      end
      m.change_column_default(:mx_cols_checked, :price, 0)
      expect_raises(Exception) do
        db.exec("INSERT INTO mx_cols_checked (price) VALUES (-5)")
      end
    end
  end

  it "changes column defaults and reverts with from:" do
    with_mx_db do |db|
      MxCreateCols.new(db).up
      mx_col(db, "mx_cols", "count").default.should eq(3_i64)
      m = MxDefaultChange.new(db)
      m.up
      mx_col(db, "mx_cols", "count").default.should eq(7_i64)
      m.down
      mx_col(db, "mx_cols", "count").default.should eq(3_i64)

      expect_raises(Saci::Record::IrreversibleMigration, /change_column_default/) do
        MxDefaultIrreversible.new(db).down
      end
    end
  end

  it "removes several columns at once" do
    with_mx_db do |db|
      MxRemovable.new(db).up
      m = MxRemovable.new(db)
      m.remove_columns(:mx_removable, [:a, :b])
      Saci::Record::Introspection.columns(db, "mx_removable").map(&.name).should eq(["id", "c"])
    end
  end

  it "adds and removes references (including polymorphic)" do
    with_mx_db do |db|
      MxRefs.new(db).up
      posts = Saci::Record::Introspection.columns(db, "mx_ref_posts").map(&.name)
      posts.should contain("user_id")
      posts.should contain("owner_id")
      posts.should contain("owner_type")
      Saci::Record::Introspection.index_exists?(db, "mx_ref_posts", :user_id).should be_true
      idx = Saci::Record::Introspection.indexes(db, "mx_ref_posts").find! { |i| i.name == "index_mx_ref_posts_on_owner" }
      idx.columns.should eq(["owner_type", "owner_id"])

      m = MxRefs.new(db)
      m.remove_reference(:mx_ref_posts, :user, index: true)
      m.remove_reference(:mx_ref_posts, :owner, polymorphic: true, index: true)
      posts = Saci::Record::Introspection.columns(db, "mx_ref_posts").map(&.name)
      posts.should eq(["id", "title"])
    end
  end

  it "creates and drops join tables" do
    with_mx_db do |db|
      MxJoin.new(db).up
      table = "mx_categories_mx_products"
      Saci::Record::Introspection.table_exists?(db, table).should be_true
      Saci::Record::Introspection.columns(db, table).map(&.name).should eq(["mx_category_id", "mx_product_id"])
      Saci::Record::Introspection.columns(db, table).each { |c| c.null.should be_false }
      Saci::Record::Introspection.indexes(db, table).map(&.name).sort.should eq([
        "index_mx_categories_mx_products_on_mx_category_id",
        "index_mx_categories_mx_products_on_mx_product_id",
      ])
      MxJoin.new(db).drop_join_table(:mx_products, :mx_categories)
      Saci::Record::Introspection.table_exists?(db, table).should be_false
    end
  end

  it "adds and removes timestamps (reversible)" do
    with_mx_db do |db|
      db.exec("CREATE TABLE \"mx_stamps\" (\"id\" INTEGER PRIMARY KEY AUTOINCREMENT, \"code\" VARCHAR(255))")
      m = MxTimestamps.new(db)
      m.up
      mx_col(db, "mx_stamps", "created_at").null.should be_false
      mx_col(db, "mx_stamps", "updated_at").null.should be_false
      m.down
      Saci::Record::Introspection.columns(db, "mx_stamps").map(&.name).should eq(["id", "code"])
    end
  end

  it "renames indexes on SQLite by recreating them" do
    with_mx_db do |db|
      MxRemovable.new(db).up
      MxAddIndexForRemove.new(db).up
      MxRenameIndex.new(db).up
      names = Saci::Record::Introspection.indexes(db, "mx_removable").map(&.name)
      names.should contain("index_mx_removable_ab")
      names.should_not contain("index_mx_removable_on_a_and_b")
      idx = Saci::Record::Introspection.indexes(db, "mx_removable").find! { |i| i.name == "index_mx_removable_ab" }
      idx.columns.should eq(["a", "b"])
    end
  end
end

describe "idempotent DDL (G37)" do
  it "makes create_table/add_column/add_index/drop_column/remove_index rerunnable" do
    with_mx_db do |db|
      m = MxIdempotent.new(db)
      m.up
      m.up
      Saci::Record::Introspection.columns(db, "mx_idem").map(&.name).should eq(["id", "name", "nick"])
      Saci::Record::Introspection.indexes(db, "mx_idem").map(&.name).should eq(["index_mx_idem_on_name"])
    end
  end

  it "drops tables idempotently" do
    with_mx_db do |db|
      m = MxIdempotent.new(db)
      m.up
      m.drop_table(:mx_idem, if_exists: true)
      m.drop_table(:mx_idem, if_exists: true)
      Saci::Record::Introspection.table_exists?(db, "mx_idem").should be_false
    end
  end

  it "falls back to introspection on SQLite for if_not_exists columns" do
    with_mx_db do |db|
      db.exec("CREATE TABLE mx_if (id INTEGER PRIMARY KEY, name TEXT)")
      m = MxExecute.new(db)
      m.add_column(:mx_if, :name, :string, if_not_exists: true)
      Saci::Record::Introspection.columns(db, "mx_if").map(&.name).should eq(["id", "name"])
    end
  end
end

describe "PostgreSQL/MySQL SQL generation (G37/G38)" do
  it "generates concurrent/idempotent index DDL" do
    sql = Saci::Record::Migration.create_index_sql(:postgres, :users, ["email"], "index_users_on_email",
      unique: true, if_not_exists: true, algorithm: :concurrently, where: "email IS NOT NULL")
    sql.should eq(%(CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS "index_users_on_email" ON "users" ("email") WHERE email IS NOT NULL))
    Saci::Record::Migration.create_index_sql(:sqlite, :users, ["email"], "idx", if_not_exists: true)
      .should eq(%(CREATE INDEX IF NOT EXISTS "idx" ON "users" ("email")))
    # MySQL has no IF NOT EXISTS for indexes; the instance helper checks
    # index_exists? first.
    Saci::Record::Migration.create_index_sql(:mysql, :users, ["email"], "idx", if_not_exists: true)
      .should eq("CREATE INDEX `idx` ON `users` (`email`)")
    expect_raises(ArgumentError, /only supported on PostgreSQL/) do
      Saci::Record::Migration.create_index_sql(:sqlite, :users, ["email"], "idx", algorithm: :concurrently)
    end

    Saci::Record::Migration.drop_index_sql(:postgres, :users, "idx", if_exists: true, algorithm: :concurrently)
      .should eq(%(DROP INDEX CONCURRENTLY IF EXISTS "idx"))
    Saci::Record::Migration.drop_index_sql(:mysql, :users, "idx").should eq("DROP INDEX `idx` ON `users`")
  end

  it "generates deferrable/not-valid foreign keys and validation DDL" do
    sql = Saci::Record::Migration.add_fk_sql(:postgres, :posts, :users, :user_id, :cascade, "fk_posts_user", :deferred, false)
    sql.should contain(%(ADD CONSTRAINT "fk_posts_user" FOREIGN KEY ("user_id") REFERENCES "users" ("id")))
    sql.should contain("ON DELETE CASCADE")
    sql.should contain("DEFERRABLE INITIALLY DEFERRED")
    sql.should contain("NOT VALID")
    Saci::Record::Migration.deferrable_sql(:deferred, :mysql).should eq("")
    Saci::Record::Migration.validate_constraint_sql(:postgres, :posts, "fk_posts_user")
      .should eq(%(ALTER TABLE "posts" VALIDATE CONSTRAINT "fk_posts_user"))
    expect_raises(ArgumentError, /only supported on PostgreSQL/) do
      Saci::Record::Migration.validate_constraint_sql(:mysql, :posts, "fk")
    end
  end

  it "generates check constraint DDL" do
    Saci::Record::Migration.add_check_constraint_sql(:postgres, :users, "age > 0", "age_positive", validate: false)
      .should eq(%(ALTER TABLE "users" ADD CONSTRAINT "age_positive" CHECK (age > 0) NOT VALID))
    Saci::Record::Migration.remove_check_constraint_sql(:mysql, :users, "age_positive")
      .should eq("ALTER TABLE `users` DROP CHECK `age_positive`")
    Saci::Record::Migration.remove_check_constraint_sql(:postgres, :users, "age_positive", if_exists: true)
      .should eq(%(ALTER TABLE "users" DROP CONSTRAINT IF EXISTS "age_positive"))
    expect_raises(ArgumentError, /not supported on SQLite/) do
      Saci::Record::Migration.add_check_constraint_sql(:sqlite, :users, "age > 0", "age_positive")
    end
  end

  it "generates view DDL per adapter" do
    Saci::Record::Migration.create_view_sql(:postgres, :recent, "SELECT * FROM posts")
      .should eq(%(CREATE VIEW "recent" AS SELECT * FROM posts))
    Saci::Record::Migration.create_view_sql(:postgres, :recent, "SELECT 1", or_replace: true)
      .should eq(%(CREATE OR REPLACE VIEW "recent" AS SELECT 1))
    Saci::Record::Migration.create_view_sql(:sqlite, :recent, "SELECT 1", if_not_exists: true)
      .should eq(%(CREATE VIEW IF NOT EXISTS "recent" AS SELECT 1))
    Saci::Record::Migration.drop_view_sql(:mysql, :recent, if_exists: true).should eq("DROP VIEW IF EXISTS `recent`")
    Saci::Record::Migration.rename_index_sql(:mysql, :users, "old", "new")
      .should eq("ALTER TABLE `users` RENAME INDEX `old` TO `new`")
  end

  it "generates column DDL builders" do
    col = Saci::Record::ColumnDef.new("nick", :string, true, nil, false)
    Saci::Record::Migration.add_column_sql(:postgres, :users, col, if_not_exists: true)
      .should eq(%(ALTER TABLE "users" ADD COLUMN IF NOT EXISTS "nick" VARCHAR(255)))
    Saci::Record::Migration.add_column_sql(:sqlite, :users, col, if_not_exists: true)
      .should eq(%(ALTER TABLE "users" ADD COLUMN "nick" VARCHAR(255)))
    Saci::Record::Migration.drop_column_sql(:postgres, :users, :nick, if_exists: true)
      .should eq(%(ALTER TABLE "users" DROP COLUMN IF EXISTS "nick"))
    Saci::Record::Migration.change_column_null_sql(:postgres, :users, :nick, false)
      .should eq(%(ALTER TABLE "users" ALTER COLUMN "nick" SET NOT NULL))
    Saci::Record::Migration.change_column_default_sql(:postgres, :users, :nick, "bob")
      .should eq(%(ALTER TABLE "users" ALTER COLUMN "nick" SET DEFAULT 'bob'))
    Saci::Record::Migration.change_column_default_sql(:mysql, :users, :nick, nil)
      .should eq("ALTER TABLE `users` ALTER COLUMN `nick` DROP DEFAULT")
    Saci::Record::Migration.remove_index_sql(:sqlite, :users, "idx", if_exists: true)
      .should eq(%(DROP INDEX IF EXISTS "idx"))
  end

  it "refuses SQLite-only gaps clearly" do
    with_mx_db do |db|
      m = MxExecute.new(db)
      expect_raises(ArgumentError, /not supported on SQLite/) { m.add_check_constraint(:x, "y > 0") }
      expect_raises(ArgumentError, /not supported on SQLite/) { m.remove_check_constraint(:x, "chk") }
      expect_raises(ArgumentError, /not supported on SQLite/) { m.validate_foreign_key(:x, column: :y_id) }
    end
  end
end

describe "introspection (P1)" do
  it "answers existence questions from PRAGMA-backed introspection" do
    with_mx_db do |db|
      MxIntro.new(db).up
      Saci::Record::Introspection.table_exists?(db, :mx_intro_children).should be_true
      Saci::Record::Introspection.table_exists?(db, :mx_nope).should be_false
      Saci::Record::Introspection.data_source_exists?(db, :mx_intro_view).should be_true
      Saci::Record::Introspection.view_exists?(db, :mx_intro_view).should be_true
      Saci::Record::Introspection.column_exists?(db, :mx_intro_children, :label).should be_true
      Saci::Record::Introspection.column_exists?(db, :mx_intro_children, :missing).should be_false
      Saci::Record::Introspection.index_exists?(db, :mx_intro_children, :label).should be_true
      Saci::Record::Introspection.index_exists?(db, :mx_intro_children, name: "index_mx_intro_children_on_label").should be_true
      Saci::Record::Introspection.foreign_key_exists?(db, :mx_intro_children, to_table: :mx_intro_parents).should be_true
      Saci::Record::Introspection.foreign_key_exists?(db, :mx_intro_children, column: :parent_id).should be_true
      Saci::Record::Introspection.foreign_key_exists?(db, :mx_intro_children, to_table: :nope).should be_false
    end
  end

  it "lists columns, indexes, foreign keys and check constraints" do
    with_mx_db do |db|
      MxIntro.new(db).up
      cols = Saci::Record::Introspection.columns(db, :mx_intro_children)
      cols.map(&.name).should eq(["id", "parent_id", "label"])
      cols.find! { |c| c.name == "id" }.primary_key.should be_true
      cols.find! { |c| c.name == "id" }.type.should eq(:serial)

      idx = Saci::Record::Introspection.indexes(db, :mx_intro_children).find! { |i| i.name == "index_mx_intro_children_on_label" }
      idx.unique.should be_true
      idx.columns.should eq(["label"])

      fk = Saci::Record::Introspection.foreign_keys(db, :mx_intro_children).first
      fk.column.should eq("parent_id")
      fk.to_table.should eq("mx_intro_parents")
      fk.on_delete.should eq("CASCADE")

      checks = Saci::Record::Introspection.check_constraints(db, :mx_intro_children)
      checks.map(&.name).should contain("label_present")
      checks.find! { |c| c.name == "label_present" }.expression.should eq("length(label) > 0")
    end
  end

  it "exposes the same API with an optional default database" do
    with_mx_db do |db|
      MxIntro.new(db).up
      Saci::Record.table_exists?(:mx_intro_children, db).should be_true
      Saci::Record.data_source_exists?(:mx_intro_view, db).should be_true
      Saci::Record.column_exists?(:mx_intro_children, :label, db).should be_true
      Saci::Record.index_exists?(:mx_intro_children, :label, db).should be_true
      Saci::Record.foreign_key_exists?(:mx_intro_children, :mx_intro_parents, nil, db).should be_true
      Saci::Record.columns(:mx_intro_children, db).size.should eq(3)
      Saci::Record.indexes(:mx_intro_children, db).size.should eq(1)
      Saci::Record.foreign_keys(:mx_intro_children, db).size.should eq(1)
      Saci::Record.check_constraints(:mx_intro_children, db).size.should eq(1)
      Saci::Record.views(db).map(&.name).should eq(["mx_intro_view"])

      # db-first overloads mirror `Introspection.*`.
      Saci::Record.table_exists?(db, :mx_intro_children).should be_true
      Saci::Record.index_exists?(db, :mx_intro_children, :label).should be_true
      Saci::Record.index_exists?(:mx_intro_children, column: :label, db: db).should be_true
      Saci::Record.foreign_key_exists?(db, :mx_intro_children, :mx_intro_parents).should be_true
      Saci::Record.columns(db, :mx_intro_children).size.should eq(3)
      Saci::Record.check_constraints(db, :mx_intro_children).size.should eq(1)
    end
  end
end

describe "UUID columns and primary keys (G283)" do
  it "renders UUID DDL per adapter" do
    id = Saci::Record::ColumnDef.new("id", :uuid, false, nil, true)
    id.to_sql(:postgres).should eq(%("id" UUID PRIMARY KEY NOT NULL DEFAULT gen_random_uuid()))
    id.to_sql(:sqlite).should eq(%("id" TEXT PRIMARY KEY NOT NULL))
    id.to_sql(:mysql).should eq("`id` CHAR(36) PRIMARY KEY NOT NULL")

    token = Saci::Record::ColumnDef.new("token", :uuid, true, nil, false)
    token.to_sql(:postgres).should eq(%("token" UUID))
    token.to_sql(:mysql).should eq("`token` CHAR(36)")
    token.to_sql(:sqlite).should eq(%("token" TEXT))

    Saci::Record.native_db_type(:uuid, :postgres).should eq("UUID")
    Saci::Record.native_db_type(:uuid, :sqlite).should eq("TEXT")
    Saci::Record.native_db_type(:uuid, :mysql).should eq("CHAR(36)")

    t = Saci::Record::TableDefinition.new
    t.uuid :token, default: :gen_random_uuid
    t.columns.first.to_sql(:postgres).should eq(%("token" UUID DEFAULT gen_random_uuid()))
    t = Saci::Record::TableDefinition.new
    t.uuid :token, default: -> { "gen_random_uuid()" }
    t.columns.first.to_sql(:postgres).should eq(%("token" UUID DEFAULT gen_random_uuid()))

    t = Saci::Record::TableDefinition.new
    t.uuid :id, primary_key: true
    t.columns.first.to_sql(:postgres).should eq(%("id" UUID PRIMARY KEY NOT NULL DEFAULT gen_random_uuid()))
  end

  it "creates and round-trips string UUIDs on SQLite" do
    with_mx_db do |db|
      MxUuidPk.new(db).up
      Saci::Record::Introspection.table_exists?(db, "mx_uuid_pk").should be_true
      mx_col(db, "mx_uuid_pk", "id").type.should eq(:uuid)
      mx_col(db, "mx_uuid_pk", "id").primary_key.should be_true

      uuid = "0f8fad5b-d9cb-469f-a165-70867728950e"
      db.exec("INSERT INTO mx_uuid_pk (id, name) VALUES (?, ?)", uuid, "first")
      db.scalar("SELECT id FROM mx_uuid_pk").should eq(uuid)
      db.scalar("SELECT COUNT(*) FROM mx_uuid_pk WHERE id = ?", uuid).should eq(1_i64)
    end
  end
end

describe "native PostgreSQL types (G284/G286)" do
  it "maps extended types per adapter" do
    Saci::Record.native_db_type(:binary, :postgres).should eq("BYTEA")
    Saci::Record.native_db_type(:bytea, :postgres).should eq("BYTEA")
    Saci::Record.native_db_type(:binary, :sqlite).should eq("BLOB")
    Saci::Record.native_db_type(:binary, :mysql).should eq("BLOB")
    Saci::Record.native_db_type(:hstore, :postgres).should eq("HSTORE")
    Saci::Record.native_db_type(:hstore, :sqlite).should eq("TEXT")
    Saci::Record.native_db_type(:inet, :postgres).should eq("INET")
    Saci::Record.native_db_type(:cidr, :postgres).should eq("CIDR")
    Saci::Record.native_db_type(:macaddr, :postgres).should eq("MACADDR")
    Saci::Record.native_db_type(:interval, :postgres).should eq("INTERVAL")
    Saci::Record.native_db_type(:money, :postgres).should eq("MONEY")
    Saci::Record.native_db_type(:money, :mysql).should eq("DECIMAL(19,4)")
    Saci::Record.native_db_type(:money, :sqlite).should eq("TEXT")
    Saci::Record.native_db_type(:bit, :postgres).should eq("BIT(1)")
    Saci::Record.native_db_type(:bit, :sqlite, size: 8).should eq("INTEGER")
    Saci::Record.native_db_type(:bit_varying, :postgres, size: 16).should eq("BIT VARYING(16)")
    Saci::Record.native_db_type(:bit_varying, :postgres).should eq("BIT VARYING")
    Saci::Record.native_db_type(:bit_varying, :mysql).should eq("TEXT")
    Saci::Record.native_db_type(:point, :postgres).should eq("POINT")
    Saci::Record.native_db_type(:point, :sqlite).should eq("TEXT")
    Saci::Record.native_db_type(:xml, :postgres).should eq("XML")
    Saci::Record.native_db_type(:oid, :postgres).should eq("OID")
    Saci::Record.native_db_type(:oid, :mysql).should eq("BIGINT UNSIGNED")
    Saci::Record.native_db_type(:oid, :sqlite).should eq("INTEGER")

    Saci::Record.native_db_type(:range, :postgres).should eq("INT4RANGE")
    Saci::Record.native_db_type(:range, :postgres, subtype: :ts).should eq("TSRANGE")
    Saci::Record.native_db_type(:range, :postgres, subtype: :tstz).should eq("TSTZRANGE")
    Saci::Record.native_db_type(:range, :sqlite).should eq("TEXT")
    expect_raises(ArgumentError, /Unknown range subtype/) do
      Saci::Record.native_db_type(:range, :postgres, subtype: :nope)
    end

    # Exact decimals: SQLite uses a TEXT-affine type, PG/MySQL real NUMERIC.
    Saci::Record.db_type(:decimal, :sqlite).should eq("TEXT_DECIMAL")
    Saci::Record.db_type(:decimal, :postgres).should eq("NUMERIC(38,18)")
    Saci::Record.db_type(:decimal, :mysql).should eq("DECIMAL(38,18)")
    Saci::Record::Migration.db_type(:uuid, :postgres).should eq("UUID")
    Saci::Record::Migration.db_type(:string, :postgres).should eq("VARCHAR(255)")
  end

  it "executes the SQLite fallbacks and stores values" do
    with_mx_db do |db|
      MxNative.new(db).up
      Saci::Record::Introspection.table_exists?(db, "mx_native").should be_true
      db.exec("INSERT INTO mx_native (token, payload, attrs, ip, span) VALUES (?, ?, ?, ?, ?)", "abc-123", Bytes[1, 2, 3], "k=>v", "127.0.0.1", "[1,10)")
      db.scalar("SELECT token FROM mx_native").should eq("abc-123")
      db.scalar("SELECT payload FROM mx_native").as(Bytes).should eq(Bytes[1, 2, 3])
      db.scalar("SELECT label FROM mx_native").should eq("xabc-123")
      mx_col(db, "mx_native", "payload").type.should eq(:binary)
      mx_col(db, "mx_native", "token").type.should eq(:text)
    end
  end
end

describe "views, check constraints and generated columns (G32)" do
  it "creates and drops views on SQLite (and auto-inverts in change)" do
    with_mx_db do |db|
      m = MxViews.new(db)
      m.up
      Saci::Record::Introspection.view_exists?(db, :mx_names).should be_true
      db.exec("INSERT INTO mx_view_src (name) VALUES ('alpha')")
      db.scalar("SELECT name FROM mx_names").should eq("alpha")
      m.down
      Saci::Record::Introspection.view_exists?(db, :mx_names).should be_false
      Saci::Record::Introspection.table_exists?(db, :mx_view_src).should be_false
    end
  end

  it "enforces create_table CHECK constraints on SQLite" do
    with_mx_db do |db|
      MxCreateCols.new(db).up
      db.exec("INSERT INTO mx_cols_checked (price) VALUES (5)")
      expect_raises(Exception) do
        db.exec("INSERT INTO mx_cols_checked (price) VALUES (-5)")
      end
    end
  end

  it "creates stored generated columns on SQLite" do
    with_mx_db do |db|
      MxGenerated.new(db).up
      db.exec("INSERT INTO mx_gen (a, b) VALUES (2, 3)")
      db.scalar("SELECT total FROM mx_gen").should eq(5_i64)
      sql = Saci::Record::ColumnDef.new("total", :integer, true, nil, false, generated_as: "a + b", stored: true).to_sql(:postgres)
      sql.should eq(%("total" INTEGER GENERATED ALWAYS AS (a + b) STORED))
      sql = Saci::Record::ColumnDef.new("total", :integer, true, nil, false, generated_as: "a + b", stored: false).to_sql(:mysql)
      sql.should eq("`total` INTEGER GENERATED ALWAYS AS (a + b) VIRTUAL")
    end
  end

  it "round-trips UUID/binary/checks/views through the schema dump" do
    with_mx_db do |db|
      MxSchemaTypes.new(db).up
      first = Saci::Record::Schema.dump(db)
      first.should contain(%(ColumnDef.new("id", :uuid, false, nil, true)))
      first.should contain(%(ColumnDef.new("payload", :binary, true, nil, false)))
      first.should contain(%(generated_as: "'x' || name", stored: true))
      first.should contain(%(Saci::Record::Schema::CheckInfo.new("name_required", "name IS NOT NULL")))
      first.should contain(%(Saci::Record::Schema::ViewInfo.new("mx_schema_view", "SELECT name FROM mx_schema_types")))
      first.should contain("Saci::Record::Schema.drop_views(db, SCHEMA_VIEWS)")
      first.should contain("Saci::Record::Schema.load_views(db, SCHEMA_VIEWS)")

      tables = Saci::Record::Schema.introspect(db)
      views = Saci::Record::Schema.views(db)
      Saci::Record::Schema.drop_views(db, views)
      Saci::Record::Schema.load(db, tables)
      Saci::Record::Schema.load_views(db, views)

      mx_col(db, "mx_schema_types", "id").type.should eq(:uuid)
      mx_col(db, "mx_schema_types", "payload").type.should eq(:binary)
      Saci::Record::Introspection.check_constraints(db, :mx_schema_types).map(&.name).should contain("name_required")
      Saci::Record::Introspection.view_exists?(db, :mx_schema_view).should be_true
      Saci::Record::Schema.dump(db).should eq(first)
    end
  end
end
