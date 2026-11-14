require "spec"
require "file"
require "../src/saci"

class CreateEncTables < Saci::Record::Migration
  def change
    create_table :enc_users do |t|
      t.string :name
      t.string :email
      t.string :ssn
      t.string :note
    end
  end
end

class EncUser < Saci::Record::Base
  column id : Int64, primary: true
  column name : String
  column email : String
  column ssn : String
  column note : String

  encrypts :ssn, :note
  encrypts :email, deterministic: true, downcase: true

  validates :email, uniqueness: true
end

ENC_DB_PATH = "/tmp/saci_record_encryption_test.db"

def enc_db : DB::Database
  Saci::Record::Base.connection.as(DB::Database)
end

# The value the database actually holds.
def enc_raw(id : Int64, col : String) : String?
  enc_db.query_one?("SELECT #{col} FROM enc_users WHERE id = ?", id, as: String?)
end

def enc_with_keys(primary : String?, deterministic : String?, previous = [] of String, &)
  old = {Saci::Record::Encryption.primary_key, Saci::Record::Encryption.deterministic_key, Saci::Record::Encryption.previous_keys}
  Saci::Record::Encryption.primary_key = primary
  Saci::Record::Encryption.deterministic_key = deterministic
  Saci::Record::Encryption.previous_keys = previous
  yield
ensure
  if o = old
    Saci::Record::Encryption.primary_key = o[0]
    Saci::Record::Encryption.deterministic_key = o[1]
    Saci::Record::Encryption.previous_keys = o[2]
  end
end

describe "Saci::Record encrypts" do
  before_all do
    ENV["SECRET_KEY_BASE"] = "spec-secret-" + "x" * 64
    File.delete(ENC_DB_PATH) if File.exists?(ENC_DB_PATH)
    Saci::Record::Base.connection = DB.open("sqlite3://#{ENC_DB_PATH}")
    Saci::Record::Migrator.migrate(enc_db, [CreateEncTables] of Saci::Record::Migration.class)
  end

  after_all do
    enc_db.close
    File.delete(ENC_DB_PATH) if File.exists?(ENC_DB_PATH)
  end

  before_each { EncUser.delete_all }

  it "stores ciphertext and loads plaintext" do
    user = EncUser.create!(name: "Ana", ssn: "123-45-6789", email: "ana@example.com")
    id = user.id.not_nil!
    raw = enc_raw(id, "ssn").not_nil!
    raw.should_not contain("123-45-6789")
    raw.split("--").size.should eq(3)
    enc_raw(id, "name").should eq("Ana")

    user.ssn.should eq("123-45-6789")
    found = EncUser.find(id)
    found.ssn.should eq("123-45-6789")
    found.changed?.should be_false
    EncUser.all.first.not_nil!.ssn.should eq("123-45-6789")
    EncUser.where(name: "Ana").pluck(:ssn).should eq(["123-45-6789"])
  end

  it "keeps nil as NULL" do
    user = EncUser.create!(name: "Nil")
    enc_raw(user.id.not_nil!, "ssn").should be_nil
    EncUser.find(user.id.not_nil!).ssn.should be_nil
  end

  it "uses a fresh IV per write for non-deterministic columns" do
    a = EncUser.create!(ssn: "same", email: "a@x.io")
    b = EncUser.create!(ssn: "same", email: "b@x.io")
    enc_raw(a.id.not_nil!, "ssn").should_not eq(enc_raw(b.id.not_nil!, "ssn"))
    EncUser.find_by(ssn: "same").should be_nil
  end

  it "queries deterministic columns, downcasing the stored value" do
    user = EncUser.create!(email: "Ana@Example.com")
    raw = enc_raw(user.id.not_nil!, "email").not_nil!
    raw.should_not contain("example")
    EncUser.find_by(email: "ana@example.com").not_nil!.id.should eq(user.id)
    EncUser.find_by(email: "ANA@EXAMPLE.COM").not_nil!.id.should eq(user.id)
    EncUser.where(email: "ana@example.com").count.should eq(1)
    EncUser.find(user.id.not_nil!).email.should eq("ana@example.com")
  end

  it "runs uniqueness validations against the ciphertext" do
    EncUser.create!(email: "dup@x.io")
    dup = EncUser.new(email: "DUP@x.io")
    dup.valid?.should be_false
    dup.errors["email"].should contain("has already been taken")
  end

  it "encrypts update_columns and updates" do
    user = EncUser.create!(ssn: "one")
    user.update!(ssn: "two")
    EncUser.find(user.id.not_nil!).ssn.should eq("two")
    user.update_columns(note: "secret note")
    enc_raw(user.id.not_nil!, "note").not_nil!.should_not contain("secret")
    EncUser.find(user.id.not_nil!).note.should eq("secret note")
  end

  it "raises on tampered or unencrypted data unless support_unencrypted_data" do
    user = EncUser.create!(ssn: "x")
    id = user.id.not_nil!
    enc_db.exec("UPDATE enc_users SET note = 'plain' WHERE id = ?", id)
    expect_raises(Saci::Record::Encryption::DecryptionError) { EncUser.find(id) }

    Saci::Record::Encryption.support_unencrypted_data = true
    begin
      EncUser.find(id).note.should eq("plain")
    ensure
      Saci::Record::Encryption.support_unencrypted_data = false
    end

    raw = enc_raw(id, "ssn").not_nil!
    parts = raw.split("--")
    parts[2] = Base64.strict_encode(Bytes.new(16))
    enc_db.exec("UPDATE enc_users SET ssn = ?, note = NULL WHERE id = ?", parts.join("--"), id)
    expect_raises(Saci::Record::Encryption::DecryptionError) { EncUser.find(id) }
  end

  it "decrypts with previous keys after rotation and re-encrypts on save" do
    id = 0_i64
    enc_with_keys("old-primary", "old-det") do
      id = EncUser.create!(ssn: "rotated", email: "r@x.io").id.not_nil!
    end
    old_raw = enc_raw(id, "ssn")
    enc_with_keys("new-primary", "new-det") do
      expect_raises(Saci::Record::Encryption::DecryptionError) { EncUser.find(id) }
    end
    enc_with_keys("new-primary", "new-det", ["old-primary", "old-det"]) do
      user = EncUser.find(id)
      user.ssn.should eq("rotated")
      user.ssn = "rotated!"
      user.save!
    end
    enc_raw(id, "ssn").should_not eq(old_raw)
    enc_with_keys("new-primary", "new-det") do
      EncUser.find(id).ssn.should eq("rotated!")
    end
  end
end
