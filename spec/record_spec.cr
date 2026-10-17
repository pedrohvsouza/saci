require "spec"
require "file"
require "../src/saci"

# -- spec schema ------------------------------------------------------------

class CreateOrmUsers < Saci::Record::Migration
  def change
    create_table :orm_users do |t|
      t.string :name, null: false
      t.string :email, null: false
      t.integer :age
      t.boolean :admin, default: false
      t.timestamps
    end
    add_index :orm_users, :email, unique: true
  end
end

class CreateOrmPosts < Saci::Record::Migration
  def change
    create_table :orm_posts do |t|
      t.string :title, null: false
      t.integer :views, default: 0
      t.boolean :published, default: false
      t.integer :orm_user_id
      t.timestamps
    end
  end
end

class AddBioToOrmUsers < Saci::Record::Migration
  def change
    add_column :orm_users, :bio, :text
  end
end

class CreateAppLogs < Saci::Record::Migration
  def change
    create_table :app_logs, id: false do |t|
      t.string :message
    end
  end
end

class CreateOrmMemberships < Saci::Record::Migration
  def change
    create_table :orm_memberships do |t|
      t.integer :orm_user_id
      t.integer :team_id
      t.string :role
      t.timestamps
    end
  end
end

class CreateOrmTags < Saci::Record::Migration
  def change
    create_table :orm_tags do |t|
      t.string :tag, null: false
      t.timestamps
    end
  end
end

class CreateOrmTaggings < Saci::Record::Migration
  def change
    create_table :orm_taggings do |t|
      t.integer :orm_post_id
      t.integer :orm_tag_id
      t.timestamps
    end
  end
end

class CreateOrmProfiles < Saci::Record::Migration
  def change
    create_table :orm_profiles do |t|
      t.integer :orm_user_id
      t.string :bio
      t.timestamps
    end
  end
end

class CreateOrmWidgets < Saci::Record::Migration
  def change
    create_table :orm_widgets do |t|
      t.string :name
      t.timestamps
    end
  end
end

class CreateOrmGadgets < Saci::Record::Migration
  def change
    create_table :orm_gadgets do |t|
      t.string :code
      t.string :handle
      t.string :kind
      t.integer :level
      t.integer :stock
      t.string :rating
      t.string :nickname
      t.string :optional_note
      t.timestamps
    end
  end
end

class CreateOrmMetrics < Saci::Record::Migration
  def change
    create_table :orm_metrics do |t|
      t.decimal :ratio
      t.date :day
      t.json :meta
      t.timestamps
    end
  end
end

class CreateOrmShelves < Saci::Record::Migration
  def change
    create_table :orm_shelves do |t|
      t.string :label
      t.integer :orm_books_count, default: 0
      t.timestamps
    end
  end
end

class CreateOrmBooks < Saci::Record::Migration
  def change
    create_table :orm_books do |t|
      t.string :title, null: false
      t.integer :orm_shelf_id
      t.timestamps
    end
  end
end

class CreateOrmCrates < Saci::Record::Migration
  def change
    create_table :orm_crates do |t|
      t.string :label
      t.timestamps
    end
  end
end

class CreateOrmDepots < Saci::Record::Migration
  def change
    create_table :orm_depots do |t|
      t.string :label
      t.timestamps
    end
  end
end

class CreateOrmPolyPosts < Saci::Record::Migration
  def change
    create_table :orm_poly_posts do |t|
      t.string :title
      t.timestamps
    end
  end
end

class CreateOrmPolyComments < Saci::Record::Migration
  def change
    create_table :orm_poly_comments do |t|
      t.string :body
      t.timestamps
    end
  end
end

class CreateOrmPolyNotes < Saci::Record::Migration
  def change
    create_table :orm_poly_notes do |t|
      t.string :notifiable_type
      t.integer :notifiable_id
      t.string :msg
      t.timestamps
    end
  end
end

class CreateOrmGuilds < Saci::Record::Migration
  def change
    create_table :orm_guilds do |t|
      t.string :label
      t.timestamps
    end
  end
end

class CreateOrmGuildMembers < Saci::Record::Migration
  def change
    create_table :orm_guild_members do |t|
      t.string :name
      t.integer :orm_guild_id
      t.timestamps
    end
  end
end

class CreateOrmStudios < Saci::Record::Migration
  def change
    create_table :orm_studios do |t|
      t.string :name
      t.timestamps
    end
  end
end

class CreateOrmBadges < Saci::Record::Migration
  def change
    create_table :orm_badges do |t|
      t.string :label
      t.integer :orm_studio_id
      t.timestamps
    end
  end
end

class CreateOrmCoupons < Saci::Record::Migration
  def change
    create_table :orm_coupons do |t|
      t.string :code
      t.string :kind
      t.string :handle
      t.timestamps
    end
  end
end

class DropTempTable < Saci::Record::Migration
  def change
    drop_table :temp_t
  end
end

# -- spec models ------------------------------------------------------------

class OrmUser < Saci::Record::Base
  column id : Int64, primary: true
  column name : String
  column email : String
  column age : Int32
  column admin : Bool, default: false
  timestamps

  validates :name, presence: true, min_length: 2, max_length: 50
  validates :email, presence: true, format: /@/
  validates :email, uniqueness: true

  has_many :orm_posts
  has_one :orm_profile
end

class OrmProfile < Saci::Record::Base
  column id : Int64, primary: true
  column orm_user_id : Int64
  column bio : String
  timestamps

  belongs_to :orm_user
end

class OrmTag < Saci::Record::Base
  column id : Int64, primary: true
  column tag : String
  timestamps

  has_many :orm_taggings
  has_many :orm_posts, through: :orm_taggings
  has_many :stories_via, class_name: "OrmPost", through: :orm_taggings, source: :orm_post, dependent: :destroy
end

class OrmTagging < Saci::Record::Base
  column id : Int64, primary: true
  column orm_post_id : Int64
  column orm_tag_id : Int64
  timestamps

  belongs_to :orm_post
  belongs_to :orm_tag
end

class OrmWidget < Saci::Record::Base
  column id : Int64, primary: true
  column name : String
  timestamps

  validates :name, presence: true

  @@log : Array(String) = [] of String

  def self.log : Array(String)
    @@log
  end

  before_validation :stamp_before_validation
  before_validation :stamp_before_validation_on_create, on: :create
  before_save :stamp_before_save
  before_save { |widget| OrmWidget.log << "before_save:block:#{widget.name}" }
  after_create :stamp_after_create, :stamp_after_create_again
  after_create -> { OrmWidget.log << "after_create:proc" }
  after_save :stamp_after_save
  after_commit :stamp_after_commit
  after_commit :stamp_after_commit_on_create, on: :create
  after_destroy :stamp_after_destroy

  def stamp_before_validation
    OrmWidget.log << "before_validation"
    self.name = "stamped" if name.nil?
  end

  def stamp_before_validation_on_create
    OrmWidget.log << "before_validation:on_create"
  end

  def stamp_before_save
    OrmWidget.log << "before_save:method"
  end

  def stamp_after_create
    OrmWidget.log << "after_create:one"
  end

  def stamp_after_create_again
    OrmWidget.log << "after_create:two"
  end

  def stamp_after_save
    OrmWidget.log << "after_save"
  end

  def stamp_after_commit
    OrmWidget.log << "after_commit"
  end

  def stamp_after_commit_on_create
    OrmWidget.log << "after_commit:on_create"
  end

  def stamp_after_destroy
    OrmWidget.log << "after_destroy"
  end
end

class OrmGadget < Saci::Record::Base
  column id : Int64, primary: true
  column code : String
  column handle : String
  column kind : String
  column level : Int32
  column stock : Int32
  column rating : String
  column nickname : String
  column optional_note : String
  timestamps

  validates :code, presence: true, uniqueness: {case_sensitive: false}
  validates :handle, length: {minimum: 2, maximum: 8}
  validates :handle, length: {maximum: 3}, on: :create
  validates :kind, inclusion: {in: ["small", "large"]}
  validates :level, inclusion: {in: 1..5}
  validates :stock, numericality: {only_integer: true, greater_than_or_equal_to: 0}
  validates :rating, numericality: {only_integer: true}
  validates :nickname, length: {maximum: 10, allow_blank: true}
  validates :optional_note, length: {maximum: 5, allow_nil: true}
  validate :code_must_start_with_g
  validate(on: :create) do
    errors.add(:code, "is reserved on create") if code == "g-reserved"
  end

  def code_must_start_with_g
    if (c = code) && !c.starts_with?("g")
      errors.add(:code, "must start with g")
    end
  end
end

class OrmMetric < Saci::Record::Base
  column id : Int64, primary: true
  column ratio : Decimal
  column day : Date
  column meta : JSON
  timestamps
end

class OrmShelf < Saci::Record::Base
  column id : Int64, primary: true
  column label : String
  column orm_books_count : Int64, default: 0
  timestamps

  has_one :spotlight, class_name: "OrmBook", dependent: :destroy
  has_many :orm_books, dependent: :destroy
end

class OrmBook < Saci::Record::Base
  column id : Int64, primary: true
  column title : String
  column orm_shelf_id : Int64
  timestamps

  validates :title, presence: true

  belongs_to :orm_shelf, counter_cache: true, touch: true

  @@log : Array(String) = [] of String

  def self.log : Array(String)
    @@log
  end

  after_destroy do |book|
    OrmBook.log << "destroyed:#{book.title}"
  end
end

class OrmCrate < Saci::Record::Base
  column id : Int64, primary: true
  column label : String
  timestamps

  has_one :purge, class_name: "OrmBook", foreign_key: "orm_shelf_id", dependent: :delete_all
  has_many :orm_books, class_name: "OrmBook", foreign_key: "orm_shelf_id", dependent: :delete_all
end

class OrmDepot < Saci::Record::Base
  column id : Int64, primary: true
  column label : String
  timestamps

  has_one :keeper, class_name: "OrmBook", foreign_key: "orm_shelf_id", dependent: :nullify
  has_many :orm_books, class_name: "OrmBook", foreign_key: "orm_shelf_id", dependent: :nullify
end

class OrmPost < Saci::Record::Base
  column id : Int64, primary: true
  column title : String
  column views : Int64
  column published : Bool
  column orm_user_id : Int64
  timestamps

  validates :title, presence: true

  belongs_to :orm_user

  has_many :orm_taggings
  has_many :orm_tags, through: :orm_taggings, dependent: :delete_all
end

class OrmPolyPost < Saci::Record::Base
  column id : Int64, primary: true
  column title : String
  timestamps

  has_many :orm_poly_notes, as: :notifiable
end

class OrmPolyComment < Saci::Record::Base
  column id : Int64, primary: true
  column body : String
  timestamps

  has_many :orm_poly_notes, as: :notifiable
end

class OrmPolyNote < Saci::Record::Base
  column id : Int64, primary: true
  column notifiable_type : String
  column notifiable_id : Int64
  column msg : String
  timestamps

  belongs_to :notifiable, polymorphic: true
end

class OrmGuild < Saci::Record::Base
  column id : Int64, primary: true
  column label : String
  timestamps

  has_many :orm_guild_members, dependent: :restrict_with_exception
end

class OrmGuildMember < Saci::Record::Base
  column id : Int64, primary: true
  column name : String
  column orm_guild_id : Int64
  timestamps

  belongs_to :orm_guild
end

class OrmStudio < Saci::Record::Base
  column id : Int64, primary: true
  column name : String
  timestamps

  has_one :badge, class_name: "OrmBadge", foreign_key: "orm_studio_id", dependent: :restrict_with_exception
end

class OrmBadge < Saci::Record::Base
  column id : Int64, primary: true
  column label : String
  column orm_studio_id : Int64
  timestamps

  belongs_to :orm_studio
end

class OrmCoupon < Saci::Record::Base
  column id : Int64, primary: true
  column code : String
  column kind : String
  column handle : String
  timestamps

  validates :code, presence: true, if: :needs_code
  validates :handle, presence: true, unless: :skip_handle
  validates :kind, presence: true, if: ->(r : OrmCoupon) { r.code == "special" }
  validates :code, format: /@/, if: ->(r : OrmCoupon) { r.kind == "email" }
  validate :code_must_be_fancy, if: :is_fancy
  validate :handle_must_be_short, unless: ->(r : OrmCoupon) { r.kind == "skip" }

  def needs_code : Bool
    kind == "promo"
  end

  def skip_handle : Bool
    kind == "free"
  end

  def is_fancy : Bool
    kind == "fancy"
  end

  def code_must_be_fancy
    errors.add(:code, "must be fancy") unless code == "fancy"
  end

  def handle_must_be_short
    if h = handle
      errors.add(:handle, "is too long") if h.size > 3
    end
  end
end

class OrmLog < Saci::Record::Base
  table "app_logs"

  column message : String
end

class OrmMembership < Saci::Record::Base
  column id : Int64, primary: true
  column orm_user_id : Int64
  column team_id : Int64
  column role : String
  timestamps

  validates :orm_user_id, uniqueness: [:team_id]
end

DB_PATH = "/tmp/opencode/saci_record_test.db"

def record_db : DB::Database
  Saci::Record::Base.connection.as(DB::Database)
end

def table_columns(db : DB::Database, table : String) : Array(String)
  cols = [] of String
  db.query("PRAGMA table_info(\"#{table}\")") do |rs|
    rs.each do
      rs.read(Int64)
      cols << rs.read(String)
      rs.read(String)
      rs.read(Int64)
      rs.read(String?)
      rs.read(Int64)
    end
  end
  cols
end

describe "Saci::Record" do
  before_all do
    File.delete(DB_PATH) if File.exists?(DB_PATH)
    Saci::Record::Base.connection = DB.open("sqlite3://#{DB_PATH}")
    Saci::Record::Migrator.migrate(record_db, [
      CreateOrmUsers,
      CreateOrmPosts,
      AddBioToOrmUsers,
      CreateAppLogs,
      CreateOrmMemberships,
      CreateOrmTags,
      CreateOrmTaggings,
      CreateOrmProfiles,
      CreateOrmWidgets,
      CreateOrmGadgets,
      CreateOrmMetrics,
      CreateOrmShelves,
      CreateOrmBooks,
      CreateOrmCrates,
      CreateOrmDepots,
      CreateOrmPolyPosts,
      CreateOrmPolyComments,
      CreateOrmPolyNotes,
      CreateOrmGuilds,
      CreateOrmGuildMembers,
      CreateOrmStudios,
      CreateOrmBadges,
      CreateOrmCoupons,
    ] of Saci::Record::Migration.class)
  end

  after_all do
    record_db.close
  end

  it "infers table names and tracks columns" do
    OrmUser.table_name.should eq("orm_users")
    OrmPost.table_name.should eq("orm_posts")
    OrmLog.table_name.should eq("app_logs")
    OrmUser.primary_key_name.should eq("id")
    OrmUser.__saci_column_names.map(&.[0]).should eq(
      ["id", "name", "email", "age", "admin", "created_at", "updated_at"]
    )
  end

  it "creates tables with expected schema" do
    table_columns(record_db, "orm_users").should contain("email")
    table_columns(record_db, "orm_users").should contain("bio")
    table_columns(record_db, "orm_users").should contain("created_at")
  end

  it "records applied migrations and skips reruns" do
    names = Saci::Record::Migrator.applied_names(record_db)
    names.should contain("CreateOrmUsers")
    names.should contain("AddBioToOrmUsers")
    rerun = Saci::Record::Migrator.migrate(record_db, [
      CreateOrmUsers,
    ] of Saci::Record::Migration.class)
    rerun.should be_empty
  end

  it "creates and finds records with type round-trips" do
    u = OrmUser.create!(name: "Ada", email: "ada@x.io", age: 36, admin: true)
    u.persisted?.should be_true
    u.new_record?.should be_false
    u.id.should_not be_nil
    u.created_at.should_not be_nil
    u.updated_at.should_not be_nil

    found = OrmUser.find(u.id.not_nil!)
    found.name.should eq("Ada")
    found.age.should eq(36)
    found.admin.should be_true
    ((found.created_at.not_nil! - u.created_at.not_nil!).abs < 2.seconds).should be_true
  end

  it "applies model and DB column defaults" do
    OrmUser.new.admin.should be_false
    u = OrmUser.create!(name: "Grace", email: "grace@x.io")
    u.admin.should be_false
    u.reload.admin.should be_false
  end

  it "validates presence, length and format" do
    u = OrmUser.new(name: "A", email: "bad-email")
    u.save.should be_false
    u.errors["name"].should contain("is too short (minimum is 2 characters)")
    u.errors["email"].should contain("is invalid")
    u.errors.full_messages.any? { |m| m.starts_with?("Name ") }.should be_true
    expect_raises(Saci::Record::RecordInvalid) { u.save! }
  end

  it "validates uniqueness, excluding self on update" do
    OrmUser.create!(name: "Alan", email: "alan@x.io")
    dup = OrmUser.new(name: "Alan2", email: "alan@x.io")
    dup.save.should be_false
    dup.errors["email"].should contain("has already been taken")

    alan = OrmUser.find_by!(email: "alan@x.io")
    alan.update(name: "Alan Turing").should be_true
  end

  it "validates scoped uniqueness" do
    OrmMembership.create!(orm_user_id: 1, team_id: 7, role: "dev")
    dup = OrmMembership.new(orm_user_id: 1, team_id: 7, role: "ops")
    dup.save.should be_false
    dup.errors["orm_user_id"].should contain("has already been taken")

    # Same user, different scope → valid; same pair, new record → invalid.
    OrmMembership.new(orm_user_id: 1, team_id: 8, role: "dev").save.should be_true
    kept = OrmMembership.new(orm_user_id: 2, team_id: 7, role: "dev")
    kept.save.should be_true

    # Updating the record itself never self-conflicts.
    kept.update(role: "lead").should be_true
  end

  it "updates, reloads and destroys" do
    u = OrmUser.create!(name: "Edsger", email: "edsger@x.io", age: 72)
    u.update(age: 73).should be_true
    u.age.should eq(73)
    record_db.scalar("SELECT age FROM orm_users WHERE id = ?", u.id.not_nil!).should eq(73)
    u.reload.age.should eq(73)

    id = u.id.not_nil!
    u.destroy.should be_true
    u.destroyed?.should be_true
    u.persisted?.should be_false
    OrmUser.exists?(id: id).should be_false
    expect_raises(Saci::Record::RecordNotFound) { OrmUser.find(id) }
  end

  it "raises on unknown attributes" do
    expect_raises(Saci::Record::UnknownAttributeError) do
      OrmUser.new(name: "X", bogus: 1)
    end
  end

  it "supports find_by, first, count and exists?" do
    OrmUser.create!(name: "Linus", email: "linus@x.io")
    OrmUser.find_by(email: "linus@x.io").not_nil!.name.should eq("Linus")
    OrmUser.find_by(email: "nobody@x.io").should be_nil
    expect_raises(Saci::Record::RecordNotFound) { OrmUser.find_by!(email: "nobody@x.io") }
    (OrmUser.count >= 1).should be_true
    OrmUser.exists?(email: "linus@x.io").should be_true
    OrmUser.exists?(email: "nobody@x.io").should be_false
    OrmUser.first.should_not be_nil
  end

  it "chains query builder methods" do
    user = OrmUser.create!(name: "Matz", email: "matz@x.io")
    OrmPost.create!(title: "Ruby", views: 500, published: true, orm_user_id: user.id)
    OrmPost.create!(title: "Crystal", views: 50, published: true, orm_user_id: user.id)
    OrmPost.create!(title: "Draft", views: 5, published: false, orm_user_id: user.id)

    OrmPost.where(published: true).count.should eq(2)
    top = OrmPost.where(published: true).order(views: :desc).first
    top.not_nil!.title.should eq("Ruby")
    popular = OrmPost.where("views > ?", 100).to_a.map(&.title)
    popular.should eq(["Ruby"])
    bare = OrmPost.where("views > 100").to_a.map(&.title)
    bare.should eq(["Ruby"])
    page = OrmPost.order(views: :desc).limit(1).offset(1).to_a
    page.size.should eq(1)
    OrmPost.pluck(:title).map(&.to_s).sort.should contain("Ruby")
  end

  it "supports update_all and delete_all" do
    n = OrmPost.where(published: false).update_all({published: true})
    (n >= 1).should be_true
    OrmPost.where(published: false).count.should eq(0)
    doomed = OrmPost.create!(title: "Temp", views: 0, published: false)
    OrmPost.where(id: doomed.id.not_nil!).delete_all.should eq(1)
    OrmPost.exists?(id: doomed.id.not_nil!).should be_false
  end

  it "resolves belongs_to and has_many" do
    user = OrmUser.create!(name: "Yukihiro", email: "yuki@x.io")
    post = OrmPost.create!(title: "Assoc", views: 1, published: true, orm_user_id: user.id)
    post.orm_user.not_nil!.name.should eq("Yukihiro")
    user.orm_posts.map(&.title).should contain("Assoc")
    user.orm_posts.where(published: true).count.should eq(1)

    orphan = OrmPost.new(title: "Orphan", views: 0, published: false)
    orphan.orm_user.should be_nil
  end

  it "resolves has_one and has_many :through" do
    user = OrmUser.create!(name: "Through", email: "through@x.io")
    user.orm_profile.should be_nil
    profile = OrmProfile.create!(orm_user_id: user.id, bio: "hello")
    user.orm_profile.not_nil!.bio.should eq("hello")

    # Unsaved owners have no associated record.
    OrmUser.new.orm_profile.should be_nil

    post = OrmPost.create!(title: "Tagged", views: 1, published: true, orm_user_id: user.id)
    post.orm_tags.to_a.should be_empty

    ruby = OrmTag.create!(tag: "ruby")
    crystal = OrmTag.create!(tag: "crystal")
    OrmTagging.create!(orm_post_id: post.id, orm_tag_id: ruby.id)
    OrmTagging.create!(orm_post_id: post.id, orm_tag_id: crystal.id)

    post.orm_tags.map(&.tag).compact.sort.should eq(["crystal", "ruby"])
    # Through queries stay chainable.
    post.orm_tags.where(tag: "ruby").map(&.tag).should eq(["ruby"])
    post.orm_tags.count.should eq(2)
    # Reverse direction + explicit class_name/source traversal.
    ruby.orm_posts.map(&.title).should eq(["Tagged"])
    ruby.stories_via.map(&.title).should eq(["Tagged"])

    other = OrmPost.create!(title: "Untagged", views: 0, published: true, orm_user_id: user.id)
    other.orm_tags.to_a.should be_empty
  end

  it "runs callbacks in Rails order on create, update and destroy" do
    OrmWidget.log.clear
    w = OrmWidget.create!(name: "w1")
    OrmWidget.log.should eq([
      "before_validation",
      "before_validation:on_create",
      "before_save:method",
      "before_save:block:w1",
      "after_create:one",
      "after_create:two",
      "after_create:proc",
      "after_save",
      "after_commit",
      "after_commit:on_create",
    ])

    # Update: no create-only callbacks.
    OrmWidget.log.clear
    w.update!(name: "w2")
    OrmWidget.log.should eq([
      "before_validation",
      "before_save:method",
      "before_save:block:w2",
      "after_save",
      "after_commit",
    ])

    # Destroy: dependents, then after_destroy + after_commit.
    OrmWidget.log.clear
    w.destroy.should be_true
    OrmWidget.log.should eq(["after_destroy", "after_commit"])

    # before_validation can fix attributes (nil name gets stamped).
    OrmWidget.log.clear
    stamped = OrmWidget.create!(name: nil)
    stamped.name.should eq("stamped")
  end

  it "defers after_commit to the transaction commit and discards on rollback" do
    OrmWidget.log.clear
    Saci::Record::Base.transaction do
      OrmWidget.create!(name: "tx")
      OrmWidget.log.should_not contain("after_commit")
      OrmWidget.log.should contain("after_create:one")
    end
    OrmWidget.log.should contain("after_commit")
    OrmWidget.log.should contain("after_commit:on_create")
    OrmWidget.exists?(name: "tx").should be_true

    OrmWidget.log.clear
    result = Saci::Record::Base.transaction do
      OrmWidget.create!(name: "nope")
      raise DB::Rollback.new
    end
    result.should be_nil
    OrmWidget.log.should contain("after_create:one")
    OrmWidget.log.should_not contain("after_commit")
    OrmWidget.log.should_not contain("after_commit:on_create")
    OrmWidget.exists?(name: "nope").should be_false
  end

  it "validates case-insensitive uniqueness" do
    OrmGadget.create!(code: "g-AbC", handle: "ab", kind: "small", level: 1, stock: 0, rating: "1")
    dup = OrmGadget.new(code: "G-aBc", handle: "ab", kind: "small", level: 1, stock: 0, rating: "1")
    dup.save.should be_false
    dup.errors["code"].should contain("has already been taken")

    ok = OrmGadget.new(code: "g-xyz", handle: "ab", kind: "small", level: 1, stock: 0, rating: "1")
    ok.save.should be_true
  end

  it "validates inclusion and numericality" do
    g = OrmGadget.new(code: "g1", handle: "ab", kind: "huge", level: 9, stock: -2, rating: "3.5")
    g.save.should be_false
    g.errors["kind"].should contain("is not included in the list")
    g.errors["level"].should contain("is not included in the list")
    g.errors["stock"].should contain("must be greater than or equal to 0")
    g.errors["rating"].should contain("must be an integer")

    g2 = OrmGadget.new(code: "g2", handle: "ab", kind: "small", level: 1, stock: 1, rating: "abc")
    g2.save.should be_false
    g2.errors["rating"].should contain("is not a number")

    g3 = OrmGadget.new(code: "g3", handle: "ab", kind: "small", level: nil, stock: nil, rating: "2")
    g3.save.should be_false
    g3.errors["level"].should contain("is not included in the list")
    g3.errors["stock"].should contain("is not a number")
  end

  it "supports custom validate methods, allow_blank/allow_nil and on:" do
    g = OrmGadget.new(code: "x1", handle: "ab", kind: "small", level: 1, stock: 1, rating: "1")
    g.save.should be_false
    g.errors["code"].should contain("must start with g")

    blank_ok = OrmGadget.new(code: "g4", handle: "ab", kind: "small", level: 1, stock: 1, rating: "1", nickname: "", optional_note: nil)
    blank_ok.save.should be_true
    long_nick = OrmGadget.new(code: "g5", handle: "ab", kind: "small", level: 1, stock: 1, rating: "1", nickname: "way-too-long-nick")
    long_nick.save.should be_false
    long_nick.errors["nickname"].should contain("is too long (maximum is 10 characters)")

    h = OrmGadget.new(code: "g6", handle: "abcd", kind: "small", level: 1, stock: 1, rating: "1")
    h.valid?(:create).should be_false
    h.errors["handle"].should contain("is too long (maximum is 3 characters)")
    h.valid?(:update).should be_true
    h.save.should be_false

    r = OrmGadget.new(code: "g-reserved", handle: "ab", kind: "small", level: 1, stock: 1, rating: "1")
    r.save.should be_false
    r.errors["code"].should contain("is reserved on create")
  end

  it "supports select and distinct" do
    u = OrmUser.create!(name: "Sel", email: "sel@x.io", age: 40, admin: true)
    partial = OrmUser.where(email: "sel@x.io").select(:name).first!
    partial.name.should eq("Sel")
    partial.age.should be_nil
    partial.email.should be_nil

    row = OrmUser.where(email: "sel@x.io").select("name", "age + 1 AS age_plus").first!
    row.read_attribute("age_plus").should eq(41)
    row[:name].should eq("Sel")

    OrmPost.create!(title: "sel-d1", views: 1, published: true, orm_user_id: u.id)
    OrmPost.create!(title: "sel-d2", views: 2, published: true, orm_user_id: u.id)
    OrmPost.create!(title: "sel-d3", views: 3, published: false, orm_user_id: u.id)
    flags = OrmPost.where("title LIKE 'sel-d%'").select(:published).distinct.to_a.map(&.published)
    flags.compact.map(&.to_s).sort.should eq(["false", "true"])
    OrmPost.where("title LIKE 'sel-d%'").select(:published).distinct.count.should eq(3)
  end

  it "supports group and scalar aggregates" do
    u = OrmUser.create!(name: "Agg", email: "agg@x.io")
    OrmPost.create!(title: "agg-1", views: 10, published: true, orm_user_id: u.id)
    OrmPost.create!(title: "agg-2", views: 20, published: true, orm_user_id: u.id)
    OrmPost.create!(title: "agg-3", views: 30, published: false, orm_user_id: u.id)
    scope = OrmPost.where("title LIKE 'agg-%'")
    scope.sum(:views).should eq(60.0)
    scope.average(:views).should eq(20.0)
    scope.avg(:views).should eq(20.0)
    scope.minimum(:views).should eq(10)
    scope.maximum(:views).should eq(30)

    by_pub = scope.group(:published).count
    by_pub[true].should eq(2)
    by_pub[false].should eq(1)
    sums = scope.group(:published).sum(:views)
    sums[true].should eq(30.0)
    sums[false].should eq(30.0)
    avgs = scope.group(:published).average(:views)
    avgs[true].should eq(15.0)
    mins = scope.group(:published).minimum(:views)
    mins[true].should eq(10)
    maxs = scope.group(:published).maximum(:views)
    maxs[false].should eq(30)

    empty = OrmPost.where("title LIKE 'agg-none-%'")
    empty.sum(:views).should eq(0.0)
    empty.average(:views).should be_nil
    empty.minimum(:views).should be_nil
    empty.maximum(:views).should be_nil
    empty.group(:published).count.should be_empty
  end

  it "supports or, where.not and range where" do
    OrmUser.create!(name: "OrA", email: "ora@orx.io", age: 30)
    OrmUser.create!(name: "OrB", email: "orb@orx.io", age: 40)
    OrmUser.create!(name: "OrC", email: "orc@orx.io", age: 50)

    names = OrmUser.where(email: "ora@orx.io").or(OrmUser.where(email: "orb@orx.io")).order(:name).map(&.name)
    names.compact.should eq(["OrA", "OrB"])

    rest = OrmUser.where("email LIKE '%@orx.io'").not(name: "OrA").order(:name).map(&.name)
    rest.compact.should eq(["OrB", "OrC"])
    OrmUser.where("email LIKE '%@orx.io'").not(age: nil).count.should eq(3)

    mid = OrmUser.where("email LIKE '%@orx.io'").where(age: 30..40).order(:name).map(&.name)
    mid.compact.should eq(["OrA", "OrB"])
    excl = OrmUser.where("email LIKE '%@orx.io'").where(age: 30...40).map(&.name)
    excl.compact.should eq(["OrA"])
    old = OrmUser.where("email LIKE '%@orx.io'").where(age: 40..).map(&.name)
    old.compact.sort.should eq(["OrB", "OrC"])

    now = Time.utc
    recent = OrmUser.where("email LIKE '%@orx.io'").where(created_at: (now - 1.hour)..now).count
    recent.should eq(3)
  end

  it "supports string joins" do
    u = OrmUser.create!(name: "Join", email: "join@x.io")
    OrmPost.create!(title: "join-1", views: 1, published: true, orm_user_id: u.id)
    titles = OrmPost.where("title LIKE 'join-%'")
      .joins("INNER JOIN orm_users ON orm_users.id = orm_posts.orm_user_id")
      .where("orm_users.email = ?", "join@x.io").map(&.title)
    titles.should eq(["join-1"])
  end

  it "preloads belongs_to and has_many via includes" do
    u = OrmUser.create!(name: "Inc", email: "inc@x.io")
    OrmPost.create!(title: "inc-1", views: 1, published: true, orm_user_id: u.id)
    OrmPost.create!(title: "inc-2", views: 2, published: false, orm_user_id: u.id)
    OrmProfile.create!(orm_user_id: u.id, bio: "inc bio")

    posts = OrmPost.where("title LIKE 'inc-%'").includes(:orm_user).order(:title).to_a
    posts.size.should eq(2)
    posts.each do |p|
      p.__saci_assoc_cache.has_key?("orm_user").should be_true
      p.orm_user.not_nil!.name.should eq("Inc")
    end

    owner = OrmUser.where(email: "inc@x.io").includes(:orm_posts, :orm_profile).first!
    owner.__saci_assoc_cache.has_key?("orm_posts").should be_true
    owner.__saci_assoc_cache.has_key?("orm_profile").should be_true
    owner.orm_posts.order(:title).map(&.title).to_a.should eq(["inc-1", "inc-2"])
    owner.orm_posts.count.should eq(2)
    owner.orm_profile.not_nil!.bio.should eq("inc bio")

    expect_raises(ArgumentError) { OrmPost.includes(:bogus) }
    expect_raises(ArgumentError) do
      OrmPost.where("title LIKE 'inc-%'").includes(:orm_tags).to_a
    end
  end

  it "supports upsert, update_columns and touch" do
    u = OrmUser.create!(name: "Up", email: "up@x.io")
    OrmUser.upsert({id: u.id, name: "Up2", email: "up@x.io"}).should be_true
    u.reload.name.should eq("Up2")

    OrmUser.upsert(name: "UpNew", email: "upsert-new@x.io").should be_true
    OrmUser.exists?(email: "upsert-new@x.io").should be_true

    # Skips validations (bad email format still persists).
    OrmUser.upsert({name: "UpBad", email: "not-an-email"}).should be_true
    OrmUser.exists?(email: "not-an-email").should be_true

    expect_raises(Saci::Record::UnknownAttributeError) do
      OrmUser.upsert({name: "x", bogus_attr: 1})
    end

    # update_columns skips validations and callbacks.
    w = OrmWidget.create!(name: "wcols")
    OrmWidget.log.clear
    w.update_columns({name: ""}).should be_true
    w.reload.name.should eq("")
    OrmWidget.log.should be_empty

    # touch bumps updated_at without validations/callbacks.
    w.update_columns({name: "wt", updated_at: Time.utc(2020, 1, 1)})
    OrmWidget.log.clear
    w.touch.should be_true
    w.reload.updated_at.not_nil!.year.should eq(Time.utc.year)
    OrmWidget.log.should be_empty
    expect_raises(Saci::Record::UnknownAttributeError) { w.touch(:bogus_col) }
  end

  it "supports decimal, date and json column types" do
    m = OrmMetric.create!(ratio: 0.75, day: Time.utc(2024, 5, 1), meta: %({"a":1}))
    m.ratio.should eq(0.75)
    m.day.not_nil!.year.should eq(2024)
    m.day.not_nil!.month.should eq(5)
    m.meta.should eq(%({"a":1}))
    m.meta_json.not_nil!["a"].should eq(1)
    OrmMetric.new.meta_json.should be_nil

    m.meta_json = JSON.parse(%({"b":[1,2]}))
    m.save.should be_true
    m.reload.meta.should eq(%({"b":[1,2]}))
    m.meta_json.not_nil!["b"][1].should eq(2)

    # Migration logical types render per adapter.
    Saci::Record.db_type(:decimal, :sqlite).should eq("REAL")
    Saci::Record.db_type(:decimal, :postgres).should eq("DOUBLE PRECISION")
    Saci::Record.db_type(:decimal, :mysql).should eq("DOUBLE")
    Saci::Record.db_type(:date, :sqlite).should eq("TEXT")
    Saci::Record.db_type(:date, :postgres).should eq("DATE")
    Saci::Record.db_type(:json, :sqlite).should eq("TEXT")
    Saci::Record.db_type(:json, :postgres).should eq("JSONB")
    # crystal-mysql cannot decode the native JSON wire type, so MySQL
    # stores JSON as TEXT (content round-trips unchanged).
    Saci::Record.db_type(:json, :mysql).should eq("TEXT")
    table_columns(record_db, "orm_metrics").should contain("ratio")
    table_columns(record_db, "orm_metrics").should contain("day")
    table_columns(record_db, "orm_metrics").should contain("meta")
  end

  it "maintains counter_cache and touch on belongs_to" do
    shelf = OrmShelf.create!(label: "counted")
    shelf.orm_books_count.should eq(0)

    b1 = OrmBook.create!(title: "c1", orm_shelf_id: shelf.id)
    b2 = OrmBook.create!(title: "c2", orm_shelf_id: shelf.id)
    shelf.reload.orm_books_count.should eq(2)

    b1.destroy.should be_true
    shelf.reload.orm_books_count.should eq(1)

    # touch: saving / destroying a book bumps the parent's updated_at.
    shelf.update_columns({updated_at: Time.utc(2020, 1, 1)})
    b2.update!(title: "c2x")
    shelf.reload.updated_at.not_nil!.year.should eq(Time.utc.year)
    shelf.update_columns({updated_at: Time.utc(2020, 1, 1)})
    b2.destroy.should be_true
    shelf.reload.updated_at.not_nil!.year.should eq(Time.utc.year)
    shelf.reload.orm_books_count.should eq(0)
  end

  it "destroys dependents with callbacks" do
    OrmBook.log.clear
    shelf = OrmShelf.create!(label: "doomed")
    OrmBook.create!(title: "d1", orm_shelf_id: shelf.id)
    OrmBook.create!(title: "d2", orm_shelf_id: shelf.id)
    shelf.destroy.should be_true
    OrmBook.log.sort.should eq(["destroyed:d1", "destroyed:d2"])
    OrmBook.where(orm_shelf_id: shelf.id).count.should eq(0)
    OrmShelf.exists?(id: shelf.id).should be_false
  end

  it "deletes dependents without callbacks" do
    OrmBook.log.clear
    crate = OrmCrate.create!(label: "purged")
    OrmBook.create!(title: "p1", orm_shelf_id: crate.id)
    OrmBook.create!(title: "p2", orm_shelf_id: crate.id)
    crate.destroy.should be_true
    OrmBook.log.should be_empty
    OrmBook.where(orm_shelf_id: crate.id).count.should eq(0)
  end

  it "nullifies dependents" do
    depot = OrmDepot.create!(label: "kept")
    kept = OrmBook.create!(title: "k1", orm_shelf_id: depot.id)
    depot.destroy.should be_true
    kept.reload.orm_shelf_id.should be_nil
    OrmBook.exists?(id: kept.id).should be_true
  end

  it "runs dependent cleanup on has_many :through joins" do
    user = OrmUser.create!(name: "DepThrough", email: "depthrough@x.io")
    post = OrmPost.create!(title: "dep-post", views: 1, published: true, orm_user_id: user.id)
    tag = OrmTag.create!(tag: "dep-tag")
    OrmTagging.create!(orm_post_id: post.id, orm_tag_id: tag.id)
    post.destroy.should be_true
    OrmTagging.where(orm_post_id: post.id).count.should eq(0)
    OrmTag.exists?(id: tag.id).should be_true

    post2 = OrmPost.create!(title: "dep-post2", views: 1, published: true, orm_user_id: user.id)
    tag2 = OrmTag.create!(tag: "dep-tag2")
    OrmTagging.create!(orm_post_id: post2.id, orm_tag_id: tag2.id)
    tag2.destroy.should be_true
    OrmTagging.where(orm_tag_id: tag2.id).count.should eq(0)
    OrmPost.exists?(id: post2.id).should be_true
  end

  it "commits and rolls back transactions" do
    Saci::Record::Base.transaction do
      OrmUser.create!(name: "Tx", email: "tx@x.io")
    end
    OrmUser.exists?(email: "tx@x.io").should be_true

    # DB::Rollback is swallowed by design (like ActiveRecord::Rollback):
    # the transaction rolls back and returns nil.
    result = Saci::Record::Base.transaction do
      OrmUser.create!(name: "Nope", email: "nope@x.io")
      raise DB::Rollback.new
    end
    result.should be_nil
    OrmUser.exists?(email: "nope@x.io").should be_false
  end

  it "rolls back reversible migrations and restores on migrate" do
    undone = Saci::Record::Migrator.rollback(record_db, [
      CreateOrmUsers,
      CreateOrmPosts,
      AddBioToOrmUsers,
      CreateAppLogs,
    ] of Saci::Record::Migration.class, 1)
    undone.should eq(["CreateAppLogs"])
    table_columns(record_db, "orm_users").should contain("bio")

    undone = Saci::Record::Migrator.rollback(record_db, [
      CreateOrmUsers,
      CreateOrmPosts,
      AddBioToOrmUsers,
      CreateAppLogs,
    ] of Saci::Record::Migration.class, 1)
    undone.should eq(["AddBioToOrmUsers"])
    table_columns(record_db, "orm_users").should_not contain("bio")

    ran = Saci::Record::Migrator.migrate(record_db, [
      CreateOrmUsers,
      CreateOrmPosts,
      AddBioToOrmUsers,
      CreateAppLogs,
    ] of Saci::Record::Migration.class)
    ran.should contain("AddBioToOrmUsers")
    ran.should contain("CreateAppLogs")
    table_columns(record_db, "orm_users").should contain("bio")
  end

  it "raises IrreversibleMigration when inverting drop_table" do
    record_db.exec("CREATE TABLE temp_t (id INTEGER PRIMARY KEY)")
    m = DropTempTable.new(record_db)
    m.up
    table_columns(record_db, "temp_t").should be_empty
    expect_raises(Saci::Record::IrreversibleMigration) { m.down }
  end

  it "cleans the database and deletes all rows per model" do
    OrmUser.create!(name: "Clean", email: "clean@x.io")
    OrmPost.create!(title: "Scrub", views: 1, published: false)
    Saci::Record.clean_database!
    OrmUser.count.should eq(0)
    OrmPost.count.should eq(0)

    OrmUser.create!(name: "Again", email: "again@x.io")
    OrmUser.delete_all.should eq(1)
    OrmUser.count.should eq(0)
  end

  it "supports polymorphic belongs_to and has_many as:" do
    post = OrmPolyPost.create!(title: "pp1")
    comment = OrmPolyComment.create!(body: "pc1")
    n1 = OrmPolyNote.create!(msg: "pm1", notifiable_type: "OrmPolyPost", notifiable_id: post.id)
    n2 = OrmPolyNote.create!(msg: "pm2", notifiable_type: "OrmPolyComment", notifiable_id: comment.id)

    n1.notifiable.not_nil!.as(OrmPolyPost).title.should eq("pp1")
    n2.notifiable.not_nil!.as(OrmPolyComment).body.should eq("pc1")
    post.orm_poly_notes.map(&.msg).compact.sort.should eq(["pm1"])
    comment.orm_poly_notes.map(&.msg).compact.sort.should eq(["pm2"])

    # Association setter stores type + id.
    n3 = OrmPolyNote.new(msg: "pm3")
    (n3.notifiable = comment).should_not be_nil
    n3.save.should be_true
    n3.notifiable_type.should eq("OrmPolyComment")
    n3.notifiable_id.should eq(comment.id)
    n3.notifiable.not_nil!.as(OrmPolyComment).body.should eq("pc1")

    # Nil type/id → nil; dangling rows raise like belongs_to.
    OrmPolyNote.new(msg: "nil-note").notifiable.should be_nil
    dangling = OrmPolyNote.new(msg: "dang", notifiable_type: "OrmPolyPost", notifiable_id: 999999)
    expect_raises(Saci::Record::RecordNotFound) { dangling.notifiable }

    # Preloading kills N+1 (one query per type, cache populated).
    notes = OrmPolyNote.where("msg LIKE 'pm%'").includes(:notifiable).order(:msg).to_a
    notes.size.should eq(3)
    notes.each { |n| n.__saci_assoc_cache.has_key?("notifiable").should be_true }
    notes.map { |n| n.notifiable.not_nil!.class.name }.sort.should eq(["OrmPolyComment", "OrmPolyComment", "OrmPolyPost"])

    posts = OrmPolyPost.where(title: "pp1").includes(:orm_poly_notes).to_a
    posts.first.__saci_assoc_cache.has_key?("orm_poly_notes").should be_true
    posts.first.orm_poly_notes.map(&.msg).compact.should contain("pm1")

    expect_raises(ArgumentError) { OrmPolyNote.joins(:notifiable).to_a }
  end

  it "preloads nested includes to two levels" do
    u = OrmUser.create!(name: "NestUser", email: "nest2@x.io")
    p = OrmPost.create!(title: "nest-p2", views: 1, published: true, orm_user_id: u.id)
    OrmTagging.create!(orm_post_id: p.id, orm_tag_id: OrmTag.create!(tag: "nest-tag2").id)

    # belongs_to chain: tagging -> post -> user.
    rows = OrmTagging.where(orm_post_id: p.id).includes(orm_post: :orm_user).to_a
    rows.size.should eq(1)
    rows.first.__saci_assoc_cache.has_key?("orm_post").should be_true
    rows.first.orm_post.not_nil!.__saci_assoc_cache.has_key?("orm_user").should be_true
    rows.first.orm_post.not_nil!.orm_user.not_nil!.name.should eq("NestUser")

    # has_many chain: user -> posts -> user.
    owners = OrmUser.where(email: "nest2@x.io").includes(orm_posts: :orm_user).to_a
    owners.first.__saci_assoc_cache.has_key?("orm_posts").should be_true
    first_post = owners.first.orm_posts.to_a.first
    first_post.__saci_assoc_cache.has_key?("orm_user").should be_true
    first_post.orm_user.not_nil!.name.should eq("NestUser")

    expect_raises(ArgumentError) { OrmTagging.includes(orm_post: :bogus).to_a }
    expect_raises(ArgumentError) { OrmTagging.includes(:bogus).to_a }
  end

  it "restricts destroy with dependent: :restrict_with_exception" do
    g = OrmGuild.create!(label: "restrict-g")
    m = OrmGuildMember.create!(name: "gm1", orm_guild_id: g.id)
    expect_raises(Saci::Record::DeleteRestrictionError) { g.destroy }
    OrmGuild.exists?(id: g.id).should be_true
    m.destroy.should be_true
    g.destroy.should be_true
    OrmGuild.exists?(id: g.id).should be_false

    s = OrmStudio.create!(name: "restrict-s")
    b = OrmBadge.create!(label: "rb1", orm_studio_id: s.id)
    expect_raises(Saci::Record::DeleteRestrictionError) { s.destroy }
    OrmStudio.exists?(id: s.id).should be_true
    b.destroy.should be_true
    s.destroy.should be_true
  end

  it "supports if:/unless: conditions on validates and validate" do
    # Symbol if: skips when false, runs when true.
    OrmCoupon.new(code: nil, kind: "other", handle: "ok").valid?.should be_true
    bad = OrmCoupon.new(code: nil, kind: "promo", handle: "ok")
    bad.valid?.should be_false
    bad.errors["code"].should contain("can't be blank")

    # Symbol unless: runs when false, skips when true.
    OrmCoupon.new(code: "c", kind: "free", handle: nil).valid?.should be_true
    bad2 = OrmCoupon.new(code: "c", kind: "other", handle: nil)
    bad2.valid?.should be_false
    bad2.errors["handle"].should contain("can't be blank")

    # Proc if: with record arg.
    OrmCoupon.new(code: "other", kind: nil, handle: "ok").valid?.should be_true
    bad3 = OrmCoupon.new(code: "special", kind: nil, handle: "ok")
    bad3.valid?.should be_false
    bad3.errors["kind"].should contain("can't be blank")

    # Proc if: on format (only email kind validates format).
    OrmCoupon.new(code: "plain", kind: "other", handle: "ok").valid?.should be_true
    bad4 = OrmCoupon.new(code: "plain", kind: "email", handle: "ok")
    bad4.valid?.should be_false
    bad4.errors["code"].should contain("is invalid")
    OrmCoupon.new(code: "a@b", kind: "email", handle: "ok").valid?.should be_true

    # Symbol if: on custom validate.
    OrmCoupon.new(code: "fancy", kind: "fancy", handle: "ok").valid?.should be_true
    bad5 = OrmCoupon.new(code: "wrong", kind: "fancy", handle: "ok")
    bad5.valid?.should be_false
    bad5.errors["code"].should contain("must be fancy")
    OrmCoupon.new(code: "wrong", kind: "other", handle: "ok").valid?.should be_true

    # Proc unless: on custom validate block.
    OrmCoupon.new(code: "c", kind: "skip", handle: "way-too-long").valid?.should be_true
    bad6 = OrmCoupon.new(code: "c", kind: "other", handle: "way-too-long")
    bad6.valid?.should be_false
    bad6.errors["handle"].should contain("is too long")
  end

  it "supports symbol-form joins alongside string joins" do
    u = OrmUser.create!(name: "SymJoin", email: "symjoin@x.io")
    OrmPost.create!(title: "sym-j1", views: 1, published: true, orm_user_id: u.id)

    OrmPost.joins(:orm_user).where("orm_users.email = ?", "symjoin@x.io").map(&.title).should eq(["sym-j1"])
    OrmUser.joins(:orm_posts).where("orm_posts.title = ?", "sym-j1").map(&.name).compact.should eq(["SymJoin"])
    OrmTagging.joins(:orm_post).where("orm_posts.title = ?", "sym-j1").to_a.size.should be >= 0

    # String joins still work and chain with symbol joins.
    OrmPost.joins(:orm_user).joins("INNER JOIN orm_users u2 ON u2.id = orm_posts.orm_user_id").where("orm_users.email = ?", "symjoin@x.io").map(&.title).should eq(["sym-j1"])

    expect_raises(ArgumentError) { OrmPost.joins(:bogus).to_a }
  end

  it "supports reset_counters, update_counter and touch_all" do
    shelf = OrmShelf.create!(label: "polish")
    b1 = OrmBook.create!(title: "pb1", orm_shelf_id: shelf.id)
    b2 = OrmBook.create!(title: "pb2", orm_shelf_id: shelf.id)
    shelf.reload.orm_books_count.should eq(2)

    # update_counter (class + instance + plural).
    OrmShelf.update_counter(shelf.id, :orm_books_count, -1).should be_true
    shelf.reload.orm_books_count.should eq(1)
    shelf.update_counter(:orm_books_count, 2).should be_true
    shelf.reload.orm_books_count.should eq(3)
    OrmShelf.update_counters(shelf.id, {orm_books_count: -1}).should be_true
    shelf.reload.orm_books_count.should eq(2)

    # reset_counters recounts from the association.
    shelf.update_columns({orm_books_count: 99})
    shelf.reload.orm_books_count.should eq(99)
    OrmShelf.reset_counters(shelf.id, :orm_books).should be_true
    shelf.reload.orm_books_count.should eq(2)
    expect_raises(Saci::Record::UnknownAttributeError) { OrmShelf.reset_counters(shelf.id, :bogus) }
    expect_raises(Saci::Record::UnknownAttributeError) { OrmShelf.update_counter(shelf.id, :bogus, 1) }

    # touch_all bumps updated_at without callbacks/validations.
    shelf.update_columns({updated_at: Time.utc(2020, 1, 1)})
    OrmShelf.where(id: shelf.id).touch_all.should eq(1)
    shelf.reload.updated_at.not_nil!.year.should eq(Time.utc.year)
    OrmBook.where(orm_shelf_id: shelf.id).touch_all.should eq(2)
    expect_raises(Saci::Record::UnknownAttributeError) { OrmShelf.where(id: shelf.id).touch_all(:bogus_col) }
  end
end

# Regression: models that inherit through an intermediate base class (the
# common `ApplicationRecord < Saci::Record::Base` pattern) used to run leaf
# validations twice — `run_validations` called `__saci_run_validations` in
# every subclass hook AND via `super` from the leaf.

class OrmIntermediateBase < Saci::Record::Base
end

class OrmIntermediateThing < OrmIntermediateBase
  table "ory_things"
  column id : Int64, primary: true
  column name : String
  validates :name, presence: true
  validate { |r| r.errors.add("name", "custom") if (r.name || "").empty? }
end

describe "validation chains through intermediate base classes" do
  before_each do
    Saci::Record.connection.exec("DROP TABLE IF EXISTS ory_things")
    Saci::Record.connection.exec("CREATE TABLE ory_things (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)")
  end

  it "runs each validation exactly once" do
    thing = OrmIntermediateThing.new
    thing.valid?.should be_false
    thing.errors["name"].should eq(["can't be blank", "custom"])
  end
end
