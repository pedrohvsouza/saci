require "spec"
require "http/client"
require "../src/saci"

AUTH_EXTRAS_DB_PATH = "/tmp/opencode/saci_auth_extras_test.db"

class AuthExtrasUser < Saci::Record::Base
  column id : Int64, primary: true
  column email : String
  column password_digest : String
  column reset_password_token : String
  column reset_password_token_expires_at : Time
  column otp_secret : String
  column two_factor_enabled : Bool, default: false

  validates :email, presence: true

  has_secure_password
  has_two_factor issuer: "Saci Test"

  generates_token_for :password_reset, expires_in: 15.minutes do |user|
    user.password_salt
  end

  generates_token_for :magic_login do |user|
    user.email
  end
end

# Exercises the `generates_password_reset_token` convenience macro.
class AuthExtrasConvenienceUser < Saci::Record::Base
  column id : Int64, primary: true
  column email : String
  column password_digest : String

  has_secure_password
  generates_password_reset_token

  def self.table_name : String
    AuthExtrasUser.table_name
  end
end

# Same table, deliberately no token generators: cross-model tokens must not
# verify.
class AuthExtrasAdmin < Saci::Record::Base
  column id : Int64, primary: true
  column email : String
  column password_digest : String
  column reset_password_token : String
  column reset_password_token_expires_at : Time
  column otp_secret : String
  column two_factor_enabled : Bool, default: false

  def self.table_name : String
    AuthExtrasUser.table_name
  end
end

class AuthExtrasProtectedController < Saci::Controller
  before_action :require_authentication

  def show
    render json: {protected: true}
  end
end

class AuthExtrasLoginController < Saci::Controller
  def login
    session[Saci::Auth.session_key] = 1_i64
    render json: {url: after_authentication_url}
  end
end

def jar_headers(jar : Hash(String, String)) : HTTP::Headers
  headers = HTTP::Headers.new
  headers["Cookie"] = jar.map { |k, v| "#{k}=#{v}" }.join("; ") unless jar.empty?
  headers
end

def auth_extras_router : Saci::Router
  Saci::Router.new.draw do |r|
    r.get "/protected", AuthExtrasProtectedController, :show
    r.get "/finish_login", AuthExtrasLoginController, :login
  end
end

describe "generates_token_for / password reset" do
  before_all do
    File.delete(AUTH_EXTRAS_DB_PATH) if File.exists?(AUTH_EXTRAS_DB_PATH)
    Saci::Record::Base.connection = DB.open("sqlite3://#{AUTH_EXTRAS_DB_PATH}")
    Saci::Record::Base.connection.as(DB::Database).exec(<<-SQL)
      CREATE TABLE "#{AuthExtrasUser.table_name}" (
        "id" INTEGER PRIMARY KEY AUTOINCREMENT,
        "email" TEXT,
        "password_digest" TEXT,
        "reset_password_token" TEXT,
        "reset_password_token_expires_at" TEXT,
        "otp_secret" TEXT,
        "two_factor_enabled" INTEGER DEFAULT 0
      )
      SQL
    Saci::Record.bcrypt_min_cost = true
  end

  after_all do
    Saci::Record.bcrypt_min_cost = false
    Saci::Record::Base.connection.as(DB::Database).close
  end

  before_each do
    Saci::Record.clean_database!
    Saci::Auth.reset!
  end

  it "generates and finds purpose-scoped tokens" do
    user = AuthExtrasUser.create!(email: "a@b.c", password: "secret123")
    token = user.generate_token_for(:password_reset)

    found = AuthExtrasUser.find_by_token_for(:password_reset, token)
    found.not_nil!.id.should eq(user.id)

    # Purpose separation, including the string form.
    AuthExtrasUser.find_by_token_for(:magic_login, token).should be_nil
    AuthExtrasUser.find_by_token_for("password_reset", token).not_nil!.id.should eq(user.id)

    # Cross-model token rejection.
    AuthExtrasAdmin.find_by_token_for(:password_reset, token).should be_nil
  end

  it "supports the generates_password_reset_token convenience macro" do
    user = AuthExtrasConvenienceUser.create!(email: "a@b.c", password: "secret123")
    token = user.generate_token_for(:password_reset)
    AuthExtrasConvenienceUser.find_by_token_for(:password_reset, token).not_nil!.id.should eq(user.id)
    user.reset_password("changed").should be_true
    AuthExtrasConvenienceUser.find_by_token_for(:password_reset, token).should be_nil
  end

  it "separates purposes declared on the same class" do
    user = AuthExtrasUser.create!(email: "a@b.c", password: "secret123")
    magic = user.generate_token_for(:magic_login)
    reset = user.generate_token_for(:password_reset)

    AuthExtrasUser.find_by_token_for(:magic_login, magic).not_nil!.id.should eq(user.id)
    AuthExtrasUser.find_by_token_for(:password_reset, magic).should be_nil
    AuthExtrasUser.find_by_token_for(:magic_login, reset).should be_nil
  end

  it "enforces expiry (and exposes an injectable clock for tests)" do
    user = AuthExtrasUser.create!(email: "a@b.c", password: "secret123")
    token = user.generate_token_for(:password_reset)
    now = Time.utc

    AuthExtrasUser.find_by_token_for(:password_reset, token, now + 14.minutes).not_nil!.id.should eq(user.id)
    AuthExtrasUser.find_by_token_for(:password_reset, token, now + 16.minutes).should be_nil
  end

  it "never expires tokens whose declaration has no expires_in" do
    user = AuthExtrasUser.create!(email: "a@b.c", password: "secret123")
    token = user.generate_token_for(:magic_login)
    AuthExtrasUser.find_by_token_for(:magic_login, token, Time.utc + 3650.days).not_nil!.id.should eq(user.id)
  end

  it "invalidates tokens when the block value rotates" do
    user = AuthExtrasUser.create!(email: "a@b.c", password: "secret123")
    reset = user.generate_token_for(:password_reset)
    magic = user.generate_token_for(:magic_login)

    user.password = "rotated-password"
    user.save!
    AuthExtrasUser.find_by_token_for(:password_reset, reset).should be_nil
    user.generate_token_for(:password_reset).should_not eq(reset)
    AuthExtrasUser.find_by_token_for(:password_reset, user.generate_token_for(:password_reset)).not_nil!.id.should eq(user.id)

    user.update(email: "new@b.c").should be_true
    AuthExtrasUser.find_by_token_for(:magic_login, magic).should be_nil
  end

  it "rejects tampered tokens, garbage and missing records" do
    user = AuthExtrasUser.create!(email: "a@b.c", password: "secret123")
    token = user.generate_token_for(:password_reset)
    tampered = token.sub(/.$/, token[-1] == 'A' ? "B" : "A")

    AuthExtrasUser.find_by_token_for(:password_reset, tampered).should be_nil
    AuthExtrasUser.find_by_token_for(:password_reset, "not-a-token").should be_nil
    AuthExtrasUser.find_by_token_for(:password_reset, "").should be_nil

    expect_raises(Saci::Record::RecordNotFound) do
      AuthExtrasUser.find_by_token_for!(:password_reset, tampered)
    end

    user.destroy
    AuthExtrasUser.find_by_token_for(:password_reset, token).should be_nil
  end

  it "raises for unpersisted records and unknown purposes" do
    expect_raises(Saci::Record::RecordNotSaved) do
      AuthExtrasUser.new(email: "x@y.z", password: "secret123").generate_token_for(:password_reset)
    end

    user = AuthExtrasUser.create!(email: "a@b.c", password: "secret123")
    expect_raises(ArgumentError) { user.generate_token_for(:nope) }
  end

  it "has_secure_password reset clears the password and stateful token" do
    user = AuthExtrasUser.create!(email: "a@b.c", password: "secret123")
    token = user.issue_password_reset_token!

    # The column stores a digest, never the plaintext token.
    user.reset_password_token.not_nil!.should_not eq(token)
    user.password_reset_token_valid?.should be_true
    user.password_reset_token_valid?(token).should be_true
    user.password_reset_token_valid?("wrong").should be_false
    AuthExtrasUser.find_by_reset_password_token(token).not_nil!.id.should eq(user.id)

    user.reset_password("brand-new", "brand-new").should be_true
    user.reload.authenticate("brand-new").not_nil!.id.should eq(user.id)
    user.reset_password_token.should be_nil
    user.reset_password_token_expires_at.should be_nil
    AuthExtrasUser.find_by_reset_password_token(token).should be_nil
  end

  it "reset_password fails on confirmation mismatch and expiry" do
    user = AuthExtrasUser.create!(email: "a@b.c", password: "secret123")
    user.reset_password("one", "two").should be_false
    user.reload.authenticate("secret123").not_nil!.id.should eq(user.id)

    fresh = AuthExtrasUser.find(user.id.not_nil!)
    expired = fresh.issue_password_reset_token!(-1.second)
    user.password_reset_token_valid?(expired).should be_false
    AuthExtrasUser.find_by_reset_password_token(expired).should be_nil
  end

  it "stateless reset tokens die after reset_password" do
    user = AuthExtrasUser.create!(email: "a@b.c", password: "secret123")
    token = user.generate_token_for(:password_reset)
    user.reset_password("brand-new").should be_true

    AuthExtrasUser.find_by_token_for(:password_reset, token).should be_nil
  end
end

describe "Saci::JWT" do
  it "round-trips HS256 payloads with custom headers" do
    now = Time.utc.to_unix
    token = Saci::JWT.encode(
      {"sub" => "42", "iss" => "saci", "iat" => now, "admin" => true, "n" => 7},
      "secret",
      headers: {"kid" => "k1"}
    )

    decoded = Saci::JWT.decode_with_header(token, "secret")
    decoded.header["alg"].as_s.should eq("HS256")
    decoded.header["kid"].as_s.should eq("k1")
    decoded.payload["sub"].as_s.should eq("42")
    decoded.payload["admin"].as_bool.should be_true
    decoded.payload["n"].as_i.should eq(7)

    Saci::JWT.decode(token, "secret").not_nil!["sub"].as_s.should eq("42")
  end

  it "matches the jwt.io HS256 example token" do
    payload = JSON.parse(%({"sub":"1234567890","name":"John Doe","iat":1516239022})).as_h
    expected = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9." \
               "eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ." \
               "SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
    Saci::JWT.encode(payload, "your-256-bit-secret").should eq(expected)
    Saci::JWT.decode(expected, "your-256-bit-secret").not_nil!["name"].as_s.should eq("John Doe")
  end

  it "supports HS384 and HS512" do
    [:hs384, :hs512].each do |algorithm|
      token = Saci::JWT.encode({"sub" => "1"}, "secret", algorithm: algorithm)
      Saci::JWT.decode(token, "secret", [algorithm]).not_nil!["sub"].as_s.should eq("1")
      Saci::JWT.decode(token, "secret").should be_nil
    end
  end

  it "rejects tampered tokens and wrong keys" do
    token = Saci::JWT.encode({"sub" => "1"}, "secret")
    Saci::JWT.decode(token, "other").should be_nil
    expect_raises(Saci::JWT::InvalidSignature) { Saci::JWT.decode!(token, "other") }

    tampered = token.sub(/.$/, token[-1] == 'A' ? "B" : "A")
    Saci::JWT.decode(tampered, "secret").should be_nil
    expect_raises(Saci::JWT::InvalidSignature) { Saci::JWT.decode!(tampered, "secret") }
  end

  it "rejects the none algorithm, including forged headers" do
    expect_raises(Saci::JWT::InvalidAlgorithm) do
      Saci::JWT.encode({"sub" => "1"}, "secret", algorithm: :none)
    end

    header = Saci::JWT.base64url_encode(%({"alg":"none","typ":"JWT"}).to_slice)
    payload = Saci::JWT.base64url_encode(%({"sub":"1"}).to_slice)
    forged = "#{header}.#{payload}.eA"
    Saci::JWT.decode(forged, "secret").should be_nil
    expect_raises(Saci::JWT::InvalidAlgorithm) { Saci::JWT.decode!(forged, "secret") }
  end

  it "validates exp, nbf and iat" do
    now = Time.utc.to_unix
    expired = Saci::JWT.encode({"sub" => "1", "exp" => now - 60}, "secret")
    Saci::JWT.decode(expired, "secret").should be_nil
    expect_raises(Saci::JWT::ExpiredSignature) { Saci::JWT.decode!(expired, "secret") }
    Saci::JWT.decode(expired, "secret", verify_exp: false).not_nil!["sub"].as_s.should eq("1")

    future = Saci::JWT.encode({"sub" => "1", "nbf" => now + 60}, "secret")
    Saci::JWT.decode(future, "secret").should be_nil
    expect_raises(Saci::JWT::NotYetValid) { Saci::JWT.decode!(future, "secret") }
    Saci::JWT.decode(future, "secret", verify_nbf: false).not_nil!["sub"].as_s.should eq("1")

    issued_in_future = Saci::JWT.encode({"sub" => "1", "iat" => now + 60}, "secret")
    Saci::JWT.decode(issued_in_future, "secret").should be_nil

    # leeway absorbs small clock skew.
    Saci::JWT.decode(expired, "secret", leeway: 2.minutes).not_nil!["sub"].as_s.should eq("1")
  end

  it "validates issuer, audience and subject" do
    token = Saci::JWT.encode(
      {"sub" => "42", "iss" => "saci", "aud" => ["mobile", "web"]},
      "secret"
    )

    Saci::JWT.decode(token, "secret", issuer: "saci", audience: "mobile", subject: "42").not_nil!
    Saci::JWT.decode(token, "secret", issuer: "evil").should be_nil
    Saci::JWT.decode(token, "secret", audience: "tv").should be_nil
    Saci::JWT.decode(token, "secret", subject: "43").should be_nil
    expect_raises(Saci::JWT::InvalidClaim) do
      Saci::JWT.decode!(token, "secret", issuer: "evil")
    end
  end

  it "rejects malformed tokens" do
    Saci::JWT.decode("", "secret").should be_nil
    Saci::JWT.decode("a.b", "secret").should be_nil
    Saci::JWT.decode("!!!.@@@.###", "secret").should be_nil
    expect_raises(Saci::JWT::MalformedToken) { Saci::JWT.decode!("a.b", "secret") }
  end
end

describe "Saci::TOTP" do
  # RFC 6238 Appendix B, SHA1, 8 digits: ASCII secret
  # "12345678901234567890" (base32 below).
  rfc_secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"

  it "matches the RFC 6238 SHA1 test vectors" do
    vectors = {
                  59_i64 => "94287082",
       1_111_111_109_i64 => "07081804",
       1_111_111_111_i64 => "14050471",
       1_234_567_890_i64 => "89005924",
       2_000_000_000_i64 => "69279037",
      20_000_000_000_i64 => "65353130",
    }
    vectors.each do |time, expected|
      Saci::TOTP.code(rfc_secret, time: Time.unix(time), digits: 8).should eq(expected)
    end
    # Default 6 digits (RFC vector truncated).
    Saci::TOTP.code(rfc_secret, time: Time.unix(59_i64)).should eq("287082")
  end

  it "verifies codes with a drift window" do
    now = Time.unix(1_234_567_890_i64)
    code = Saci::TOTP.code(rfc_secret, time: now, digits: 8)
    previous = Saci::TOTP.code(rfc_secret, time: now - 30.seconds, digits: 8)

    Saci::TOTP.verify(rfc_secret, code, time: now, digits: 8).should be_true
    Saci::TOTP.verify(rfc_secret, previous, time: now, digits: 8, drift: 1).should be_true
    Saci::TOTP.verify(rfc_secret, previous, time: now, digits: 8, drift: 0).should be_false
    Saci::TOTP.verify(rfc_secret, "00000000", time: now, digits: 8).should be_false
    Saci::TOTP.verify(rfc_secret, "not-a-code", time: now, digits: 8).should be_false
  end

  it "round-trips base32 secrets (including padding and grouping)" do
    secret = Saci::TOTP.random_secret
    decoded = Saci::TOTP.base32_decode(secret)
    decoded.size.should eq(20)
    Saci::TOTP.base32_encode(decoded).should eq(secret)

    grouped = secret.scan(/.{1,4}/).join(" ")
    Saci::TOTP.base32_decode(grouped).should eq(decoded)
    Saci::TOTP.base32_decode(secret + "====").should eq(decoded)
    expect_raises(ArgumentError) { Saci::TOTP.base32_decode("not-base32!") }
  end

  it "builds standard provisioning URIs" do
    Saci::TOTP.provisioning_uri(
      "JBSWY3DPEHPK3PXP",
      issuer: "ACME Co",
      account: "alice@example.com"
    ).should eq(
      "otpauth://totp/ACME%20Co:alice%40example.com?secret=JBSWY3DPEHPK3PXP" \
      "&issuer=ACME%20Co&algorithm=SHA1&digits=6&period=30"
    )

    Saci::TOTP.provisioning_uri("JBSWY3DPEHPK3PXP", account: "alice@example.com")
      .should eq("otpauth://totp/alice%40example.com?secret=JBSWY3DPEHPK3PXP&algorithm=SHA1&digits=6&period=30")
  end

  it "generates and verifies backup codes without ambiguous characters" do
    codes = Saci::TOTP.generate_backup_codes(count: 8, length: 10)
    codes.size.should eq(8)
    codes.each do |code|
      code.size.should eq(10)
      code.should match(/\A[A-HJ-NP-Z2-9]+\z/)
    end
    codes.uniq.size.should eq(8)

    Saci::TOTP.verify_backup_code(codes[0], codes).should be_true
    Saci::TOTP.verify_backup_code(codes[0].downcase, codes).should be_true
    Saci::TOTP.verify_backup_code("WRONGCODE1", codes).should be_false

    digest = Saci::TOTP.backup_code_digest(codes[0])
    Saci::TOTP.verify_backup_code_digest(codes[0], digest).should be_true
    Saci::TOTP.verify_backup_code_digest(codes[1], digest).should be_false
  end
end

describe "two-factor model helpers" do
  before_each do
    Saci::Record.clean_database!
  end

  it "generates, enables, verifies and disables TOTP" do
    user = AuthExtrasUser.create!(email: "a@b.c", password: "secret123")
    user.two_factor_enabled?.should be_false

    secret = user.enable_two_factor!
    user.reload.two_factor_enabled?.should be_true
    user.two_factor_secret.should eq(secret)
    user.verify_two_factor_code(Saci::TOTP.code(secret)).should be_true
    user.verify_two_factor_code("000000").should be_false

    uri = user.two_factor_provisioning_uri("a@b.c")
    uri.should start_with("otpauth://totp/Saci%20Test:a%40b.c?secret=#{secret}")

    user.disable_two_factor!.should be_true
    user.reload.two_factor_enabled?.should be_false
    user.two_factor_secret.should be_nil
  end
end

describe "Saci::Authentication helpers" do
  before_each do
    Saci::Record.clean_database!
    Saci::Auth.reset!
  end

  it "exposes session key names and credential lookup" do
    Saci::Authentication.session_key.should eq(:user_id)
    Saci::Authentication.redirect_key.should eq(:redirect_to)
    Saci::Authentication.token_key.should eq(:session_token)
    Saci::Authentication.login_path.should eq("/login")
    Saci::Authentication.after_authentication_path.should eq("/")

    user = AuthExtrasUser.create!(email: "a@b.c", password: "secret123")
    Saci::Authentication.authenticate_by(AuthExtrasUser, email: "a@b.c", password: "secret123")
      .not_nil!.id.should eq(user.id)
    Saci::Authentication.find_by_credentials(AuthExtrasUser, email: "a@b.c", password: "wrong")
      .should be_nil
  end

  it "require_authentication redirects and after_authentication_url consumes the target" do
    Saci::TestSession.serve(auth_extras_router) do |app|
      resp = app.get("/protected")
      resp.status_code.should eq(302)
      resp.headers["Location"].should eq("/login")

      jar = {} of String => String
      resp.headers.get("Set-Cookie").each do |line|
        key, _, value = line.split(";").first.partition("=")
        jar[key] = value
      end

      finish = app.get("/finish_login", jar_headers(jar))
      JSON.parse(finish.body)["url"].as_s.should eq("/protected")
      finish.headers.get("Set-Cookie").each do |line|
        key, _, value = line.split(";").first.partition("=")
        jar[key] = value
      end

      again = app.get("/finish_login", jar_headers(jar))
      JSON.parse(again.body)["url"].as_s.should eq("/")
    end
  end
end
