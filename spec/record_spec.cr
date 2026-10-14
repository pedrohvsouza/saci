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
end
