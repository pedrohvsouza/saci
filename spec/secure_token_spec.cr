require "spec"
require "../src/saci"

TOKEN_DB_PATH = "/tmp/opencode/saci_secure_token_test.db"

class TokenUser < Saci::Record::Base
  column id : Int64, primary: true
  column email : String
  column password_digest : String
  column token : String
  column api_token : String
  validates :email, presence: true

  has_secure_password
  has_secure_token
  has_secure_token :api_token
end

# Same table as TokenUser — for cross-model signed-id tests.
class TokenAdmin < Saci::Record::Base
  column id : Int64, primary: true
  column email : String
  column password_digest : String
  column token : String
  column api_token : String

  def self.table_name : String
    TokenUser.table_name
  end
end

URLSAFE_32 = /\A[A-Za-z0-9\-_]{32}\z/

describe "has_secure_token" do
  before_all do
    File.delete(TOKEN_DB_PATH) if File.exists?(TOKEN_DB_PATH)
    Saci::Record::Base.connection = DB.open("sqlite3://#{TOKEN_DB_PATH}")
    Saci::Record::Base.connection.as(DB::Database).exec(
      "CREATE TABLE \"#{TokenUser.table_name}\" (\"id\" INTEGER PRIMARY KEY AUTOINCREMENT, \"email\" TEXT, \"password_digest\" TEXT, \"token\" TEXT, \"api_token\" TEXT)"
    )
    Saci::Record.bcrypt_min_cost = true
  end

  after_all do
    Saci::Record.bcrypt_min_cost = false
    Saci::Record::Base.connection.as(DB::Database).close
  end

  before_each do
    Saci::Record.clean_database!
  end

  it "generates url-safe tokens on create (default + named)" do
    u = TokenUser.create!(email: "a@b.c", password: "secret123")
    u.token.not_nil!.should match(URLSAFE_32)
    u.api_token.not_nil!.should match(URLSAFE_32)
    u.token.should_not eq(u.api_token)
  end

  it "generates unique tokens across records" do
    a = TokenUser.create!(email: "a@b.c", password: "secret123")
    b = TokenUser.create!(email: "b@c.d", password: "secret123")
    a.token.should_not eq(b.token)
    a.api_token.should_not eq(b.api_token)
  end

  it "keeps an explicitly assigned token" do
    u = TokenUser.create!(email: "a@b.c", password: "secret123", token: "mine")
    u.token.should eq("mine")
    u.api_token.not_nil!.should match(URLSAFE_32)
  end

  it "never overwrites the token on update" do
    u = TokenUser.create!(email: "a@b.c", password: "secret123")
    before = u.token
    before_api = u.api_token
    u.update(email: "new@x.io").should be_true
    u.reload.token.should eq(before)
    u.reload.api_token.should eq(before_api)
  end

  it "regenerate_<attr>! changes the value and persists it" do
    u = TokenUser.create!(email: "a@b.c", password: "secret123")
    old_token = u.token
    old_api = u.api_token
    fresh = u.regenerate_api_token!
    fresh.should match(URLSAFE_32)
    fresh.should_not eq(old_api)
    u.api_token.should eq(fresh)
    u.reload.api_token.should eq(fresh)
    u.token.should eq(old_token)

    fresh_default = u.regenerate_token!
    fresh_default.should_not eq(old_token)
    u.reload.token.should eq(fresh_default)
  end

  it "validates uniqueness at the model level" do
    TokenUser.create!(email: "a@b.c", password: "secret123", token: "taken")
    dup = TokenUser.new(email: "b@c.d", password: "secret123", token: "taken")
    dup.save.should be_false
    dup.errors["token"].should contain("has already been taken")
  end
end

describe "signed_id" do
  before_all do
    unless Saci::Record.configuration_names.includes?("primary")
      Saci::Record::Base.connection = DB.open("sqlite3://#{TOKEN_DB_PATH}")
    end
  end

  before_each do
    Saci::Record.clean_database!
  end

  it "round-trips with purpose and expiry" do
    u = TokenUser.create!(email: "a@b.c", password: "secret123")
    sid = u.signed_id(purpose: "login", expires_in: 15.minutes)
    found = TokenUser.find_signed(sid, purpose: "login")
    found.not_nil!.id.should eq(u.id)
  end

  it "round-trips without purpose or expiry" do
    u = TokenUser.create!(email: "a@b.c", password: "secret123")
    TokenUser.find_signed(u.signed_id).not_nil!.id.should eq(u.id)
  end

  it "returns nil for wrong purpose" do
    u = TokenUser.create!(email: "a@b.c", password: "secret123")
    sid = u.signed_id(purpose: "login")
    TokenUser.find_signed(sid, purpose: "reset").should be_nil
    TokenUser.find_signed(sid).should be_nil
    TokenUser.find_signed(u.signed_id, purpose: "login").should be_nil
  end

  it "returns nil when expired" do
    u = TokenUser.create!(email: "a@b.c", password: "secret123")
    sid = u.signed_id(purpose: "login", expires_in: -60.seconds)
    TokenUser.find_signed(sid, purpose: "login").should be_nil
  end

  it "returns nil when tampered" do
    u = TokenUser.create!(email: "a@b.c", password: "secret123")
    sid = u.signed_id(purpose: "login")
    tampered = sid.sub(/.$/, sid[-1] == 'A' ? "B" : "A")
    tampered.should_not eq(sid)
    TokenUser.find_signed(tampered, purpose: "login").should be_nil
  end

  it "returns nil for garbage and missing rows" do
    TokenUser.find_signed("not-a-token").should be_nil
    TokenUser.find_signed("").should be_nil
    u = TokenUser.create!(email: "a@b.c", password: "secret123")
    sid = u.signed_id
    u.destroy
    TokenUser.find_signed(sid).should be_nil
  end

  it "returns nil for cross-model tokens" do
    u = TokenUser.create!(email: "a@b.c", password: "secret123")
    TokenAdmin.find_signed(u.signed_id).should be_nil
  end
end

describe "authenticate_by" do
  before_each do
    Saci::Record.clean_database!
  end

  it "returns the record on success" do
    u = TokenUser.create!(email: "a@b.c", password: "secret123")
    found = TokenUser.authenticate_by(email: "a@b.c", password: "secret123")
    found.not_nil!.id.should eq(u.id)
  end

  it "returns nil for wrong password and unknown login (no enumeration)" do
    TokenUser.create!(email: "a@b.c", password: "secret123")
    TokenUser.authenticate_by(email: "a@b.c", password: "wrong").should be_nil
    TokenUser.authenticate_by(email: "nobody@x.io", password: "secret123").should be_nil
  end

  it "raises on missing password, bare password, or unknown attributes" do
    TokenUser.create!(email: "a@b.c", password: "secret123")
    expect_raises(ArgumentError) { TokenUser.authenticate_by(email: "a@b.c") }
    expect_raises(ArgumentError) { TokenUser.authenticate_by(password: "secret123") }
    expect_raises(Saci::Record::UnknownAttributeError) do
      TokenUser.authenticate_by(nonsense: "x", password: "secret123")
    end
  end
end
