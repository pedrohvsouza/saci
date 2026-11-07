require "spec"
require "file"
require "../src/saci"

class CreateDeepOrmTables < Saci::Record::Migration
  def change
    create_table :deep_authors do |t|
      t.string :name
      t.timestamps
    end

    create_table :deep_posts do |t|
      t.string :title
      t.integer :deep_author_id
      t.integer :lock_version, default: 0
      t.timestamps
    end

    create_table :deep_comments do |t|
      t.text :body
      t.integer :deep_post_id
      t.timestamps
    end

    create_table :deep_accounts do |t|
      t.integer :deep_author_id
      t.string :label
      t.timestamps
    end

    create_table :deep_profiles do |t|
      t.integer :deep_account_id
      t.string :bio
      t.timestamps
    end

    create_table :deep_tags do |t|
      t.string :name
      t.timestamps
    end

    create_table :deep_taggings do |t|
      t.integer :deep_post_id
      t.integer :deep_tag_id
      t.timestamps
    end

    create_table :deep_poly_taggings do |t|
      t.integer :deep_post_id
      t.integer :taggable_id
      t.string :taggable_type
      t.timestamps
    end

    create_table :deep_articles do |t|
      t.string :title
      t.timestamps
    end

    create_table :deep_articles_deep_tags, id: false do |t|
      t.integer :deep_article_id
      t.integer :deep_tag_id
    end
  end
end

class DeepAuthor < Saci::Record::Base
  column id : Int64, primary: true
  column name : String
  timestamps

  validates :name, presence: true

  has_many :deep_posts, autosave: true
  has_many :deep_comments, through: :deep_posts

  has_one :deep_account
  has_one :deep_profile, through: :deep_account, source: :deep_profile

  accepts_nested_attributes_for :deep_account, update_only: true
end

class DeepPost < Saci::Record::Base
  column id : Int64, primary: true
  column title : String
  column deep_author_id : Int64
  column lock_version : Int32, default: 0
  timestamps

  validates :title, presence: true

  belongs_to :deep_author, autosave: true, touch: true

  has_many :deep_comments
  has_many :deep_taggings
  has_many :deep_tags, through: :deep_taggings
  has_many :deep_poly_taggings
  has_many :deep_poly_tags, class_name: "DeepTag", through: :deep_poly_taggings,
    source: :taggable, source_type: "DeepTag"

  accepts_nested_attributes_for :deep_comments, allow_destroy: true,
    reject_if: :all_blank, limit: 3
end

class DeepComment < Saci::Record::Base
  column id : Int64, primary: true
  column body : String
  column deep_post_id : Int64
  timestamps

  validates :body, presence: true, length: {maximum: 20}

  belongs_to :deep_post

  # Used by the transactional rollback spec: a before_save explosion must
  # take the parent INSERT down with it.
  @@explode = false

  def self.explode=(value : Bool)
    @@explode = value
  end

  before_save do
    raise "comment exploded" if @@explode && body == "boom"
  end
end

class DeepAccount < Saci::Record::Base
  column id : Int64, primary: true
  column deep_author_id : Int64
  column label : String
  timestamps

  belongs_to :deep_author
  has_one :deep_profile
end

class DeepProfile < Saci::Record::Base
  column id : Int64, primary: true
  column deep_account_id : Int64
  column bio : String
  timestamps

  belongs_to :deep_account
end

class DeepTag < Saci::Record::Base
  column id : Int64, primary: true
  column name : String
  timestamps

  has_many :deep_taggings
  has_many :deep_posts, through: :deep_taggings
end

class DeepTagging < Saci::Record::Base
  column id : Int64, primary: true
  column deep_post_id : Int64
  column deep_tag_id : Int64
  timestamps

  validates :deep_tag_id, presence: true

  belongs_to :deep_post
  belongs_to :deep_tag
end

class DeepPolyTagging < Saci::Record::Base
  column id : Int64, primary: true
  column deep_post_id : Int64
  column taggable_id : Int64
  column taggable_type : String
  timestamps

  belongs_to :taggable, polymorphic: true
end

class DeepArticle < Saci::Record::Base
  column id : Int64, primary: true
  column title : String
  timestamps

  has_and_belongs_to_many :deep_tags, join_table: "deep_articles_deep_tags",
    foreign_key: "deep_article_id", association_foreign_key: "deep_tag_id"
end

DEEP_DB_PATH = "/tmp/opencode/saci_orm_deep_test.db"

def deep_db : DB::Database
  Saci::Record::Base.connection.as(DB::Database)
end

describe "Saci::Record deep ActiveRecord gaps" do
  before_all do
    File.delete(DEEP_DB_PATH) if File.exists?(DEEP_DB_PATH)
    Saci::Record::Base.connection = DB.open("sqlite3://#{DEEP_DB_PATH}")
    Saci::Record::Migrator.migrate(deep_db, [CreateDeepOrmTables] of Saci::Record::Migration.class)
  end

  after_all do
    deep_db.close
  end

  describe "nested attributes (G19)" do
    it "creates children from symbol-keyed mass assignment" do
      post = DeepPost.create!(title: "na-create", deep_comments_attributes: [{body: "first"}, {body: "second"}])
      post.persisted?.should be_true
      comments = DeepComment.where(deep_post_id: post.id).order(:id).to_a
      comments.map(&.body).should eq(["first", "second"])
      post.previous_changes.has_key?("title").should be_true
    end

    it "accepts string keys, a single hash and an index-keyed params hash" do
      post = DeepPost.new(title: "na-params")
      post.deep_comments_attributes = {"0" => {"body" => "zero"}, "1" => {"body" => "one"}}
      post.save.should be_true
      DeepComment.where(deep_post_id: post.id).count.should eq(2)

      post.deep_comments_attributes = {"body" => "single"}
      post.save.should be_true
      DeepComment.where(deep_post_id: post.id).count.should eq(3)
    end

    it "updates existing children and destroys with _destroy" do
      post = DeepPost.create!(title: "na-update", deep_comments_attributes: [{body: "keep"}, {body: "drop"}])
      keep = DeepComment.where(deep_post_id: post.id, body: "keep").first!
      drop = DeepComment.where(deep_post_id: post.id, body: "drop").first!

      post.deep_comments_attributes = [
        {"id" => keep.id.to_s, "body" => "kept"},
        {"id" => drop.id.to_s, "_destroy" => "1"},
      ]
      post.save.should be_true

      keep.reload.body.should eq("kept")
      DeepComment.where(id: drop.id).exists?.should be_false
      DeepComment.where(deep_post_id: post.id).count.should eq(1)
    end

    it "keeps children when allow_destroy is not enabled" do
      # DeepAuthor's has_one nested attributes do not pass allow_destroy;
      # an update_only hash without id must never delete the account.
      author = DeepAuthor.create!(name: "na-nodelete")
      account = DeepAccount.create!(deep_author_id: author.id, label: "old")
      author.deep_account_attributes = {"label" => "new"}
      author.save.should be_true
      DeepAccount.where(id: account.id, label: "new").exists?.should be_true
    end

    it "rejects all-blank submissions" do
      post = DeepPost.create!(title: "na-reject", deep_comments_attributes: [{body: ""}, {body: "   "}])
      DeepComment.where(deep_post_id: post.id).count.should eq(0)
    end

    it "enforces the collection limit" do
      post = DeepPost.new(title: "na-limit")
      expect_raises(Saci::Record::TooManyRecords) do
        post.deep_comments_attributes = [
          {"body" => "1"}, {"body" => "2"}, {"body" => "3"}, {"body" => "4"},
        ]
      end
    end

    it "propagates invalid children to the parent and writes nothing" do
      post = DeepPost.new(title: "na-invalid", deep_comments_attributes: [{body: "this body is definitely too long"}])
      post.valid?.should be_false
      post.errors["deep_comments"].should contain("is invalid")
      post.save.should be_false
      DeepPost.where(title: "na-invalid").exists?.should be_false
      DeepComment.where(deep_post_id: nil).count.should eq(0)
    end

    it "rolls the parent back when a child write raises" do
      before_posts = DeepPost.count
      before_comments = DeepComment.count
      DeepComment.explode = true
      begin
        expect_raises(Exception, "comment exploded") do
          DeepPost.create!(title: "na-rollback", deep_comments_attributes: [{body: "boom"}])
        end
      ensure
        DeepComment.explode = false
      end
      DeepPost.count.should eq(before_posts)
      DeepComment.count.should eq(before_comments)
      DeepPost.where(title: "na-rollback").exists?.should be_false
    end
  end

  describe "pessimistic locking and isolation (G21)" do
    it "locks and reloads a row inside a transaction on SQLite" do
      post = DeepPost.create!(title: "lock-before")
      DeepPost.where(id: post.id).update_all(title: "lock-after")

      result = post.with_lock do |locked|
        locked.title.should eq("lock-after")
        locked.title = "lock-inside"
        locked.save!
        :done
      end

      result.should eq(:done)
      post.reload.title.should eq("lock-inside")
    end

    it "requires a transaction for lock!" do
      post = DeepPost.create!(title: "lock-required")
      expect_raises(Saci::Record::TransactionRequired) { post.lock! }
    end

    it "generates FOR UPDATE SQL on PostgreSQL/MySQL and omits it on SQLite" do
      query = DeepPost.where(title: "lock-before").lock
      query.to_sql(:postgres).should contain("FOR UPDATE")
      query.to_sql(:mysql).should contain("FOR UPDATE")
      query.to_sql(:sqlite).should_not contain("FOR UPDATE")
    end

    it "generates driver isolation statements" do
      Saci::Record.isolation_sql(:postgres, :serializable).should eq("BEGIN ISOLATION LEVEL SERIALIZABLE")
      Saci::Record.isolation_sql(:postgres, :repeatable_read).should eq("BEGIN ISOLATION LEVEL REPEATABLE READ")
      Saci::Record.isolation_sql(:mysql, :read_committed).should eq("SET TRANSACTION ISOLATION LEVEL READ COMMITTED")
      Saci::Record.isolation_sql(:mysql, :read_uncommitted).should eq("SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED")
      Saci::Record.isolation_sql(:sqlite, :serializable).should be_nil
      expect_raises(ArgumentError) { Saci::Record.isolation_sql(:postgres, :bogus) }
    end

    it "runs transaction(isolation:) with a documented SQLite fallback" do
      value = DeepPost.transaction(isolation: :serializable) do |_conn|
        DeepPost.create!(title: "isolation-sqlite").id
      end
      value.should_not be_nil
      DeepPost.where(title: "isolation-sqlite").exists?.should be_true

      # Nested calls join the open transaction and ignore isolation.
      DeepPost.transaction do |_conn|
        nested = DeepPost.transaction(isolation: :repeatable_read) { |_c| :nested }
        nested.should eq(:nested)
      end
    end

    it "suppresses belongs_to touches inside no_touching (G238)" do
      author = DeepAuthor.create!(name: "no-touch-author")
      post = DeepPost.new(title: "no-touch-1")
      post.deep_author = author
      post.save!
      stamp = author.reload.updated_at

      Saci::Record.no_touching do
        post.title = "no-touch-2"
        post.save!
        post.touch.should be_true
        Saci::Record.no_touching do
          post.touch.should be_true
        end
      end

      author.reload.updated_at.should eq(stamp)
    end
  end

  describe "optimistic locking (G20)" do
    it "starts at version 0 and increments on update" do
      post = DeepPost.create!(title: "optimistic")
      post.lock_version.should eq(0)

      post.title = "optimistic-1"
      post.save.should be_true
      post.lock_version.should eq(1)
      post.saved_change_to_lock_version.should eq([0, 1])
      post.lock_version_changed?.should be_false
      post.reload.lock_version.should eq(1)
    end

    it "raises StaleObjectError when another writer changed the row" do
      post = DeepPost.create!(title: "stale-base")
      first = DeepPost.find(post.id)
      second = DeepPost.find(post.id)

      first.title = "stale-first"
      first.save.should be_true

      second.title = "stale-second"
      expect_raises(Saci::Record::StaleObjectError) { second.save! }
      DeepPost.find(post.id).title.should eq("stale-first")
    end
  end

  describe "has_one :through (G186)" do
    it "reads, assigns, preloads and joins through the intermediate record" do
      author = DeepAuthor.create!(name: "ho-author")
      account = DeepAccount.create!(deep_author_id: author.id, label: "main")
      DeepProfile.create!(deep_account_id: account.id, bio: "first bio")

      author.deep_profile.not_nil!.bio.should eq("first bio")

      loaded = DeepAuthor.where(id: author.id).includes(:deep_profile).first!
      loaded.__saci_assoc_cache.has_key?("deep_profile").should be_true
      loaded.deep_profile.not_nil!.bio.should eq("first bio")

      joined = DeepAuthor.joins(:deep_profile).where("deep_profiles.bio = ?", "first bio").first
      joined.not_nil!.id.should eq(author.id)

      replacement = DeepProfile.new(bio: "second bio")
      author.deep_profile = replacement
      replacement.persisted?.should be_true
      author.deep_profile.not_nil!.bio.should eq("second bio")
      DeepProfile.where(deep_account_id: account.id).count.should eq(1)
    end
  end

  describe "batched through preloading (G187)" do
    it "preloads classic has_many :through with two queries" do
      p1 = DeepPost.create!(title: "pre-1")
      p2 = DeepPost.create!(title: "pre-2")
      t1 = DeepTag.create!(name: "pre-a")
      t2 = DeepTag.create!(name: "pre-b")
      DeepTagging.create!(deep_post_id: p1.id, deep_tag_id: t1.id)
      DeepTagging.create!(deep_post_id: p2.id, deep_tag_id: t2.id)

      posts = DeepPost.where("title LIKE 'pre-%'").includes(:deep_tags).order(:title).to_a
      posts.size.should eq(2)
      posts.each { |p| p.__saci_assoc_cache.has_key?("deep_tags").should be_true }
      posts[0].deep_tags.map(&.name).should eq(["pre-a"])
      posts[1].deep_tags.map(&.name).should eq(["pre-b"])
    end

    it "preloads nested through (author -> posts -> comments)" do
      author = DeepAuthor.create!(name: "nested-through")
      post = DeepPost.create!(title: "nested-through-post", deep_author_id: author.id)
      DeepComment.create!(body: "nested-1", deep_post_id: post.id)
      DeepComment.create!(body: "nested-2", deep_post_id: post.id)

      loaded = DeepAuthor.where(id: author.id).includes(:deep_comments).first!
      loaded.__saci_assoc_cache.has_key?("deep_comments").should be_true
      loaded.deep_comments.map(&.body).compact.sort.should eq(["nested-1", "nested-2"])
    end

    it "honors source: for reverse through associations" do
      post = DeepPost.create!(title: "reverse-source")
      tag = DeepTag.create!(name: "reverse")
      DeepTagging.create!(deep_post_id: post.id, deep_tag_id: tag.id)

      loaded = DeepTag.where(id: tag.id).includes(:deep_posts).first!
      loaded.__saci_assoc_cache.has_key?("deep_posts").should be_true
      loaded.deep_posts.map(&.title).should eq(["reverse-source"])
    end

    it "filters polymorphic source_type rows" do
      post = DeepPost.create!(title: "poly-source")
      tag = DeepTag.create!(name: "poly-tag")
      DeepPolyTagging.create!(deep_post_id: post.id, taggable_id: tag.id, taggable_type: "DeepTag")
      # Same numeric id, wrong type — must be ignored by source_type.
      DeepPolyTagging.create!(deep_post_id: post.id, taggable_id: tag.id, taggable_type: "DeepAuthor")

      post.deep_poly_tags.map(&.id).should eq([tag.id])
      loaded = DeepPost.where(id: post.id).includes(:deep_poly_tags).first!
      loaded.deep_poly_tags.map(&.id).should eq([tag.id])
    end
  end

  describe "autosave associations (G240)" do
    it "saves built has_many children with the owner in one transaction" do
      author = DeepAuthor.new(name: "auto-author")
      p1 = author.deep_posts.build(title: "auto-1")
      p2 = author.deep_posts.build(title: "auto-2")
      author.deep_posts.to_a.map(&.title).compact.sort.should eq(["auto-1", "auto-2"])

      author.save.should be_true
      p1.persisted?.should be_true
      p2.persisted?.should be_true
      p1.deep_author_id.should eq(author.id)
      p2.deep_author_id.should eq(author.id)
      DeepPost.where(deep_author_id: author.id).count.should eq(2)
    end

    it "saves dirty children loaded with includes" do
      author = DeepAuthor.create!(name: "auto-dirty")
      DeepPost.create!(title: "before-dirty", deep_author_id: author.id)

      loaded = DeepAuthor.where(id: author.id).includes(:deep_posts).first!
      child = loaded.deep_posts.first!
      child.title = "after-dirty"
      loaded.save.should be_true
      child.reload.title.should eq("after-dirty")
    end

    it "saves an assigned belongs_to before the owner" do
      author = DeepAuthor.new(name: "auto-belongs")
      post = DeepPost.new(title: "auto-belongs-post")
      post.deep_author = author

      post.save.should be_true
      author.persisted?.should be_true
      post.deep_author_id.should eq(author.id)
    end

    it "leaves autosave: false associations manual" do
      post = DeepPost.create!(title: "manual-post")
      tag = DeepTag.new(name: "manual-tag")
      # DeepTagging has plain belongs_to associations (no autosave):
      # assigning the target does not persist it.
      tagging = DeepTagging.new(deep_post_id: post.id)
      tagging.deep_tag = tag
      tagging.save.should be_false
      tag.persisted?.should be_false
    end
  end

  describe "has_and_belongs_to_many (G33)" do
    it "adds, removes and replaces join rows" do
      article = DeepArticle.create!(title: "habtm")
      t1 = DeepTag.create!(name: "habtm-a")
      t2 = DeepTag.create!(name: "habtm-b")

      article.deep_tags << t1
      article.deep_tags << t1 # idempotent
      article.deep_tags << t2
      article.deep_tags.map(&.name).compact.sort.should eq(["habtm-a", "habtm-b"])

      article.delete(t1)
      article.deep_tags.map(&.name).compact.sort.should eq(["habtm-b"])

      article.deep_tags = [t1]
      article.deep_tags.map(&.name).compact.sort.should eq(["habtm-a"])

      count = Saci::Record.scalar_compat(deep_db,
        "SELECT COUNT(*) FROM deep_articles_deep_tags WHERE deep_article_id = ?",
        [article.id] of Saci::Record::Value)
      count.as(Int64).should eq(1)
    end

    it "preloads the target collection in two queries" do
      a1 = DeepArticle.create!(title: "habtm-pre-1")
      a2 = DeepArticle.create!(title: "habtm-pre-2")
      t1 = DeepTag.create!(name: "habtm-pre-a")
      t2 = DeepTag.create!(name: "habtm-pre-b")
      a1.deep_tags = [t1]
      a2.deep_tags = [t2]

      articles = DeepArticle.where("title LIKE 'habtm-pre-%'").includes(:deep_tags).order(:title).to_a
      articles.size.should eq(2)
      articles.each { |a| a.__saci_assoc_cache.has_key?("deep_tags").should be_true }
      articles[0].deep_tags.map(&.name).should eq(["habtm-pre-a"])
      articles[1].deep_tags.map(&.name).should eq(["habtm-pre-b"])

      joined = DeepArticle.joins(:deep_tags).where("deep_tags.name = ?", "habtm-pre-a").first
      joined.not_nil!.title.should eq("habtm-pre-1")
    end
  end
end
