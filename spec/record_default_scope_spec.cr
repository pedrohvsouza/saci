require "spec"
require "file"
require "../src/saci"

class CreateDsTables < Saci::Record::Migration
  def change
    create_table :ds_authors do |t|
      t.string :name
    end
    create_table :ds_posts do |t|
      t.integer :ds_author_id
      t.string :title
      t.string :slug
      t.integer :position, default: 0
      t.boolean :deleted, default: false
    end
    create_table :ds_tags do |t|
      t.string :name
    end
  end
end

# A column-less parent: its default scope reaches every subclass.
class DsSoftDeletable < Saci::Record::Base
  default_scope { where(deleted: false) }
end

class DsAuthor < Saci::Record::Base
  column id : Int64, primary: true
  column name : String
  has_many :ds_posts
end

class DsPost < DsSoftDeletable
  column id : Int64, primary: true
  column ds_author_id : Int64
  column title : String
  column slug : String
  column position : Int32, default: 0
  column deleted : Bool, default: false
  belongs_to :ds_author

  validates :slug, uniqueness: true

  default_scope { order(:position) }
  scope :titled, ->(t : String) { where(title: t) }
end

class DsTag < Saci::Record::Base
  column id : Int64, primary: true
  column name : String
end

DS_DB_PATH = "/tmp/saci_record_default_scope_test.db"

def ds_db : DB::Database
  Saci::Record::Base.connection.as(DB::Database)
end

describe "Saci::Record default_scope" do
  before_all do
    File.delete(DS_DB_PATH) if File.exists?(DS_DB_PATH)
    Saci::Record::Base.connection = DB.open("sqlite3://#{DS_DB_PATH}")
    Saci::Record::Migrator.migrate(ds_db, [CreateDsTables] of Saci::Record::Migration.class)
  end

  after_all do
    ds_db.close
    File.delete(DS_DB_PATH) if File.exists?(DS_DB_PATH)
  end

  before_each do
    DsPost.unscoped.delete_all
    DsAuthor.delete_all
    DsTag.delete_all
  end

  it "applies inherited and own default scopes to every query" do
    author = DsAuthor.create!(name: "a")
    aid = author.id.not_nil!
    DsPost.create!(ds_author_id: aid, title: "second", slug: "s2", position: 2)
    DsPost.create!(ds_author_id: aid, title: "first", slug: "s1", position: 1)
    gone = DsPost.create!(ds_author_id: aid, title: "gone", slug: "s3", position: 0)
    gone.update_columns(deleted: true)

    DsPost.count.should eq(2)
    DsPost.all.map(&.title).should eq(["first", "second"])
    DsPost.first.not_nil!.title.should eq("first")
    DsPost.where(ds_author_id: aid).count.should eq(2)
    DsPost.titled("gone").count.should eq(0)
    DsPost.find_by(slug: "s3").should be_nil
    expect_raises(Saci::Record::RecordNotFound) { DsPost.find(gone.id.not_nil!) }
    author.ds_posts.count.should eq(2)
  end

  it "is skipped by unscoped, unscoped blocks and unscope(:where)" do
    DsPost.create!(title: "b", slug: "b", position: 2)
    gone = DsPost.create!(title: "a", slug: "a", position: 1)
    gone.update_columns(deleted: true)
    gid = gone.id.not_nil!

    DsPost.unscoped.count.should eq(2)
    DsPost.unscoped.titled("a").count.should eq(1)
    DsPost.unscoped { DsPost.find(gid).title }.should eq("a")
    DsPost.unscoped { DsPost.count }.should eq(2)
    DsPost.count.should eq(1)
    # unscope(:where) drops the conditions but keeps the default order.
    DsPost.all.unscope(:where).map(&.title).should eq(["a", "b"])
  end

  it "unscopes only the given model inside the block" do
    DsTag.create!(name: "t")
    gone = DsPost.create!(title: "x", slug: "x")
    gone.update_columns(deleted: true)
    DsTag.unscoped { DsPost.count }.should eq(0)
  end

  it "restores the default scope after an exception in the block" do
    gone = DsPost.create!(title: "x", slug: "x")
    gone.update_columns(deleted: true)
    expect_raises(Exception, "boom") { DsPost.unscoped { raise "boom" } }
    DsPost.count.should eq(0)
  end

  it "keeps the scope off for nested unscoped blocks until the outer one ends" do
    gone = DsPost.create!(title: "x", slug: "x")
    gone.update_columns(deleted: true)
    DsPost.unscoped do
      DsPost.unscoped { DsPost.count }.should eq(1)
      DsPost.count.should eq(1)
    end
    DsPost.count.should eq(0)
  end

  it "checks uniqueness and reloads across the default scope" do
    gone = DsPost.create!(title: "x", slug: "taken")
    gone.update_columns(deleted: true)
    dup = DsPost.new(title: "y", slug: "taken")
    dup.valid?.should be_false
    dup.errors["slug"].should contain("has already been taken")
    gone.reload.deleted.should be_true
  end
end
