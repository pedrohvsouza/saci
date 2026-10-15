require "spec"
require "../src/saci"
require "pg"

# Live PostgreSQL harness. Needs a server; `live/run.sh` provides the URL
# (and the OpenSSL link shim). Run: `live/run.sh` (both adapters) or
# `PG_URL=postgres://... crystal spec live/pg_live_spec.cr --link-flags=...`.
LIVE_PG_URL = ENV["PG_URL"]? || abort("PG_URL is not set (e.g. postgres://saci:saci@127.0.0.1:55432/saci_test). See live/README.md.")

# -- models (PgLive* prefix: this file shares a process with mysql_live_spec) --

class PgLiveAuthor < Saci::Record::Base
  table "pg_live_authors"
  column id : Int64, primary: true
  column name : String
  column email : String
  column posts_count : Int32
  timestamps

  validates :name, presence: true
  validates :email, uniqueness: {case_sensitive: false}

  has_many :posts, class_name: PgLivePost, foreign_key: :author_id
end

class PgLivePost < Saci::Record::Base
  table "pg_live_posts"
  column id : Int64, primary: true
  column author_id : Int64
  column title : String
  column slug : String
  column code : String
  column views : Int32
  column rating : Float64
  column score : Decimal
  column active : Bool
  column published_at : Time
  column birthday : Date
  column meta : JSON
  column bio : String
  column order : String
  timestamps

  validates :title, presence: true, max_length: 80
  validates :code, format: /\A[A-Z]{3}\z/
  validates :slug, uniqueness: {scope: :author_id}

  belongs_to :author, class_name: PgLiveAuthor, foreign_key: :author_id, counter_cache: :posts_count
  has_many :post_tags, class_name: PgLivePostTag, foreign_key: :post_id
  has_many :tags, class_name: PgLiveTag, through: :post_tags, source: :tag
end

class PgLiveTag < Saci::Record::Base
  table "pg_live_tags"
  column id : Int64, primary: true
  column label : String

  has_many :post_tags, class_name: PgLivePostTag, foreign_key: :tag_id
end

class PgLivePostTag < Saci::Record::Base
  table "pg_live_post_tags"
  column id : Int64, primary: true
  column post_id : Int64
  column tag_id : Int64

  belongs_to :post, class_name: PgLivePost, foreign_key: :post_id
  belongs_to :tag, class_name: PgLiveTag, foreign_key: :tag_id
end

# -- migrations (domain tables + a dedicated schema-probe table) --

class PgLiveM1 < Saci::Record::Migration
  def change
    create_table :pg_live_authors do |t|
      t.string :name, null: false
      t.string :email
      t.integer :posts_count, default: 0
      t.timestamps
    end
    create_table :pg_live_posts do |t|
      t.bigint :author_id
      t.string :title, null: false
      t.string :slug
      t.string :code
      t.integer :views, default: 0
      t.float :rating
      t.decimal :score
      t.boolean :active, default: false
      t.datetime :published_at
      t.date :birthday
      t.json :meta
      t.text :bio
      t.string :order
      t.timestamps
    end
    create_table :pg_live_tags do |t|
      t.string :label, null: false
    end
    create_table :pg_live_post_tags do |t|
      t.bigint :post_id
      t.bigint :tag_id
    end
    add_index :pg_live_posts, :author_id
  end
end

class PgLiveSchema1 < Saci::Record::Migration
  def change
    create_table :pg_live_widgets do |t|
      t.string :name, null: false
      t.text :blurb
      t.integer :count
      t.bigint :total
      t.float :ratio
      t.decimal :price
      t.boolean :flag, default: true
      t.datetime :at
      t.date :day
      t.json :data
      t.timestamps
    end
    add_index :pg_live_widgets, :name
  end
end

class PgLiveSchema2 < Saci::Record::Migration
  def change
    add_column :pg_live_widgets, :subtitle, :string, null: false, default: "hi"
    add_index :pg_live_widgets, :subtitle, unique: true
  end
end

class PgLiveDropMe < Saci::Record::Migration
  def up
    create_table :pg_live_tmp do |t|
      t.string :name
    end
  end

  def down
    drop_table :pg_live_tmp
  end
end

LIVE_PG_MANIFEST = [
  PgLiveM1,
  PgLiveSchema1,
  PgLiveSchema2,
  PgLiveDropMe,
] of Saci::Record::Migration.class

LIVE_PG_TABLES = %w[
  pg_live_post_tags pg_live_tags pg_live_posts pg_live_authors
  pg_live_widgets pg_live_tmp
]

describe "PostgreSQL live" do
  before_all do
    Saci::Record.connect(LIVE_PG_URL)
    Saci::Record.adapter_for_name("primary").should eq(:postgres)
    Saci::Record::Migrator.migrate(Saci::Record.connection, LIVE_PG_MANIFEST)
  end

  after_all do
    db = Saci::Record.connection
    ad = Saci::Record.adapter_of(db)
    LIVE_PG_TABLES.each do |t|
      Saci::Record.exec_compat(db, "DROP TABLE IF EXISTS #{Saci::Record.quote(t, ad)}")
    end
    Saci::Record.exec_compat(db, "DELETE FROM #{Saci::Record.quote("schema_migrations", ad)}")
    db.close
  end

  before_each do
    Saci::Record.clean_database!
  end

  it "migrates, rolls back, and re-applies schema changes" do
    db = Saci::Record.connection
    ad = Saci::Record.adapter_of(db)
    widgets = Saci::Record.quote("pg_live_widgets", ad)
    tmp = Saci::Record.quote("pg_live_tmp", ad)
    c_name = Saci::Record.quote("name", ad)
    c_sub = Saci::Record.quote("subtitle", ad)
    c_created = Saci::Record.quote("created_at", ad)
    c_updated = Saci::Record.quote("updated_at", ad)
    stamp = Saci::Record.to_db(Time.utc(2024, 1, 2, 3, 4, 5), ad)

    Saci::Record::Migrator.applied_names(db).should contain("PgLiveSchema2")

    undone = Saci::Record::Migrator.rollback(db, [PgLiveSchema1, PgLiveSchema2] of Saci::Record::Migration.class, 1)
    undone.should eq(["PgLiveSchema2"])
    Saci::Record::Migrator.applied_names(db).should_not contain("PgLiveSchema2")
    expect_raises(Exception) do
      Saci::Record.exec_compat(db, "SELECT #{c_sub} FROM #{widgets}")
    end

    ran = Saci::Record::Migrator.migrate(db, [PgLiveSchema1, PgLiveSchema2] of Saci::Record::Migration.class)
    ran.should eq(["PgLiveSchema2"])

    # String DEFAULT rendering + UNIQUE index enforcement, live.
    Saci::Record.exec_compat(db,
      "INSERT INTO #{widgets} (#{c_name}, #{c_created}, #{c_updated}) VALUES (?, ?, ?)",
      ["w1", stamp, stamp] of Saci::Record::Value)
    sub = Saci::Record.scalar_compat(db,
      "SELECT #{c_sub} FROM #{widgets} WHERE #{c_name} = ?", ["w1"] of Saci::Record::Value)
    sub.should eq("hi")
    Saci::Record.exec_compat(db,
      "INSERT INTO #{widgets} (#{c_name}, #{c_sub}, #{c_created}, #{c_updated}) VALUES (?, ?, ?, ?)",
      ["w2", "dup", stamp, stamp] of Saci::Record::Value)
    expect_raises(Exception) do
      Saci::Record.exec_compat(db,
        "INSERT INTO #{widgets} (#{c_name}, #{c_sub}, #{c_created}, #{c_updated}) VALUES (?, ?, ?, ?)",
        ["w3", "dup", stamp, stamp] of Saci::Record::Value)
    end
    Saci::Record.exec_compat(db, "DELETE FROM #{widgets}")

    # drop_table via a custom down migration.
    Saci::Record::Migrator.rollback(db, [PgLiveDropMe] of Saci::Record::Migration.class, 1).should eq(["PgLiveDropMe"])
    expect_raises(Exception) do
      Saci::Record.exec_compat(db, "SELECT * FROM #{tmp}")
    end
    Saci::Record::Migrator.migrate(db, [PgLiveDropMe] of Saci::Record::Migration.class).should eq(["PgLiveDropMe"])
  end

  it "connects over the postgres adapter" do
    Saci::Record.adapter_for_name("primary").should eq(:postgres)
    Saci::Record.adapter_of(Saci::Record.connection).should eq(:postgres)
  end

  it "creates, finds, updates, and destroys" do
    author = PgLiveAuthor.create!(name: "Ada", email: "ada@ex.com")
    author.id.should_not be_nil
    author.persisted?.should be_true
    PgLiveAuthor.find(author.id).name.should eq("Ada")
    PgLiveAuthor.find_by(name: "Ada").not_nil!.email.should eq("ada@ex.com")
    expect_raises(Saci::Record::RecordNotFound) { PgLiveAuthor.find(999_999_999) }
    expect_raises(Saci::Record::RecordNotFound) { PgLiveAuthor.find_by!(name: "nobody") }
    author.update!(name: "Ada L.")
    author.reload.name.should eq("Ada L.")
    author.destroy.should be_true
    PgLiveAuthor.find_by(name: "Ada L.").should be_nil
  end

  it "assigns primary keys on insert via RETURNING" do
    a = PgLiveAuthor.create!(name: "K1", email: "k1@ex.com")
    b = PgLiveAuthor.create!(name: "K2", email: "k2@ex.com")
    a.id.should_not be_nil
    b.id.not_nil!.should be > a.id.not_nil!
  end

  it "round-trips every column type" do
    author = PgLiveAuthor.create!(name: "T", email: "types@ex.com")
    at = Time.utc(2024, 5, 1, 12, 30, 0)
    day = Time.utc(1990, 2, 15, 0, 0, 0)
    post = PgLivePost.create!(
      author_id: author.id, title: "Types", slug: "types", code: "ABC",
      views: 7, rating: 1.25, score: 9.99, active: true,
      published_at: at, birthday: day, meta: %({"a":1,"b":[true]}),
      bio: "long text here", order: "first")
    got = PgLivePost.find(post.id)
    got.views.should eq(7)
    got.rating.should eq(1.25)
    (got.score.not_nil! - 9.99).abs.should be < 1e-9
    got.active.should be_true
    got.published_at.should eq(at)
    got.birthday.should eq(day)
    got.meta.should eq(%({"a":1,"b":[true]}))
    got.meta_json.not_nil!["a"].as_i.should eq(1)
    got.bio.should eq("long text here")
    got.order.should eq("first")
    got.created_at.should_not be_nil
    got.updated_at.should_not be_nil
  end

  it "applies database-level defaults to skipped columns" do
    author = PgLiveAuthor.create!(name: "D", email: "def@ex.com")
    post = PgLivePost.new
    post.author_id = author.id
    post.title = "Defaults"
    post.code = "DEF"
    post.slug = "defaults"
    post.save!
    post.views.should be_nil
    fresh = PgLivePost.find(post.id)
    fresh.views.should eq(0)
    fresh.active.should be_false
  end

  it "validates presence, length, and format" do
    bad = PgLivePost.new(title: "", code: "abc", slug: "v1")
    bad.valid?.should be_false
    bad.errors[:title].should_not be_empty
    bad.errors[:code].should_not be_empty
    long = PgLivePost.new(title: "x" * 81, code: "ABC", slug: "v2")
    long.valid?.should be_false
    long.errors[:title].join.should contain("too long")
    PgLivePost.new(title: "Fine", code: "ABC", slug: "v3").valid?.should be_true
  end

  it "validates scoped and case-insensitive uniqueness" do
    a1 = PgLiveAuthor.create!(name: "U1", email: "U1@ex.com")
    a2 = PgLiveAuthor.create!(name: "U2", email: "u2@ex.com")
    p1 = PgLivePost.create!(author_id: a1.id, title: "One", slug: "hello", code: "AAA")
    dup = PgLivePost.new(author_id: a1.id, title: "Two", slug: "hello", code: "BBB")
    dup.valid?.should be_false
    dup.errors[:slug].should_not be_empty
    PgLivePost.new(author_id: a2.id, title: "Three", slug: "hello", code: "CCC").valid?.should be_true
    p1.valid?.should be_true
    clash = PgLiveAuthor.new(name: "U3", email: "u1@EX.com")
    clash.valid?.should be_false
    clash.errors[:email].should_not be_empty
  end

  it "loads belongs_to, has_many, and through associations" do
    author = PgLiveAuthor.create!(name: "Assoc", email: "assoc@ex.com")
    p1 = PgLivePost.create!(author_id: author.id, title: "P1", slug: "p1", code: "AAA")
    p2 = PgLivePost.create!(author_id: author.id, title: "P2", slug: "p2", code: "BBB")
    t1 = PgLiveTag.create!(label: "crystal")
    t2 = PgLiveTag.create!(label: "orm")
    PgLivePostTag.create!(post_id: p1.id, tag_id: t1.id)
    PgLivePostTag.create!(post_id: p1.id, tag_id: t2.id)
    p1.author.not_nil!.name.should eq("Assoc")
    author.posts.map { |p| p.title.to_s }.sort.should eq(["P1", "P2"])
    p1.tags.map { |t| t.label.to_s }.sort.should eq(["crystal", "orm"])
    author.reload.posts_count.should eq(2)
    p2.destroy
    author.reload.posts_count.should eq(1)
  end

  it "commits and rolls back transactions" do
    Saci::Record.transaction do |_|
      PgLiveAuthor.create!(name: "Tx", email: "tx@ex.com")
    end
    PgLiveAuthor.find_by(name: "Tx").should_not be_nil
    Saci::Record.transaction do |_|
      PgLiveAuthor.create!(name: "Nope", email: "nope@ex.com")
      raise DB::Rollback.new
    end
    PgLiveAuthor.find_by(name: "Nope").should be_nil
  end

  it "rewrites placeholders and quotes reserved words" do
    author = PgLiveAuthor.create!(name: "Q", email: "q@ex.com")
    PgLivePost.create!(author_id: author.id, title: "Find me", slug: "fm", code: "FMX", bio: "really?", order: "second")
    hits = PgLivePost.where("bio = 'really?' AND title = ?", "Find me").to_a
    hits.size.should eq(1)
    hits.first.order.should eq("second")
    PgLivePost.where(order: "second").first.not_nil!.title.should eq("Find me")
    PgLivePost.where(active: false).count.should eq(1)
  end

  it "supports update_all, delete_all, count, and pluck" do
    author = PgLiveAuthor.create!(name: "Bulk", email: "bulk@ex.com")
    codes = ["AAA", "BBB", "CCC"]
    3.times do |i|
      PgLivePost.create!(author_id: author.id, title: "Bulk #{i}", slug: "bulk-#{i}", code: codes[i], active: false)
    end
    PgLivePost.count.should eq(3)
    PgLivePost.pluck(:title).map(&.to_s).sort.should eq(["Bulk 0", "Bulk 1", "Bulk 2"])
    PgLivePost.where(active: false).update_all({active: true}).should eq(3)
    PgLivePost.where(active: true).count.should eq(3)
    PgLivePost.where(slug: "bulk-0").delete_all.should eq(1)
    PgLivePost.count.should eq(2)
  end

  it "cleans the database" do
    author = PgLiveAuthor.create!(name: "Gone", email: "gone@ex.com")
    PgLivePost.create!(author_id: author.id, title: "Gone", slug: "gone", code: "GGG")
    Saci::Record.clean_database!
    PgLiveAuthor.count.should eq(0)
    PgLivePost.count.should eq(0)
    PgLiveTag.count.should eq(0)
  end
end
