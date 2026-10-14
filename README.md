# Saci

A Rails-compatible (Rails-like API) web framework in Crystal. Familiar MVC
conventions and directory-free single-shard design, implemented idiomatically
on top of Crystal's `HTTP::Server`.

**Status: Router + Controller (0.1.0) and ORM (0.2.0)** — the equivalents of
ActionDispatch + ActionController + ActiveRecord (SQLite).

## Requirements

- Crystal >= 1.0.0 (developed against 1.22.0)
- `libpcre2`, `libssl`, `libgc`, `zlib` available to the linker

## Quick start

```crystal
require "saci"

class ApplicationController < Saci::Controller
end

class PostsController < ApplicationController
  before_action :log, except: [:index]

  def index
    render json: [{id: 1, title: "Hello Saci"}]
  end

  def show
    render json: {id: params["id"]? || "?", title: "Post"}
  end

  def create
    render json: {id: 2, title: params["title"]? || "Untitled"}, status: :created
  end

  def update
    render json: {id: params["id"]? || "?"}
  end

  def destroy
    head :no_content
  end

  private def log
    puts "[Posts##{action_name}] #{params.to_h}"
  end
end

router = Saci::Router.new.draw do |r|
  r.root PostsController, :index
  r.resources "posts", PostsController
  r.namespace("/api") do |api|
    api.get "/hello", PostsController, :index
  end
  r.get("/ping") { |ctx, _params| ctx.response.print("pong") }
end

Saci::Application.new(router).listen(3000)
```

Run the bundled example:

```sh
crystal run examples/basic_app.cr
curl http://127.0.0.1:3000/posts/7
```

Run the test suite (46 examples: live-HTTP web specs, file-backed SQLite
ORM specs, CLI generator specs):

```sh
crystal spec
```

Validate the whole framework through a Forem-inspired demo community
(users, articles, comments, reactions, analytics DB) — 22 live-HTTP
examples covering every subsystem, plus a runnable server:

```sh
crystal spec spec/forem_lite_spec.cr
crystal run examples/forem_lite_app.cr
curl http://127.0.0.1:3000/
```

Build the CLI:

```sh
shards build saci   # -> bin/saci (gitignored build artifact)
```

## CLI

```sh
saci new blog
cd blog
saci generate model Post title:string views:integer published:boolean
saci generate controller Posts index show
saci generate migration AddBioToUsers bio:text
saci db:migrate
saci db:rollback        # rolls back the last migration
saci serve --port 3000
```

- `new` scaffolds `shard.yml` (path-dependency on the framework source),
  `src/<app>.cr` entrypoint, controllers/models dirs, `db/migrate/` +
  `db/migrations.cr` manifest + standalone `db/migrate.cr` runner, and specs.
- Generators write files and print next steps (routes to add). The migration
  generator rebuilds `db/migrations.cr` from `db/migrate/*.cr`, so hand-added
  migration files are picked up too.
- `serve` execs `crystal run src/<app>.cr` with `PORT`/`HOST` set; anything
  after `--` is forwarded to `crystal` as compiler flags
  (e.g. `--link-flags=...`).
- `db:migrate` / `db:rollback [STEPS]` re-sync the manifest, then run the
  standalone runner (models only — the web server is never booted).

## ORM (ActiveRecord equivalent)

```crystal
Saci::Record.connection = DB.open("sqlite3://./app.db")

class CreatePosts < Saci::Record::Migration
  def change
    create_table :posts do |t|
      t.string :title, null: false
      t.integer :views, default: 0
      t.boolean :published, default: false
      t.integer :user_id
      t.timestamps
    end
  end
end

Saci::Record::Migrator.migrate(db, [CreatePosts] of Saci::Record::Migration.class)
Saci::Record::Migrator.rollback(db, [CreatePosts] of Saci::Record::Migration.class)

class Post < Saci::Record::Base
  column id : Int64, primary: true
  column title : String
  column views : Int64
  column published : Bool, default: false
  column user_id : Int64
  timestamps

  validates :title, presence: true, max_length: 200
  validates :email, format: /@/, uniqueness: true

  belongs_to :user
end

post = Post.create!(title: "Hi")          # raises RecordInvalid when invalid
post.update(views: 10)
post.destroy
Post.find(1)                              # raises RecordNotFound when missing
Post.find_by(title: "Hi")
Post.where(published: true).where("views > ?", 5)
    .order(views: :desc).limit(10).offset(5).to_a
Post.count / Post.exists?(published: true) / Post.pluck(:title)
Post.where(published: false).update_all({published: true})
user.posts.where(published: true).to_a    # has_many returns a chainable Query
Saci::Record.transaction { ... }          # raise DB::Rollback to roll back
```

Notes:

- Table names are inferred (`SpecUser` → `spec_users`); override with
  `table "custom"`. Column types: `Int32/Int64/Float64/String/Bool/Time/Bytes`
  (all nilable); `timestamps` maintains `created_at/updated_at`.
- `change`-style migrations roll back automatically (`create_table`,
  `add_column`, `add_index`); `drop_table`/`remove_column`/`remove_index`
  inside `change` raise `IrreversibleMigration` on rollback — use `up`/`down`.
- Connection state is module-global (`Saci::Record.connection`): Crystal
  class variables are per-class, so a `@@connection` on the base class would
  be invisible to subclasses.
- Unset attributes are omitted from INSERTs so DB defaults apply; model-level
  `default:` applies at `new` (like ActiveRecord).

## Databases (SQLite, PostgreSQL, MySQL)

```crystal
Saci::Record.connect("sqlite3://./db/app.db")          # adapter from scheme
Saci::Record.establish_connection("warehouse", "postgres://localhost/wh")
Saci::Record.establish_connection("legacy", "mysql://root@localhost/old")

class WarehouseEvent < ApplicationRecord
  connects_to database: "warehouse"
end

Saci::Record.connected_to("legacy") { LegacyRow.count }
```

The adapter is detected from the URL scheme (`sqlite3://`, `postgres(ql)://`,
`mysql://`); unknown schemes raise immediately. `?` placeholders, identifier
quoting, boolean/timestamp binds, auto-increment PKs (`AUTOINCREMENT` /
`BIGSERIAL` / `AUTO_INCREMENT`), `RETURNING`-based inserts and rollback
ordering are all handled per adapter — write `?` and double quotes
everywhere, and migrations render for the database they run against.

Two things you must know:

1. **Drivers are app-owned.** Add `will/crystal-pg` (`~> 0.30.0`) or
   `crystal-lang/crystal-mysql` (`~> 0.17.0`) to *your* `shard.yml` and
   `require "pg"` / `require "mysql"` yourself (`saci new` scaffolds the
   commented lines). The framework never requires drivers: `DB.open`
   resolves drivers through a virtual dispatch that links *every*
   registered driver's connect path — including pg's `Digest`-based auth,
   which cannot link on OpenSSL ≥ 3.2 systems (same reason Saci vendors its
   GCM binding). Framework-level requires would break linking for all
   users, including pure-SQLite ones.
2. **No live PG/MySQL verification here.** No servers are available in this
   environment, so PostgreSQL/MySQL support is proven by SQL-generation
   specs (`spec/adapters_spec.cr`: scheme detection, placeholder rewriting,
   quoting, DDL per adapter, portable rollback) plus the unchanged SQLite
   suite. Point `DATABASE_URL` at a real server to verify live — the
   execution paths are shared with SQLite by construction.

## Testing

```sh
saci test                        # crystal spec in the app
saci test spec/models            # subset
```

- Apps boot with `APP_ENV` (`development` by default); specs force
  `APP_ENV=test`, so `db/<app>_test.db` never touches development data.
  `db:migrate` respects `APP_ENV` too (`APP_ENV=test saci db:migrate`).
- Generated specs use two helpers:
  - `Saci::TestSession.serve(router) { |app| ... }` — live request specs
    over real HTTP on an ephemeral port (`app.get/post/put/patch/delete`).
  - `Saci::Record.clean_database!` in `before_each` — truncates every table
    except `schema_migrations`.
- `saci g model` writes `spec/models/<name>_spec.cr`;
  `saci g controller` writes `spec/requests/<name>_spec.cr`.

## Hot-reload

```sh
saci serve --watch [--watch-interval 0.5]
```

Polling file watcher (stdlib only): rebuilds with `crystal build` into `tmp/`
and restarts a single supervised binary. Ignores `*.db/*.log` and
`tmp/log/lib/.git`; debounces rapid saves; build failures and crashes wait
for the next save instead of hot-spinning; INT/TERM shuts down watcher +
child cleanly. Supervised `build` — not `crystal run` — deliberately:
`run` orphans a grandchild process that keeps holding the port.

## WebSockets (ActionCable equivalent)

```crystal
class ChatChannel < Saci::Cable::Channel
  def subscribed
    stream_from "room:#{params["room"]?.try(&.as_s?) || "lobby"}"
  end

  def receive(data)
    Saci::Cable.broadcast("room:1", {text: data["text"]? || data})
  end
end

router = Saci::Router.new.draw do |r|
  r.cable "/cable", ChatChannel                       # multiplexed endpoint
  r.websocket("/live") { |ws, ctx, params| ws.send("hi") }  # raw escape hatch
end
```

- Wire protocol is an ActionCable-compatible subset (`subscribe` / `message` /
  `unsubscribe` commands with JSON identifiers; `welcome`, `confirm_`,
  `reject_subscription`, and `{identifier, message}` deliveries).
- ` transmit(payload)` replies to one subscription; `stream_from` /
  `stop_stream` / `stop_all_streams` manage stream membership;
  `Channel.broadcast_to(stream, payload)` and `Saci::Cable.broadcast`
  fan out. Call `reject` in `subscribed` to refuse (client gets
  `reject_subscription`).
- `saci g channel Chat` writes the channel plus a `TestClient`-based spec.
  `Saci::Cable::TestClient` is a synchronous spec client (buffered frames,
  timeouts) — see `examples/cable_example.cr` for a two-client chat demo.
- Single-process pub/sub (no Redis adapter yet); override the registry per
  app with `r.cable "/cable", ChatChannel, server: my_server` or
  `Saci::Cable.server = ...`.

## Multithreading

Crystal runs single-threaded by default. Saci is thread-safe (fiber-keyed
transactions and locales, mutex-guarded pub/sub, stateless dispatch), so to
use all cores:

```sh
saci serve --mt [--workers 4]   # compiles -Dexecution_context, sets SACI_MT
```

Generated entrypoints call `Saci.enable_multithreading!` when `SACI_MT=1`
(workers default to CPU count, honoring `CRYSTAL_WORKERS`). Without the flag
the call is a harmless no-op, so the same code compiles and runs either way —
the suite passes both plain and with `crystal spec -Dexecution_context`.

Notes: `Saci::Record` auto-tunes SQLite (`WAL` + `busy_timeout`) when the
connection is assigned, so concurrent readers/writers behave; transactions
are per-fiber (nested blocks reuse the outer one); locales are per-fiber too.

## Localization

```crystal
Saci::I18n.load_path << "config/locales/*.yml"  # default; then:
Saci::I18n.reload!

Saci::I18n.t("hello")                       # "Hello"
Saci::I18n.t("greeting", name: "Ada")       # "Hello, Ada!"
Saci::I18n.t("items", count: 0)             # zero/one/other (+%{count})
Saci::I18n.with_locale(:es) { Saci::I18n.t("hello") }  # "Hola", nestable
Saci::I18n.locale_from_header(request.headers["Accept-Language"]?)
```

- `config/locales/*.yml` mirror Rails (`en:` → nested keys, flattened to
  dot paths at load). Missing keys fall back to the default locale, then to
  `"translation missing: <locale>.<key>"`; missing `%{args}` raise
  `MissingInterpolation`.
- In controllers, `t("greeting", name: ...)` uses the current locale — set it
  per request, e.g. `before_action { Saci::I18n.locale = Saci::I18n.parse_locale(params["locale"]?) }`.
- Locales accept `:es` or `"es"` interchangeably (normalized internally —
  Crystal has no runtime string-to-symbol conversion).

## Security

```crystal
class ApplicationController < Saci::Controller
  protect_from_forgery          # CSRF: 422 on forged state-changing requests
end

class User < ApplicationRecord
  column password_digest : String
  has_secure_password           # bcrypt + authenticate + validations
end

user.authenticate("secret")     # => user or nil
```

- **CSRF** uses the stateless double-submit-cookie pattern: safe methods set
  the `saci_csrf` cookie (`SameSite=Lax`); POST/PUT/PATCH/DELETE must echo it
  via the `authenticity_token` param or `X-CSRF-Token` header (compared in
  constant time). `form_authenticity_token` returns the token for forms.
  Failures raise `InvalidAuthenticityToken`, rendered as 422.
- **Secure headers** (`X-Frame-Options: SAMEORIGIN`,
  `X-Content-Type-Options: nosniff`, `Referrer-Policy`) are applied to every
  controller response unless already set; tune via
  `Saci::SecureHeaders.configure`.
- **Passwords**: `has_secure_password` digests with bcrypt on assignment,
  validates presence-on-create, confirmation match, and the 72-byte bcrypt
  limit. `Saci::Record.bcrypt_min_cost = true` speeds up specs (like
  `ActiveModel::SecurePassword.min_cost`).
- **XSS**: `h(user_input)` (`HTML.escape`) before interpolating into
  `render html:`; JSON rendering is escaped by construction; all SQL uses
  bound parameters; mass-assignment goes through `assign` (unknown attributes
  raise).
- **Sessions & cookies**: `session[:user_id]` (HMAC-signed cookie store,
  `reset_session` on login), `cookies` / `cookies.signed` /
  `cookies.encrypted` (AES-256-GCM, opaque to clients) / `cookies.delete`,
  and `flash[:notice]` (one redirect) with `flash.now`. Secret from
  `SECRET_KEY_BASE` (`saci secret` generates one; dev fallback persisted to
  `tmp/.dev_secret`, never commit it). Set `Saci::Session.encrypt = true`
  for opaque sessions (generated production envs do); enabling it
  invalidates previously signed sessions, so turn it on before launch.
- Not yet: CSP defaults — see roadmap.

## Logging

```crystal
Saci.logger.info { "booted" }           # ::Log wrapper, swappable
Saci.logger = ::Log.for("myapp")        # e.g. in specs
Saci.log_requests = false               # silence request lines
Saci.filter_parameters = ["password"]   # substring match, filtered in logs

Saci.tagged("worker-1") do
  Saci.logger.info { "[#{Saci.current_tags.join(" ")}] working" }
end
```

Every request logs `Completed 200 in 3.2ms | GET /posts | params={...} |
[req-id]` at info level with filtered params, and carries an `X-Request-Id`
(request header honored when present, generated otherwise).

## Background jobs

```crystal
class WelcomeJob < Saci::Job::Base
  queue_as :mailers
  retry_on IO::Error, attempts: 3, wait: :exponential
  discard_on Saci::Record::RecordNotFound

  def perform(payload : JSON::Any) : Nil
    puts "hello #{payload["user_id"]}"
  end
end

WelcomeJob.perform_later({user_id: 1})
WelcomeJob.set(wait: 5.minutes).perform_later({user_id: 1})
WelcomeJob.perform_now({user_id: 1})
```

- Payloads cross a JSON boundary (even in-process) — pass ids, not objects.
- Adapters: `:async` (spawned fiber, dev default), `:inline` (immediate —
  use in specs), `:test` (records into `Saci::Job.enqueued_jobs` without
  running), `:db` (durable: persists to `saci_jobs`, survives restarts —
  run `Saci::Job::Db.drain` for scripts or `work_once` in a worker loop;
  final failures land in `saci_dead_jobs` with `retry_dead`/`drop_dead`
  ops). `Saci::Job.with_adapter(:inline) { }` scopes the switch.
- Retries count total tries; failures/discards report via `Saci::Job.on_error`
  (default: STDERR line). Redis adapters remain roadmap; at-least-once
  everywhere, so jobs MUST be idempotent.

## Mailers

```crystal
class UserMailer < Saci::Mailer::Base
  default_from "noreply@example.com"

  def self.welcome(email : String) : Saci::Mailer::Mail
    mail(to: email, subject: "Welcome!") do |format|
      format.text { "Welcome, #{email}!" }
      format.html { "<h1>Welcome, #{email}!</h1>" }
    end
  end
end

UserMailer.welcome("a@b.c").deliver_now
UserMailer.welcome("a@b.c").deliver_later            # via Saci::Job
```

- Adapters: `:file` (dev default, `tmp/mails/*.eml`), `:test` (inspect
  `Saci::Mailer.deliveries` in specs), `:sendmail` (`/usr/sbin/sendmail -t`),
  `:smtp` (dependency-free STARTTLS + AUTH LOGIN client — set
  `MAILER_ADAPTER=smtp` plus `SMTP_HOST/PORT/USERNAME/PASSWORD`).
- `deliver_later` renders now and delivers the rendered email later, so it
  works with every job adapter (present and future).

## Views

```crystal
class PostsController < ApplicationController
  def show
    @post = Post.find(params["id"])
    render_template(:show)         # views/posts/show.ecr + layout
  end
end
```

```erb
<!-- views/posts/show.ecr -->
<h1><%= h(@post.title) %></h1>
<%= render_partial("shared/meta") %>
```

- Templates live in `<app>/src/views/` (layouts in `views/layouts/`,
  default `application` with `<%= content %>`); actions share state via
  instance variables. `render_template("posts/show", layout: false)` skips
  the layout. `<%= %>` does NOT escape — use `h()` (documented loudly).
- `form_with(url) { |f| f.text_field("name") + f.submit }` builds escaped
  forms with `_method` override + CSRF token; `link_to("Delete", url,
  method: :delete)` renders a self-contained mini-form (works with the
  `_method` routing override, no JavaScript).

## HTTP caching

```crystal
def show
  @post = Post.find(params["id"])
  return unless stale?(@post)   # etag from table/id/updated_at
  render json: @post
end
```

`stale?(etag:, last_modified:)` / `fresh_when` set validators and reply 304
when fresh (weak-etag comparison, `*` support, second-resolution IMS);
`expires_in(60.seconds, public: true)` sets `Cache-Control`.

## Rate limiting

```crystal
Saci::Throttle.throttle("logins/ip", limit: 5, period: 1.minute) do |ctx|
  ctx.request.path == "/login" ? Saci::Throttle.client_ip(ctx) : nil
end
Saci::Throttle.safelist { |ctx| Saci::Throttle.client_ip(ctx) == "127.0.0.1" }
Saci::Throttle.blocklist { |ctx| banned?(ctx) }
```

Fixed windows (nil discriminator skips); throttled → 429 + `Retry-After`,
blocklisted → 403. In-process counters (`reset!`/`clear_counts!` for specs);
Redis sharding is roadmap.

## Storage

```crystal
key = Saci::Storage.upload(data, filename: "pic.png", content_type: "image/png")
Saci::Storage.download(key) # => Bytes
r.get "/files/*key", Saci::Storage::FilesController, :show
Saci::Storage.signed_url(key) # => "/files/ab/cd/…?expires=…&sig=…"
```

Disk service with sharded keys + JSON sidecars (type/filename/size);
`send_file`/`send_data` stream downloads; `FilesController` serves private
files through expiring HMAC-signed URLs (tampered/expired/missing → 404,
path traversal rejected).

## Credentials

```sh
saci credentials:show | credentials:edit [EDITOR] | credentials:keygen
```

AES-256-GCM encrypted `config/credentials.yml.enc` + gitignored
`config/master.key` (or `RAILS_MASTER_KEY`); `saci new` seeds both including
a `secret_key_base` that sessions pick up automatically.
`Saci::Credentials.dig("aws.access_key")` reads dot paths.

> Implementation note: stdlib `OpenSSL::Cipher` binds symbols removed in
> OpenSSL ≥ 3.2 and cannot link there, so Saci vendors a minimal GCM binding
> (`Saci::MessageEncryptor`) using only long-stable EVP symbols. `Digest::*`
> is unavailable for the same reason — ETags use pure-Crystal FNV-1a.

## Environments & multidatabase

- `APP_ENV` (`Saci.env`, `production?`…) with `config/environments/*.cr`
  (`log_level`, `force_ssl` with localhost bypass, detailed HTML error pages
  outside production, test env silences logs + cheap bcrypt).
- Named databases: `Saci::Record.establish_connection("analytics", url)`,
  `connects_to database: "analytics"` per model,
  `Saci::Record.connected_to("analytics") { }` scoping, per-database
  transactions (no cross-DB atomicity).

## API notes (web)

- **Routes**: `get/post/put/patch/delete(path, Controller, :action)`,
  `root`, `resources` (index/show/create/update/destroy, with
  `only:`/`except:`), `namespace`/`scope`, and block routes via
  `add`/arity overloads. Unknown routes render JSON 404.
- **Params**: path + query + JSON/form body merged into `params`,
  with `require` (raises `Saci::ParameterMissing` → 400),
  `permit`, `int`, `to_h`.
- **Rendering**: `render json:/html:/text:/plain:` with `status:`
  (integer or `:ok`, `:created`, `:no_content`, `:unauthorized`, …),
  `redirect_to`, `head`.
- **Filters**: `before_action :name, only: [...], except: [...]`.
  Parent filters run before child filters; rendering/redirecting inside a
  filter halts the chain (the action is skipped).
- **Errors**: `params.require` failures → 400 JSON; unhandled exceptions →
  500 JSON; actions that never render → 500 JSON hint.

## Crystal constraints (vs Rails)

Because Crystal is statically compiled, dynamic `send(:action)` is
impossible. Saci generates dispatch code at compile time
(`inherited` hook + deferred `{% verbatim %}` expansion, the same technique
`JSON::Serializable` uses), so plain `def show ... end` actions just work —
including inherited and overridden actions. Two consequences:

1. Any **public zero-argument** instance method is dispatchable (same rule as
   Rails, effectively). Keep helpers private or give them parameters.
2. Avoid public zero-argument `&block` methods and public zero-argument
   `def self.x` methods in controllers; they confuse dispatcher codegen.

## Layout

```text
src/saci.cr             # entrypoint
src/saci/router.cr      # Saci::Router
src/saci/controller.cr  # Saci::Controller
src/saci/params.cr      # Saci::Params
src/saci/application.cr # Saci::Application / Handler (rails server equiv.)
src/saci/record.cr      # Saci::Record entrypoint + coercions
src/saci/job.cr           # background jobs
src/saci/job_db.cr        # durable DB-backed queue (:db adapter)
src/saci/logging.cr       # logger, tags, filtering, request lines
src/saci/mailer.cr        # mailers + delivery
src/saci/smtp.cr          # dependency-free SMTP client (STARTTLS + AUTH)
src/saci/views.cr         # ECR templates, forms, links, caching, files
src/saci/throttle.cr      # rate limiting
src/saci/storage.cr       # disk uploads + signed serving
src/saci/crypto.cr        # vendored AES-256-GCM (see note)
src/saci/credentials.cr   # encrypted credentials file
src/saci/record/base.cr # Saci::Record::Base (models)
src/saci/record/query.cr      # chainable queries
src/saci/record/migration.cr  # migrations + Migrator
src/saci/record/errors.cr     # validation errors
src/saci/record/inflector.cr  # table-name inflection
src/saci/cable.cr         # ActionCable-style channels + TestClient
src/saci/concurrency.cr   # enable_multithreading!
src/saci/csrf.cr          # double-submit CSRF tokens
src/saci/secure_headers.cr  # secure response headers
src/saci/secrets.cr       # secret_key_base + signed values
src/saci/cookies.cr       # cookie jar + signed/encrypted cookies
src/saci/session.cr       # cookie sessions (signed or encrypted) + flash
src/saci/i18n.cr          # localization
src/saci/test_session.cr  # live request specs helper
src/saci/version.cr
src/saci/exceptions.cr
spec/saci_spec.cr       # web unit + live-server integration specs
spec/record_spec.cr     # ORM specs (file-backed SQLite)
spec/adapters_spec.cr   # PG/MySQL SQL generation (no servers needed)
spec/jobs_spec.cr       # job adapters, retry/discard, test recording
spec/jobs_db_spec.cr    # durable :db adapter (persist, drain, dead letters)
spec/logging_spec.cr    # filtering, tags, request lines/ids
spec/mailers_spec.cr    # building, adapters, deliver_later round-trip
spec/smtp_spec.cr       # SMTP framing/auth/errors against a fake server
spec/views_spec.cr      # templates, layouts, partials, forms, links
spec/caching_spec.cr    # etag/last-modified flows, expires_in, records
spec/throttle_spec.cr   # limits, safelist, blocklist, windows
spec/storage_spec.cr    # disk service, signed URLs, FilesController
spec/credentials_spec.cr  # AES-GCM, credentials file, CLI commands
spec/multidb_spec.cr    # named DBs, connects_to, connected_to, tx routing
spec/env_spec.cr        # env, log levels, force_ssl, error pages
spec/cli_spec.cr        # CLI generator specs (temp dirs, no compilation)
spec/test_session_spec.cr  # TestSession request specs (ephemeral ports)
spec/cable_spec.cr      # Cable specs (live two-client broadcast, reject, unsubscribe)
spec/security_spec.cr   # CSRF/headers/escaping/bcrypt specs
spec/session_spec.cr    # session/flash/cookie/secret specs
spec/forem_lite_spec.cr # Forem Lite validation app (all subsystems, live HTTP)
examples/basic_app.cr   # runnable web example
examples/forem_lite_app.cr  # runnable Forem Lite demo (DEV.to-style community)
examples/record_example.cr  # runnable ORM example
```

## Roadmap

- [x] Router + Controller
- [x] ORM: models, queries, validations, associations, migrations
- [x] CLI: new / generate / serve / db:migrate / db:rollback / test / --watch
- [x] WebSockets (ActionCable-style channels)
- [x] Multithreading (`serve --mt`, fiber-safe state) + localization (I18n)
- [x] Basic security (CSRF, secure headers, has_secure_password, escaping)
- [x] Sessions, signed cookies, flash + `saci secret`
- [x] Encrypted cookies (`cookies.encrypted`) + opt-in encrypted sessions
- [x] Logging, background jobs, mailers (+ `g job/mailer`)
- [x] Views (ECR templates/layouts/partials, forms), HTTP caching
- [x] Rate limiting, disk storage, encrypted credentials, env config, multidb
- [x] PostgreSQL + MySQL adapters (SQL generation specced; live servers needed)
- [x] SMTP delivery (STARTTLS + AUTH LOGIN, verified live via Ethereal)
- ECR-based views / layouts
- ActiveJob durable Redis adapters; encrypted cookies
- Eager loading (`includes`), joins, callbacks, has_many :through

> The living plan — framework, CLI, Forem Lite app and ops, prioritized
> P0/P1/P2 with the validation story behind each item — is [ROADMAP.md](ROADMAP.md).
