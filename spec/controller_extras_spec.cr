require "spec"
require "http/client"
require "base64"
require "file_utils"
require "../src/saci"

class SpecExtrasBoomError < Exception
end

module SpecExtrasEvents
  private def extras_event(name : String) : Nil
    response.headers["X-Events"] = (response.headers["X-Events"]? || "") + name + ";"
  end
end

class SpecExtrasAroundController < Saci::Controller
  include SpecExtrasEvents

  before_action :extras_before
  around_action :extras_outer
  around_action :extras_inner
  after_action :extras_after

  rescue_from SpecExtrasBoomError do
    extras_event("rescue")
    render json: {error: "boom"}, status: :bad_gateway
  end

  def index
    extras_event("action")
    render json: {ok: true}
  end

  def boom
    extras_event("action")
    raise SpecExtrasBoomError.new("boom")
  end

  private def extras_before
    extras_event("before")
  end

  private def extras_after
    extras_event("after")
  end

  private def extras_outer(&)
    extras_event("outer-pre")
    yield
  ensure
    extras_event("outer-post")
  end

  private def extras_inner(&)
    extras_event("inner-pre")
    yield
  ensure
    extras_event("inner-post")
  end
end

class SpecExtrasAroundChildController < SpecExtrasAroundController
  skip_around_action :extras_outer
end

class SpecExtrasAroundBlockController < Saci::Controller
  include SpecExtrasEvents

  around_action only: [:index] do |action|
    extras_event("block-pre")
    action.call
    extras_event("block-post")
  end

  around_action only: [:boom] do |action|
    begin
      action.call
    ensure
      response.headers["X-Block-Ensure"] = "1"
    end
  end

  def index
    extras_event("action")
    render json: {ok: true}
  end

  def boom
    extras_event("action")
    raise SpecExtrasBoomError.new("block boom")
  end

  def other
    render json: {ok: true}
  end
end

class SpecExtrasFalseHaltController < Saci::Controller
  include SpecExtrasEvents

  before_action :first_returns_false
  before_action :second_must_not_run

  def index
    extras_event("action")
    render json: {ok: true}
  end

  private def first_returns_false : Bool
    extras_event("first")
    false
  end

  private def second_must_not_run
    extras_event("second")
  end
end

class SpecExtrasBeforeBlockController < Saci::Controller
  before_action only: [:index] do
    response.headers["X-Before-Block"] = "1"
  end

  def index
    render json: {ok: true}
  end

  def other
    render json: {ok: true}
  end
end

class SpecExtrasPrependParentController < Saci::Controller
  include SpecExtrasEvents

  before_action :prepend_parent_before
  after_action :prepend_parent_after
  around_action :prepend_parent_around

  def index
    extras_event("action")
    render json: {ok: true}
  end

  private def prepend_parent_before
    extras_event("parent-before")
  end

  private def prepend_parent_after
    extras_event("parent-after")
  end

  private def prepend_parent_around(&)
    extras_event("parent-around-pre")
    yield
  ensure
    extras_event("parent-around-post")
  end
end

class SpecExtrasPrependChildController < SpecExtrasPrependParentController
  prepend_before_action :prepend_child_before
  prepend_after_action :prepend_child_after
  prepend_around_action :prepend_child_around
  before_action :prepend_child_normal

  private def prepend_child_before
    extras_event("child-prepend-before")
  end

  private def prepend_child_after
    extras_event("child-prepend-after")
  end

  private def prepend_child_normal
    extras_event("child-before")
  end

  private def prepend_child_around(&)
    extras_event("child-around-pre")
    yield
  ensure
    extras_event("child-around-post")
  end
end

class SpecExtrasRedirectController < Saci::Controller
  rescue_from Saci::Controller::UnsafeRedirectError do
    render plain: "blocked", status: :bad_request
  end

  def back
    redirect_back(fallback_location: "/fallback")
  end

  def back_see_other
    redirect_back(fallback_location: "/fallback", status: :see_other)
  end

  def unsafe
    redirect_to "https://evil.example/phish"
  end

  def allow
    redirect_to "https://evil.example/ok", allow_other_host: true
  end

  def same_host
    redirect_to "http://#{request.host_with_port}/target"
  end

  def relative
    redirect_to "/target", status: :see_other
  end

  def legacy
    redirect_to "https://evil.example/legacy"
  end

  def protocol_relative
    redirect_to "//evil.example/x"
  end
end

class SpecExtrasAuthController < Saci::Controller
  @basic_user : String? = nil
  @token_value : String? = nil

  before_action :require_basic, only: [:basic]
  before_action :require_token, only: [:token]

  def basic
    render json: {user: @basic_user}
  end

  def token
    render json: {token: @token_value}
  end

  def optional_basic
    ok = authenticate_with_http_basic { |user, password| user == "admin" && password == "secret" }
    render json: {ok: ok}
  end

  def optional_token
    ok = authenticate_with_http_token { |value, _options| value == "abc" }
    render json: {ok: ok}
  end

  private def require_basic
    authenticate_or_request_with_http_basic("Extras") do |user, password|
      if user == "admin" && password == "secret"
        @basic_user = user
        true
      else
        false
      end
    end
  end

  private def require_token
    authenticate_or_request_with_http_token("Extras") do |value, _options|
      @token_value = value
      value == "abc"
    end
  end
end

class SpecExtrasBasicMacroController < Saci::Controller
  http_basic_authenticate_with name: "admin", password: "secret", realm: "Macro"

  def index
    render json: {ok: true}
  end
end

# A credential that may be missing (`Saci::Credentials.dig` is `String?`).
SPEC_EXTRAS_MISSING_PASSWORD = ENV["SACI_SPEC_SURELY_UNSET_PASSWORD"]?

class SpecExtrasBasicNilableController < Saci::Controller
  http_basic_authenticate_with name: "admin", password: SPEC_EXTRAS_MISSING_PASSWORD

  def index
    render json: {ok: true}
  end
end

class SpecExtrasBasicCredentialsController < Saci::Controller
  http_basic_authenticate_with credentials: "moderation", realm: "Moderation"

  def index
    render json: {ok: true}
  end
end

class SpecExtrasRenderController < Saci::Controller
  rescue_from Saci::Controller::UnsafeFilePath do
    render plain: "unsafe", status: :bad_request
  end

  def body
    render body: "raw-body", content_type: "text/csv", status: 202
  end

  def file
    render file: "spec/support/renderable.txt"
  end

  def traversal
    render file: "../../etc/passwd"
  end

  def template
    render template: "spec_status/oops", layout: false, status: 203
  end

  def action
    render action: "spec_status/oops", layout: false
  end

  def partial
    render partial: "spec_parts/greet", name: "Ada"
  end

  def partial_locals
    render partial: "spec_parts/greet", locals: {name: "Bob"}
  end

  def to_string
    render plain: render_to_string(json: {a: 1})
  end

  def to_string_template
    render plain: render_to_string(template: "spec_status/oops", layout: false)
  end

  def to_string_partial
    render plain: render_to_string(partial: "spec_parts/greet", name: "Zoe")
  end

  def location
    render json: {id: 1}, status: :created, location: "/things/1", content_type: "application/vnd.api+json"
  end

  def no_content
    head :no_content
  end
end

class SpecExtrasParamsController < Saci::Controller
  wrap_parameters format: :json, include: [:name, :email, :role], exclude: [:role], name: :user

  def create
    user = params.expect(user: [:name, :email])
    render json: {
      name:    user.as_h["name"].as_s,
      email:   user.as_h["email"].as_s,
      wrapped: params["user"]?,
      top:     params["name"]?,
    }
  end

  def create_form
    render json: {wrapped: params["user"]?}
  end

  def scalar
    render json: {id: params.expect(:id).as_s}
  end

  def array
    tags = params.expect(tags: [] of Symbol)
    render json: {tags: tags.as_a.map(&.as_s)}
  end

  def rows
    rows = params.expect(rows: [[:name, :email]])
    render json: {names: rows.as_a.map { |row| row.as_h["name"].as_s }}
  end

  def nested
    user = params.expect(user: {address: [:street]})
    render json: {street: user.as_h["address"].as_h["street"].as_s}
  end

  def bang
    params.expect!(user: [:name, :email])
    render json: {ok: true}
  end

  def missing
    params.expect(user: [:name, :email])
    render json: {ok: true}
  end

  def require_permit
    story = params.require(:story).permit(:title, tags: [] of String)
    render json: {title: story["title"].as_s}
  end
end

class SpecExtrasUsersController < Saci::Controller
  wrap_parameters format: :json

  def create
    render json: {wrapped: params["spec_extras_user"]?}
  end
end

class SpecExtrasRateController < Saci::Controller
  rate_limit to: 2, within: 1.minute, only: [:limited],
    by: ->(req : HTTP::Request) { req.headers["X-Client"]? || "anon" }

  rate_limit to: 1, within: 1.minute, only: [:custom], name: :custom,
    with: -> { response.headers["X-Custom-Limit"] = "1"; head :too_many_requests }

  def limited
    render json: {ok: true}
  end

  def custom
    render json: {ok: true}
  end

  def open
    render json: {ok: true}
  end
end

class SpecExtrasRateSkipController < SpecExtrasRateController
  skip_rate_limit
end

class SpecExtrasRequestController < Saci::Controller
  def info
    render json: {
      host:           request.host,
      host_with_port: request.host_with_port,
      port:           request.port,
      domain:         request.domain,
      subdomain:      request.subdomain,
      ssl:            request.ssl?,
      full_url:       full_url_for("/x?y=1"),
    }
  end
end

class SpecExtrasRequestOverrideController < Saci::Controller
  def default_url_options : Hash(String, String)
    {"protocol" => "https", "host" => "cdn.example.com"}
  end

  def info
    render json: {full_url: full_url_for("path")}
  end
end

class SpecExtrasBrowserController < Saci::Controller
  allow_browser versions: :modern, only: [:modern]
  allow_browser allow: ["Friendly"], only: [:allowlist]
  allow_browser block: ["BadBot"], only: [:blocklist]

  def modern
    render json: {ok: true}
  end

  def allowlist
    render json: {ok: true}
  end

  def blocklist
    render json: {ok: true}
  end

  def open
    render json: {ok: true}
  end
end

class SpecExtrasRescueWithController < Saci::Controller
  rescue_from SpecExtrasBoomError, with: :handle_boom

  def boom
    raise SpecExtrasBoomError.new("with-handler")
  end

  private def handle_boom(ex : SpecExtrasBoomError)
    render json: {handled: ex.message}, status: :bad_gateway
  end
end

class SpecExtrasResponsesController < Saci::Controller
  rescue_responses({"SpecExtrasBoomError" => :bad_gateway})

  def index
    render json: {ok: true}
  end
end

def spec_extras_router : Saci::Router
  Saci::Router.new.draw do |r|
    r.get "/around", SpecExtrasAroundController, :index
    r.get "/around/boom", SpecExtrasAroundController, :boom
    r.get "/around-child", SpecExtrasAroundChildController, :index
    r.get "/around-block", SpecExtrasAroundBlockController, :index
    r.get "/around-block/boom", SpecExtrasAroundBlockController, :boom
    r.get "/around-block/other", SpecExtrasAroundBlockController, :other
    r.get "/prepend", SpecExtrasPrependChildController, :index
    r.get "/false-halt", SpecExtrasFalseHaltController, :index
    r.get "/before-block", SpecExtrasBeforeBlockController, :index
    r.get "/before-block/other", SpecExtrasBeforeBlockController, :other

    r.get "/redirect/back", SpecExtrasRedirectController, :back
    r.get "/redirect/back-303", SpecExtrasRedirectController, :back_see_other
    r.get "/redirect/unsafe", SpecExtrasRedirectController, :unsafe
    r.get "/redirect/allow", SpecExtrasRedirectController, :allow
    r.get "/redirect/same-host", SpecExtrasRedirectController, :same_host
    r.get "/redirect/relative", SpecExtrasRedirectController, :relative
    r.get "/redirect/legacy", SpecExtrasRedirectController, :legacy
    r.get "/redirect/protocol-relative", SpecExtrasRedirectController, :protocol_relative

    r.get "/auth/basic", SpecExtrasAuthController, :basic
    r.get "/auth/token", SpecExtrasAuthController, :token
    r.get "/auth/optional-basic", SpecExtrasAuthController, :optional_basic
    r.get "/auth/optional-token", SpecExtrasAuthController, :optional_token
    r.get "/auth/basic-macro", SpecExtrasBasicMacroController, :index
    r.get "/auth/basic-nilable", SpecExtrasBasicNilableController, :index
    r.get "/auth/basic-credentials", SpecExtrasBasicCredentialsController, :index

    r.get "/render/body", SpecExtrasRenderController, :body
    r.get "/render/file", SpecExtrasRenderController, :file
    r.get "/render/traversal", SpecExtrasRenderController, :traversal
    r.get "/render/template", SpecExtrasRenderController, :template
    r.get "/render/action", SpecExtrasRenderController, :action
    r.get "/render/partial", SpecExtrasRenderController, :partial
    r.get "/render/partial-locals", SpecExtrasRenderController, :partial_locals
    r.get "/render/to-string", SpecExtrasRenderController, :to_string
    r.get "/render/to-string-template", SpecExtrasRenderController, :to_string_template
    r.get "/render/to-string-partial", SpecExtrasRenderController, :to_string_partial
    r.get "/render/location", SpecExtrasRenderController, :location
    r.get "/render/no-content", SpecExtrasRenderController, :no_content

    r.post "/params/users", SpecExtrasParamsController, :create
    r.post "/params/users-form", SpecExtrasParamsController, :create_form
    r.get "/params/scalar", SpecExtrasParamsController, :scalar
    r.get "/params/array", SpecExtrasParamsController, :array
    r.post "/params/rows", SpecExtrasParamsController, :rows
    r.post "/params/nested", SpecExtrasParamsController, :nested
    r.post "/params/bang", SpecExtrasParamsController, :bang
    r.get "/params/missing", SpecExtrasParamsController, :missing
    r.post "/params/require-permit", SpecExtrasParamsController, :require_permit
    r.post "/params/inferred", SpecExtrasUsersController, :create

    r.get "/rate/limited", SpecExtrasRateController, :limited
    r.get "/rate/custom", SpecExtrasRateController, :custom
    r.get "/rate/open", SpecExtrasRateController, :open
    r.get "/rate-skip/limited", SpecExtrasRateSkipController, :limited

    r.get "/request/info", SpecExtrasRequestController, :info
    r.get "/request/override", SpecExtrasRequestOverrideController, :info

    r.get "/browser/modern", SpecExtrasBrowserController, :modern
    r.get "/browser/allowlist", SpecExtrasBrowserController, :allowlist
    r.get "/browser/blocklist", SpecExtrasBrowserController, :blocklist
    r.get "/browser/open", SpecExtrasBrowserController, :open

    r.get "/rescue-with/boom", SpecExtrasRescueWithController, :boom
    r.get "/responses", SpecExtrasResponsesController, :index
  end
end

def json_headers : HTTP::Headers
  HTTP::Headers{"Content-Type" => "application/json"}
end

def basic_auth(user : String, password : String) : HTTP::Headers
  HTTP::Headers{"Authorization" => "Basic #{Base64.strict_encode("#{user}:#{password}")}"}
end

def events(resp : HTTP::Client::Response) : String
  resp.headers["X-Events"]? || ""
end

describe "controller extras (integration)" do
  session = nil
  before_all do
    session = Saci::TestSession.new(spec_extras_router)
  end
  after_all do
    session.try(&.close)
  end

  it "runs before → around pre → action → around post → after" do
    resp = session.not_nil!.get("/around")
    resp.status_code.should eq(200)
    events(resp).should eq("before;outer-pre;inner-pre;action;inner-post;outer-post;after;")
  end

  it "runs around ensure blocks when the action raises" do
    resp = session.not_nil!.get("/around/boom")
    resp.status_code.should eq(502)
    events(resp).should eq("before;outer-pre;inner-pre;action;inner-post;outer-post;rescue;after;")
  end

  it "supports skip_around_action on child controllers" do
    resp = session.not_nil!.get("/around-child")
    resp.status_code.should eq(200)
    events(resp).should eq("before;inner-pre;action;inner-post;after;")
  end

  it "supports around_action blocks with only:" do
    resp = session.not_nil!.get("/around-block")
    resp.status_code.should eq(200)
    events(resp).should eq("block-pre;action;block-post;")

    resp = session.not_nil!.get("/around-block/other")
    resp.status_code.should eq(200)
    events(resp).should eq("")
  end

  it "runs block around ensure on action exceptions" do
    resp = session.not_nil!.get("/around-block/boom")
    resp.status_code.should eq(500)
    resp.headers["X-Block-Ensure"]?.should eq("1")
  end

  it "halts the before chain when a filter returns false" do
    resp = session.not_nil!.get("/false-halt")
    resp.status_code.should eq(500)
    events(resp).should eq("first;")
  end

  it "supports before_action blocks with only:" do
    resp = session.not_nil!.get("/before-block")
    resp.status_code.should eq(200)
    resp.headers["X-Before-Block"]?.should eq("1")

    resp = session.not_nil!.get("/before-block/other")
    resp.headers["X-Before-Block"]?.should be_nil
  end

  it "orders prepend_* filters before inherited filters" do
    resp = session.not_nil!.get("/prepend")
    resp.status_code.should eq(200)
    events(resp).should eq(
      "child-prepend-before;parent-before;child-before;" \
      "child-around-pre;parent-around-pre;action;parent-around-post;child-around-post;" \
      "child-prepend-after;parent-after;"
    )
  end

  it "redirects back to a same-host referer and falls back otherwise" do
    host = "127.0.0.1:#{session.not_nil!.port}"
    resp = session.not_nil!.get("/redirect/back", HTTP::Headers{"Referer" => "http://#{host}/from"})
    resp.status_code.should eq(302)
    resp.headers["Location"].should eq("http://#{host}/from")

    resp = session.not_nil!.get("/redirect/back")
    resp.status_code.should eq(302)
    resp.headers["Location"].should eq("/fallback")

    resp = session.not_nil!.get("/redirect/back", HTTP::Headers{"Referer" => "https://evil.example/from"})
    resp.headers["Location"].should eq("/fallback")

    resp = session.not_nil!.get("/redirect/back-303")
    resp.status_code.should eq(303)
    resp.headers["Location"].should eq("/fallback")
  end

  it "blocks cross-host redirects and allows the escape hatches" do
    resp = session.not_nil!.get("/redirect/unsafe")
    resp.status_code.should eq(400)
    resp.body.should eq("blocked")

    resp = session.not_nil!.get("/redirect/protocol-relative")
    resp.status_code.should eq(400)

    resp = session.not_nil!.get("/redirect/allow")
    resp.status_code.should eq(302)
    resp.headers["Location"].should eq("https://evil.example/ok")

    resp = session.not_nil!.get("/redirect/relative")
    resp.status_code.should eq(303)
    resp.headers["Location"].should eq("/target")

    resp = session.not_nil!.get("/redirect/same-host")
    resp.status_code.should eq(302)
    resp.headers["Location"].should eq("http://127.0.0.1:#{session.not_nil!.port}/target")
  end

  it "supports disabling open-redirect protection globally (legacy mode)" do
    begin
      Saci.raise_on_open_redirects = false
      resp = session.not_nil!.get("/redirect/legacy")
      resp.status_code.should eq(302)
      resp.headers["Location"].should eq("https://evil.example/legacy")
    ensure
      Saci.raise_on_open_redirects = true
    end
  end

  it "authenticates with HTTP basic credentials" do
    resp = session.not_nil!.get("/auth/basic")
    resp.status_code.should eq(401)
    resp.headers["WWW-Authenticate"].should contain("Basic realm=\"Extras\"")
    resp.body.should contain("Access denied")

    resp = session.not_nil!.get("/auth/basic", basic_auth("admin", "secret"))
    resp.status_code.should eq(200)
    JSON.parse(resp.body)["user"].should eq("admin")

    resp = session.not_nil!.get("/auth/basic", basic_auth("admin", "nope"))
    resp.status_code.should eq(401)

    resp = session.not_nil!.get("/auth/optional-basic")
    JSON.parse(resp.body)["ok"].should be_false
    resp = session.not_nil!.get("/auth/optional-basic", basic_auth("admin", "secret"))
    JSON.parse(resp.body)["ok"].should be_true
  end

  it "authenticates with HTTP token credentials" do
    resp = session.not_nil!.get("/auth/token", HTTP::Headers{"Authorization" => %(Token token="abc", nonce="1")})
    resp.status_code.should eq(200)
    JSON.parse(resp.body)["token"].should eq("abc")

    resp = session.not_nil!.get("/auth/token", HTTP::Headers{"Authorization" => "Bearer abc"})
    resp.status_code.should eq(200)

    resp = session.not_nil!.get("/auth/token")
    resp.status_code.should eq(401)
    resp.headers["WWW-Authenticate"].should contain("Token realm=\"Extras\"")

    resp = session.not_nil!.get("/auth/optional-token", HTTP::Headers{"Authorization" => "Bearer abc"})
    JSON.parse(resp.body)["ok"].should be_true
  end

  it "supports http_basic_authenticate_with" do
    resp = session.not_nil!.get("/auth/basic-macro")
    resp.status_code.should eq(401)
    resp.headers["WWW-Authenticate"].should contain("Basic realm=\"Macro\"")

    resp = session.not_nil!.get("/auth/basic-macro", basic_auth("admin", "secret"))
    resp.status_code.should eq(200)
  end

  it "fails closed when http_basic_authenticate_with gets a nil password" do
    session.not_nil!.get("/auth/basic-nilable").status_code.should eq(401)
    session.not_nil!.get("/auth/basic-nilable", basic_auth("admin", "")).status_code.should eq(401)
  end

  it "reads http_basic_authenticate_with credentials: from encrypted credentials" do
    dir = "/tmp/opencode/saci-basic-creds-#{Random.rand(1_000_000)}"
    Dir.mkdir_p(dir)
    old_file = Saci::Credentials.file_path
    old_key = Saci::Credentials.key_path
    begin
      Saci::Credentials.file_path = File.join(dir, "credentials.yml.enc")
      Saci::Credentials.key_path = File.join(dir, "master.key")
      # No master key and no file yet: everyone is denied.
      session.not_nil!.get("/auth/basic-credentials", basic_auth("mod", "pw")).status_code.should eq(401)

      File.write(Saci::Credentials.key_path, Saci::Credentials.generate_key)
      moderation = {YAML::Any.new("user") => YAML::Any.new("mod"), YAML::Any.new("password") => YAML::Any.new("pw")}
      Saci::Credentials.write({"moderation" => YAML::Any.new(moderation)})
      resp = session.not_nil!.get("/auth/basic-credentials")
      resp.status_code.should eq(401)
      resp.headers["WWW-Authenticate"].should contain("Moderation")
      session.not_nil!.get("/auth/basic-credentials", basic_auth("mod", "nope")).status_code.should eq(401)
      session.not_nil!.get("/auth/basic-credentials", basic_auth("mod", "pw")).status_code.should eq(200)
    ensure
      Saci::Credentials.file_path = old_file
      Saci::Credentials.key_path = old_key
      FileUtils.rm_rf(dir)
    end
  end

  it "renders body:, file:, template:, action:, partial: and render_to_string" do
    resp = session.not_nil!.get("/render/body")
    resp.status_code.should eq(202)
    resp.headers["Content-Type"].should contain("text/csv")
    resp.body.should eq("raw-body")

    resp = session.not_nil!.get("/render/file")
    resp.body.should contain("rendered-from-file")
    resp.status_code.should eq(200)
    resp.headers["Content-Type"].should contain("text/plain")

    resp = session.not_nil!.get("/render/traversal")
    resp.status_code.should eq(400)
    resp.body.should eq("unsafe")

    resp = session.not_nil!.get("/render/template")
    resp.status_code.should eq(203)
    resp.body.should contain("<p>oops</p>")

    resp = session.not_nil!.get("/render/action")
    resp.status_code.should eq(200)
    resp.body.should contain("<p>oops</p>")

    resp = session.not_nil!.get("/render/partial")
    resp.body.should contain("Hello, Ada!")

    resp = session.not_nil!.get("/render/partial-locals")
    resp.body.should contain("Hello, Bob!")

    resp = session.not_nil!.get("/render/to-string")
    resp.body.should eq(%({"a":1}))

    resp = session.not_nil!.get("/render/to-string-template")
    resp.body.should contain("<p>oops</p>")

    resp = session.not_nil!.get("/render/to-string-partial")
    resp.body.should contain("Hello, Zoe!")

    resp = session.not_nil!.get("/render/location")
    resp.status_code.should eq(201)
    resp.headers["Location"].should eq("/things/1")
    resp.headers["Content-Type"].should contain("application/vnd.api+json")

    resp = session.not_nil!.get("/render/no-content")
    resp.status_code.should eq(204)
  end

  it "wraps JSON params and applies params.expect" do
    body = %({"name":"Ada","email":"ada@example.com","role":"admin","other":"ignored"})
    resp = session.not_nil!.post("/params/users", json_headers, body)
    resp.status_code.should eq(200)
    parsed = JSON.parse(resp.body)
    parsed["name"].should eq("Ada")
    parsed["email"].should eq("ada@example.com")
    parsed["top"].should eq("Ada")
    wrapped = JSON.parse(parsed["wrapped"].as_s)
    wrapped.as_h.keys.sort.should eq(["email", "name"])

    resp = session.not_nil!.post(
      "/params/users-form",
      HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"},
      "name=Ada"
    )
    JSON.parse(resp.body)["wrapped"].raw.should be_nil
  end

  it "infers the wrap_parameters root name from the controller" do
    resp = session.not_nil!.post("/params/inferred", json_headers, %({"name":"Ada"}))
    resp.status_code.should eq(200)
    parsed = JSON.parse(resp.body)
    wrapped = JSON.parse(parsed["wrapped"].as_s)
    wrapped.as_h["name"].as_s.should eq("Ada")
  end

  it "supports scalar, array, nested and array-of-hash expect forms" do
    resp = session.not_nil!.get("/params/scalar?id=7")
    JSON.parse(resp.body)["id"].should eq("7")

    resp = session.not_nil!.get("/params/array?tags[]=a&tags[]=b")
    JSON.parse(resp.body)["tags"].as_a.map(&.as_s).should eq(["a", "b"])

    resp = session.not_nil!.post("/params/rows", json_headers, %({"rows":[{"name":"a","email":"e","x":1}]}))
    JSON.parse(resp.body)["names"].as_a.map(&.as_s).should eq(["a"])

    resp = session.not_nil!.post("/params/nested", json_headers, %({"user":{"address":{"street":"Main","zip":"1"}}}))
    JSON.parse(resp.body)["street"].should eq("Main")
  end

  it "returns 400 for missing expectations (expect and expect!)" do
    resp = session.not_nil!.get("/params/missing")
    resp.status_code.should eq(400)
    resp.body.should contain("user")

    resp = session.not_nil!.post("/params/bang", json_headers, %({"user":{"name":"Ada"}}))
    resp.status_code.should eq(400)
    resp.body.should contain("user.email")

    resp = session.not_nil!.get("/params/scalar")
    resp.status_code.should eq(400)
  end

  it "keeps require/permit working alongside expect" do
    resp = session.not_nil!.post(
      "/params/require-permit",
      json_headers,
      %({"story":{"title":"T","tags":["a"],"x":1}})
    )
    resp.status_code.should eq(200)
    JSON.parse(resp.body)["title"].should eq("T")
  end

  it "rate limits actions with Retry-After and per-client keys" do
    Saci::Throttle.clear_counts!
    headers = HTTP::Headers{"X-Client" => "client-a"}
    session.not_nil!.get("/rate/limited", headers).status_code.should eq(200)
    session.not_nil!.get("/rate/limited", headers).status_code.should eq(200)
    resp = session.not_nil!.get("/rate/limited", headers)
    resp.status_code.should eq(429)
    resp.headers["Retry-After"].to_i.should be > 0

    session.not_nil!.get("/rate/limited", HTTP::Headers{"X-Client" => "client-b"}).status_code.should eq(200)

    session.not_nil!.get("/rate/open").status_code.should eq(200)
  end

  it "supports custom rate_limit responses and skip_rate_limit" do
    Saci::Throttle.clear_counts!
    session.not_nil!.get("/rate/custom").status_code.should eq(200)
    resp = session.not_nil!.get("/rate/custom")
    resp.status_code.should eq(429)
    resp.headers["X-Custom-Limit"]?.should eq("1")

    Saci::Throttle.clear_counts!
    3.times do
      session.not_nil!.get("/rate-skip/limited", HTTP::Headers{"X-Client" => "skip"}).status_code.should eq(200)
    end
  end

  it "exposes request host/subdomain/url helpers" do
    resp = session.not_nil!.get("/request/info")
    parsed = JSON.parse(resp.body)
    parsed["host"].should eq("127.0.0.1")
    parsed["port"].as_i.should eq(session.not_nil!.port)
    parsed["domain"].should eq("127.0.0.1")
    parsed["subdomain"].should eq("")
    parsed["ssl"].should be_false
    parsed["full_url"].should eq("http://127.0.0.1:#{session.not_nil!.port}/x?y=1")

    resp = session.not_nil!.get("/request/info", HTTP::Headers{"Host" => "api.example.com:3000"})
    parsed = JSON.parse(resp.body)
    parsed["domain"].should eq("example.com")
    parsed["subdomain"].should eq("api")
    parsed["port"].as_i.should eq(3000)
    parsed["host_with_port"].should eq("api.example.com:3000")

    resp = session.not_nil!.get("/request/info", HTTP::Headers{"Host" => "dev.api.example.com"})
    parsed = JSON.parse(resp.body)
    parsed["subdomain"].should eq("dev.api")
    parsed["domain"].should eq("example.com")

    resp = session.not_nil!.get("/request/info", HTTP::Headers{"X-Forwarded-Proto" => "https"})
    parsed = JSON.parse(resp.body)
    parsed["ssl"].should be_true
    parsed["full_url"].as_s.should start_with("https://")

    resp = session.not_nil!.get("/request/override")
    JSON.parse(resp.body)["full_url"].should eq("https://cdn.example.com/path")
  end

  it "gates browsers with allow_browser (modern/allowlist/blocklist)" do
    modern = HTTP::Headers{"User-Agent" => "Mozilla/5.0 Chrome/124.0.0.0 Safari/537.36"}
    old = HTTP::Headers{"User-Agent" => "Mozilla/5.0 Chrome/80.0.0.0 Safari/537.36"}

    session.not_nil!.get("/browser/modern", modern).status_code.should eq(200)
    session.not_nil!.get("/browser/modern", old).status_code.should eq(406)
    session.not_nil!.get("/browser/modern").status_code.should eq(406)

    session.not_nil!.get("/browser/allowlist", HTTP::Headers{"User-Agent" => "Friendly/1.0"}).status_code.should eq(200)
    session.not_nil!.get("/browser/allowlist", modern).status_code.should eq(406)

    session.not_nil!.get("/browser/blocklist", HTTP::Headers{"User-Agent" => "BadBot/1.0"}).status_code.should eq(406)
    session.not_nil!.get("/browser/blocklist", modern).status_code.should eq(200)

    session.not_nil!.get("/browser/open").status_code.should eq(200)
  end

  it "supports rescue_from with: handlers" do
    resp = session.not_nil!.get("/rescue-with/boom")
    resp.status_code.should eq(502)
    JSON.parse(resp.body)["handled"].should eq("with-handler")
  end

  it "records rescue_responses mappings" do
    Saci::Controller.rescue_response_status_for("SpecExtrasBoomError").should eq(502)
    session.not_nil!.get("/responses").status_code.should eq(200)
  end
end

describe "Saci::Params#expect" do
  it "requires and permits hash keys" do
    req = HTTP::Request.new("POST", "/", json_headers, %({"user":{"name":"Ada","email":"a@x","role":"admin"}}))
    params = Saci::Params.build(req, {} of String => String)
    user = params.expect(user: [:name, :email])
    user.as_h.keys.sort.should eq(["email", "name"])

    req = HTTP::Request.new("POST", "/", json_headers, %({"user":{"name":"Ada"}}))
    params = Saci::Params.build(req, {} of String => String)
    expect_raises(Saci::ParameterMissing) { params.expect(user: [:name, :email]) }
    expect_raises(Saci::Params::ExpectedParameterMissing) { params.expect!(user: [:name, :email]) }
  end

  it "rejects incompatible types" do
    req = HTTP::Request.new("POST", "/", json_headers, %({"user":"hack"}))
    params = Saci::Params.build(req, {} of String => String)
    expect_raises(Saci::ParameterMissing) { params.expect(user: [:name]) }

    req = HTTP::Request.new("POST", "/", json_headers, %({"tags":{"a":1}}))
    params = Saci::Params.build(req, {} of String => String)
    expect_raises(Saci::ParameterMissing) { params.expect(tags: [] of Symbol) }
  end

  it "supports positional scalars and multiple filters" do
    req = HTTP::Request.new("POST", "/?id=7", json_headers, %({"user":{"name":"Ada"}}))
    params = Saci::Params.build(req, {} of String => String)
    values = params.expect(:id, user: [:name])
    values.as_a.size.should eq(2)
    values.as_a[0].as_s.should eq("7")
    values.as_a[1].as_h["name"].as_s.should eq("Ada")
  end

  it "wraps params under a root key" do
    req = HTTP::Request.new("POST", "/", json_headers, %({"name":"Ada","role":"admin"}))
    params = Saci::Params.build(req, {} of String => String)
    params.wrap!("user", ["name"], [] of String)
    JSON.parse(params["user"]).as_h.keys.should eq(["name"])
  end
end

describe "Saci::Params::UploadedFile" do
  it "exposes the Rails-ish uploaded-file API" do
    body = "--TESTBOUND\r\nContent-Disposition: form-data; name=\"avatar\"; filename=\"a.png\"\r\nContent-Type: image/png\r\n\r\nPNGDATA\r\n" +
           "--TESTBOUND--\r\n"
    headers = HTTP::Headers{"Content-Type" => "multipart/form-data; boundary=TESTBOUND"}
    req = HTTP::Request.new("POST", "/upload", headers, body)
    params = Saci::Params.build(req, {} of String => String)
    file = params.file("avatar").not_nil!
    file.original_filename.should eq("a.png")
    file.filename.should eq("a.png")
    file.content_type.should eq("image/png")
    file.headers["Content-Type"].should eq("image/png")
    file.size.should eq(7)
    file.read.should eq("PNGDATA")
    file.read.should eq("")
    file.rewind
    file.read.should eq("PNGDATA")
    file.rewind
    file.tempfile.gets_to_end.should eq("PNGDATA")
    file.bytes.should eq("PNGDATA".to_slice)
    params.expect_file("avatar").original_filename.should eq("a.png")
    expect_raises(Saci::ParameterMissing) { params.expect_file("missing") }
  end
end

describe "HTTP::Request host helpers" do
  it "parses Host headers, ports and subdomains" do
    req = HTTP::Request.new("GET", "/x")
    req.headers["Host"] = "dev.api.example.co.uk:8080"
    req.host.should eq("dev.api.example.co.uk")
    req.host_with_port.should eq("dev.api.example.co.uk:8080")
    req.port.should eq(8080)
    # Without a public-suffix list the default tld_length: 1 yields "co.uk".
    req.domain.should eq("co.uk")
    req.subdomain.should eq("dev.api.example")
    req.domain(tld_length: 2).should eq("example.co.uk")
    req.subdomain(tld_length: 2).should eq("dev.api")
    req.ssl?.should be_false

    req = HTTP::Request.new("GET", "https://example.com/")
    req.ssl?.should be_true
    req.protocol.should eq("https")
  end
end

describe "Saci::Controller open-redirect setting" do
  it "delegates to the module-level switch" do
    Saci::Controller.raise_on_open_redirects.should be_true
    Saci::Controller.raise_on_open_redirects = false
    Saci.raise_on_open_redirects.should be_false
  ensure
    Saci::Controller.raise_on_open_redirects = true
  end
end
