require "spec"
require "../src/saci"

class CreateFtsArticles < Saci::Record::Migration
  def change
    create_table :fts_articles do |t|
      t.string :title, null: false
      t.text :body
      t.boolean :published, default: true
      t.timestamps
    end
  end
end

class CreateFtsPosts < Saci::Record::Migration
  def change
    create_table :fts_posts do |t|
      t.string :title, null: false
      t.text :body
    end
    create_fts_table :fts_posts, [:title, :body],
      tokenize: "unicode61 remove_diacritics 2", external_content: true
  end
end

class CreateFtsNotes < Saci::Record::Migration
  def change
    create_table :fts_notes do |t|
      t.string :title, null: false
    end
  end
end

class CreateFtsNotesIndex < Saci::Record::Migration
  def change
    create_fts_table :fts_notes, [:title]
  end
end

class FtsPost < Saci::Record::Base
  column id : Int64, primary: true
  column title : String
  column body : String

  fts_search [:title, :body]
end

class FtsNote < Saci::Record::Base
  column id : Int64, primary: true
  column title : String
end

class FtsArticle < Saci::Record::Base
  column id : Int64, primary: true
  column title : String
  column body : String
  column published : Bool, default: true
  timestamps

  validates :title, presence: true
end

class FtsUnindexed < Saci::Record::Base
  column id : Int64, primary: true
  column title : String
end

FTS_DB_PATH = "/tmp/opencode/saci_fts_test.db"

describe "Saci::Record::FTS" do
  before_all do
    Dir.mkdir_p(File.dirname(FTS_DB_PATH))
    File.delete(FTS_DB_PATH) if File.exists?(FTS_DB_PATH)
    Saci::Record::Base.connection = DB.open("sqlite3://#{FTS_DB_PATH}")
    Saci::Record::Migrator.migrate(
      Saci::Record::Base.connection.as(DB::Database),
      [CreateFtsArticles, CreateFtsPosts, CreateFtsNotes] of Saci::Record::Migration.class
    )
    Saci::Record::FTS.setup(FtsArticle, [:title, :body])
  end

  after_all do
    Saci::Record::Base.connection.as(DB::Database).close
  end

  before_each do
    # DELETE fires the sync triggers, so base + FTS stay consistent.
    FtsArticle.delete_all
    FtsPost.delete_all
  end

  it "finds rows by indexed terms" do
    FtsArticle.create!(title: "crystal language", body: "fast and fun")
    FtsArticle.create!(title: "ruby language", body: "slow and fun")
    FtsArticle.search_fts("crystal").map(&.title).should eq(["crystal language"])
    FtsArticle.search_fts("fun").count.should eq(2)
  end

  it "syncs updates and destroys through triggers" do
    a = FtsArticle.create!(title: "crystal language", body: "v1")
    a.update!(title: "ruby language")
    FtsArticle.search_fts("crystal").to_a.should be_empty
    FtsArticle.search_fts("ruby").map(&.title).should eq(["ruby language"])
    a.destroy.should be_true
    FtsArticle.search_fts("ruby").to_a.should be_empty
  end

  it "orders by rank (best match first)" do
    FtsArticle.create!(title: "ruby ruby ruby", body: "ruby")
    FtsArticle.create!(title: "ruby", body: "once")
    FtsArticle.search_fts("ruby").map(&.title).should eq(["ruby ruby ruby", "ruby"])
  end

  it "returns a chainable query" do
    FtsArticle.create!(title: "ruby draft", body: "ruby", published: false)
    FtsArticle.create!(title: "ruby live", body: "ruby", published: true)
    FtsArticle.search_fts("ruby").where(published: true).map(&.title).should eq(["ruby live"])
    FtsArticle.search_fts("ruby").where(published: true).limit(1).count.should eq(1)
    FtsArticle.where(published: false).search_fts("ruby").map(&.title).should eq(["ruby draft"])
  end

  it "matches nothing on a blank query" do
    FtsArticle.create!(title: "crystal", body: "x")
    FtsArticle.search_fts("").to_a.should be_empty
    FtsArticle.search_fts("   ").count.should eq(0)
  end

  it "requires setup before searching" do
    expect_raises(ArgumentError, /no FTS index/) { FtsUnindexed.search_fts("x") }
  end

  it "rejects unknown columns at setup" do
    expect_raises(ArgumentError, /unknown column/) do
      Saci::Record::FTS.setup(FtsArticle, [:bogus_col])
    end
    FtsArticle.create!(title: "still indexed", body: "y")
    FtsArticle.search_fts("indexed").count.should eq(1)
  end

  it "rebuilds the index from base rows" do
    FtsArticle.create!(title: "rebuild me", body: "please")
    Saci::Record::Base.connection.as(DB::Database).exec(
      %(DELETE FROM "#{Saci::Record::FTS.fts_table_name(FtsArticle)}")
    )
    FtsArticle.search_fts("rebuild").to_a.should be_empty
    Saci::Record::FTS.rebuild!(FtsArticle)
    FtsArticle.search_fts("rebuild").map(&.title).should eq(["rebuild me"])
  end

  describe "setup on an existing index" do
    it "skips the DDL and rebuild when the index is in sync" do
      db = Saci::Record::Base.connection.as(DB::Database)
      a = FtsArticle.create!(title: "crystal", body: "x")
      # Same rowids, different text: only a rebuild would undo this.
      db.exec(%(UPDATE "fts_articles_fts" SET title = 'marker' WHERE rowid = ?), a.id)
      Saci::Record::FTS.setup(FtsArticle, [:title, :body])
      FtsArticle.search_fts("marker").count.should eq(1)
      FtsArticle.search_fts("crystal").count.should eq(0)

      Saci::Record::FTS.setup(FtsArticle, [:title, :body], force: true)
      FtsArticle.search_fts("marker").count.should eq(0)
      FtsArticle.search_fts("crystal").count.should eq(1)
    end

    it "rebuilds when the index is out of sync" do
      db = Saci::Record::Base.connection.as(DB::Database)
      FtsArticle.create!(title: "lost row", body: "x")
      db.exec(%(DELETE FROM "fts_articles_fts"))
      FtsArticle.search_fts("lost").count.should eq(0)
      Saci::Record::FTS.setup(FtsArticle, [:title, :body])
      FtsArticle.search_fts("lost").count.should eq(1)
    end

    it "recreates a missing trigger and rebuilds" do
      db = Saci::Record::Base.connection.as(DB::Database)
      db.exec(%(DROP TRIGGER "fts_articles_fts_ai"))
      FtsArticle.create!(title: "untracked", body: "x")
      FtsArticle.search_fts("untracked").count.should eq(0)
      Saci::Record::FTS.setup(FtsArticle, [:title, :body])
      FtsArticle.search_fts("untracked").count.should eq(1)
      FtsArticle.create!(title: "tracked", body: "x")
      FtsArticle.search_fts("tracked").count.should eq(1)
    end

    it "recreates the index when its definition changes" do
      db = Saci::Record::Base.connection.as(DB::Database)
      FtsArticle.create!(title: "alpha", body: "beta")
      Saci::Record::FTS.setup(FtsArticle, [:title], tokenize: "porter unicode61")
      sql = db.query_one("SELECT sql FROM sqlite_master WHERE name = 'fts_articles_fts'", as: String)
      sql.should contain("porter unicode61")
      sql.should_not contain("body")
      FtsArticle.search_fts("alpha").count.should eq(1)
      Saci::Record::FTS.setup(FtsArticle, [:title, :body])
      FtsArticle.search_fts("beta").count.should eq(1)
    end

    it "only registers over an in-sync create_fts_table index (external content)" do
      db = Saci::Record::Base.connection.as(DB::Database)
      FtsPost.create!(title: "Ação", body: "x")
      before = db.query_all("SELECT type || ':' || name || ':' || COALESCE(sql, '') FROM sqlite_master WHERE name LIKE 'fts_posts_fts%' ORDER BY name", as: String)
      Saci::Record::FTS.setup(FtsPost, [:title, :body], tokenize: "unicode61 remove_diacritics 2", external_content: true)
      db.query_all("SELECT type || ':' || name || ':' || COALESCE(sql, '') FROM sqlite_master WHERE name LIKE 'fts_posts_fts%' ORDER BY name", as: String).should eq(before)
      FtsPost.search_fts("acao").count.should eq(1)

      # Drop a trigger: the next setup restores it and rebuilds.
      db.exec(%(DROP TRIGGER "fts_posts_fts_ai"))
      FtsPost.create!(title: "silent", body: "x")
      Saci::Record::FTS.setup(FtsPost, [:title, :body], tokenize: "unicode61 remove_diacritics 2", external_content: true)
      FtsPost.search_fts("silent").count.should eq(1)
      db.exec(%(INSERT INTO "fts_posts_fts"("fts_posts_fts", rank) VALUES ('integrity-check', 1)))
    end
  end

  it "raises a clear error on non-SQLite adapters" do
    expect_raises(ArgumentError, /SQLite-only/) do
      Saci::Record::FTS.ensure_sqlite!(:postgres)
    end
    expect_raises(ArgumentError, /SQLite-only/) do
      Saci::Record::FTS.ensure_sqlite!(:mysql)
    end
  end

  describe "migration helper + fts_search" do
    it "matches accent-insensitively with remove_diacritics" do
      FtsPost.create!(title: "Ação rápida", body: "café com pão")
      FtsPost.search_fts("acao").map(&.title).should eq(["Ação rápida"])
      FtsPost.search_fts("RAPIDA").count.should eq(1)
      FtsPost.search_fts("cafe pao").count.should eq(1)
      FtsPost.search_fts("pão").count.should eq(1)
    end

    it "keeps an external content index correct on insert/update/delete" do
      db = Saci::Record::Base.connection.as(DB::Database)
      Saci::Record::FTS.external_content?(db, "fts_posts").should be_true
      Saci::Record::FTS.external_content?(db, "fts_articles").should be_false
      integrity = -> { db.exec(%(INSERT INTO "fts_posts_fts"("fts_posts_fts", rank) VALUES ('integrity-check', 1))) }

      a = FtsPost.create!(title: "crystal language", body: "v1")
      FtsPost.create!(title: "ruby language", body: "v1")
      FtsPost.search_fts("crystal").map(&.title).should eq(["crystal language"])
      integrity.call

      a.update!(title: "elixir language")
      FtsPost.search_fts("crystal").to_a.should be_empty
      FtsPost.search_fts("elixir").map(&.title).should eq(["elixir language"])
      FtsPost.search_fts("language").count.should eq(2)
      integrity.call

      a.destroy.should be_true
      FtsPost.search_fts("elixir").to_a.should be_empty
      FtsPost.search_fts("language").count.should eq(1)
      integrity.call

      Saci::Record::FTS.rebuild!(FtsPost)
      FtsPost.search_fts("language").map(&.title).should eq(["ruby language"])
      integrity.call
    end

    it "creates, backfills and reverts the index" do
      db = Saci::Record::Base.connection.as(DB::Database)
      objects = -> {
        db.query_all("SELECT name FROM sqlite_master WHERE name LIKE 'fts_notes_fts%' ORDER BY name", as: String)
      }
      FtsNote.create!(title: "before the index")
      objects.call.should be_empty

      CreateFtsNotesIndex.new(db).up
      objects.call.should contain("fts_notes_fts")
      ["ai", "ad", "au"].each do |sfx|
        db.query_one("SELECT count(*) FROM sqlite_master WHERE type = 'trigger' AND name = ?", "fts_notes_fts_#{sfx}", as: Int64).should eq(1)
      end
      Saci::Record::FTS.register(FtsNote, [:title])
      FtsNote.search_fts("before").count.should eq(1)
      FtsNote.create!(title: "after the index")
      FtsNote.search_fts("after").count.should eq(1)

      CreateFtsNotesIndex.new(db).down
      objects.call.should be_empty
      db.query_one("SELECT count(*) FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'fts_notes_fts_%'", as: Int64).should eq(0)
      FtsNote.create!(title: "no index, no trigger") # would fail if a trigger survived
      FtsNote.count.should eq(3)
    end

    it "registers at runtime without DDL or a rebuild" do
      db = Saci::Record::Base.connection.as(DB::Database)
      FtsArticle.create!(title: "registered only", body: "x")
      db.exec(%(DELETE FROM "fts_articles_fts"))
      FtsArticle.fts_search [:title, :body]
      FtsArticle.search_fts("registered").to_a.should be_empty # no rebuild
      Saci::Record::FTS.rebuild!(FtsArticle)
      FtsArticle.search_fts("registered").count.should eq(1)
      expect_raises(ArgumentError, /unknown column/) { FtsPost.fts_search [:nope] }
    end

    it "renders tokenize and escapes quotes" do
      sql = Saci::Record::FTS.create_sql(:sqlite, "t", ["a"], tokenize: "porter 'x'").first
      sql.should contain("tokenize='porter ''x'''")
      sql.should_not contain("content=")
    end
  end
end
