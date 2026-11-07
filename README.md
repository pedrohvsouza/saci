# Saci

Saci is a full-stack web framework for [Crystal](https://crystal-lang.org).
It borrows the conventions and vocabulary of Ruby on Rails (MVC,
`resources` routing, Active Record-style models, migrations, jobs,
mailers, channels) and builds them on Crystal's stdlib `HTTP::Server`,
with compile-time code generation in place of runtime metaprogramming.

You get one shard and a single compiled binary. SQLite works out of the
box, PostgreSQL and MySQL are supported, and Redis is optional. Every
subsystem is built with the standard library: Saci vendors small
pure-Crystal implementations instead of linking extra C libraries.

```crystal
require "saci"

class PostsController < Saci::Controller
  def index
    render json: Post.where(published: true).order(created_at: :desc).limit(20).to_a
  end
end

router = Saci::Router.new.draw do |r|
  r.resources "posts", PostsController, only: [:index]
end

Saci::Application.new(router).listen(3000)
```

- [What's included](#whats-included)
- [Installation](#installation)
- [Quick start](#quick-start)
- [CLI](#cli)
- [Configuration and middleware](#configuration-and-middleware)
- [Routing](#routing)
- [Controllers](#controllers)
- [Models (`Saci::Record`)](#models-sacirecord)
- [Databases](#databases)
- [Schema snapshots and drift check](#schema-snapshots-and-drift-check)
- [Views](#views)
- [Frontend: Turbo, Stimulus, importmap](#frontend-turbo-stimulus-importmap)
- [Rich text](#rich-text)
- [WebSockets](#websockets)
- [Background jobs](#background-jobs)
- [Mailers](#mailers)
- [Inbound email](#inbound-email)
- [Storage and attachments](#storage-and-attachments)
- [Caching](#caching)
- [Rate limiting](#rate-limiting)
- [Security](#security)
- [Authorization, serializers, search, audit](#authorization-serializers-search-audit)
- [GraphQL](#graphql)
- [Spreadsheets, PDF and CSV](#spreadsheets-pdf-and-csv)
- [Localization and time zones](#localization-and-time-zones)
- [Logging and metrics](#logging-and-metrics)
- [Multithreading](#multithreading)
- [Environments, credentials, deployment](#environments-credentials-deployment)
- [Testing](#testing)
- [How Saci differs from Rails](#how-saci-differs-from-rails)
- [Developing Saci](#developing-saci)

## What's included

| Area | What you get |
|---|---|
| HTTP | Router with resources, namespaces, constraints and optional segments; named route helpers; controllers with filters, `rescue_from`, `respond_to`; a configurable middleware stack (CORS, host authorization, trusted proxies, static files, gzip, `/up`, body limits) |
| Data | `Saci::Record` ORM for SQLite, PostgreSQL and MySQL: associations, validations, callbacks, dirty tracking, exact decimals, enums, nested attributes, locking, bulk writes, migrations, introspection, schema snapshots, SQLite FTS5 |
| Views | ECR templates, layouts, partials, form builders, asset pipeline with fingerprinting, fragment caching, Turbo Frames/Streams, Turbo Drive, Stimulus, importmap, PWA assets |
| Background | Jobs (`:async`, `:inline`, `:test`, durable `:db`) with retries, priorities, uniqueness, batches and continuations; recurring jobs (cron); dashboard |
| Messaging | Mailers (SMTP, sendmail, SendGrid, Mailgun, Postmark, SES, DKIM, attachments, previews); inbound email (mailboxes, routing, ingress) |
| Realtime | ActionCable-compatible WebSocket channels, with in-process, Redis or database fan-out |
| Security | CSRF, CSP with nonces, secure headers, signed and encrypted cookies, pluggable session stores, `has_secure_password`, auth helpers, signed IDs, JWT, TOTP 2FA, rate limiting, encrypted credentials |
| Extras | Storage with signed URLs, blobs, attachments, direct uploads and S3; rich text; GraphQL; XLSX/PDF/CSV; serializers; policies; search; audit trail; I18n; time zones; metrics; structured logging |
| Tooling | `saci` CLI (new app scaffold, generators, `db:*` tasks, routes, runner, console, hot reload, credentials, local CI) and a testing kit (fixtures, factories, transactional tests, assertions, time travel, `assert_select`) |

## Installation

Requirements:

- Crystal >= 1.0.0 (developed against 1.22)
- `libpcre2`, `libssl`, `libgc` and `zlib` available to the linker

Build the CLI from a checkout:

```sh
git clone https://github.com/pedrohvsouza/saci.git
cd saci
shards install
shards build saci      # -> bin/saci
```

Or add Saci to an existing shard:

```yaml
dependencies:
  saci:
    github: pedrohvsouza/saci
```

`saci new` writes a `path:` dependency pointing at the checkout the CLI was
built from, so freshly generated apps compile right away.

## Quick start

```sh
saci new blog                     # --db=postgres|mysql, --devcontainer
cd blog
saci generate scaffold Post title:string body:text published:boolean
saci db:migrate
saci serve --watch                # http://127.0.0.1:3000
```

The generated app is a regular Crystal project:

```text
blog/
  src/blog.cr                 # entrypoint: requires, configuration, routes, listen
  src/controllers/            # ApplicationController + your controllers
  src/models/                 # ApplicationRecord + your models
  src/views/                  # ECR templates and layouts
  config/                     # environments, initializers, database.yml, credentials
  db/migrate/ db/migrations.cr db/migrate.cr db/seed.cr
  spec/                       # model and request specs
  bin/                        # saci, ci, docker-entrypoint, kamal, ...
  public/ Dockerfile config/deploy.yml .github/workflows/
```

The repository also contains runnable examples:

```sh
crystal run examples/basic_app.cr          # JSON API
crystal run examples/record_example.cr     # ORM
crystal run examples/cable_example.cr      # WebSocket chat
crystal run examples/forem_lite_app.cr     # demo community app using most subsystems
```

## CLI

```sh
saci new NAME [--db=sqlite|postgres|mysql] [--devcontainer] [--skip-git] [--skip-shards]
saci generate KIND NAME [fields...] [--pretend] [--force]
saci destroy KIND NAME
saci serve [--port 3000] [--host] [--watch] [--mt [--workers N]] [-- crystal flags]
saci test [spec paths] [-- crystal flags]
saci routes [--grep PATTERN]
saci runner -e CODE | saci runner FILE [args]
saci console [-e CODE]
saci db:migrate [--all] | db:rollback [STEPS] [--all] | db:seed
saci db:prepare | db:setup | db:reset | db:create | db:drop | db:version | db:migrate:status
saci db:schema:dump [--all] | db:schema:load | db:schema:check [--all]
saci credentials:show | credentials:edit | credentials:keygen | credentials:fetch KEY
saci task NAME | task:list
saci importmap:install | importmap:pin | importmap:json
saci ci | app:update | secret | about | stats | notes | middleware | initializers
```

Generators: `model`, `controller`, `migration`, `scaffold`,
`scaffold_controller`, `resource`, `admin`, `authentication`, `channel`,
`job`, `mailer`, `task`, `helper`, `test`, `integration_test`, `benchmark`,
`application_record`.

- Generators write the files, rebuild `db/migrations.cr` from
  `db/migrate/*.cr`, and print the routes you need to add. Routes stay
  hand-edited. Migration names starting with `AddIndex...` (or `--unique`)
  generate `add_index`.
- If a target file already exists with different content, the generator
  asks `overwrite? [y/n/a/q]` on a TTY. Piped input never blocks: EOF
  skips with a warning. Use `--force` in CI. `--pretend` shows what would
  be created, with a preview of each file, and writes nothing.
- `destroy` removes only files the matching generator owns. It prompts
  when a file differs from what the generator would produce now.
- `db:migrate` and `db:rollback` run the standalone `db/migrate.cr`
  runner, which loads the models but never boots the web server. `--all`
  also covers every named database registered through
  `DATABASE_URL_<NAME>`. After each run the runner prints schema drift
  warnings.
- `routes` parses the route DSL statically, with no compilation, and
  prints `VERB PATH -> Controller#action`.
- `runner` and `console` compile a temporary wrapper under `tmp/` with
  models, initializers and the database connection loaded. Crystal has
  no runtime eval, so `console` recompiles on every line. Put multi-line
  code in a file.
- `serve --watch` polls the source tree, rebuilds with `crystal build` and
  restarts a single supervised binary. Build failures wait for the next
  save. Path dependencies (such as a local Saci checkout) are watched too.
- `ci` runs the steps declared in `config/ci.cr` with `Saci::CI.step` and
  `Saci::CI.run`. `app:update` re-applies the scaffold, prompting before
  it changes any file you edited.

## Configuration and middleware

```crystal
Saci.configure do |config|
  config.hosts = ["example.com", "www.example.com"]
  config.trusted_proxies = ["10.0.0.0/8"]
  config.assume_ssl = true
  config.force_ssl = true
  config.max_request_body = 10.megabytes
  config.cors do |cors|
    cors.allowed_origins = ["https://app.example.com"]
  end

  config.middleware.use MyAuthHandler.new(secret: ENV["SECRET"])
  config.middleware.use TimingHandler, header: "X-Timing"
  config.middleware.insert_before Saci::Middleware::Static, RequestId.new
  config.middleware.delete Saci::Middleware::HostAuthorization
end
```

A middleware is a plain `HTTP::Handler`. Built-in handlers can be disabled
at runtime and still work as `insert_before` / `insert_after` / `swap`
targets. `saci middleware` prints the resolved chain.

Boot hooks:

```crystal
Saci::Initializers.before_configuration { Saci.log_level = :debug }
Saci::Initializers.to_prepare { }          # re-run on reload; keep it idempotent
Saci::Initializers.after_initialize { }    # once, after configuration
```

Generated apps load `config/initializers/*.cr` and
`config/environments/<APP_ENV>.cr`. Declarative YAML lives in `config/`
(`database.yml`, `cache.yml`, `queue.yml`, `cable.yml`, `storage.yml`,
`server.yml`). ERB-style `<%= ENV["X"] %>` tags in those files are
interpolated before parsing. Read them with
`Saci.config_for(:name)`.

## Routing

```crystal
router = Saci::Router.new.draw do |r|
  r.root HomeController, :index
  r.resources "posts", PostsController do |s|
    s.member { |m| m.post :upvote }          # POST /posts/:id/upvote
    s.collection { |c| c.get :search }       # GET  /posts/search
    s.resources "comments", CommentsController
  end
  r.resource "profile", ProfileController    # singular resource
  r.namespace :admin do |a|
    a.resources "posts", Admin::PostsController
  end
  r.get "/top(/:length(/page/:page))", StoriesController, :top
  r.get "/~:username", UsersController, :show
  r.constraints(id: /\d+/) { |c| c.get "/s/:id", StoriesController, :show }
  r.redirect("/u/:username", to: "/~%{username}", status: 301)
  r.get("/ping") { |ctx, _params| ctx.response.print("pong") }
  r.fallback ErrorsController, :not_found
end
```

- `resources` generates the seven REST actions (`only:` and `except:`
  filter them). Nested resources become `/posts/:post_id/comments`.
  `shallow`, `concern`, `direct`, `resolve` and `mount` behave as in Rails.
- Segments can carry literal prefixes and suffixes (`/~:user`,
  `/avatars/:name.png`). Parenthesized groups such as `(.:format)` are
  optional. `*splat` captures the rest of the path.
- POST forms can tunnel PUT, PATCH and DELETE through a hidden `_method`
  parameter.

Named helpers come in two flavors. Compile-time helpers are generated from
the same DSL, so a typo is a compile error:

```crystal
Saci::Routes.define AppRoutes do |r|
  r.resources "posts", PostsController do |s|
    s.member { |m| m.post :upvote }
  end
end

AppRoutes.post_path(12)          # "/posts/12"
AppRoutes.edit_post_path(12)     # "/posts/12/edit"
AppRoutes.upvote_post_path(4)    # "/posts/4/upvote"
```

Runtime lookup works on any drawn router and from controllers and views:
`path_for(:post, 12)`, `url_for(...)`, `polymorphic_path(post)`,
`polymorphic_path([post, comment])`, `dom_id(post)`, and
`router.recognize_path("/posts/1")`.

## Controllers

```crystal
class PostsController < ApplicationController
  before_action :require_login, except: [:index, :show]
  around_action :with_timing
  rescue_from Saci::Record::RecordNotFound do |_ex|
    render json: {error: "not found"}, status: :not_found
  end

  def index
    respond_to do |f|
      f.html { render_template :index }
      f.json { render json: Post.all.to_a }
      f.rss { render xml: rss_feed(title: "Posts", link: "/posts", description: "latest", items: items) }
    end
  end

  def create
    post = Post.new(title: params["title"]?, body: params["body"]?)
    if post.save
      redirect_to path_for(:post, post.id)
    else
      render_template :new, status: 422
    end
  end

  private def with_timing(&)
    elapsed = Time.measure { yield }
    Saci.logger.info { "took #{elapsed}" }
  end
end
```

- Filters: `before_action`, `after_action`, `around_action`, the
  `prepend_*` variants and `skip_*_action`, all with `only:` / `except:`.
  A before filter that renders or redirects halts the chain.
- Rendering: `render json:/html:/text:/plain:/xml:/body:/file:`,
  `render_template`, `render_partial`, `render_to_string`, `head`,
  `redirect_to`, `redirect_back(fallback_location:)`, `send_file` and
  `send_data`. `status:` accepts integers or symbols (`:created`,
  `:unprocessable_content`, ...).
- `redirect_to` rejects cross-host URLs unless you pass
  `allow_other_host: true`.
- Params: path, query, JSON, form and multipart bodies are merged into one
  tree: `params.require(:post).permit(:title, tags: [] of String)`,
  `params.expect(...)`, `params.dig`, `params.array`, `params.file`.
  `wrap_parameters` nests JSON bodies under a root key.
- HTTP auth: `authenticate_or_request_with_http_basic`,
  `authenticate_with_http_token`, `http_basic_authenticate_with`.
- Also available: `rate_limit to: 10, within: 1.minute`,
  `allow_browser versions: :modern`, request host helpers (`request.host`,
  `request.subdomain`, `request.ssl?`), and conditional GET (see
  [Caching](#caching)).
- Any public method that takes no arguments is an action. Keep helpers
  private or give them parameters (see
  [How Saci differs from Rails](#how-saci-differs-from-rails)).

## Models (`Saci::Record`)

```crystal
class CreatePosts < Saci::Record::Migration
  def change
    create_table :posts do |t|
      t.string :title, null: false
      t.decimal :price, precision: 10, scale: 2
      t.enum :status, values: ["draft", "published"]
      t.references :user, foreign_key: true
      t.timestamps
    end
    add_index :posts, :title
  end
end

class Post < ApplicationRecord
  column id : Int64, primary: true
  column title : String
  column price : Decimal
  column status : String
  column user_id : Int64
  column tags : Array(String)
  column meta : JSON
  timestamps

  validates :title, presence: true, length: {maximum: 200}
  validates :title, uniqueness: {scope: :user_id, case_sensitive: false}
  validates :price, numericality: {greater_than_or_equal_to: 0}
  validate :title_is_fine, on: :create

  belongs_to :user, counter_cache: true, touch: true
  has_many :comments, dependent: :destroy
  has_many :taggings
  has_many :tags, through: :taggings
  has_one :moderation
  accepts_nested_attributes_for :comments, allow_destroy: true

  before_save :normalize
  after_commit :reindex, on: :create
end

post = Post.create!(title: "Hi")
post.title = "Hello"
post.changes                                   # {"title" => ["Hi", "Hello"]}
post.save
post.saved_change_to_title                     # ["Hi", "Hello"]

Post.where(status: "published").where("views > ?", 5).order(created_at: :desc).limit(10).to_a
Post.where(created_at: 1.day.ago..Time.utc).or(Post.where(pinned: true))
Post.all.not(user_id: nil).includes(:user).includes(comments: :user).to_a
Post.joins(:user).group(:user_id).count
Post.insert_all([{title: "a"}, {title: "b"}])
Post.upsert_all(rows, unique_by: :slug)
Post.find_each(batch_size: 500) { |p| ... }
Post.find_or_create_by(title: "x")
Post.where(status: "draft").pluck(:id)
Post.transaction(isolation: :serializable) { post.lock!; ... }
```

- **Types**: `Int32`, `Int64`, `Float64`, `String`, `Bool`, `Time` and
  `Bytes`, plus `Decimal` (exact, `BigDecimal`-backed), `Date`, `JSON`
  (with `<col>_json` helpers) and `Array(String)`. Every attribute is
  nilable. `model_enum status: {draft: 0, live: 1}` maps labels to stored
  values. Migrations also cover UUIDs, binary, generated and virtual
  columns, check constraints, views, and PostgreSQL native types
  (`hstore`, `inet`, `cidr`, ranges, `interval`, `money`, ...).
- **Queries**: `select`, `distinct`, `group` with aggregates, `having`,
  `joins` (symbol or SQL), `left_joins`, `includes`/`preload` (batched,
  including through and polymorphic), `merge`, `rewhere`, `unscope`,
  `none`, `in_order_of`, `sole`, `pick`, `ids`, `explain`, `in_batches`,
  `annotate`, `lock`.
- **Associations**: `belongs_to` (with `polymorphic:`, `counter_cache:`,
  `touch:`, `autosave:`), `has_many` / `has_one` (with `through:`, `as:`,
  and `dependent:` set to `:destroy`, `:delete_all`, `:nullify` or
  `:restrict_with_exception`), and `has_and_belongs_to_many`.
- **Persistence**: `update_columns`, `update_column` and `touch` skip
  validations and callbacks. `upsert` runs no validations. `increment!`,
  `toggle!` and `destroy!` are available, and optimistic locking turns on
  when the table has a `lock_version` column.
- **Migrations**: `change` reverses automatically. Operations that cannot
  be reversed raise `IrreversibleMigration`; use `up`/`down` or
  `reversible` for those. Also available: `change_table`, `revert`,
  `execute`, `if_not_exists:`, `disable_ddl_transaction!` and
  `algorithm: :concurrently`.
- **Full-text search**: `Saci::Record::FTS.setup(Post, [:title, :body])`
  creates an FTS5 virtual table with triggers.
  `Post.search_fts("crystal")` returns a ranked, chainable query (SQLite
  only).

## Databases

```crystal
Saci::Record.connect("sqlite3://./db/app.db")      # adapter detected from the scheme
Saci::Record.establish_connection("analytics", "postgres://localhost/analytics")

class Event < ApplicationRecord
  connects_to database: "analytics"
end

Saci::Record.connected_to("analytics") { Event.count }
```

- Write `?` placeholders and double-quoted identifiers everywhere. Saci
  rewrites placeholders, quoting, auto-increment keys, `RETURNING` inserts
  and DDL for each adapter.
- **Your app owns the drivers.** Add `will/crystal-pg` or
  `crystal-lang/crystal-mysql` to your `shard.yml` and require them
  yourself; `saci new --db=...` does this for you. Saci never requires a
  driver itself, so SQLite-only apps link nothing extra.
- SQLite connections are tuned for web workloads (WAL and
  `busy_timeout`). Transactions are scoped per fiber and per database;
  there is no atomicity across databases.
- On OpenSSL ≥ 3.2, `crystal-pg` needs a two-symbol link shim (see
  [`live/README.md`](live/README.md)). `crystal-mysql` requires the server
  to accept `mysql_native_password`.

## Schema snapshots and drift check

```sh
saci db:schema:dump [--all]   # write db/schema.cr
saci db:schema:load           # recreate tables, indexes, checks and views
saci db:schema:check [--all]  # exit 1 when the database and the models disagree
```

`db/schema.cr` is a standalone Crystal program. It connects the same way
`db/migrate.cr` does and replays an embedded snapshot through
adapter-aware DDL. The snapshot is data, not raw SQL, so one file loads on
SQLite, PostgreSQL and MySQL. `schema_migrations` is never dumped; the
durable job tables are. SQLite stores several logical types in the same
storage class, so booleans reload as `:integer` and dates and JSON as
`:text`. Saci's own `t.decimal` reloads as `:decimal`. Re-dumping a loaded
database produces the same bytes.

Every model registers itself, so `Saci::Record.check_schema!(db)` can
return one warning per mismatch: a table without a model, a model without
a table, or a column missing on either side. Only names are compared.

## Views

```crystal
class PostsController < ApplicationController
  def show
    @post = Post.find(params["id"])
    render_template :show            # src/views/posts/show.ecr inside layouts/application.ecr
  end
end
```

```erb
<h1><%= h(@post.title) %></h1>
<%= render_partial("comments/comment", collection: @post.comments.to_a) %>
<%= cache(cache_key(@post)) { render_partial("posts/sidebar", post: @post) } %>
<%= form_with("/posts", model: @post, scope: "post") { |f| f.text_field("title") + f.error_messages + f.submit } %>
<%= link_to("Delete", path_for(:post, @post.id), method: :delete) %>
```

- `<%= %>` does **not** escape. Use `h()` for user input. Helpers that
  build HTML escape their own arguments.
- Layouts use `<%= content %>`. `content_for` and `capture` fill named
  slots. `render_template(:x, layout: false)` renders without a layout.
- Forms: `form_with`, `fields_for`, `collection_select`, the `*_tag`
  helpers, HTML5 input types, CSRF tokens, and `_method` overrides.
  `link_to(..., method: :delete)` renders a small form, so it works
  without JavaScript.
- Text and number helpers: `truncate`, `simple_format`, `sanitize`,
  `strip_tags`, `highlight`, `pluralize`, `number_to_currency`,
  `number_with_delimiter`, `distance_of_time_in_words`, `markdown`
  (escape-first), `page_numbers`, `rss_feed`, `tag`, `content_tag`,
  `button_to`, `mail_to`.
- Assets: `Saci::Assets.build_manifest(src, out)` fingerprints files.
  `asset_path`, `stylesheet_link_tag`, `javascript_include_tag` and
  `image_tag` resolve through the manifest and fall back to `/assets/...`
  in development.
- Pagination: `Saci::Pagination.paginate(query, page:, per_page:)` returns
  a page object, and `paginate_nav` renders windowed links.

## Frontend: Turbo, Stimulus, importmap

```crystal
turbo_frame_tag("profile") { "<p>Ada</p>" }
render turbo_stream: Saci::Turbo.append("msgs", "<p>#{h(text)}</p>")
Saci::Turbo.broadcast_append("room:1", "msgs", "<p>hi</p>")    # over Cable

Saci::Importmap.draw do |map|
  map.pin "application", to: "app/javascript/application.js", preload: true
  map.pin_all_from "app/javascript/controllers", under: "controllers"
end
```

In a layout: `<%= importmap_tags %>`, `<%= turbo_drive_tags %>`,
`<%= stimulus_tags %>`, `<%= pwa_tags %>`. Turbo Drive and Stimulus ship
as small vendored, dependency-free subsets of the Hotwire libraries. For
the full libraries, pin them from a CDN through the importmap. Turbo
stream payloads go into `<template>` unescaped, so escape user input
yourself.

## Rich text

```crystal
class Post < ApplicationRecord
  column body : String
  has_rich_text :body
end

post.body_rich_text.to_s            # sanitized HTML
post.body_rich_text.to_plain_text   # for search indexes and notifications
```

The column stores raw HTML and is sanitized on every read, using an
allowlist and escape-first approach. `rich_text_area` renders a plain
`<textarea data-rich-text>` that Trix (loaded from a CDN) can enhance.
`<action-text-attachment>` tags that point at storage blobs are rendered
with `render_attachments`.

## WebSockets

```crystal
class ChatChannel < Saci::Cable::Channel
  def subscribed
    stream_from "room:#{params["room"]?.try(&.as_s?) || "lobby"}"
  end

  def receive(data)
    Saci::Cable.broadcast("room:1", {text: data["text"]?})
  end
end

Saci::Cable.identify do |connection|
  connection.reject_unauthorized_connection unless connection.session.try(&.["user_id"])
end

router = Saci::Router.new.draw do |r|
  r.cable "/cable", ChatChannel
end
```

- The wire protocol is compatible with ActionCable clients. Channels also
  support `stream_for record`, `periodically 5.seconds { }`, `transmit`,
  `reject`, and `identified_by`.
- Fan-out uses a single process by default. For several processes, set
  `Saci::Cable.server` to `Cable::RedisServer.new(ENV["REDIS_URL"])`
  (built-in RESP2 client, no extra dependency) or to `Cable::DbServer`
  (database polling, Solid Cable style). If Redis is down, broadcasts
  still reach local subscribers.
- Writes go through a shared pool of writer fibers with bounded
  per-connection queues, so idle sockets stay cheap and slow readers get
  disconnected instead of piling up memory.
- `Saci::Cable::TestClient` and `Cable::TestServer` support specs, and
  `saci g channel` generates both.

## Background jobs

```crystal
class WelcomeJob < Saci::Job::Base
  queue_as :mailers
  queue_with_priority 10
  unique :until_executed
  retry_on IO::Error, attempts: 3, wait: :exponential
  discard_on Saci::Record::RecordNotFound

  def perform(payload : JSON::Any) : Nil
    UserMailer.welcome(payload["email"].as_s).deliver_now
  end
end

Saci::Job.queue_adapter = :db
WelcomeJob.perform_later({email: "a@b.c"})
WelcomeJob.set(wait: 5.minutes, queue: :low).perform_later({email: "a@b.c"})
```

- Adapters: `:async` (fiber, the development default), `:inline`,
  `:test` (records jobs instead of running them), and `:db` (durable,
  persisted in `saci_jobs` with a dead-letter table and claims via
  `FOR UPDATE SKIP LOCKED`). Run `Saci::Job::Db.work_once` in a worker
  loop or `drain` from scripts.
- Payloads cross a JSON boundary. Records are serialized as GlobalID
  references. Delivery is at-least-once, so jobs must be idempotent.
- Also available: callbacks and middleware, `limits_concurrency`, batches
  (`Saci::Job::Batch`), and resumable jobs (`continuable` + `step`).
- Recurring jobs:
  `Saci::Recurring.cron("*/5 * * * *", "refresh") { RefreshJob.perform_later({}) }`
  and `Saci::Recurring.every(1.hour, "cleanup") { ... }`, then
  `Saci::Recurring.start`. Missed ticks collapse into a single run.
- Dashboard: mount `Saci::Job::DashboardController` to see pending and
  dead jobs, with retry and drop actions. It is disabled in production by
  default.

## Mailers

```crystal
class UserMailer < Saci::Mailer::Base
  default_from "noreply@example.com"
  layout "mailer"

  def self.welcome(email : String) : Saci::Mailer::Mail
    attachments["terms.pdf"] = {mime_type: "application/pdf", path: "public/terms.pdf"}
    mail(to: email, subject: "Welcome!") do |format|
      format.text { "Welcome, #{email}!" }
      format.html { "<h1>Welcome, #{email}!</h1>" }
    end
  end
end

UserMailer.welcome("a@b.c").deliver_later
UserMailer.with(user: user).digest.deliver_now
```

- Delivery adapters: `:file` (development, writes `tmp/mails/*.eml`),
  `:test`, `:sendmail`, `:smtp` (built-in STARTTLS client), and HTTP
  providers (SendGrid, Mailgun, Postmark, Amazon SES with SigV4). DKIM
  signing is optional.
- `deliver_later` renders the mail immediately and sends the result
  through the job system.
- Previews: register them with `Saci::Mailer::Preview.register` and mount
  `PreviewController` (development only). Non-ASCII subjects are
  RFC 2047-encoded on the wire.

## Inbound email

```crystal
class SupportMailbox < Saci::Mailbox::Base
  def process
    Ticket.create!(subject: mail.subject, body: mail.text_body)
  end
end

Saci::Mailbox.router = Saci::Mailbox::Router.new.draw do |r|
  r.route SupportMailbox, to: "support@example.com"
  r.route all: :backup
end

router = Saci::Router.new.draw { |r| Saci::Mailbox.mount(r) }
```

Includes a MIME parser (multipart, RFC 2047/2231, charsets), persisted
`InboundEmail` records deduplicated by Message-ID, `bounce_with` and
`relay_to`, incineration of processed mail, an HTTP ingress endpoint for
providers, and test helpers.

## Storage and attachments

```crystal
class User < ApplicationRecord
  column id : Int64, primary: true
  has_one_attached :avatar
end

user.avatar.attach(io, filename: "me.png")
user.avatar.url                                   # expiring signed URL

r.get "/files/*key", Saci::Storage::FilesController, :show
r.post "/direct_uploads", Saci::Storage::DirectUploadsController, :create
```

- `DiskService` stores files under sharded keys. Private files are served
  through expiring HMAC-signed URLs. Signing keys can be rotated: old URLs
  keep working until they expire. A `public/` key prefix is served
  without signatures.
- `S3Service` works with AWS, MinIO, R2 and other S3-compatible stores,
  using its own SigV4 signer. `MirrorService` writes to several services
  at once.
- Blobs have checksums and metadata. Image dimensions come from a
  pure-Crystal analyzer. Variants and previews go through a pluggable
  processor; none is bundled, so without one they return the original
  file.
- Uploads with content types that browsers execute are rejected by
  default, and upload size is capped.

## Caching

```crystal
Saci::Cache.fetch("stats", expires_in: 5.minutes) { compute_stats }
Saci::Cache.store = Saci::Cache::RedisStore.new(ENV["REDIS_URL"])
Saci::Cache.store = :db                         # database-backed store (Solid Cache style)

def show
  @post = Post.find(params["id"])
  return unless stale?(@post)                   # ETag / Last-Modified, 304 when fresh
  expires_in 60.seconds, public: true
  render_template :show
end
```

- Stores: `MemoryStore` (LRU, with stampede protection through
  `race_condition_ttl:`), `RedisStore`, and `DbStore` (one portable table;
  `trim` and `prune_expired` handle cleanup).
- Fragment caching: `cache(key) { ... }` in views, keyed by
  `cache_key(record)`, `cache_key(records)` or `version:`. If the store is
  down, the fragment is rendered but not stored.
- `Saci::PageCache` writes whole pages to disk.

## Rate limiting

```crystal
Saci::Throttle.throttle("logins/ip", limit: 5, period: 1.minute) do |ctx|
  ctx.request.path == "/login" ? Saci::Throttle.client_ip(ctx) : nil
end
Saci::Throttle.safelist { |ctx| Saci::Throttle.client_ip(ctx) == "127.0.0.1" }
Saci::Throttle.store = Saci::Throttle::RedisStore.new(ENV["REDIS_URL"])
```

Fixed windows. Throttled requests get 429 with `Retry-After`; blocklisted
requests get 403. If the store is unreachable, requests are allowed and a
warning is logged. In controllers, `rate_limit to:, within:` uses the
same store.

## Security

```crystal
class ApplicationController < Saci::Controller
  protect_from_forgery
end

class User < ApplicationRecord
  column password_digest : String
  has_secure_password
  has_secure_token :api_token
  generates_token_for :password_reset, expires_in: 15.minutes do |user|
    user.password_salt
  end
end

User.authenticate_by(email: params["email"], password: params["password"])
user.signed_id(purpose: "login", expires_in: 15.minutes)
```

- **CSRF**: double-submit cookie, with masked and per-form tokens checked
  in constant time.
- **Headers**: secure defaults (`X-Frame-Options`, `nosniff`,
  `Referrer-Policy`, CSP `default-src 'self'`), CSP nonces
  (`content_security_policy_nonce`), Permissions-Policy, and HSTS. Change
  them per action with `csp` / `skip_csp`.
- **Sessions and cookies**: `session`, `flash`, `cookies.signed` and
  `cookies.encrypted` (AES-256-GCM). Signing keys can be rotated. Session
  stores: cookie (the default), memory, cache, or database.
- **Authentication helpers**: `login(user)` resets the session first to
  prevent fixation. Also `logout`, `current_user`
  (`memoize_current_user User`), `require_login`,
  `allow_unauthenticated_access`, and `after_authentication_url`.
  `saci g authentication` generates a complete flow with password
  resets.
- **Tokens**: `Saci::JWT` (HS256/384/512), `Saci::TOTP` (codes,
  provisioning URIs, backup codes), and `has_two_factor` for models.
- **Secrets**: `SECRET_KEY_BASE` or encrypted credentials. Production
  refuses to boot without a secret.

Saci vendors a small AES-GCM binding and pure-Crystal digests. On systems
with OpenSSL ≥ 3.2, the stdlib `OpenSSL::Cipher` and `Digest` modules
fail to link because they reference symbols that were removed.

## Authorization, serializers, search, audit

```crystal
class PostPolicy < Saci::Policy
  resource Post
  allow :read
  role :editor do
    can :update, Post
  end
  scope { scope.where(status: "published") }
end

authorize!(:update, post)                      # in a controller
policy_scope(Post)

class PostSerializer < Saci::Serializer(Post)
  attributes :id, :title
  has_many :comments, serializer: CommentSerializer
end
render json: PostSerializer.new(post, root: "post", key_transform: :camel)

class Post < ApplicationRecord
  searchable_attributes :title, :status, :created_at
  include Saci::Auditable
  audited only: [:title, :status]
end
Post.search(params).page                       # Ransack-style q[title_cont]=...
post.audits
```

## GraphQL

```crystal
class PostType < Saci::GraphQL::ObjectType
  source Post
  field :id, Saci::GraphQL::ID, null: false
  field :title, String
end

class QueryType < Saci::GraphQL::ObjectType
  graphql_name "Query"
  field :posts, [PostType], null: false do |_source, _args, _ctx|
    Post.order(id: :asc).to_a
  end
end

class AppSchema < Saci::GraphQL::Schema
  query QueryType
end

Saci::GraphQL.mount(router, path: "/graphql", schema: AppSchema)
```

Supports queries, mutations, input objects, enums, variables, fragments,
introspection, batched requests and GraphiQL. Types are compile-time
classes and resolvers are typed blocks.

## Spreadsheets, PDF and CSV

```crystal
require "saci/office"

xlsx = Saci::Office::XLSX.from_records(User.all, columns: [:id, :email, :created_at])
send_xlsx xlsx, filename: "users.xlsx"

pdf = Saci::Office::PDF.table(title: "Users", headers: ["Name", "Email"], rows: rows)
send_pdf pdf, filename: "users.pdf"

send_csv rows, filename: "users.csv"
```

XLSX is written as a ZIP package using the stdlib DEFLATE implementation.
PDFs use the standard Helvetica fonts. CSV follows RFC 4180.

## Localization and time zones

```crystal
Saci::I18n.load_path << "config/locales/*.yml"
Saci::I18n.t("greeting", name: "Ada")
Saci::I18n.t("items", count: 3)
Saci::I18n.with_locale(:es) { Saci::I18n.t("hello") }
Saci::I18n.l(Time.utc, format: :short)

Time.use_zone("America/Sao_Paulo") { Time.current }
3.days.from_now
Date.current
```

Locale files use the same nested YAML layout as Rails. Features include
fallback chains, pluralization rules, localized date and time formats,
and the `Accept-Language` header. Durations, calendar helpers, a small
`Date` type, inflections and `CurrentAttributes` are included too.

## Logging and metrics

```crystal
Saci.logger.info { "booted" }
Saci.filter_parameters += ["token"]
Saci.tagged("worker-1") { ... }

r.get "/metrics", Saci::Metrics::Controller, :index    # JSON, or Prometheus with ?format=prom
```

Every request logs one line with the status, duration, method, path,
filtered params and request id. Set `SACI_LOG_FORMAT=json` for structured
output. `Saci::Notifications` publishes instrumentation events
(`process_action.saci`, `sql.saci`, `perform.saci`, ...) and the
slow-query logger subscribes to them. Metrics are kept in process
(requests, routes, jobs, cache, database gauges) and have no built-in
auth, so mount them behind your own gate.

## Multithreading

```sh
saci serve --mt [--workers 4]     # compiles with -Dexecution_context
```

Generated entrypoints call `Saci.enable_multithreading!`. Without the
compile flag the call does nothing, so the same code runs single-threaded.
Transactions, locales, time zones and the auth context are scoped per
fiber, and shared registries are mutex-guarded.

## Environments, credentials, deployment

- `APP_ENV` selects `config/environments/<env>.cr` (`development`,
  `test`, `production`, `staging`). `Saci.env`, `Saci.production?` and
  `Saci.staging?` are available. Production and staging refuse to boot
  without a secret and never show detailed errors.
- `config/credentials.yml.enc` plus `config/master.key` (or
  `RAILS_MASTER_KEY`). Read values with
  `Saci::Credentials.dig("aws.access_key")` and edit them with
  `saci credentials:edit`.
- `saci new` generates a multi-stage Dockerfile, `bin/docker-entrypoint`,
  a Kamal 2 configuration (`config/deploy.yml`, `.kamal/secrets`), a
  GitHub Actions workflow, `config/server.yml`, public error pages and an
  optional devcontainer. `bin/thrust` documents the proxy setup; Saci
  does not bundle an HTTP/2 proxy.
- `app.listen_gracefully(port, host, shutdown: Saci::Deploy::GracefulShutdown.new(timeout: 10.seconds))`
  waits for in-flight requests on SIGTERM. `Saci::Deploy.doctor` checks
  the secret, the database URL and writable directories.

## Testing

```crystal
require "saci/testing"

load_fixtures :all
fixture :users, User

factory :post, Post do
  title { "Post #{Saci::Testing::Factory.sequence(:post)}" }
end

describe "posts" do
  transactional_tests

  it "publishes" do
    post = Saci::Testing::Factory.create_post
    assert_enqueued_jobs(1) { PublishJob.perform_later({id: post.id}) }
    travel_to(Time.utc(2026, 1, 1)) { Time.utc.year.should eq(2026) }
  end

  it "renders the index" do
    Saci::TestSession.serve(router) do |app|
      response = app.get("/posts")
      assert_select response, "h1", text: "Posts"
    end
  end
end
```

- `Saci::TestSession.serve(router)` starts the full middleware and
  router stack over real HTTP on an ephemeral port.
- Includes YAML fixtures (label references, ERB), factories with traits
  and associations, transactional tests with savepoints, assertions for
  mail, jobs, cable, changes and queries, time travel, `assert_select`,
  test database preparation, and per-worker databases for parallel runs.
- Generated apps run their specs with `APP_ENV=test` against a separate
  database.

## How Saci differs from Rails

Crystal is compiled and statically typed, which changes a few things:

- **No autoloading or in-process reload.** Files are required explicitly
  (generated apps use globs) and `saci serve --watch` rebuilds and
  restarts the binary. `saci console` compiles every line.
- **No `send`, `constantize` or `method_missing`.** Controllers, routes,
  jobs, mailboxes and models generate their dispatch code at compile time
  through macros and `inherited` hooks. Any public method on a controller
  that takes no arguments becomes an action. Avoid public zero-argument
  methods that take a block, and public zero-argument class methods, in
  controllers.
- **Templates are compiled.** ECR is compiled into the binary and
  `<%= %>` does not escape.
- **Static types at the edges.** Columns, route helpers and job payloads
  are typed, and job arguments cross a JSON boundary.
- **No gem ecosystem.** Features that Rails apps usually get from gems
  (pagination, authorization, serializers, search, audit, fixtures and
  factories, JWT, 2FA, rate limiting, GraphQL) ship with the framework.

[COMING_FROM_RAILS.md](COMING_FROM_RAILS.md) maps Rails APIs and common
gems to their Saci equivalents and lists what is not supported.

## Developing Saci

```sh
shards install
crystal spec                                   # full suite (SQLite)
CRYSTAL_WORKERS=4 crystal spec -Dexecution_context
crystal tool format --check src spec
live/run.sh                                    # live PostgreSQL + MySQL harness
```

Specs that need Redis, PostgreSQL or MySQL are skipped unless
`REDIS_URL`, `PG_URL` or `MYSQL_URL` is set. See
[`live/README.md`](live/README.md) for the live database harness,
[ROADMAP.md](ROADMAP.md) for planned work and
[CHANGELOG.md](CHANGELOG.md) for release notes.

Source layout: `src/saci.cr` requires everything. Each subsystem lives in
`src/saci/<name>.cr`, with larger ones in a matching directory
(`record/`, `cli/`, `storage/`, `mailer/`, `mailbox/`, `graphql/`,
`office/`, `testing/`, `support/`, `middleware/`, `deploy/`). Specs
mirror that layout under `spec/`.

## License

MIT
