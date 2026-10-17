require "spec"
require "../src/saci"

{% if env("PG_URL") %}
require "pg"
{% end %}
{% if env("MYSQL_URL") %}
require "mysql"
{% end %}

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

  it "builds t.references columns, indexes and FK targets" do
    t = Saci::Record::TableDefinition.new
    t.references :user
    t.columns.map(&.name).should eq(["user_id"])
    t.columns.first.logical_type.should eq(:bigint)
    t.columns.first.null.should be_true
    t.foreign_keys.should be_empty
    t.pending_indexes.should eq(["user_id"])

    t = Saci::Record::TableDefinition.new
    t.references :user, foreign_key: true, null: false, index: false
    t.columns.first.null.should be_false
    t.pending_indexes.should be_empty
    t.foreign_keys.size.should eq(1)
    t.foreign_keys.first.column.should eq("user_id")
    t.foreign_keys.first.to_table.should eq("users")
    t.foreign_keys.first.on_delete.should be_nil

    t = Saci::Record::TableDefinition.new
    t.references :author, foreign_key: true, to_table: :users, on_delete: :cascade
    t.foreign_keys.first.column.should eq("author_id")
    t.foreign_keys.first.to_table.should eq("users")
    t.foreign_keys.first.on_delete.should eq(:cascade)

    t = Saci::Record::TableDefinition.new
    t.references :person, foreign_key: :accounts
    t.foreign_keys.first.column.should eq("person_id")
    t.foreign_keys.first.to_table.should eq("accounts")

    # foreign_key default is explicit opt-in (false), unlike Rails 5+.
    t = Saci::Record::TableDefinition.new
    t.references :user, foreign_key: false
    t.foreign_keys.should be_empty
    t = Saci::Record::TableDefinition.new
    t.references :user, foreign_key: nil
    t.foreign_keys.should be_empty
  end

  it "renders FK DDL per adapter" do
    pg = Saci::Record::Migration.add_fk_sql(:postgres, :stories, :users, :user_id)
    pg.should eq(%(ALTER TABLE "stories" ADD CONSTRAINT "fk_stories_on_user_id" FOREIGN KEY ("user_id") REFERENCES "users" ("id")))
    my = Saci::Record::Migration.add_fk_sql(:mysql, :stories, :users, :user_id, :cascade)
    my.should eq("ALTER TABLE `stories` ADD CONSTRAINT `fk_stories_on_user_id` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE CASCADE")
    nullify = Saci::Record::Migration.add_fk_sql(:sqlite, :stories, :users, :user_id, :nullify)
    nullify.should contain("ON DELETE SET NULL")
    restrict = Saci::Record::Migration.add_fk_sql(:postgres, :stories, :users, :user_id, :restrict, "custom_fk")
    restrict.should contain(%("custom_fk"))
    restrict.should contain("ON DELETE RESTRICT")
    expect_raises(ArgumentError, /nknown on_delete/) do
      Saci::Record::Migration.add_fk_sql(:postgres, :a, :b, :c, :explode)
    end

    Saci::Record::Migration.remove_fk_sql(:postgres, :stories, "fk_stories_on_user_id").should eq(
      %(ALTER TABLE "stories" DROP CONSTRAINT "fk_stories_on_user_id"))
    Saci::Record::Migration.remove_fk_sql(:mysql, :stories, "fk_stories_on_user_id").should eq(
      "ALTER TABLE `stories` DROP FOREIGN KEY `fk_stories_on_user_id`")

    Saci::Record::Migration.fk_default_column(:users).should eq("user_id")
    Saci::Record::Migration.fk_default_column(:stories).should eq("story_id")
  end

  it "renders create_table FK clauses per adapter" do
    fk = Saci::Record::TableForeignKey.new("user_id", "users", :cascade, nil)
    Saci::Record::Migration.create_table_fk_sql(:postgres, :stories, fk).should eq(
      %(CONSTRAINT "fk_stories_on_user_id" FOREIGN KEY ("user_id") REFERENCES "users" ("id") ON DELETE CASCADE))
    Saci::Record::Migration.create_table_fk_sql(:mysql, :stories, fk).should eq(
      "CONSTRAINT `fk_stories_on_user_id` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE CASCADE")
    Saci::Record::Migration.create_table_fk_sql(:sqlite, :stories, fk).should contain("REFERENCES")
  end

  it "renders renames per adapter" do
    Saci::Record::Migration.rename_table_sql(:postgres, :old_things, :new_things).should eq(
      %(ALTER TABLE "old_things" RENAME TO "new_things"))
    Saci::Record::Migration.rename_table_sql(:mysql, :old_things, :new_things).should eq(
      "ALTER TABLE `old_things` RENAME TO `new_things`")
    Saci::Record::Migration.rename_table_sql(:sqlite, :old_things, :new_things).should eq(
      %(ALTER TABLE "old_things" RENAME TO "new_things"))
    Saci::Record::Migration.rename_column_sql(:postgres, :things, :old_c, :new_c).should eq(
      %(ALTER TABLE "things" RENAME COLUMN "old_c" TO "new_c"))
    Saci::Record::Migration.rename_column_sql(:mysql, :things, :old_c, :new_c).should eq(
      "ALTER TABLE `things` RENAME COLUMN `old_c` TO `new_c`")
    Saci::Record::Migration.rename_column_sql(:sqlite, :things, :old_c, :new_c).should eq(
      %(ALTER TABLE "things" RENAME COLUMN "old_c" TO "new_c"))
  end

  it "renders change_column per adapter and refuses SQLite" do
    pg = Saci::Record::Migration.change_column_sqls(:postgres, :things, :title, :text, null: false)
    pg.first.should eq(%(ALTER TABLE "things" ALTER COLUMN "title" TYPE TEXT USING "title"::TEXT))
    pg.should contain(%(ALTER TABLE "things" ALTER COLUMN "title" SET NOT NULL))
    pg.should contain(%(ALTER TABLE "things" ALTER COLUMN "title" DROP DEFAULT))
    pg_default = Saci::Record::Migration.change_column_sqls(:postgres, :things, :views, :integer, default: 0)
    pg_default.last.should contain("SET DEFAULT 0")
    pg_default.should contain(%(ALTER TABLE "things" ALTER COLUMN "views" DROP NOT NULL))

    my = Saci::Record::Migration.change_column_sqls(:mysql, :things, :title, :text, null: false)
    my.size.should eq(1)
    my.first.should eq("ALTER TABLE `things` MODIFY COLUMN `title` TEXT NOT NULL")

    expect_raises(ArgumentError, /not supported on SQLite/) do
      Saci::Record::Migration.change_column_sqls(:sqlite, :things, :title, :text)
    end
  end

  it "raises IrreversibleMigration when rolling back change_column/remove_foreign_key" do
    path = "/tmp/opencode/saci_irreversible_probe.db"
    File.delete(path) if File.exists?(path)
    db = DB.open("sqlite3://#{path}")
    begin
      # `down` replays `change` in inverting mode: both helpers raise
      # before touching the database (no tables needed).
      expect_raises(Saci::Record::IrreversibleMigration, /change_column/) do
        AdapterProbeChange.new(db).down
      end
      expect_raises(Saci::Record::IrreversibleMigration, /remove_foreign_key/) do
        AdapterProbeRemoveFk.new(db).down
      end
    ensure
      db.close
      File.delete(path) if File.exists?(path)
    end
  end

  it "SQLite round-trips create_table FKs, renames and rollback inverts" do
    path = "/tmp/opencode/saci_fk_probe.db"
    File.delete(path) if File.exists?(path)
    db = DB.open("sqlite3://#{path}")
    begin
      db.exec("PRAGMA foreign_keys = ON")
      Saci::Record::Migrator.migrate(db, [AdapterProbeFk1, AdapterProbeFk2] of Saci::Record::Migration.class)

      # create_table block FK is enforced on SQLite.
      db.exec(%(INSERT INTO "fk_probe_users" ("name", "created_at", "updated_at") VALUES (?, ?, ?)), "u", "2024-01-01", "2024-01-02")
      db.exec(%(INSERT INTO "fk_probe_stories" ("title", "user_id", "created_at", "updated_at") VALUES (?, ?, ?, ?)), "s", 1, "2024-01-01", "2024-01-02")
      expect_raises(Exception) do
        db.exec(%(INSERT INTO "fk_probe_stories" ("title", "user_id", "created_at", "updated_at") VALUES (?, ?, ?, ?)), "bad", 999, "2024-01-01", "2024-01-02")
      end

      # references index exists.
      idx_names = [] of String
      db.query("SELECT name FROM sqlite_master WHERE type = 'index'") do |rs|
        rs.each { idx_names << rs.read(String) }
      end
      idx_names.should contain("index_fk_probe_stories_on_user_id")

      # rename_column applied, rollback inverts.
      Saci::Record::Migrator.migrate(db, [AdapterProbeRename] of Saci::Record::Migration.class)
      cols = [] of String
      db.query(%(PRAGMA table_info("fk_probe_stories"))) do |rs|
        rs.each do
          rs.read(Int64); cols << rs.read(String); rs.read(String?); rs.read(Int64); rs.read(String?); rs.read(Int64)
        end
      end
      cols.should contain("headline")
      cols.should_not contain("title")
      Saci::Record::Migrator.rollback(db, [AdapterProbeFk1, AdapterProbeFk2, AdapterProbeRename] of Saci::Record::Migration.class, 1)
      cols = [] of String
      db.query(%(PRAGMA table_info("fk_probe_stories"))) do |rs|
        rs.each do
          rs.read(Int64); cols << rs.read(String); rs.read(String?); rs.read(Int64); rs.read(String?); rs.read(Int64)
        end
      end
      cols.should contain("title")

      # add_foreign_key / remove_foreign_key / change_column refuse SQLite clearly.
      expect_raises(ArgumentError, /CREATE TABLE time only/) do
        AdapterProbeFk1.new(db).add_foreign_key(:fk_probe_stories, :fk_probe_users)
      end
      expect_raises(ArgumentError, /not supported on SQLite/) do
        AdapterProbeFk1.new(db).remove_foreign_key(:fk_probe_stories, :fk_probe_users)
      end
      expect_raises(ArgumentError, /not supported on SQLite/) do
        AdapterProbeFk1.new(db).change_column(:fk_probe_stories, :title, :text)
      end
    ensure
      begin
        db.close
      rescue SQLite3::Exception
        # crystal-sqlite3 quirk: sqlite3_finalize echoes a failed step's
        # sticky error, so closing after the (asserted) FOREIGN KEY
        # violation above re-raises it from the pooled statement cache
        # (same quirk as the UNIQUE case in spec/schema_spec.cr).
      end
      File.delete(path) if File.exists?(path)
    end
  end

  it "SQLite round-trips rename_table with rollback inverting" do
    path = "/tmp/opencode/saci_rename_probe.db"
    File.delete(path) if File.exists?(path)
    db = DB.open("sqlite3://#{path}")
    begin
      Saci::Record::Migrator.migrate(db, [AdapterProbeRenameTable, AdapterProbeRenameTable2] of Saci::Record::Migration.class)
      names = [] of String
      db.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'") do |rs|
        rs.each { names << rs.read(String) }
      end
      names.should contain("renamed_things")
      names.should_not contain("original_things")
      Saci::Record::Migrator.rollback(db, [AdapterProbeRenameTable, AdapterProbeRenameTable2] of Saci::Record::Migration.class, 1)
      names = [] of String
      db.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'") do |rs|
        rs.each { names << rs.read(String) }
      end
      names.should contain("original_things")
      names.should_not contain("renamed_things")
    ensure
      db.close
      File.delete(path) if File.exists?(path)
    end
  end

  it "maps enum columns per adapter" do
    Saci::Record.db_type(:enum, :sqlite, ["draft", "published"], "posts_status_enum").should eq("TEXT")
    Saci::Record.db_type(:enum, :postgres, ["draft", "published"], "posts_status_enum").should eq(%("posts_status_enum"))
    Saci::Record.db_type(:enum, :mysql, ["draft", "published"], "posts_status_enum").should eq("ENUM('draft','published')")
    # Single quotes in values are escaped per adapter quoting rules.
    Saci::Record.db_type(:enum, :mysql, ["o'clock"], "t_x_enum").should eq("ENUM('o''clock')")
    Saci::Record.db_type(:enum, :postgres, ["o'clock"], "t_x_enum").should eq(%("t_x_enum"))
    expect_raises(ArgumentError, /requires values/) do
      Saci::Record.db_type(:enum, :sqlite)
    end
    expect_raises(ArgumentError, /requires values/) do
      Saci::Record.db_type(:enum, :postgres, [] of String, "t_x_enum")
    end
    expect_raises(ArgumentError, /requires a type name/) do
      Saci::Record.db_type(:enum, :postgres, ["a"])
    end
  end

  it "maps string arrays per adapter" do
    Saci::Record.db_type(:string_array, :postgres).should eq("TEXT[]")
    Saci::Record.db_type(:string_array, :mysql).should eq("TEXT")
    Saci::Record.db_type(:string_array, :sqlite).should eq("TEXT")
  end

  it "renders timestamp precision per adapter and ignores it on SQLite" do
    Saci::Record.db_type(:datetime, :postgres, precision: 6).should eq("TIMESTAMP(6)")
    Saci::Record.db_type(:datetime, :mysql, precision: 6).should eq("DATETIME(6)")
    Saci::Record.db_type(:datetime, :sqlite, precision: 6).should eq("TEXT")
    Saci::Record.db_type(:datetime, :postgres, precision: 0).should eq("TIMESTAMP(0)")
    # No precision: historical rendering is unchanged.
    Saci::Record.db_type(:datetime, :sqlite).should eq("TEXT")
    Saci::Record.db_type(:datetime, :postgres).should eq("TIMESTAMP")
    Saci::Record.db_type(:datetime, :mysql).should eq("DATETIME")
    expect_raises(ArgumentError, /out of range/) do
      Saci::Record.db_type(:datetime, :postgres, precision: 7)
    end
    expect_raises(ArgumentError, /out of range/) do
      Saci::Record.db_type(:datetime, :mysql, precision: -1)
    end
  end

  it "builds enum, string_array and precision columns in TableDefinition" do
    t = Saci::Record::TableDefinition.new
    t.enum :status, values: ["draft", "published"]
    t.columns.first.logical_type.should eq(:enum)
    t.columns.first.enum_values.should eq(["draft", "published"])
    expect_raises(ArgumentError, /must not be empty/) do
      Saci::Record::TableDefinition.new.enum(:status, [] of String)
    end

    t = Saci::Record::TableDefinition.new
    t.string_array :tags
    t.columns.first.logical_type.should eq(:string_array)

    t = Saci::Record::TableDefinition.new
    t.datetime :at, precision: 6
    t.columns.first.precision.should eq(6)
    expect_raises(ArgumentError, /out of range/) do
      Saci::Record::TableDefinition.new.datetime(:at, precision: 9)
    end

    t = Saci::Record::TableDefinition.new
    t.timestamps precision: 6
    t.columns.map(&.precision).should eq([6, 6])
    t = Saci::Record::TableDefinition.new
    t.timestamps
    t.columns.map(&.precision).should eq([nil, nil])

    t = Saci::Record::TableDefinition.new
    t.enum :status, values: ["draft", "published"]
    t.string_array :tags
    t.datetime :at, precision: 6
    t.timestamps precision: 6
    t.columns.map(&.to_sql(:postgres, "posts")).join(", ").should eq(
      %("status" "posts_status_enum", "tags" TEXT[], "at" TIMESTAMP(6), "created_at" TIMESTAMP(6) NOT NULL, "updated_at" TIMESTAMP(6) NOT NULL))
    t.columns.map(&.to_sql(:mysql, "posts")).join(", ").should contain("`status` ENUM('draft','published')")
    t.columns.map(&.to_sql(:mysql, "posts")).join(", ").should contain("`at` DATETIME(6)")
    t.columns.map(&.to_sql(:sqlite, "posts")).join(", ").should contain(%("status" TEXT))
  end

  it "renders idempotent enum type DDL and drops it on rollback" do
    Saci::Record::Migration.enum_type_name(:posts, :status).should eq("posts_status_enum")
    Saci::Record::Migration.create_enum_sql(:postgres, :posts, :status, ["draft", "published"]).should eq(
      %(DO $$ BEGIN CREATE TYPE "posts_status_enum" AS ENUM ('draft', 'published'); EXCEPTION WHEN duplicate_object THEN NULL; END $$;))
    # No standalone type on MySQL/SQLite (inline ENUM / TEXT instead).
    Saci::Record::Migration.create_enum_sql(:mysql, :posts, :status, ["a"]).should be_nil
    Saci::Record::Migration.create_enum_sql(:sqlite, :posts, :status, ["a"]).should be_nil
    Saci::Record::Migration.drop_enum_sql(:postgres, :posts, :status).should eq(
      %(DROP TYPE IF EXISTS "posts_status_enum"))
    Saci::Record::Migration.drop_enum_sql(:mysql, :posts, :status).should be_nil
    Saci::Record::Migration.drop_enum_sql(:sqlite, :posts, :status).should be_nil
  end

  it "encodes string arrays per adapter" do
    Saci::Record.to_db(["a", "b"], :sqlite).should eq(%(["a","b"]))
    Saci::Record.to_db(["a", "b"], :mysql).should eq(%(["a","b"]))
    Saci::Record.to_db(["a", "b"], :postgres).should eq(["a", "b"])
    Saci::Record.to_db(nil, :sqlite).should be_nil
    Saci::Record.parse_string_array?(%(["x","y"])).should eq(["x", "y"])
    Saci::Record.parse_string_array?("").should be_nil
    Saci::Record.parse_string_array?("nope").should be_nil
    Saci::Record.to_string_array(["a", "b"]).should eq(["a", "b"])
    Saci::Record.to_string_array(%(["a","b"])).should eq(["a", "b"])
    Saci::Record.to_string_array(nil).should be_nil
    Saci::Record.blank?([] of String).should be_true
    Saci::Record.blank?(["a"]).should be_false
    Saci::Record.column_default_sql(["a", "b"], :sqlite).should eq(%('["a","b"]'))
  end

  it "SQLite round-trips enum, string arrays and precision timestamps with rollback" do
    path = "/tmp/opencode/saci_p2_probe.db"
    File.delete(path) if File.exists?(path)
    db = DB.open("sqlite3://#{path}")
    begin
      Saci::Record::Migrator.migrate(db, [AdapterProbeEnums, AdapterProbeEnumAdd] of Saci::Record::Migration.class)
      info = {} of String => String
      db.query(%(PRAGMA table_info("adapter_probe_articles"))) do |rs|
        rs.each do
          rs.read(Int64); name = rs.read(String); info[name] = rs.read(String); rs.read(Int64); rs.read(String?); rs.read(Int64)
        end
      end
      # SQLite stores enums and arrays as TEXT (no DB-level enforcement).
      info["status"].should eq("TEXT")
      info["tags"].should eq("TEXT")
      info["published_at"].should eq("TEXT")
      info["created_at"].should eq("TEXT")
      info["audience"].should eq("TEXT")
      info["labels"].should eq("TEXT")

      # Rollback drops the added columns; arrays need no extra statements.
      Saci::Record::Migrator.rollback(db, [AdapterProbeEnums, AdapterProbeEnumAdd] of Saci::Record::Migration.class, 1)
      info = {} of String => String
      db.query(%(PRAGMA table_info("adapter_probe_articles"))) do |rs|
        rs.each do
          rs.read(Int64); name = rs.read(String); info[name] = rs.read(String); rs.read(Int64); rs.read(String?); rs.read(Int64)
        end
      end
      info.has_key?("audience").should be_false
      info.has_key?("labels").should be_false
      info.has_key?("status").should be_true
    ensure
      db.close
    end
    begin
      # Model round-trips go through the primary database (saved and
      # restored — registering a named database would leak into the
      # global registry).
      had_primary = Saci::Record.configuration_names.includes?("primary")
      prev = had_primary ? Saci::Record.database("primary") : nil
      Saci::Record::Base.connection = DB.open("sqlite3://#{path}")
      row = AdapterProbeArticle.create!(status: "draft", tags: ["crystal", "o'hara, jr."])
      row.id.should_not be_nil
      fresh = AdapterProbeArticle.find(row.id)
      fresh.status.should eq("draft")
      # JSON encoding round-trips commas, quotes and unicode exactly.
      fresh.tags.should eq(["crystal", "o'hara, jr."])

      # Change detection on assign: a plain setter replaces the value.
      row.tags = ["one"]
      row.save!
      row.reload.tags.should eq(["one"])

      # Nil and empty arrays are distinct and round-trip.
      row.update!(tags: nil)
      row.reload.tags.should be_nil
      row.update!(tags: [] of String)
      AdapterProbeArticle.find(row.id).tags.should eq([] of String)

      # Timestamps keep whole-second precision through SQLite (its storage
      # is RFC3339 text without fractional seconds — precision: is
      # accepted but ignored there, documented above).
      at = Time.utc(2024, 5, 1, 12, 30, 45)
      row.update!(published_at: at)
      AdapterProbeArticle.find(row.id).published_at.should eq(at)

      # SQLite has no ENUM type: the model-level inclusion validation is
      # the enforcement there.
      bad = AdapterProbeArticle.new(status: "bogus", tags: ["a"])
      bad.valid?.should be_false
      bad.errors[:status].join.should contain("is not included in the list")
    ensure
      Saci::Record.database("primary").close
      if p = prev
        Saci::Record::Base.connection = p
      end
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

class AdapterProbeFk1 < Saci::Record::Migration
  def change
    create_table :fk_probe_users do |t|
      t.string :name
      t.timestamps
    end
    create_table :fk_probe_stories do |t|
      t.string :title, null: false
      t.references :user, foreign_key: true, to_table: :fk_probe_users, on_delete: :cascade
      t.timestamps
    end
  end
end

class AdapterProbeFk2 < Saci::Record::Migration
  def change
    create_table :fk_probe_tags do |t|
      t.string :label
      t.bigint :story_id
      t.foreign_key :fk_probe_stories, column: :story_id, on_delete: :nullify
    end
    add_column :fk_probe_tags, :extra, :string
  end
end

class AdapterProbeRename < Saci::Record::Migration
  def change
    rename_column :fk_probe_stories, :title, :headline
  end
end

class AdapterProbeRenameTable < Saci::Record::Migration
  def change
    create_table :original_things do |t|
      t.string :name
    end
  end
end

class AdapterProbeRenameTable2 < Saci::Record::Migration
  def change
    rename_table :original_things, :renamed_things
  end
end

class AdapterProbeChange < Saci::Record::Migration
  def change
    change_column :change_probe_things, :title, :text
  end
end

class AdapterProbeRemoveFk < Saci::Record::Migration
  def change
    remove_foreign_key :stories, :users
  end
end

class AdapterProbeEnums < Saci::Record::Migration
  def change
    create_table :adapter_probe_articles do |t|
      t.enum :status, values: ["draft", "published"]
      t.string_array :tags
      t.datetime :published_at, precision: 6
      t.timestamps precision: 6
    end
  end
end

class AdapterProbeEnumAdd < Saci::Record::Migration
  def change
    add_column :adapter_probe_articles, :audience, :enum, values: ["free", "paid"]
    add_column :adapter_probe_articles, :labels, :string_array
  end
end

# SQLite enforcement for `t.enum` is model-level (SQLite stores TEXT):
# the inclusion set mirrors the migration's `values:`. Tests run it
# against the primary database (saved/restored, never registered — the
# global registry is asserted exactly by spec/multidb_spec.cr).
class AdapterProbeArticle < Saci::Record::Base
  column id : Int64, primary: true
  column status : String
  column tags : Array(String)
  column published_at : Time
  timestamps

  validates :status, inclusion: {in: ["draft", "published"]}, allow_nil: true
end

# -- live enum/array/precision (compile-time URL gate; pending otherwise) --
#
# Needs real servers (`PG_URL` / `MYSQL_URL` at COMPILE time, like
# spec/schema_spec.cr). The default `crystal spec` stays driver-free and
# reports these as pending.

{% if env("PG_URL") %}
class PgProbeArticle < Saci::Record::Base
  table "pg_probe_articles"
  column id : Int64, primary: true
  column status : String
  column tags : Array(String)
  column published_at : Time
  timestamps

  validates :status, inclusion: {in: ["draft", "published"]}, allow_nil: true
end

class PgProbeEnums < Saci::Record::Migration
  def change
    create_table :pg_probe_articles do |t|
      t.enum :status, values: ["draft", "published"]
      t.string_array :tags
      t.datetime :published_at, precision: 6
      t.timestamps precision: 6
    end
  end
end

describe "PostgreSQL enum/array/precision live" do
  it "round-trips enums, native arrays and microsecond timestamps, dropping the type on rollback" do
    url = ENV["PG_URL"]?
    next if url.nil?
    db : DB::Database? = nil
    begin
      db = Saci::Record.establish_connection("adapter_spec_pg", url)
    rescue
      next
    end
    db = db.as(DB::Database)
    begin
      ad = Saci::Record.adapter_of(db)
      tbl = Saci::Record.quote("pg_probe_articles", ad)
      sm = Saci::Record.quote("schema_migrations", ad)
      c_name = Saci::Record.quote("name", ad)
      begin
        Saci::Record.exec_compat(db, "DROP TABLE IF EXISTS #{tbl}")
        Saci::Record.exec_compat(db, "DROP TYPE IF EXISTS #{Saci::Record.quote("pg_probe_articles_status_enum", ad)}")
        Saci::Record.exec_compat(db, "DELETE FROM #{sm} WHERE #{c_name} = ?", ["PgProbeEnums"] of Saci::Record::Value)
      rescue
      end
      Saci::Record::Migrator.migrate(db, [PgProbeEnums] of Saci::Record::Migration.class)

      # Standalone type exists exactly once (the DO block is idempotent:
      # running the CREATE again is a no-op, so reruns are safe).
      Saci::Record.exec_compat(db, Saci::Record::Migration.create_enum_sql(ad, :pg_probe_articles, :status, ["draft", "published"]).not_nil!)
      Saci::Record.scalar_compat(db,
        "SELECT COUNT(*) FROM pg_type WHERE typname = ?",
        ["pg_probe_articles_status_enum"] of Saci::Record::Value).should eq(1)
      Saci::Record.scalar_compat(db,
        "SELECT datetime_precision FROM information_schema.columns WHERE table_name = ? AND column_name = ?",
        ["pg_probe_articles", "published_at"] of Saci::Record::Value).should eq(6)

      # PostgreSQL enforces the enum at the DB level (invalid values
      # reject even past model validations).
      expect_raises(Exception) do
        db.exec("INSERT INTO #{tbl} (\"status\") VALUES ($1)", "bogus")
      end

      Saci::Record.connected_to("adapter_spec_pg") do
        at = Time.utc(2024, 5, 1, 12, 30, 45, nanosecond: 123456_000)
        row = PgProbeArticle.create!(status: "published", tags: ["a", "b"], published_at: at)
        got = PgProbeArticle.find(row.id)
        got.status.should eq("published")
        got.tags.should eq(["a", "b"])
        got.published_at.should eq(at)
        row.tags = [] of String
        row.save!
        PgProbeArticle.find(row.id).tags.should eq([] of String)
      end

      # Rollback drops the table AND the standalone enum type.
      Saci::Record::Migrator.rollback(db, [PgProbeEnums] of Saci::Record::Migration.class, 1)
      Saci::Record.scalar_compat(db,
        "SELECT COUNT(*) FROM pg_type WHERE typname = ?",
        ["pg_probe_articles_status_enum"] of Saci::Record::Value).should eq(0)
      # ... and the migration re-applies cleanly afterwards.
      Saci::Record::Migrator.migrate(db, [PgProbeEnums] of Saci::Record::Migration.class)
    ensure
      begin
        Saci::Record.exec_compat(db, "DROP TABLE IF EXISTS #{Saci::Record.quote("pg_probe_articles", Saci::Record.adapter_of(db))}")
        Saci::Record.exec_compat(db, "DROP TYPE IF EXISTS #{Saci::Record.quote("pg_probe_articles_status_enum", Saci::Record.adapter_of(db))}")
      rescue
      end
      db.close
    end
  end
end
{% else %}
pending "live PostgreSQL enum/array/precision (set PG_URL at compile time, e.g. postgres://saci:saci@127.0.0.1:55432/saci_test)" do
  raise "needs PG_URL"
end
{% end %}

{% if env("MYSQL_URL") %}
class MyProbeArticle < Saci::Record::Base
  table "my_probe_articles"
  column id : Int64, primary: true
  column status : String
  column tags : Array(String)
  column published_at : Time
  timestamps

  validates :status, inclusion: {in: ["draft", "published"]}, allow_nil: true
end

class MyProbeEnums < Saci::Record::Migration
  def change
    create_table :my_probe_articles do |t|
      t.enum :status, values: ["draft", "published"]
      t.string_array :tags
      t.datetime :published_at, precision: 6
      t.timestamps precision: 6
    end
  end
end

describe "MySQL enum/array/precision live" do
  it "round-trips inline enums, JSON-backed arrays and fractional timestamps" do
    url = ENV["MYSQL_URL"]?
    next if url.nil?
    db : DB::Database? = nil
    begin
      db = Saci::Record.establish_connection("adapter_spec_mysql", url)
    rescue
      next
    end
    db = db.as(DB::Database)
    begin
      ad = Saci::Record.adapter_of(db)
      tbl = Saci::Record.quote("my_probe_articles", ad)
      sm = Saci::Record.quote("schema_migrations", ad)
      c_name = Saci::Record.quote("name", ad)
      begin
        Saci::Record.exec_compat(db, "DROP TABLE IF EXISTS #{tbl}")
        Saci::Record.exec_compat(db, "DELETE FROM #{sm} WHERE #{c_name} = ?", ["MyProbeEnums"] of Saci::Record::Value)
      rescue
      end
      Saci::Record::Migrator.migrate(db, [MyProbeEnums] of Saci::Record::Migration.class)

      # ENUM is inline on MySQL; arrays are TEXT (JSON-encoded, like
      # `:json`, because crystal-mysql cannot decode native JSON).
      Saci::Record.scalar_compat(db,
        "SELECT column_type FROM information_schema.columns WHERE table_schema = DATABASE() AND table_name = ? AND column_name = ?",
        ["my_probe_articles", "status"] of Saci::Record::Value).should eq("enum('draft','published')")
      Saci::Record.scalar_compat(db,
        "SELECT data_type FROM information_schema.columns WHERE table_schema = DATABASE() AND table_name = ? AND column_name = ?",
        ["my_probe_articles", "tags"] of Saci::Record::Value).should eq("text")
      Saci::Record.scalar_compat(db,
        "SELECT datetime_precision FROM information_schema.columns WHERE table_schema = DATABASE() AND table_name = ? AND column_name = ?",
        ["my_probe_articles", "published_at"] of Saci::Record::Value).should eq(6)

      Saci::Record.connected_to("adapter_spec_mysql") do
        at = Time.utc(2024, 5, 1, 12, 30, 45, nanosecond: 123456_000)
        row = MyProbeArticle.create!(status: "draft", tags: ["x,y", "z"], published_at: at)
        got = MyProbeArticle.find(row.id)
        got.status.should eq("draft")
        got.tags.should eq(["x,y", "z"])
        got.published_at.should eq(at)
      end

      # Rollback drops the table (arrays are plain columns — nothing
      # extra; enums are inline — no type to drop).
      Saci::Record::Migrator.rollback(db, [MyProbeEnums] of Saci::Record::Migration.class, 1)
      expect_raises(Exception) do
        Saci::Record.exec_compat(db, "SELECT * FROM #{tbl}")
      end
      Saci::Record::Migrator.migrate(db, [MyProbeEnums] of Saci::Record::Migration.class)
    ensure
      begin
        Saci::Record.exec_compat(db, "DROP TABLE IF EXISTS #{Saci::Record.quote("my_probe_articles", Saci::Record.adapter_of(db))}")
      rescue
      end
      db.close
    end
  end
end
{% else %}
pending "live MySQL enum/array/precision (set MYSQL_URL at compile time, e.g. mysql://saci:saci@127.0.0.1:53306/saci_test)" do
  raise "needs MYSQL_URL"
end
{% end %}
