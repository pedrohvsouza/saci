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

class FtsArticle < Saci::Record::Base
  column id : Int64, primary: true
  column title : String
  column body : String
  column published : Bool, default: true
  timestamps

  validates :title, presence: true
end

# Never indexed — proves the setup guard.
class FtsUnindexed < Saci::Record::Base
  column id : Int64, primary: true
  column title : String
end

FTS_DB_PATH = "/tmp/opencode/saci_fts_test.db"

describe "Saci::Record::FTS" do
  before_all do
    File.delete(FTS_DB_PATH) if File.exists?(FTS_DB_PATH)
    Saci::Record::Base.connection = DB.open("sqlite3://#{FTS_DB_PATH}")
    Saci::Record::Migrator.migrate(
      Saci::Record::Base.connection.as(DB::Database),
      [CreateFtsArticles] of Saci::Record::Migration.class
    )
    Saci::Record::FTS.setup(FtsArticle, [:title, :body])
  end

  after_all do
    Saci::Record::Base.connection.as(DB::Database).close
  end

  before_each do
    # DELETE fires the sync triggers, so base + FTS stay consistent.
    FtsArticle.delete_all
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
    # Failed setup leaves the previous index intact.
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

  it "raises a clear error on non-SQLite adapters" do
    expect_raises(ArgumentError, /SQLite-only/) do
      Saci::Record::FTS.ensure_sqlite!(:postgres)
    end
    expect_raises(ArgumentError, /SQLite-only/) do
      Saci::Record::FTS.ensure_sqlite!(:mysql)
    end
  end
end
