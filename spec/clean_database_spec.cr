require "spec"
require "../src/saci"

{% if env("PG_URL") %}
  require "pg"
{% end %}

# `Saci::Record.clean_database!` on SQLite databases with virtual tables
# (FTS5 external content / own content / contentless, R*Tree) and
# RESTRICT foreign keys (parent/child and self-references).

CLEAN_DB_SCHEMA = [
  "CREATE TABLE schema_migrations (name TEXT PRIMARY KEY)",
  "CREATE TABLE questions (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, body TEXT)",
  "CREATE TABLE notes (id INTEGER PRIMARY KEY, title TEXT NOT NULL)",
  "CREATE VIRTUAL TABLE docs_fts USING fts5(body)",
  "CREATE VIRTUAL TABLE tags_fts USING fts5(name, content='')",
  "CREATE VIRTUAL TABLE boxes USING rtree(id, min_x, max_x)",
  # Parents before children (and a self-reference) so `sqlite_master`
  # order deletes referenced rows first.
  "CREATE TABLE parents (id INTEGER PRIMARY KEY, name TEXT)",
  "CREATE TABLE children (id INTEGER PRIMARY KEY, parent_id INTEGER NOT NULL REFERENCES parents(id) ON DELETE RESTRICT)",
  "CREATE TABLE nodes (id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES nodes(id) ON DELETE RESTRICT)",
] +
                  Saci::Record::FTS.create_sql(:sqlite, "questions", ["title", "body"], external_content: true) +
                  Saci::Record::FTS.create_sql(:sqlite, "notes", ["title"])

def clean_db_seed(db) : Nil
  db.exec "INSERT OR IGNORE INTO schema_migrations (name) VALUES ('CreateEverything')"
  db.exec "INSERT INTO questions (title, body) VALUES ('crystal macros', 'how do macros work'), ('sqlite fts', 'external content')"
  db.exec "INSERT INTO notes (title) VALUES ('crystal note'), ('other note')"
  db.exec "INSERT INTO docs_fts (body) VALUES ('crystal docs')"
  db.exec "INSERT INTO tags_fts (rowid, name) VALUES (1, 'crystal')"
  db.exec "INSERT INTO boxes VALUES (1, 0, 10), (2, 5, 15)"
  db.exec "INSERT INTO parents (id, name) VALUES (1, 'p')"
  db.exec "INSERT INTO children (id, parent_id) VALUES (1, 1)"
  db.exec "INSERT INTO nodes (id, parent_id) VALUES (1, NULL), (2, 1), (3, 2)"
end

def clean_db_count(db, table : String) : Int64
  db.scalar("SELECT COUNT(*) FROM \"#{table}\"").as(Int64)
end

def clean_db_integrity!(db, table : String) : Nil
  db.exec "INSERT INTO \"#{table}\"(\"#{table}\") VALUES('integrity-check')"
end

def clean_db_master(db) : Array(String)
  names = [] of String
  db.query("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name") { |rs| rs.each { names << rs.read(String) } }
  names
end

def with_clean_db(&)
  path = File.tempname("saci_clean_database", ".db")
  url = "sqlite3://#{path}"
  begin
    db = Saci::Record.connect(url)
    CLEAN_DB_SCHEMA.each { |sql| db.exec(sql) }
    clean_db_seed(db)
    yield db, url
  ensure
    Saci::Record.database("primary").close rescue nil
    ["", "-wal", "-shm"].each { |s| File.delete(path + s) if File.exists?(path + s) }
  end
end

def clean_db_assert_clean(db) : Nil
  %w(questions notes parents children nodes docs_fts boxes questions_fts notes_fts).each do |t|
    clean_db_count(db, t).should eq(0)
  end
  clean_db_count(db, "schema_migrations").should eq(1)
  %w(questions_fts notes_fts docs_fts tags_fts).each { |t| clean_db_integrity!(db, t) }
  db.scalar("PRAGMA integrity_check").should eq("ok")
  db.scalar("SELECT COUNT(*) FROM tags_fts WHERE tags_fts MATCH 'crystal'").should eq(0)
end

describe "Saci::Record.clean_database! (SQLite)" do
  it "empties base and virtual tables, keeps the FTS indexes usable and FKs on" do
    with_clean_db do |db, url|
      before = clean_db_master(db)
      Saci::Record.clean_database!
      clean_db_assert_clean(db)
      clean_db_master(db).should eq(before)

      # New connections (the old code wiped `<fts>_config`/`<fts>_data`, so
      # a fresh connection failed with `vtable constructor failed`).
      db.close
      db = Saci::Record.connect(url)
      Saci::Record.clean_database!
      clean_db_assert_clean(db)
      clean_db_master(db).should eq(before)

      # Inserting + searching works again; triggers keep both indexes in
      # sync and AUTOINCREMENT counters are kept.
      db.exec "INSERT INTO questions (title, body) VALUES ('crystal again', 'fresh')"
      db.scalar("SELECT id FROM questions").as(Int64).should eq(3)
      db.scalar("SELECT COUNT(*) FROM questions_fts WHERE questions_fts MATCH 'crystal'").should eq(1)
      db.exec "INSERT INTO notes (title) VALUES ('crystal note')"
      db.scalar("SELECT COUNT(*) FROM notes_fts WHERE notes_fts MATCH 'crystal'").should eq(1)
      db.exec "INSERT INTO docs_fts (body) VALUES ('crystal docs')"
      db.scalar("SELECT COUNT(*) FROM docs_fts WHERE docs_fts MATCH 'docs'").should eq(1)
      db.exec "INSERT INTO tags_fts (rowid, name) VALUES (7, 'crystal')"
      db.scalar("SELECT rowid FROM tags_fts WHERE tags_fts MATCH 'crystal'").should eq(7)
      db.exec "INSERT INTO boxes VALUES (3, 0, 10)"
      db.scalar("SELECT COUNT(*) FROM boxes WHERE min_x <= 5 AND max_x >= 5").should eq(1)
      %w(questions_fts notes_fts docs_fts tags_fts).each { |t| clean_db_integrity!(db, t) }

      # Foreign keys are still enforced on every pooled connection.
      db.using_connection { |conn| conn.scalar("PRAGMA foreign_keys").should eq(1) }
      expect_raises(Exception, /FOREIGN KEY/) do
        db.exec "INSERT INTO children (id, parent_id) VALUES (9, 999)"
      end

      # Cleaning again with fresh rows still works.
      clean_db_seed(db)
      Saci::Record.clean_database!
      clean_db_count(db, "questions").should eq(0)
      clean_db_count(db, "tags_fts").should eq(0)
      clean_db_integrity!(db, "questions_fts")
    end
  end

  it "rebuilds an external-content index that has no sync triggers" do
    with_clean_db do |db, _|
      db.exec "DROP TRIGGER questions_fts_ad"
      Saci::Record.clean_database!
      clean_db_count(db, "questions").should eq(0)
      clean_db_integrity!(db, "questions_fts")
      db.exec "INSERT INTO questions_fts(questions_fts, rank) VALUES('integrity-check', 1)"
    end
  end

  it "keeps foreign keys off when they were off" do
    with_clean_db do |db, _|
      db.using_connection do |conn|
        conn.exec "PRAGMA foreign_keys = OFF"
        Saci::Record.clean_database!(conn).should be > 0
        conn.scalar("PRAGMA foreign_keys").should eq(0)
        conn.exec "PRAGMA foreign_keys = ON"
      end
      clean_db_count(db, "children").should eq(0)
    end
  end

  it "defers foreign keys and deletes children first inside a transaction" do
    with_clean_db do |db, _|
      Saci::Record.transaction do |conn|
        Saci::Record.clean_database!
        conn.scalar("PRAGMA defer_foreign_keys").should eq(0)
        conn.scalar("PRAGMA foreign_keys").should eq(1)
      end
      clean_db_count(db, "parents").should eq(0)
      clean_db_count(db, "children").should eq(0)
      clean_db_integrity!(db, "questions_fts")
    end
  end

  it "cleans self-referencing RESTRICT rows inside a transaction" do
    with_clean_db do |db, _|
      # nodes: 1 <- 2 <- 3 (nullable, RESTRICT) plus a NOT NULL one with a
      # row pointing at itself, declared parent-first. Neither can be
      # deleted with a plain DELETE while foreign keys are enforced.
      db.exec "CREATE TABLE strict_nodes (id INTEGER PRIMARY KEY, parent_id INTEGER NOT NULL REFERENCES strict_nodes(id) ON DELETE RESTRICT)"
      db.exec "INSERT INTO strict_nodes (id, parent_id) VALUES (1, 1), (2, 1), (3, 2)"
      expect_raises(Exception, /FOREIGN KEY/) { db.exec "DELETE FROM nodes" }
      expect_raises(Exception, /FOREIGN KEY/) { db.exec "DELETE FROM strict_nodes" }

      Saci::Record.transaction do |conn|
        conn.scalar("PRAGMA foreign_keys").should eq(1)
        Saci::Record.clean_database!
        # Rows are gone without being nulled first, still inside the
        # transaction, and the pragmas are back to their defaults.
        conn.scalar("SELECT COUNT(*) FROM nodes").should eq(0)
        conn.scalar("SELECT COUNT(*) FROM strict_nodes").should eq(0)
        conn.scalar("PRAGMA defer_foreign_keys").should eq(0)
        conn.scalar("PRAGMA foreign_keys").should eq(1)
      end
      clean_db_assert_clean(db)
      clean_db_count(db, "strict_nodes").should eq(0)
      db.scalar("SELECT COUNT(*) FROM pragma_foreign_key_check").should eq(0)
      expect_raises(Exception, /FOREIGN KEY/) do
        db.exec "INSERT INTO strict_nodes (id, parent_id) VALUES (1, 99)"
      end
    end
  end

  it "keeps the caller's defer_foreign_keys setting" do
    with_clean_db do |db, _|
      Saci::Record.transaction do |conn|
        conn.exec "PRAGMA defer_foreign_keys = ON"
        Saci::Record.clean_database!
        conn.scalar("PRAGMA defer_foreign_keys").should eq(1)
      end
      clean_db_assert_clean(db)
    end
  end

  it "returns the number of emptied tables through DBTasks" do
    with_clean_db do |db, _|
      # 5 base tables (schema_migrations excluded) + 5 virtual tables.
      Saci::DBTasks.clean_database!(db).should eq(10)
      clean_db_assert_clean(db)
    end
  end
end

describe "Saci::Record::Introspection.sqlite_virtual_tables" do
  it "reports module, FTS content option and shadow tables" do
    with_clean_db do |db, _|
      vts = Saci::Record::Introspection.sqlite_virtual_tables(db).to_h { |v| {v.name, v} }
      vts.keys.sort.should eq(%w(boxes docs_fts notes_fts questions_fts tags_fts))
      vts["questions_fts"].module_name.should eq("fts5")
      vts["questions_fts"].fts_content.should eq("questions")
      vts["questions_fts"].shadow_tables.sort.should eq(%w(questions_fts_config questions_fts_data questions_fts_docsize questions_fts_idx))
      vts["notes_fts"].fts_content.should be_nil
      vts["notes_fts"].shadow_tables.should contain("notes_fts_content")
      vts["tags_fts"].fts_content.should eq("")
      vts["boxes"].module_name.should eq("rtree")
      vts["boxes"].shadow_tables.sort.should eq(%w(boxes_node boxes_parent boxes_rowid))
      vts["boxes"].fts?.should be_false

      names = Saci::Record::Introspection.virtual_and_shadow_tables(db)
      names.should contain("questions_fts_data")
      names.should_not contain("questions")
      Saci::Record.virtual_tables(db, ["questions", "questions_fts_idx", "boxes_node"])
        .should eq(%w(docs_fts tags_fts boxes questions_fts notes_fts questions_fts_idx boxes_node))
    end
  end
end

# Live PostgreSQL: TRUNCATEs every `public` table of PG_URL, so point it at
# a dedicated test database.
{% if env("PG_URL") %}
  describe "Saci::Record.clean_database! (PostgreSQL live)" do
    it "truncates RESTRICT parents/children and self-references in one statement, keeping ids" do
      db = Saci::Record.establish_connection("clean_db_pg", ENV["PG_URL"])
      begin
        db.exec "DROP TABLE IF EXISTS clean_pg_children, clean_pg_nodes, clean_pg_parents"
        db.exec "CREATE TABLE clean_pg_parents (id BIGSERIAL PRIMARY KEY)"
        db.exec "CREATE TABLE clean_pg_children (id BIGSERIAL PRIMARY KEY, parent_id BIGINT NOT NULL REFERENCES clean_pg_parents(id) ON DELETE RESTRICT)"
        db.exec "CREATE TABLE clean_pg_nodes (id BIGSERIAL PRIMARY KEY, parent_id BIGINT REFERENCES clean_pg_nodes(id) ON DELETE RESTRICT)"
        db.exec "INSERT INTO clean_pg_parents DEFAULT VALUES"
        db.exec "INSERT INTO clean_pg_children (parent_id) SELECT id FROM clean_pg_parents"
        db.exec "INSERT INTO clean_pg_nodes (parent_id) VALUES (NULL)"
        db.exec "INSERT INTO clean_pg_nodes (parent_id) SELECT MIN(id) FROM clean_pg_nodes"
        Saci::Record.connected_to("clean_db_pg") { Saci::Record.clean_database! }
        %w(clean_pg_parents clean_pg_children clean_pg_nodes).each do |t|
          db.scalar("SELECT COUNT(*) FROM #{t}").should eq(0)
        end
        db.scalar("INSERT INTO clean_pg_parents DEFAULT VALUES RETURNING id").as(Int64).should be > 1
      ensure
        db.exec "DROP TABLE IF EXISTS clean_pg_children, clean_pg_nodes, clean_pg_parents" rescue nil
        db.close
        Saci::Record.remove_connection("clean_db_pg")
      end
    end
  end
{% else %}
  pending "live PostgreSQL clean_database! (set PG_URL at compile time to a dedicated test database)" do
    raise "needs PG_URL"
  end
{% end %}
