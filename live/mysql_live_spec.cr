require "spec"
require "../src/saci"
require "mysql"

# Live MySQL harness. Needs a server; `live/run.sh` provides the URL
# (and the OpenSSL link shim). Run: `live/run.sh` (both adapters) or
# `MYSQL_URL=mysql://... crystal spec live/mysql_live_spec.cr --link-flags=...`.
LIVE_MY_URL = ENV["MYSQL_URL"]? || abort("MYSQL_URL is not set (e.g. mysql://saci:saci@127.0.0.1:53306/saci_test). See live/README.md.")

# -- models (MyLive* prefix: this file shares a process with pg_live_spec) --

class MyLiveAuthor < Saci::Record::Base
  table "my_live_authors"
  column id : Int64, primary: true
  column name : String
  column email : String
  column posts_count : Int32
  timestamps

  validates :name, presence: true
  validates :email, uniqueness: {case_sensitive: false}

  has_many :posts, class_name: MyLivePost, foreign_key: :author_id
end

class MyLivePost < Saci::Record::Base
  table "my_live_posts"
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

  belongs_to :author, class_name: MyLiveAuthor, foreign_key: :author_id, counter_cache: :posts_count
  has_many :post_tags, class_name: MyLivePostTag, foreign_key: :post_id
  has_many :tags, class_name: MyLiveTag, through: :post_tags, source: :tag
end

class MyLiveTag < Saci::Record::Base
  table "my_live_tags"
  column id : Int64, primary: true
  column label : String

  has_many :post_tags, class_name: MyLivePostTag, foreign_key: :tag_id
end

class MyLivePostTag < Saci::Record::Base
  table "my_live_post_tags"
  column id : Int64, primary: true
  column post_id : Int64
  column tag_id : Int64

  belongs_to :post, class_name: MyLivePost, foreign_key: :post_id
  belongs_to :tag, class_name: MyLiveTag, foreign_key: :tag_id
end

# -- migrations (domain tables + a dedicated schema-probe table) --

class MyLiveM1 < Saci::Record::Migration
  def change
    create_table :my_live_authors do |t|
      t.string :name, null: false
      t.string :email
      t.integer :posts_count, default: 0
      t.timestamps
    end
    create_table :my_live_posts do |t|
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
    create_table :my_live_tags do |t|
      t.string :label, null: false
    end
    create_table :my_live_post_tags do |t|
      t.bigint :post_id
      t.bigint :tag_id
    end
    add_index :my_live_posts, :author_id
  end
end

class MyLiveSchema1 < Saci::Record::Migration
  def change
    create_table :my_live_widgets do |t|
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
    add_index :my_live_widgets, :name
  end
end

class MyLiveSchema2 < Saci::Record::Migration
  def change
    add_column :my_live_widgets, :subtitle, :string, null: false, default: "hi"
    add_index :my_live_widgets, :subtitle, unique: true
  end
end

class MyLiveDropMe < Saci::Record::Migration
  def up
    create_table :my_live_tmp do |t|
      t.string :name
    end
  end

  def down
    drop_table :my_live_tmp
  end
end

# -- Task B (migration depth): FK / rename / change_column coverage --
#
# `MyLiveFkSetup` uses the `create_table` block forms (`t.references` with
# `foreign_key: true`, `t.foreign_key`); `MyLiveFkAdd` exercises the
# standalone `add_foreign_key` (ADD CONSTRAINT — same syntax on MySQL,
# InnoDB assumed).

class MyLiveFkSetup < Saci::Record::Migration
  def change
    create_table :my_live_fk_owners do |t|
      t.string :name, null: false
    end
    create_table :my_live_fk_pets do |t|
      t.string :name
      t.references :owner, foreign_key: true, to_table: :my_live_fk_owners, on_delete: :cascade
    end
    create_table :my_live_fk_toys do |t|
      t.string :name
      t.bigint :pet_id
      t.foreign_key :my_live_fk_pets, column: :pet_id, on_delete: :restrict
    end
    create_table :my_live_fk_chews do |t|
      t.string :name
      t.bigint :owner_id
    end
  end
end

class MyLiveFkAdd < Saci::Record::Migration
  def change
    add_foreign_key :my_live_fk_chews, :my_live_fk_owners, column: :owner_id, on_delete: :nullify
  end
end

class MyLiveFkRenames < Saci::Record::Migration
  def change
    rename_column :my_live_fk_pets, :name, :label
    rename_table :my_live_fk_chews, :my_live_fk_treats
  end
end

class MyLiveFkChange < Saci::Record::Migration
  def up
    change_column :my_live_fk_owners, :name, :text, null: false
  end

  def down
    change_column :my_live_fk_owners, :name, :string, null: false
  end
end

MY_LIVE_FK_MANIFEST = [
  MyLiveFkSetup,
  MyLiveFkAdd,
  MyLiveFkRenames,
  MyLiveFkChange,
] of Saci::Record::Migration.class

# Drop order is children-before-parents: InnoDB rejects dropping a
# referenced table, and the ensure-block drops swallow errors.
MY_LIVE_FK_TABLES = %w[
  my_live_fk_toys my_live_fk_treats my_live_fk_chews my_live_fk_pets
  my_live_fk_owners
]

LIVE_MY_MANIFEST = [
  MyLiveM1,
  MyLiveSchema1,
  MyLiveSchema2,
  MyLiveDropMe,
] of Saci::Record::Migration.class

LIVE_MY_TABLES = %w[
  my_live_post_tags my_live_tags my_live_posts my_live_authors
  my_live_widgets my_live_tmp
]

describe "MySQL live" do
  before_all do
    Saci::Record.connect(LIVE_MY_URL)
    Saci::Record.adapter_for_name("primary").should eq(:mysql)
    Saci::Record::Migrator.migrate(Saci::Record.connection, LIVE_MY_MANIFEST)
  end

  after_all do
    db = Saci::Record.connection
    ad = Saci::Record.adapter_of(db)
    LIVE_MY_TABLES.each do |t|
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
    widgets = Saci::Record.quote("my_live_widgets", ad)
    tmp = Saci::Record.quote("my_live_tmp", ad)
    c_name = Saci::Record.quote("name", ad)
    c_sub = Saci::Record.quote("subtitle", ad)
    c_created = Saci::Record.quote("created_at", ad)
    c_updated = Saci::Record.quote("updated_at", ad)
    stamp = Saci::Record.to_db(Time.utc(2024, 1, 2, 3, 4, 5), ad)

    Saci::Record::Migrator.applied_names(db).should contain("MyLiveSchema2")

    undone = Saci::Record::Migrator.rollback(db, [MyLiveSchema1, MyLiveSchema2] of Saci::Record::Migration.class, 1)
    undone.should eq(["MyLiveSchema2"])
    Saci::Record::Migrator.applied_names(db).should_not contain("MyLiveSchema2")
    expect_raises(Exception) do
      Saci::Record.exec_compat(db, "SELECT #{c_sub} FROM #{widgets}")
    end

    ran = Saci::Record::Migrator.migrate(db, [MyLiveSchema1, MyLiveSchema2] of Saci::Record::Migration.class)
    ran.should eq(["MyLiveSchema2"])

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
    Saci::Record::Migrator.rollback(db, [MyLiveDropMe] of Saci::Record::Migration.class, 1).should eq(["MyLiveDropMe"])
    expect_raises(Exception) do
      Saci::Record.exec_compat(db, "SELECT * FROM #{tmp}")
    end
    Saci::Record::Migrator.migrate(db, [MyLiveDropMe] of Saci::Record::Migration.class).should eq(["MyLiveDropMe"])
  end

  it "connects over the postgres adapter" do
    Saci::Record.adapter_for_name("primary").should eq(:mysql)
    Saci::Record.adapter_of(Saci::Record.connection).should eq(:mysql)
  end

  it "enforces foreign keys, renames, and change_column" do
    db = Saci::Record.connection
    ad = Saci::Record.adapter_of(db)
    owners = Saci::Record.quote("my_live_fk_owners", ad)
    pets = Saci::Record.quote("my_live_fk_pets", ad)
    chews = Saci::Record.quote("my_live_fk_chews", ad)
    treats = Saci::Record.quote("my_live_fk_treats", ad)
    c_name = Saci::Record.quote("name", ad)
    c_label = Saci::Record.quote("label", ad)
    c_owner = Saci::Record.quote("owner_id", ad)
    sm = Saci::Record.quote("schema_migrations", ad)
    # Cleanup-first: a previous interrupted run may leave tables behind
    # without schema_migrations rows (DDL is not transactional), which
    # would make `migrate` fail with "already exists".
    MY_LIVE_FK_TABLES.each do |t|
      begin
        Saci::Record.exec_compat(db, "DROP TABLE IF EXISTS #{Saci::Record.quote(t, ad)}")
      rescue
      end
    end
    MY_LIVE_FK_MANIFEST.each do |m|
      begin
        Saci::Record.exec_compat(db,
          "DELETE FROM #{sm} WHERE #{c_name} = ?", [m.name] of Saci::Record::Value)
      rescue
      end
    end
    Saci::Record::Migrator.migrate(db, [MyLiveFkSetup] of Saci::Record::Migration.class)
    begin
      # Block-form FK (`t.references ... foreign_key: true`) is enforced.
      expect_raises(Exception) do
        Saci::Record.exec_compat(db,
          "INSERT INTO #{pets} (#{c_name}, #{c_owner}) VALUES (?, ?)",
          ["ghost", 999_999_999] of Saci::Record::Value)
      end
      Saci::Record.exec_compat(db,
        "INSERT INTO #{owners} (#{c_name}) VALUES (?)", ["oda"] of Saci::Record::Value)
      owner_id = Saci::Record.scalar_compat(db,
        "SELECT #{Saci::Record.quote("id", ad)} FROM #{owners} WHERE #{c_name} = ?", ["oda"] of Saci::Record::Value).as(Int64)
      Saci::Record.exec_compat(db,
        "INSERT INTO #{pets} (#{c_name}, #{c_owner}) VALUES (?, ?)",
        ["fido", owner_id] of Saci::Record::Value)

      # ON DELETE CASCADE (block form): deleting the owner removes pets.
      Saci::Record.exec_compat(db, "DELETE FROM #{owners}")
      Saci::Record.scalar_compat(db, "SELECT COUNT(*) FROM #{pets}").should eq(0)

      # Standalone add_foreign_key (ON DELETE SET NULL) is enforced.
      Saci::Record::Migrator.migrate(db, [MyLiveFkSetup, MyLiveFkAdd] of Saci::Record::Migration.class)
      expect_raises(Exception) do
        Saci::Record.exec_compat(db,
          "INSERT INTO #{chews} (#{c_name}, #{c_owner}) VALUES (?, ?)",
          ["ghost-chew", 999_999_999] of Saci::Record::Value)
      end
      Saci::Record.exec_compat(db,
        "INSERT INTO #{owners} (#{c_name}) VALUES (?)", ["oda2"] of Saci::Record::Value)
      owner2 = Saci::Record.scalar_compat(db,
        "SELECT #{Saci::Record.quote("id", ad)} FROM #{owners} WHERE #{c_name} = ?", ["oda2"] of Saci::Record::Value).as(Int64)
      Saci::Record.exec_compat(db,
        "INSERT INTO #{chews} (#{c_name}, #{c_owner}) VALUES (?, ?)",
        ["chewy", owner2] of Saci::Record::Value)

      # Renames applied: new column/table names accept writes.
      Saci::Record::Migrator.migrate(db, [MyLiveFkSetup, MyLiveFkAdd, MyLiveFkRenames] of Saci::Record::Migration.class)
      Saci::Record.exec_compat(db,
        "INSERT INTO #{pets} (#{c_label}, #{c_owner}) VALUES (?, ?)",
        ["renamed", nil] of Saci::Record::Value)
      Saci::Record.exec_compat(db,
        "INSERT INTO #{treats} (#{c_name}, #{c_owner}) VALUES (?, ?)",
        ["treat", owner2] of Saci::Record::Value)

      # change_column kept the column usable (VARCHAR -> TEXT).
      Saci::Record::Migrator.migrate(db, MY_LIVE_FK_MANIFEST)
      Saci::Record.exec_compat(db,
        "INSERT INTO #{owners} (#{c_name}) VALUES (?)", ["second"] of Saci::Record::Value)

      # Rollback inverts change_column (custom down) and renames
      # (table + column names restored).
      Saci::Record::Migrator.rollback(db, MY_LIVE_FK_MANIFEST, 2)
      Saci::Record.exec_compat(db,
        "INSERT INTO #{owners} (#{c_name}) VALUES (?)", ["third"] of Saci::Record::Value)
      Saci::Record.exec_compat(db,
        "INSERT INTO #{chews} (#{c_name}, #{c_owner}) VALUES (?, ?)",
        ["back", nil] of Saci::Record::Value)

      # Rollback drops the added FK: dangling references now insert fine.
      Saci::Record::Migrator.rollback(db, MY_LIVE_FK_MANIFEST, 1)
      Saci::Record.exec_compat(db,
        "INSERT INTO #{chews} (#{c_name}, #{c_owner}) VALUES (?, ?)",
        ["dangling", 999_999_999] of Saci::Record::Value)
    ensure
      MY_LIVE_FK_TABLES.each do |t|
        begin
          Saci::Record.exec_compat(db, "DROP TABLE IF EXISTS #{Saci::Record.quote(t, ad)}")
        rescue
        end
      end
      MY_LIVE_FK_MANIFEST.each do |m|
        begin
          Saci::Record.exec_compat(db,
            "DELETE FROM #{Saci::Record.quote("schema_migrations", ad)} WHERE #{c_name} = ?", [m.name] of Saci::Record::Value)
        rescue
        end
      end
    end
  end

  it "creates, finds, updates, and destroys" do
    author = MyLiveAuthor.create!(name: "Ada", email: "ada@ex.com")
    author.id.should_not be_nil
    author.persisted?.should be_true
    MyLiveAuthor.find(author.id).name.should eq("Ada")
    MyLiveAuthor.find_by(name: "Ada").not_nil!.email.should eq("ada@ex.com")
    expect_raises(Saci::Record::RecordNotFound) { MyLiveAuthor.find(999_999_999) }
    expect_raises(Saci::Record::RecordNotFound) { MyLiveAuthor.find_by!(name: "nobody") }
    author.update!(name: "Ada L.")
    author.reload.name.should eq("Ada L.")
    author.destroy.should be_true
    MyLiveAuthor.find_by(name: "Ada L.").should be_nil
  end

  it "assigns primary keys on insert via last_insert_id" do
    a = MyLiveAuthor.create!(name: "K1", email: "k1@ex.com")
    b = MyLiveAuthor.create!(name: "K2", email: "k2@ex.com")
    a.id.should_not be_nil
    b.id.not_nil!.should be > a.id.not_nil!
  end

  it "round-trips every column type" do
    author = MyLiveAuthor.create!(name: "T", email: "types@ex.com")
    at = Time.utc(2024, 5, 1, 12, 30, 0)
    day = Time.utc(1990, 2, 15, 0, 0, 0)
    post = MyLivePost.create!(
      author_id: author.id, title: "Types", slug: "types", code: "ABC",
      views: 7, rating: 1.25, score: 9.99, active: true,
      published_at: at, birthday: day, meta: %({"a":1,"b":[true]}),
      bio: "long text here", order: "first")
    got = MyLivePost.find(post.id)
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
    author = MyLiveAuthor.create!(name: "D", email: "def@ex.com")
    post = MyLivePost.new
    post.author_id = author.id
    post.title = "Defaults"
    post.code = "DEF"
    post.slug = "defaults"
    post.save!
    post.views.should be_nil
    fresh = MyLivePost.find(post.id)
    fresh.views.should eq(0)
    fresh.active.should be_false
  end

  it "validates presence, length, and format" do
    bad = MyLivePost.new(title: "", code: "abc", slug: "v1")
    bad.valid?.should be_false
    bad.errors[:title].should_not be_empty
    bad.errors[:code].should_not be_empty
    long = MyLivePost.new(title: "x" * 81, code: "ABC", slug: "v2")
    long.valid?.should be_false
    long.errors[:title].join.should contain("too long")
    MyLivePost.new(title: "Fine", code: "ABC", slug: "v3").valid?.should be_true
  end

  it "validates scoped and case-insensitive uniqueness" do
    a1 = MyLiveAuthor.create!(name: "U1", email: "U1@ex.com")
    a2 = MyLiveAuthor.create!(name: "U2", email: "u2@ex.com")
    p1 = MyLivePost.create!(author_id: a1.id, title: "One", slug: "hello", code: "AAA")
    dup = MyLivePost.new(author_id: a1.id, title: "Two", slug: "hello", code: "BBB")
    dup.valid?.should be_false
    dup.errors[:slug].should_not be_empty
    MyLivePost.new(author_id: a2.id, title: "Three", slug: "hello", code: "CCC").valid?.should be_true
    p1.valid?.should be_true
    clash = MyLiveAuthor.new(name: "U3", email: "u1@EX.com")
    clash.valid?.should be_false
    clash.errors[:email].should_not be_empty
  end

  it "loads belongs_to, has_many, and through associations" do
    author = MyLiveAuthor.create!(name: "Assoc", email: "assoc@ex.com")
    p1 = MyLivePost.create!(author_id: author.id, title: "P1", slug: "p1", code: "AAA")
    p2 = MyLivePost.create!(author_id: author.id, title: "P2", slug: "p2", code: "BBB")
    t1 = MyLiveTag.create!(label: "crystal")
    t2 = MyLiveTag.create!(label: "orm")
    MyLivePostTag.create!(post_id: p1.id, tag_id: t1.id)
    MyLivePostTag.create!(post_id: p1.id, tag_id: t2.id)
    p1.author.not_nil!.name.should eq("Assoc")
    author.posts.map { |p| p.title.to_s }.sort.should eq(["P1", "P2"])
    p1.tags.map { |t| t.label.to_s }.sort.should eq(["crystal", "orm"])
    author.reload.posts_count.should eq(2)
    p2.destroy
    author.reload.posts_count.should eq(1)
  end

  it "commits and rolls back transactions" do
    Saci::Record.transaction do |_|
      MyLiveAuthor.create!(name: "Tx", email: "tx@ex.com")
    end
    MyLiveAuthor.find_by(name: "Tx").should_not be_nil
    Saci::Record.transaction do |_|
      MyLiveAuthor.create!(name: "Nope", email: "nope@ex.com")
      raise DB::Rollback.new
    end
    MyLiveAuthor.find_by(name: "Nope").should be_nil
  end

  it "rewrites placeholders and quotes reserved words" do
    author = MyLiveAuthor.create!(name: "Q", email: "q@ex.com")
    MyLivePost.create!(author_id: author.id, title: "Find me", slug: "fm", code: "FMX", bio: "really?", order: "second")
    hits = MyLivePost.where("bio = 'really?' AND title = ?", "Find me").to_a
    hits.size.should eq(1)
    hits.first.order.should eq("second")
    MyLivePost.where(order: "second").first.not_nil!.title.should eq("Find me")
    MyLivePost.where(active: false).count.should eq(1)
  end

  it "supports update_all, delete_all, count, and pluck" do
    author = MyLiveAuthor.create!(name: "Bulk", email: "bulk@ex.com")
    codes = ["AAA", "BBB", "CCC"]
    3.times do |i|
      MyLivePost.create!(author_id: author.id, title: "Bulk #{i}", slug: "bulk-#{i}", code: codes[i], active: false)
    end
    MyLivePost.count.should eq(3)
    MyLivePost.pluck(:title).map(&.to_s).sort.should eq(["Bulk 0", "Bulk 1", "Bulk 2"])
    MyLivePost.where(active: false).update_all({active: true}).should eq(3)
    MyLivePost.where(active: true).count.should eq(3)
    MyLivePost.where(slug: "bulk-0").delete_all.should eq(1)
    MyLivePost.count.should eq(2)
  end

  it "cleans the database" do
    author = MyLiveAuthor.create!(name: "Gone", email: "gone@ex.com")
    MyLivePost.create!(author_id: author.id, title: "Gone", slug: "gone", code: "GGG")
    Saci::Record.clean_database!
    MyLiveAuthor.count.should eq(0)
    MyLivePost.count.should eq(0)
    MyLiveTag.count.should eq(0)
  end
end
