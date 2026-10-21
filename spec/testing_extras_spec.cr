require "spec"
require "../src/saci"
require "../src/saci/testing"

# ---------------------------------------------------------------------------
# Test schema / models (registered with the testing migration registry)
# ---------------------------------------------------------------------------

class CreateTestingTeams < Saci::Record::Migration
  def change
    create_table :testing_teams do |t|
      t.string :name, null: false
      t.timestamps
    end
  end
end

class CreateTestingUsers < Saci::Record::Migration
  def change
    create_table :testing_users do |t|
      t.string :name, null: false
      t.string :email
      t.boolean :admin, null: false, default: false
      t.bigint :team_id
      t.timestamps
    end
  end
end

class CreateTestingPosts < Saci::Record::Migration
  def change
    create_table :testing_posts do |t|
      t.string :title, null: false
      t.bigint :user_id
      t.timestamps
    end
  end
end

class TestingTeam < Saci::Record::Base
  table "testing_teams"
  column id : Int64, primary: true
  column name : String
  timestamps
end

class TestingUser < Saci::Record::Base
  table "testing_users"
  column id : Int64, primary: true
  column name : String
  column email : String
  column admin : Bool
  column team_id : Int64
  timestamps

  @@commit_log = [] of String

  def self.commit_log : Array(String)
    @@commit_log
  end

  def self.reset_commit_log! : Nil
    @@commit_log.clear
  end

  after_commit -> { TestingUser.commit_log << name.to_s }
end

class TestingPost < Saci::Record::Base
  table "testing_posts"
  column id : Int64, primary: true
  column title : String
  column user_id : Int64
  timestamps
end

# ---------------------------------------------------------------------------
# Factories (compile-time macro DSL)
# ---------------------------------------------------------------------------

# Model class omitted: `factory :testing_team` infers the `TestingTeam`
# constant at compile time.
factory :testing_team do
  name "The Team"
end

factory :testing_user, TestingUser do
  name "Alice"
  email { "user#{Saci::Testing::Factory.sequence(:email)}@example.com" }
  admin false
  belongs_to :team, :testing_team

  trait :admin do
    admin true
  end
end

factory :testing_author, TestingUser do
  name "Author"
  has_many :posts, :testing_post, count: 2, foreign_key: "user_id"
end

factory :testing_post, TestingPost do
  title "A post"
  belongs_to :user, :testing_user, foreign_key: "user_id"
end

# ---------------------------------------------------------------------------
# Fixture files + database preparation
# ---------------------------------------------------------------------------

FIXTURE_DIR = "tmp/saci_testing_spec/fixtures"
DB_PATH     = "tmp/saci_testing_spec/db/app_test.db"
DB_URL      = Saci::Testing.sqlite_url_for(DB_PATH)

Dir.mkdir_p(FIXTURE_DIR)

File.write(File.join(FIXTURE_DIR, "testing_teams.yml"), <<-YAML)
alpha:
  name: Alpha
beta:
  name: Beta
YAML

File.write(File.join(FIXTURE_DIR, "testing_users.yml"), <<-YAML)
alice:
  name: Alice
  email: alice@example.com
  admin: false
  team_id: testing_teams.alpha
bob:
  name: Bob
  email: bob@example.com
  admin: true
  team_id: testing_teams.beta
carol:
  name: Carol
  email: carol@example.com
  team_id: testing_teams.alpha
YAML

File.write(File.join(FIXTURE_DIR, "testing_posts.yml"), <<-YAML)
hello:
  title: Hello
  user_id: testing_users.alice
world:
  title: World
  user_id: bob
YAML

Spec.before_suite do
  Saci::Testing.prepare_database!(url: DB_URL, fresh: true)
end

load_fixtures :all, path: FIXTURE_DIR
fixture :testing_users, TestingUser
fixture :testing_teams, TestingTeam
fixture :testing_posts, TestingPost

# ---------------------------------------------------------------------------
# Test database lifecycle
# ---------------------------------------------------------------------------

describe "Saci::Testing test database lifecycle" do
  it "prepares a fresh SQLite database and runs registered migrations" do
    Saci::Testing.opened_url.should eq(DB_URL)
    applied = Saci::Record::Migrator.applied_names(Saci::Record.database("primary"))
    applied.should contain(CreateTestingTeams.name)
    applied.should contain(CreateTestingUsers.name)
    applied.should contain(CreateTestingPosts.name)
    Saci::Testing.registered_migrations.should contain(CreateTestingUsers.name)
  end

  it "maintain_test_schema! is idempotent" do
    newly_applied = Saci::Testing.maintain_test_schema!
    newly_applied.should be_empty
  end

  it "builds sqlite URLs and extracts paths" do
    Saci::Testing.sqlite_url_for("tmp/foo.db").should eq("sqlite3://./tmp/foo.db")
    Saci::Testing.sqlite_path_from_url("sqlite3://./tmp/foo.db").should eq("./tmp/foo.db")
    Saci::Testing.sqlite_path_from_url("postgres://localhost/x").should be_nil
  end

  it "splits schema SQL on unquoted semicolons" do
    statements = Saci::Testing.split_sql_statements(<<-SQL)
      INSERT INTO t (name) VALUES ('a;b');
      -- a comment; with a semicolon
      SELECT 1;
      SQL
    statements.size.should eq(2)
    statements[0].should contain("'a;b'")
    statements[1].should eq("SELECT 1")
  end

  it "loads schema SQL into the database" do
    Saci::Testing.load_schema_sql!("CREATE TABLE schema_probe (id INTEGER PRIMARY KEY, name TEXT)")
    Saci::Record.query_compat(Saci::Record.connection, "SELECT name FROM schema_probe") { |_rs| }
    Saci::Record.exec_compat(Saci::Record.connection, "DROP TABLE schema_probe")
  end

  it "clean_database! truncates all tables and the fixture registry" do
    TestingUser.create!(name: "temporary")
    Saci::Testing.clean_database!
    TestingUser.count.should eq(0)
    Saci::Testing::Fixtures.loaded?.should be_false
    Saci::Testing::Fixtures.load(FIXTURE_DIR)
    TestingUser.count.should eq(3)
  end
end

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

describe "Saci::Testing::Fixtures" do
  transactional_tests

  it "loads YAML fixtures, assigns ids and exposes labels" do
    Saci::Testing::Fixtures.rows("testing_users").size.should eq(3)
    Saci::Testing::Fixtures.id_for("testing_users", "alice").should be_a(Int64)
    Saci::Testing::Fixtures.loaded_labels["testing_teams"].should eq(["alpha", "beta"])
  end

  it "generates typed accessors via the fixture macro" do
    testing_users(:alice).name.should eq("Alice")
    testing_users?(:nobody).should be_nil
    testing_teams(:beta).name.should eq("Beta")
  end

  it "resolves table.label and inferred label references" do
    testing_posts(:hello).user_id.should eq(testing_users(:alice).id)
    testing_posts(:world).user_id.should eq(testing_users(:bob).id)
    testing_users(:alice).team_id.should eq(testing_teams(:alpha).id)
  end

  it "fills NOT NULL timestamp columns automatically" do
    user = testing_users(:alice)
    user.created_at.should_not be_nil
    user.updated_at.should_not be_nil
  end

  it "respects database defaults for omitted columns" do
    testing_users(:carol).admin.should be_false
  end

  it "rejects ERB values with a helpful error" do
    path = File.join(FIXTURE_DIR, "erb_users.yml")
    File.write(path, "x:\n  name: <%= User.first.name %>\n")
    expect_raises(Saci::Testing::Fixtures::FixtureLoadError, /ERB is not supported/) do
      Saci::Testing::Fixtures.load(path, table: "testing_users")
    end
    # A failed parse must not clear the in-memory fixture view.
    testing_users(:alice).name.should eq("Alice")
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "reports unknown columns" do
    path = File.join(FIXTURE_DIR, "bad_users.yml")
    File.write(path, "x:\n  nope: 1\n")
    expect_raises(Saci::Testing::Fixtures::FixtureLoadError, /unknown column/) do
      Saci::Testing::Fixtures.load(path, table: "testing_users")
    end
  ensure
    File.delete(path) if path && File.exists?(path)
  end
end

# Reloading fixtures inside a rolled-back transaction would desync the
# in-memory label/id table from the database, so mutation tests run outside
# transactional_tests and reload afterwards.
describe "Saci::Testing::Fixtures reloading" do
  it "replaces existing rows when delete_existing is true" do
    TestingUser.create!(name: "extra")
    TestingUser.count.should eq(4)
    Saci::Testing::Fixtures.load(FIXTURE_DIR)
    TestingUser.count.should eq(3)
  ensure
    Saci::Testing::Fixtures.reload!
  end

  it "loads an explicit file with an explicit table" do
    rows = Saci::Testing::Fixtures.load(File.join(FIXTURE_DIR, "testing_users.yml"), table: "testing_users")
    rows.map(&.label).should contain("alice")
  ensure
    Saci::Testing::Fixtures.reload!
  end
end

# ---------------------------------------------------------------------------
# Factories
# ---------------------------------------------------------------------------

describe "Saci::Testing::Factory" do
  transactional_tests

  it "builds unsaved records and creates persisted ones" do
    built = Saci::Testing::Factory.build(:testing_user)
    built.persisted?.should be_false
    created = Saci::Testing::Factory.create(:testing_user)
    created.persisted?.should be_true
    created.as(TestingUser).name.should eq("Alice")
  end

  it "generates typed helper methods" do
    user = Saci::Testing::Factory.create_testing_user(name: "Typed")
    user.should be_a(TestingUser)
    user.name.should eq("Typed")
  end

  it "increments sequences for lazy values" do
    first = Saci::Testing::Factory.create(:testing_user).as(TestingUser).email.not_nil!
    second = Saci::Testing::Factory.create(:testing_user).as(TestingUser).email.not_nil!
    first.should_not eq(second)
    first.should match(/\Auser\d+@example\.com\z/)
  end

  it "applies traits after base attributes" do
    Saci::Testing::Factory.create(:testing_user, :admin).as(TestingUser).admin.should be_true
    Saci::Testing::Factory.create(:testing_user).as(TestingUser).admin.should be_false
  end

  it "creates belongs_to associations and sets the foreign key" do
    user = Saci::Testing::Factory.create(:testing_user).as(TestingUser)
    user.team_id.should_not be_nil
    TestingTeam.find(user.team_id).name.should eq("The Team")

    built = Saci::Testing::Factory.build(:testing_user).as(TestingUser)
    built.team_id.should be_nil
  end

  it "creates has_many children after the owner is saved" do
    author = Saci::Testing::Factory.create(:testing_author).as(TestingUser)
    TestingPost.where(user_id: author.id).count.should eq(2)
  end

  it "attributes_for omits associations and does not persist" do
    attrs = Saci::Testing::Factory.attributes_for(:testing_user, name: "Override")
    attrs["name"].should eq("Override")
    attrs.has_key?("id").should be_false
    attrs.has_key?("team_id").should be_false
    TestingUser.where(name: "Override").count.should eq(0)
  end

  it "supports overrides and list helpers" do
    Saci::Testing::Factory.create(:testing_user, name: "Overridden").as(TestingUser).name.should eq("Overridden")
    Saci::Testing::Factory.build_list(:testing_user, 3).size.should eq(3)
    Saci::Testing::Factory.create_list(:testing_user, 2).size.should eq(2)
  end

  it "resets sequences" do
    Saci::Testing::Factory.reset_sequences!
    Saci::Testing::Factory.sequence(:spec_seq).should eq(1)
    Saci::Testing::Factory.sequence(:spec_seq).should eq(2)
  end
end

# ---------------------------------------------------------------------------
# Transactional tests
# ---------------------------------------------------------------------------

describe "Saci::Testing.transactional" do
  it "rolls back the block and returns its value" do
    before = TestingUser.count
    result = Saci::Testing.transactional do
      TestingUser.create!(name: "temporary")
      TestingUser.count
    end
    result.should eq(before + 1)
    TestingUser.count.should eq(before)
  end

  it "rolls back nested savepoints independently" do
    before = TestingUser.count
    Saci::Testing.transactional do
      TestingUser.create!(name: "outer")
      TestingUser.count.should eq(before + 1)

      Saci::Testing.transactional do
        TestingUser.create!(name: "inner")
        TestingUser.count.should eq(before + 2)
      end

      # Inner savepoint was rolled back; outer work remains.
      TestingUser.count.should eq(before + 1)
      TestingUser.where(name: "inner").count.should eq(0)
    end
    TestingUser.count.should eq(before)
  end

  it "reports the transaction state" do
    Saci::Testing.in_transaction?.should be_false
    Saci::Testing.transactional do
      Saci::Testing.in_transaction?.should be_true
    end
    Saci::Testing.in_transaction?.should be_false
  end

  it "defers and discards after_commit callbacks" do
    TestingUser.reset_commit_log!
    Saci::Testing.transactional do
      TestingUser.create!(name: "committed?")
      TestingUser.commit_log.should be_empty
      Saci::Testing.flush_after_commit!
      TestingUser.commit_log.should eq(["committed?"])
    end
    # Rollback happened; no extra callback.
    TestingUser.commit_log.should eq(["committed?"])
  end

  it "re-raises errors after rolling back" do
    before = TestingUser.count
    expect_raises(Exception, "boom") do
      Saci::Testing.transactional do
        TestingUser.create!(name: "doomed")
        raise "boom"
      end
    end
    TestingUser.count.should eq(before)
  end

  it "supports the clean_database! fallback" do
    TestingUser.create!(name: "dirty")
    Saci::Testing.clean_database!
    TestingUser.count.should eq(0)
    Saci::Testing::Fixtures.load(FIXTURE_DIR)
  end
end

# ---------------------------------------------------------------------------
# Time helpers
# ---------------------------------------------------------------------------

describe "Saci::Testing time helpers" do
  transactional_tests

  it "travels and restores time inside a block" do
    target = Time.utc(2020, 6, 15, 12, 0, 0)
    travel_to(target) do
      Time.current.should eq(target)
      Time.now.should eq(target)
      Time.utc.should eq(target)
      Time.local.to_unix.should eq(target.to_unix)
      Date.current.to_s.should eq("2020-06-15")
      Time.current.should eq(target)
    end
    (Time.current - target).should be > 1.day
  end

  it "travels by a duration" do
    travel_to(Time.utc(2020, 1, 1, 0, 0, 0)) do
      travel(2.hours) do
        Time.current.should eq(Time.utc(2020, 1, 1, 2, 0, 0))
      end
      Time.current.should eq(Time.utc(2020, 1, 1, 0, 0, 0))
    end
  end

  it "freezes the current time" do
    freeze_time do
      first = Time.current
      sleep 10.milliseconds
      Time.current.should eq(first)
    end
    freeze_time(Time.utc(1999, 12, 31, 23, 59, 59)) do
      Date.current.to_s.should eq("1999-12-31")
    end
  end

  it "travel_back restores real time" do
    travel_to(Time.utc(2001, 1, 1))
    Time.current.year.should eq(2001)
    travel_back
    Time.current.year.should_not eq(2001)
  end

  it "does not leak into spawned fibers" do
    target = Time.utc(2022, 2, 2, 2, 2, 2)
    travel_to(target) do
      channel = Channel(Time).new
      spawn { channel.send(Time.current) }
      channel.receive.should_not eq(target)
      Time.current.should eq(target)
    end
  end

  it "drives ORM timestamps" do
    target = Time.utc(2018, 3, 4, 5, 6, 7)
    travel_to(target) do
      user = TestingUser.create!(name: "Timed")
      user.created_at.not_nil!.to_unix.should eq(target.to_unix)
      user.updated_at.not_nil!.to_unix.should eq(target.to_unix)
    end
  end
end

# ---------------------------------------------------------------------------
# Assertion helpers
# ---------------------------------------------------------------------------

class TestingJob < Saci::Job::Base
  def perform(payload : JSON::Any) : Nil
  end
end

class TestingMailer < Saci::Mailer::Base
  default_from "tests@example.com"

  def self.welcome(to : String, subject : String = "Welcome") : Saci::Mailer::Mail
    mail(to: to, subject: subject) do |format|
      format.text { "Hello from Saci" }
    end
  end
end

describe "Saci::Testing assertion helpers" do
  transactional_tests

  it "asserts changes and no changes" do
    assert_changes(-> { TestingUser.count }) do
      TestingUser.create!(name: "changed")
    end
    before = TestingUser.count
    assert_changes(-> { TestingUser.count }, from: before, to: before + 1) do
      TestingUser.create!(name: "changed-again")
    end
    assert_no_changes(-> { TestingUser.count }) do
      # no writes
    end
  end

  it "asserts differences with an optional delta" do
    assert_difference(-> { TestingUser.count }, 2) do
      2.times { |i| TestingUser.create!(name: "diff#{i}") }
    end
    assert_no_difference(-> { TestingUser.count }) do
      # no writes
    end
  end

  it "counts SQL queries" do
    assert_queries(1) do
      TestingUser.create!(name: "query-counted")
    end
    assert_no_queries do
      1 + 1
    end
  end

  it "asserts mailer deliveries" do
    assert_emails(1) do
      TestingMailer.welcome("a@example.com").deliver_now
    end
    assert_no_emails do
      # nothing delivered
    end
  end

  it "asserts enqueued emails" do
    assert_enqueued_email_with(to: "later@example.com", subject: "Later") do
      TestingMailer.welcome("later@example.com", "Later").deliver_later
    end
  end

  it "asserts enqueued jobs" do
    assert_enqueued_jobs(1) do
      TestingJob.perform_later({value: 1})
    end
    assert_no_enqueued_jobs do
      # nothing enqueued
    end
    assert_enqueued_with(job: TestingJob, args: {value: 2}) do
      TestingJob.perform_later({value: 2})
    end
  end

  it "asserts performed jobs" do
    assert_performed_jobs(1) do
      TestingJob.perform_later({value: 3})
    end
    assert_no_performed_jobs do
      # nothing performed
    end
    assert_performed_with(job: TestingJob, args: {value: 5}) do
      TestingJob.perform_now({value: 5})
    end
  end

  it "asserts cable broadcasts" do
    Saci::Testing::Probes.clear_broadcasts!
    assert_broadcasts("room:1", 1) do
      Saci::Cable.broadcast("room:1", {text: "hi"})
    end
    assert_no_broadcasts("room:2") do
      Saci::Cable.broadcast("room:1", {text: "still room 1"})
    end
  end

  it "asserts active cable streams" do
    previous = Saci::Cable.server
    server = Saci::Cable::Server.new
    Saci::Cable.server = server
    begin
      socket = HTTP::WebSocket.new(IO::Memory.new)
      connection = Saci::Cable::Connection.new(socket, Saci::Params.new, server)
      channel = Saci::Cable::Channel.new(connection, "{}", {} of String => JSON::Any)
      server.add_stream(connection, "chat:1", "{}", channel)

      assert_has_stream "chat:1"
      server.stream_names.should eq(["chat:1"])
    ensure
      Saci::Cable.server = previous
    end
  end
end

# ---------------------------------------------------------------------------
# assert_select
# ---------------------------------------------------------------------------

class TestingPagesController < Saci::Controller
  def show
    render html: <<-HTML
      <!doctype html>
      <html>
        <body>
          <div id="main" class="page wide" data-role="root">
            <h1>Hello</h1>
            <p class="lead">Welcome <b>Alice</b></p>
            <ul>
              <li class="item">One</li>
              <li class="item">Two</li>
            </ul>
            <input type="text" name="q" disabled>
          </div>
        </body>
      </html>
      HTML
  end
end

def testing_pages_router : Saci::Router
  Saci::Router.new.draw do |r|
    r.get "/page", TestingPagesController, :show
  end
end

describe "Saci::Testing.assert_select" do
  it "matches tag/id/class selectors and counts" do
    Saci::TestSession.serve(testing_pages_router) do |app|
      response = app.get("/page")
      assert_select(response, "div#main.page", count: 1)
      assert_select(response, "div#main.page.wide", count: 1)
      assert_select(response, "li.item", count: 2)
      assert_select(response, "div#main li.item", count: 2)
    end
  end

  it "matches attribute selectors" do
    Saci::TestSession.serve(testing_pages_router) do |app|
      response = app.get("/page")
      assert_select(response, "div[data-role=root]", count: 1)
      assert_select(response, "input[type=text][name=q]", count: 1)
    end
  end

  it "matches text exactly and with regexes" do
    Saci::TestSession.serve(testing_pages_router) do |app|
      response = app.get("/page")
      assert_select(response, "p.lead", text: "Welcome Alice")
      assert_select(response, "h1", text: /Hell/)
      assert_select(response, "li.item", text: "Two")
    end
  end

  it "fails with a useful message when nothing matches" do
    Saci::TestSession.serve(testing_pages_router) do |app|
      response = app.get("/page")
      expect_raises(Spec::AssertionFailed, /div#missing/) do
        assert_select(response, "div#missing")
      end
      expect_raises(Spec::AssertionFailed, /expected 3/) do
        assert_select(response, "li.item", count: 3)
      end
    end
  end
end

# ---------------------------------------------------------------------------
# Parallel tests
# ---------------------------------------------------------------------------

describe "Saci::Testing.parallelize" do
  it "derives per-worker sqlite URLs" do
    Saci::Testing.worker_database_url("sqlite3://./db/app_test.db", 2).should eq("sqlite3://./db/app_test_2.db")
  end

  it "reads the SACI_TEST_WORKER convention" do
    previous = ENV["SACI_TEST_WORKER"]?
    begin
      ENV.delete("SACI_TEST_WORKER")
      Saci::Testing.worker_index.should eq(0)
      Saci::Testing.worker_env?.should be_false
      ENV["SACI_TEST_WORKER"] = "3"
      Saci::Testing.worker_index.should eq(3)
      Saci::Testing.worker_env?.should be_true
    ensure
      if previous
        ENV["SACI_TEST_WORKER"] = previous
      else
        ENV.delete("SACI_TEST_WORKER")
      end
    end
  end

  it "distributes spec files across worker shards" do
    files = ["a_spec.cr", "b_spec.cr", "c_spec.cr", "d_spec.cr", "e_spec.cr"]
    plan = Saci::Testing::ParallelPlan.new(2, "sqlite3://./db/app_test.db",
      ["sqlite3://./db/app_test_0.db", "sqlite3://./db/app_test_1.db"], files)
    plan.shards.should eq([["a_spec.cr", "c_spec.cr", "e_spec.cr"], ["b_spec.cr", "d_spec.cr"]])
    plan.commands.first.should contain("SACI_TEST_WORKER=0")
  end

  it "clones the base database for each worker" do
    plan = Saci::Testing.prepare_parallel_databases!(2, base_url: DB_URL, spec_files: ["a_spec.cr"])
    plan.workers.should eq(2)
    plan.database_urls.size.should eq(2)
    plan.database_urls.each do |url|
      path = Saci::Testing.sqlite_path_from_url(url).not_nil!
      File.exists?(path).should be_true
      db = DB.open(url)
      begin
        names = [] of String
        Saci::Record.query_compat(db, "SELECT name FROM schema_migrations") do |rs|
          rs.each { names << rs.read(String) }
        end
        names.should contain(CreateTestingUsers.name)
      ensure
        db.close
      end
    end
  end

  it "generates a bin/ci-friendly script" do
    plan = Saci::Testing::ParallelPlan.new(2, "sqlite3://./db/app_test.db",
      ["sqlite3://./db/app_test_0.db", "sqlite3://./db/app_test_1.db"], ["a_spec.cr", "b_spec.cr"])
    script = plan.ci_script
    script.should contain("#!/usr/bin/env bash")
    script.should contain("SACI_TEST_WORKER=0 crystal spec a_spec.cr")
    script.should contain("SACI_TEST_WORKER=1 crystal spec b_spec.cr")
    script.should contain("exit \"$status\"")
  end
end
