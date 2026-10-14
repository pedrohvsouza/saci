require "spec"
require "http/client"
require "../src/saci"

SEC_DB_PATH = "/tmp/opencode/saci_security_test.db"

class SecUser < Saci::Record::Base
  column id : Int64, primary: true
  column email : String
  column password_digest : String
  validates :email, presence: true

  has_secure_password
end

class SecItemsController < Saci::Controller
  protect_from_forgery

  def show
    render json: {id: params["id"]? || "?"}
  end

  def create
    render json: {created: true}, status: :created
  end
end

class SecPagesController < Saci::Controller
  def index
    render html: "<h1>hi #{h(params["name"]? || "stranger")}</h1>"
  end

  def custom
    response.headers["X-Frame-Options"] = "DENY"
    render text: "custom"
  end
end

def security_router : Saci::Router
  Saci::Router.new.draw do |r|
    r.get "/items/:id", SecItemsController, :show
    r.post "/items", SecItemsController, :create
    r.get "/pages", SecPagesController, :index
    r.get "/custom", SecPagesController, :custom
  end
end

def extract_csrf_token(resp : HTTP::Client::Response) : String
  set_cookie = resp.headers["Set-Cookie"]? || raise "expected Set-Cookie header"
  pair = set_cookie.split(";").first
  pair.split("=", 2)[1]
end

describe "CSRF protection" do
  it "sets the csrf cookie on safe requests" do
    Saci::TestSession.serve(security_router) do |app|
      resp = app.get("/items/1")
      resp.status_code.should eq(200)
      token = extract_csrf_token(resp)
      token.size.should be > 20
      resp.headers.get("Set-Cookie").join(";").should contain("SameSite=Lax")
    end
  end

  it "rejects state-changing requests without a token" do
    Saci::TestSession.serve(security_router) do |app|
      resp = app.post("/items")
      resp.status_code.should eq(422)
      JSON.parse(resp.body)["error"].as_s.should contain("InvalidAuthenticityToken")
    end
  end

  it "rejects mismatched tokens" do
    Saci::TestSession.serve(security_router) do |app|
      token = extract_csrf_token(app.get("/items/1"))
      headers = HTTP::Headers{
        "Cookie"       => "saci_csrf=#{token}",
        "Content-Type" => "application/x-www-form-urlencoded",
      }
      resp = app.post("/items", headers, "authenticity_token=wrong-token")
      resp.status_code.should eq(422)
    end
  end

  it "accepts matching cookie + param tokens" do
    Saci::TestSession.serve(security_router) do |app|
      token = extract_csrf_token(app.get("/items/1"))
      headers = HTTP::Headers{
        "Cookie"       => "saci_csrf=#{token}",
        "Content-Type" => "application/x-www-form-urlencoded",
      }
      resp = app.post("/items", headers, "authenticity_token=#{token}")
      resp.status_code.should eq(201)
    end
  end

  it "accepts the X-CSRF-Token header instead of a param" do
    Saci::TestSession.serve(security_router) do |app|
      token = extract_csrf_token(app.get("/items/1"))
      headers = HTTP::Headers{
        "Cookie"       => "saci_csrf=#{token}",
        "X-CSRF-Token" => token,
      }
      resp = app.post("/items", headers)
      resp.status_code.should eq(201)
    end
  end

  it "compares tokens in constant time and rejects blanks" do
    Saci::CSRF.tokens_match?("abc", "abc").should be_true
    Saci::CSRF.tokens_match?("abc", "abd").should be_false
    Saci::CSRF.tokens_match?(nil, "abc").should be_false
    Saci::CSRF.tokens_match?("", "").should be_false
    Saci::CSRF.generate_token.should_not eq(Saci::CSRF.generate_token)
  end
end

describe "SecureHeaders" do
  it "applies safe defaults to controller responses" do
    Saci::TestSession.serve(security_router) do |app|
      resp = app.get("/items/1")
      resp.headers["X-Frame-Options"].should eq("SAMEORIGIN")
      resp.headers["X-Content-Type-Options"].should eq("nosniff")
      resp.headers["Referrer-Policy"].should eq("strict-origin-when-cross-origin")
    end
  end

  it "lets actions override defaults" do
    Saci::TestSession.serve(security_router) do |app|
      resp = app.get("/custom")
      resp.headers["X-Frame-Options"].should eq("DENY")
      resp.headers["X-Content-Type-Options"].should eq("nosniff")
    end
  end

  it "is configurable and resettable" do
    begin
      Saci::SecureHeaders.configure { |h| h["X-Frame-Options"] = "DENY" }
      Saci::SecureHeaders.headers["X-Frame-Options"].should eq("DENY")
    ensure
      Saci::SecureHeaders.reset!
    end
    Saci::SecureHeaders.headers["X-Frame-Options"].should eq("SAMEORIGIN")
  end
end

describe "HTML escaping" do
  it "escapes user input in html responses" do
    Saci::TestSession.serve(security_router) do |app|
      resp = app.get("/pages?name=<script>alert(1)</script>")
      resp.body.should contain("&lt;script&gt;")
      resp.body.should_not contain("<script>")
    end
  end
end

describe "has_secure_password" do
  before_all do
    File.delete(SEC_DB_PATH) if File.exists?(SEC_DB_PATH)
    Saci::Record::Base.connection = DB.open("sqlite3://#{SEC_DB_PATH}")
    Saci::Record::Base.connection.as(DB::Database).exec(
      "CREATE TABLE \"#{SecUser.table_name}\" (\"id\" INTEGER PRIMARY KEY AUTOINCREMENT, \"email\" TEXT, \"password_digest\" TEXT)"
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

  it "digests on assignment and authenticates" do
    u = SecUser.new(email: "a@b.c", password: "secret123")
    u.password_digest.not_nil!.should start_with("$2a$")
    u.save.should be_true
    u.authenticate("secret123").should eq(u)
    u.authenticate("wrong").should be_nil
  end

  it "requires a password on create" do
    u = SecUser.new(email: "a@b.c")
    u.save.should be_false
    u.errors["password"].should contain("can't be blank")
  end

  it "validates confirmation and bcrypt length" do
    u = SecUser.new(email: "a@b.c", password: "secret123", password_confirmation: "nope")
    u.save.should be_false
    u.errors["password_confirmation"].should contain("doesn't match Password")

    long = SecUser.new(email: "b@c.d", password: "x" * 73)
    long.save.should be_false
    long.errors["password"].any? { |m| m.includes?("72") }.should be_true
  end

  it "updates without re-entering the password" do
    u = SecUser.create!(email: "a@b.c", password: "secret123")
    u.update(email: "new@x.io").should be_true
    u.reload.email.should eq("new@x.io")
    u.authenticate("secret123").should_not be_nil
  end
end
