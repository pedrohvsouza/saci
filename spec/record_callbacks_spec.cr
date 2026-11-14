require "spec"
require "file"
require "../src/saci"

class CreateCbTables < Saci::Record::Migration
  def change
    create_table :cb_posts do |t|
      t.string :title
      t.boolean :locked, default: false
      t.boolean :published, default: false
      t.integer :views, default: 0
      t.integer :author_id
      t.timestamps
    end
    create_table :cb_notes do |t|
      t.integer :cb_post_id
      t.string :body
    end
  end
end

CB_LOG = [] of String

class CbNote < Saci::Record::Base
  column id : Int64, primary: true
  column cb_post_id : Int64
  column body : String
  belongs_to :cb_post

  scope :with_body, ->(text : String) { where(body: text) }
end

class CbPost < Saci::Record::Base
  column id : Int64, primary: true
  column title : String
  column locked : Bool, default: false
  column published : Bool, default: false
  column views : Int32, default: 0
  column author_id : Int64
  timestamps

  has_many :cb_notes, dependent: :destroy

  property halt_on : String? = nil
  property skip_yield : Bool = false

  scope :published, -> { where(published: true) }
  scope :popular, -> { where("views >= ?", 10) }
  scope :by_author, ->(id : Int64) { where(author_id: id) }
  scope :featured, -> { published.popular }
  scope :maybe_locked, ->(only : Bool) { where(locked: true) if only }

  before_validation { |p| CB_LOG << "before_validation"; p.throw_abort if p.halt_on == "before_validation" }
  before_save { |p| CB_LOG << "before_save"; p.throw_abort if p.halt_on == "before_save" }
  around_save :wrap_save
  before_create { |p| CB_LOG << "before_create"; p.throw_abort if p.halt_on == "before_create" }
  around_create { |_p, proceed| CB_LOG << "around_create:in"; proceed.call; CB_LOG << "around_create:out" }
  after_create { CB_LOG << "after_create" }
  before_update { |p| CB_LOG << "before_update"; p.throw_abort if p.halt_on == "before_update" }
  around_update { |_p, proceed| CB_LOG << "around_update:in"; proceed.call; CB_LOG << "around_update:out" }
  after_update { CB_LOG << "after_update" }
  after_save { CB_LOG << "after_save" }
  after_commit { CB_LOG << "after_commit" }
  after_commit(on: :destroy) { CB_LOG << "after_destroy_commit" }
  after_commit(on: :update) { CB_LOG << "after_update_commit" }
  before_destroy { |p| CB_LOG << "before_destroy"; p.throw_abort if p.locked }
  around_destroy :wrap_destroy
  after_destroy { CB_LOG << "after_destroy" }

  def wrap_save(&)
    CB_LOG << "around_save:in"
    return if skip_yield
    yield
    CB_LOG << "around_save:out"
  end

  def wrap_destroy(&)
    CB_LOG << "around_destroy:in"
    yield
    CB_LOG << "around_destroy:out"
  end
end

# A second model with a scope of the same name: the shared `Query`
# forwarder must dispatch per model.
class CbOther < Saci::Record::Base
  table "cb_posts"
  column id : Int64, primary: true
  column title : String
  column published : Bool, default: false

  scope :published, -> { where(published: false) }
end

CB_DB_PATH = "/tmp/saci_record_callbacks_test.db"

def cb_db : DB::Database
  Saci::Record::Base.connection.as(DB::Database)
end

describe "Saci::Record callbacks and scopes" do
  before_all do
    File.delete(CB_DB_PATH) if File.exists?(CB_DB_PATH)
    Saci::Record::Base.connection = DB.open("sqlite3://#{CB_DB_PATH}")
    Saci::Record::Migrator.migrate(cb_db, [CreateCbTables] of Saci::Record::Migration.class)
  end

  after_all do
    cb_db.close
    File.delete(CB_DB_PATH) if File.exists?(CB_DB_PATH)
  end

  before_each do
    CbNote.delete_all
    CbPost.delete_all
    CB_LOG.clear
  end

  describe "order" do
    it "runs create callbacks in Rails order" do
      CbPost.create!(title: "a")
      CB_LOG.should eq(%w(before_validation before_save around_save:in before_create
        around_create:in around_create:out after_create around_save:out after_save after_commit))
    end

    it "runs update callbacks in Rails order" do
      post = CbPost.create!(title: "a")
      CB_LOG.clear
      post.update!(title: "b")
      CB_LOG.should eq(%w(before_validation before_save around_save:in before_update
        around_update:in around_update:out after_update around_save:out after_save after_commit after_update_commit))
    end

    it "runs destroy callbacks in Rails order" do
      post = CbPost.create!(title: "a")
      CB_LOG.clear
      post.destroy.should be_true
      CB_LOG.should eq(%w(before_destroy around_destroy:in around_destroy:out after_destroy after_commit after_destroy_commit))
      post.destroyed?.should be_true
    end

    it "lets after_update read saved_changes" do
      post = CbPost.create!(title: "a")
      post.title = "b"
      post.save.should be_true
      post.saved_change_to_title.should eq(["a", "b"])
    end
  end

  describe "throw_abort" do
    {"before_validation", "before_save", "before_create"}.each do |hook|
      it "halts a create from #{hook}" do
        post = CbPost.new(title: "x")
        post.halt_on = hook
        post.save.should be_false
        post.halted?.should be_true
        post.new_record?.should be_true
        CbPost.count.should eq(0)
        CB_LOG.should_not contain("after_save")
        expect_raises(Saci::Record::RecordNotSaved) { post.save! }
      end
    end

    it "halts an update from before_update without writing" do
      post = CbPost.create!(title: "a")
      post.title = "b"
      post.halt_on = "before_update"
      post.save.should be_false
      post.halted?.should be_true
      CbPost.find(post.id.not_nil!).title.should eq("a")
      post.changed?.should be_true
    end

    it "halts when an around callback does not yield" do
      post = CbPost.new(title: "x")
      post.skip_yield = true
      post.save.should be_false
      post.halted?.should be_true
      CbPost.count.should eq(0)
    end

    it "keeps the record and its dependents when before_destroy aborts" do
      post = CbPost.create!(title: "a", locked: true)
      CbNote.create!(cb_post_id: post.id.not_nil!, body: "n")
      CB_LOG.clear
      post.destroy.should be_false
      post.halted?.should be_true
      post.destroyed?.should be_false
      CbPost.count.should eq(1)
      CbNote.count.should eq(1)
      CB_LOG.should eq(%w(before_destroy))
      expect_raises(Saci::Record::RecordNotDestroyed) { post.destroy! }
    end

    it "clears halted? on the next successful save" do
      post = CbPost.new(title: "x")
      post.halt_on = "before_save"
      post.save.should be_false
      post.halt_on = nil
      post.save.should be_true
      post.halted?.should be_false
    end

    it "raises when throw_abort is called after the write" do
      post = CbPost.create!(title: "a")
      expect_raises(Saci::Record::CallbackAbort) { post.throw_abort }
    end
  end

  describe "scope" do
    it "defines chainable class and query methods" do
      CbPost.create!(title: "a", published: true, views: 20, author_id: 1_i64)
      CbPost.create!(title: "b", published: true, views: 1, author_id: 2_i64)
      CbPost.create!(title: "c", published: false, views: 30, author_id: 1_i64)

      CbPost.published.count.should eq(2)
      CbPost.published.popular.map(&.title).should eq(["a"])
      CbPost.where(author_id: 1_i64).published.map(&.title).should eq(["a"])
      CbPost.by_author(1_i64).order(:title).map(&.title).should eq(["a", "c"])
      CbPost.popular.by_author(1_i64).count.should eq(2)
      CbPost.featured.map(&.title).should eq(["a"])
    end

    it "returns the query unchanged when the body returns nil" do
      CbPost.create!(title: "a", locked: true)
      CbPost.create!(title: "b")
      CbPost.maybe_locked(false).count.should eq(2)
      CbPost.maybe_locked(true).count.should eq(1)
    end

    it "dispatches same-named scopes per model" do
      CbPost.create!(title: "a", published: true)
      CbPost.create!(title: "b", published: false)
      CbPost.published.map(&.title).should eq(["a"])
      CbOther.published.map(&.title).should eq(["b"])
      CbOther.all.published.map(&.title).should eq(["b"])
    end

    it "works on association queries" do
      post = CbPost.create!(title: "a")
      CbNote.create!(cb_post_id: post.id.not_nil!, body: "n")
      CbNote.create!(cb_post_id: post.id.not_nil!, body: "m")
      post.cb_notes.with_body("m").map(&.body).should eq(["m"])
    end
  end
end
