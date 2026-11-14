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

class PostsController < Controller
  def index
    render json: Post.where(published: true).order(created_at: :desc).limit(20).to_a
  end
end

router = Router.new.draw do |r|
  r.resources "posts", PostsController, only: [:index]
end

Application.new(router).listen(3000)
```

- [What's included](#whats-included)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Framework names](#framework-names)
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
  src/jobs/ src/mailers/ src/channels/  # ApplicationJob, ApplicationMailer, ApplicationChannel
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

## Framework names

Framework types live in the `Saci` module, and `require "saci"` includes
that module at the top level, so app code uses them without the prefix.
Module methods keep it, like `Rails.logger`:

```crystal
class Post < Record::Base                      # Saci::Record::Base
end

class PostsController < Controller             # Saci::Controller
  rescue_from Record::RecordNotFound do |_ex|
    Saci.logger.warn { "not found" }
    head :not_found
  end
end
```

Names your app defines at the top level win over Saci's: an app `Session`
model stays the app's, and `Time` and `DB` are always the stdlib and
crystal-db ones. The full `Saci::` path always works. Compile with
`-Dsaci_namespaced` to skip the include and keep every framework type
behind `Saci::`.

Generated apps follow Rails: the prefix appears once per kind, in the base
classes (`ApplicationRecord < Saci::Record::Base`, `ApplicationController`,
`ApplicationJob`, `ApplicationMailer`, `ApplicationChannel`), and in the
files under `config/`, `spec/spec_helper.cr` and `db/migrate.cr`. Those
files then still compile if the app adds a model named like a framework
type, such as `Session` or `Job`. Generated models, controllers, jobs,
mailers, channels, migrations, specs and routes use the short names.

## CLI

```sh
saci new NAME [--db=sqlite|postgres|mysql] [--devcontainer] [--saci-path PATH] [--skip-git] [--skip-shards]
saci generate KIND NAME [fields...] [--pretend] [--force]
saci destroy KIND NAME
saci serve [--port 3000] [--host] [--watch] [--mt [--workers N]] [-- crystal flags]
saci test [spec paths] [-- crystal flags]
saci routes [--grep PATTERN] [--boot [-- crystal flags]]
saci runner -e CODE | saci runner FILE [args]
saci console [-e CODE]
saci db:migrate [--all] | db:rollback [STEPS] [--all] | db:seed
saci db:prepare | db:setup | db:reset | db:create | db:drop | db:version | db:migrate:status
saci db:schema:dump [--all] | db:schema:load | db:schema:check [--all]
saci credentials:show | credentials:edit | credentials:keygen
saci credentials:get KEY | credentials:set KEY VALUE|--stdin | credentials:unset KEY
saci assets:precompile [--source DIR] [--output DIR] | assets:clobber
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
  prints `VERB PATH -> Controller#action`. Routes drawn in loops or
  helper methods are invisible to that parse; `routes --boot` compiles
  the app and prints the router it actually builds (it sets
  `SACI_ROUTES_DUMP`, so the app prints its routes and exits before
  binding a port).
- When the port is taken, `serve` (before compiling) and
  `Application#listen` move on to the next free port and print which one
  they picked, instead of raising `Address already in use`.
- `saci new` depends on Saci from GitHub (`version: ~> X.Y.Z`), so the app
  builds on any machine and in Docker. `--saci-path PATH` uses a local
  checkout (`path:`) instead.
- `credentials:set` writes one dotted key without an editor
  (`saci credentials:set admin.password --stdin < secret.txt`), which
  works in scripts and CI. `credentials:get` prints one value;
  `credentials:unset` removes it.
- `assets:precompile` copies `src/assets` into `public/assets` with
  SHA-256 fingerprints plus a manifest, so `asset_path` returns digested
  URLs. `assets:clobber` removes only what it wrote.
- `runner` and `console` compile a temporary wrapper under `tmp/` with
  models, initializers and the database connection loaded. Crystal has
  no runtime eval, so `console` recompiles on every line. Put multi-line
  code in a file.
- `serve --watch` polls the source tree, rebuilds with `crystal build` and
  restarts a single supervised binary. Build failures wait for the next
  save. Path dependencies (such as a local Saci checkout) are watched too.
- Every command that compiles (`serve`, `test`, `runner`, `console`,
  `routes --boot`, `db:*`) shows a progress line while the compiler runs
  (`⠹ Compiling app… 4.2s`, then `✓ Compiled app in 11.8s`) and prints
  the compiler's warnings or errors after it. The animation only runs on
  a terminal; pipes and CI get two plain lines. `SACI_SPINNER=0` turns it
  off, `SACI_SPINNER=1` forces it.
- `ci` runs the steps declared in `config/ci.cr` with `CI.step` and
  `CI.run`. `app:update` re-applies the scaffold, prompting before
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
  config.middleware.insert_before Middleware::Static, RequestId.new
  config.middleware.delete Middleware::HostAuthorization
end
```

A middleware is a plain `HTTP::Handler`. Built-in handlers can be disabled
at runtime and still work as `insert_before` / `insert_after` / `swap`
targets. `saci middleware` prints the resolved chain.

Boot hooks:

```crystal
Initializers.before_configuration { Saci.log_level = :debug }
Initializers.to_prepare { }          # re-run on reload; keep it idempotent
Initializers.after_initialize { }    # once, after configuration
```

Generated apps load `config/initializers/*.cr` and
`config/environments/<APP_ENV>.cr`. Declarative YAML lives in `config/`
(`database.yml`, `cache.yml`, `queue.yml`, `cable.yml`, `storage.yml`,
`server.yml`). ERB-style `<%= ENV["X"] %>` tags in those files are
interpolated before parsing. Read them with
`Saci.config_for(:name)`.

## Routing

```crystal
router = Router.new.draw do |r|
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
Routes.define AppRoutes do |r|
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
  rescue_from Record::RecordNotFound do |_ex|
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
class CreatePosts < Record::Migration
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
- **Full-text search**: `Record::FTS.setup(Post, [:title, :body])`
  creates an FTS5 virtual table with triggers.
  `Post.search_fts("crystal")` returns a ranked, chainable query (SQLite
  only).

## Databases

```crystal
Record.connect("sqlite3://./db/app.db")      # adapter detected from the scheme
Record.establish_connection("analytics", "postgres://localhost/analytics")

class Event < ApplicationRecord
  connects_to database: "analytics"
end

Record.connected_to("analytics") { Event.count }
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

Every model registers itself, so `Record.check_schema!(db)` can
return one warning per mismatch: a table without a model, a model without
a table, or a column missing on either side. Only names are compared.

## Views

```crystal
class PostsController < ApplicationController
  def show
    @post = Post.find(params["id"])
    render_template :show            # src/views/posts/show.ecr inside layouts/application.ecr
  end

  def feed
    render_template "shared/feed"    # a name with a slash is a path from src/views/
  end
end
```

```erb
<h1><%= h(@post.title) %></h1>
<%= render_partial("comments/comment", collection: @post.comments.to_a) %>
<%= cache(cache_key(@post)) { render_partial("posts/sidebar", post: @post) } %>
<% form_with("/posts/#{@post.id}", method: :patch, model: @post, scope: "post") do |f| %>
  <%= f.error_messages %>
  <label>Title <%= f.text_field("title") %></label>
  <%= f.submit %>
<% end %>
<%= link_to("Delete", path_for(:post, @post.id), method: :delete) %>
```

- `form_with` with an ECR block uses `<% %>`, not `<%= %>` (ECR has no
  block output tag), and writes the form into the page. A block that
  returns the fields as a String works with `<%= %>`:
  `<%= form_with("/search", method: :get) { |f| f.text_field("q") } %>`.

- `<%= %>` does **not** escape. Use `h()` for user input. Helpers that
  build HTML escape their own arguments.
- Layouts use `<%= content %>`. `render_template(:x, layout: false)`
  renders without a layout.
- `content_for` and `capture` take ECR blocks, so markup inside them goes
  to the slot instead of the page:

  ```erb
  <% content_for(:head) do %>
    <link rel="preload" href="/fonts/inter.woff2" as="font" crossorigin>
  <% end %>
  ```

  The layout prints it with `<%= content_for(:head) %>`.
- Partials have **no** leading underscore: `render_partial("shared/header")`
  reads `src/views/shared/header.ecr` (Rails would look for `_header`).
- Forms: `form_with`, `fields_for`, `collection_select`, the `*_tag`
  helpers, HTML5 input types, CSRF tokens, and `_method` overrides.
  `link_to(..., method: :delete)` renders a small form, so it works
  without JavaScript.
- Text and number helpers: `truncate`, `simple_format`, `sanitize`,
  `strip_tags`, `highlight`, `pluralize`, `number_to_currency`,
  `number_with_delimiter`, `distance_of_time_in_words`, `markdown`
  (escape-first), `page_numbers`, `rss_feed`, `tag`, `content_tag`,
  `button_to`, `mail_to`.
- Assets live in `src/assets`. In development and test,
  `Middleware::DevAssets` serves them under `/assets/` with
  `Cache-Control: no-cache`, so edits show up on reload. For production,
  `saci assets:precompile` (run by the generated Dockerfile) writes
  fingerprinted copies to `public/assets`. `asset_path`,
  `stylesheet_link_tag`, `javascript_include_tag` and `image_tag` resolve
  through its manifest and fall back to `/assets/...` without one.
  Fingerprinted files are served `public, max-age=31536000, immutable`;
  other static files get `no-cache` in development and test and
  `public, max-age=3600` elsewhere unless you set
  `config.public_file_server.cache_control`.
- Pagination: `Pagination.paginate(query, page:, per_page:)` returns
  a page object, and `paginate_nav` renders windowed links. Its labels come
  from I18n: `saci.pagination.prev`, `saci.pagination.next`,
  `saci.pagination.gap` and `saci.pagination.label` (the `aria-label`).

## Frontend: Turbo, Stimulus, importmap

```crystal
turbo_frame_tag("profile") { "<p>Ada</p>" }
render turbo_stream: Turbo.append("msgs", "<p>#{h(text)}</p>")
Turbo.broadcast_append("room:1", "msgs", "<p>hi</p>")    # over Cable

Importmap.draw do |map|
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
class ChatChannel < ApplicationChannel
  def subscribed
    stream_from "room:#{params["room"]?.try(&.as_s?) || "lobby"}"
  end

  def receive(data)
    Cable.broadcast("room:1", {text: data["text"]?})
  end
end

Cable.identify do |connection|
  connection.reject_unauthorized_connection unless connection.session.try(&.["user_id"])
end

router = Router.new.draw do |r|
  r.cable "/cable", ChatChannel
end
```

- The wire protocol is compatible with ActionCable clients. Channels also
  support `stream_for record`, `periodically 5.seconds { }`, `transmit`,
  `reject`, and `identified_by`.
- Fan-out uses a single process by default. For several processes, set
  `Cable.server` to `Cable::RedisServer.new(ENV["REDIS_URL"])`
  (built-in RESP2 client, no extra dependency) or to `Cable::DbServer`
  (database polling, Solid Cable style). If Redis is down, broadcasts
  still reach local subscribers.
- On PostgreSQL, `Cable::PostgresServer.new(db, listen_notify: true,
  listen_url: ENV["DATABASE_URL"])` replaces polling with
  `LISTEN/NOTIFY`: peers fetch a broadcast as soon as it commits, and a
  5-second poll remains as a safety net. It needs `require "pg"` and
  `require "saci/cable_pg"` in the app, plus a direct connection
  (PgBouncer in transaction mode does not support `LISTEN`).
- Writes go through a shared pool of writer fibers with bounded
  per-connection queues, so idle sockets stay cheap and slow readers get
  disconnected instead of piling up memory.
- `Cable::TestClient` and `Cable::TestServer` support specs, and
  `saci g channel` generates both.

## Background jobs

```crystal
class WelcomeJob < ApplicationJob
  queue_as :mailers
  queue_with_priority 10
  unique :until_executed
  retry_on IO::Error, attempts: 3, wait: :exponential
  discard_on Record::RecordNotFound

  def perform(payload : JSON::Any) : Nil
    UserMailer.welcome(payload["email"].as_s).deliver_now
  end
end

Job.queue_adapter = :db
WelcomeJob.perform_later({email: "a@b.c"})
WelcomeJob.set(wait: 5.minutes, queue: :low).perform_later({email: "a@b.c"})
```

- Adapters: `:async` (fiber, the development default), `:inline`,
  `:test` (records jobs instead of running them), and `:db` (durable,
  persisted in `saci_jobs` with a dead-letter table and claims via
  `FOR UPDATE SKIP LOCKED`). Run `Job::Db.work_once` in a worker
  loop or `drain` from scripts.
- Payloads cross a JSON boundary. Records are serialized as GlobalID
  references. Delivery is at-least-once, so jobs must be idempotent.
- Also available: callbacks and middleware, `limits_concurrency`, batches
  (`Job::Batch`), and resumable jobs (`continuable` + `step`).
- Recurring jobs:
  `Recurring.cron("*/5 * * * *", "refresh") { RefreshJob.perform_later({}) }`
  and `Recurring.every(1.hour, "cleanup") { ... }`, then
  `Recurring.start`. Missed ticks collapse into a single run.
- Dashboard: mount `Job::DashboardController` to see pending and
  dead jobs, with retry and drop actions. It is disabled in production by
  default.

## Mailers

```crystal
class UserMailer < ApplicationMailer
  default_from "noreply@example.com"
  layout "mailer"

  def self.welcome(email : String) : Mailer::Mail
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
- Previews: register them with `Mailer::Preview.register` and mount
  `PreviewController` (development only). Non-ASCII subjects are
  RFC 2047-encoded on the wire.

## Inbound email

```crystal
class SupportMailbox < Mailbox::Base
  def process
    Ticket.create!(subject: mail.subject, body: mail.text_body)
  end
end

Mailbox.router = Mailbox::Router.new.draw do |r|
  r.route SupportMailbox, to: "support@example.com"
  r.route all: :backup
end

router = Router.new.draw { |r| Mailbox.mount(r) }
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
user.photo.attach(io, filename: "a.png", public: true)  # unsigned public/ key

r.get "/files/*key", Storage::FilesController, :show
r.post "/direct_uploads", Storage::DirectUploadsController, :create
```

- `DiskService` stores files under sharded keys. Private files are served
  through expiring HMAC-signed URLs. Signing keys can be rotated: old URLs
  keep working until they expire. A `public/` key prefix is served
  without signatures. `DiskService.new(public: true)` makes that the
  default for every upload to the service; `attach(..., public:)` overrides
  it per file. Variants keep their original's visibility.
- `S3Service` works with AWS, MinIO, R2 and other S3-compatible stores,
  using its own SigV4 signer. `MirrorService` writes to several services
  at once.
- Blobs have checksums and metadata. Image dimensions come from a
  pure-Crystal analyzer.
- Variants and previews need a processor. Without one they return the
  original file. Two are bundled. They run the command-line tools, so
  nothing extra is linked into the app:

  ```crystal
  Storage.variant_processor = Storage::Processors::Vips.new        # apt install libvips-tools
  Storage.variant_processor = Storage::Processors::ImageMagick.new # apt install imagemagick
  Storage.variant_processor = Storage::Processors.detect           # whichever is installed

  user.avatar.variant(resize_to_limit: [300, 300]).url
  user.avatar.variant(resize_to_fill: [64, 64], format: "webp", quality: 80).url
  doc.file.preview(resize_to_limit: [400, 400]).url  # PDF page 1 (poppler-utils), video frame 1 (ffmpeg)
  ```

  `resize_to_limit` only shrinks, `resize_to_fit` also enlarges, and
  `resize_to_fill` crops to the exact size. The other options are
  `format:` (png, jpeg, gif, webp, avif), `quality:` and `strip: true`.
  A variant is processed on first use and stored under a key derived
  from the original and the options, so later requests reuse it.
  `purge` deletes the variants along with the original. Inputs must be
  PNG, JPEG, GIF or WebP, detected from the bytes. Images over 50
  megapixels are refused, and each command is killed after 30 seconds
  (`max_pixels:` and `timeout:` change both). Animated GIFs keep only
  their first frame. A custom processor subclasses
  `Storage::Variant::Processor`.
- Uploads with content types that browsers execute are rejected by
  default, and upload size is capped.

## Caching

```crystal
Cache.fetch("stats", expires_in: 5.minutes) { compute_stats }
Cache.store = Cache::RedisStore.new(ENV["REDIS_URL"])
Cache.store = :db                         # database-backed store (Solid Cache style)

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
- `PageCache` writes whole pages to disk.

## Rate limiting

```crystal
Throttle.throttle("logins/ip", limit: 5, period: 1.minute) do |ctx|
  ctx.request.path == "/login" ? Throttle.client_ip(ctx) : nil
end
Throttle.safelist { |ctx| Throttle.client_ip(ctx) == "127.0.0.1" }
Throttle.store = Throttle::RedisStore.new(ENV["REDIS_URL"])
```

Fixed windows. Throttled requests get 429 with `Retry-After`; blocklisted
requests get 403. If the store is unreachable, requests are allowed and a
warning is logged. In controllers, `rate_limit to:, within:` uses the
same store.

`client_ip` is the address `Middleware::RemoteIp` resolved. It never reads
`X-Forwarded-For` itself, because clients can send any value there. Behind
a proxy or CDN, list its addresses in `config.trusted_proxies` (generated
apps trust private networks in `config/initializers/trusted_proxies.cr`;
add your CDN's published ranges there). Otherwise every request is keyed
on the proxy's address.

## Security

```crystal
class ApplicationController < Controller
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
  in constant time. The cookie is only set when a page asks for a token
  (`form_authenticity_token`, forms, `csrf_meta_tags`), so plain GETs stay
  cookie-free and cacheable. It is always `HttpOnly`, and `Secure` on
  HTTPS requests or with `force_ssl` / `assume_ssl`.
- **Headers**: secure defaults (`X-Frame-Options`, `nosniff`,
  `Referrer-Policy`, CSP `default-src 'self'`), CSP nonces
  (`content_security_policy_nonce`), Permissions-Policy, and HSTS. Change
  them per action with `csp` / `skip_csp`. Generated apps keep the policy
  in `config/initializers/content_security_policy.cr`.
- **CSP warnings**: in development, each HTML response is checked against
  its policy, and anything the browser would block (inline `<style>`,
  `style=""` attributes, `on*` handlers, stylesheets, scripts, images or
  fonts from other hosts, such as Google Fonts) is logged once per path.
  Toggle with `SecureHeaders.csp_warnings = true|false`.
- **CSP nonces and HTTP caching**: a nonce changes on every response. A
  `304` from `stale?` carries the new nonce in its header, but the browser
  reuses the cached body with the old one, so nonced styles and scripts
  stop applying. On pages you cache with ETags, use external files under
  `'self'` instead of nonces.
- **Errors**: error pages render the app's `public/<status>.html` (the
  generated 404, 422 and 500 pages) when it exists. Unknown routes answer
  browsers with that page and API clients with a JSON body; in production
  the exceptions app answers non-HTML clients with plain text instead.
- **HTTP basic auth**: `http_basic_authenticate_with credentials: "admin"`
  reads `admin.name` (or `admin.user`) and `admin.password` from encrypted
  credentials, and nil or empty values deny every request instead of
  opening the action.
- **Sessions and cookies**: `session`, `flash`, `cookies.signed` and
  `cookies.encrypted` (AES-256-GCM). Signing keys can be rotated. Session
  stores: cookie (the default), memory, cache, or database.
- **Authentication helpers**: `login(user)` resets the session first to
  prevent fixation. Also `logout`, `current_user`
  (`memoize_current_user User`), `require_login`,
  `allow_unauthenticated_access`, and `after_authentication_url`.
  `saci g authentication` generates a complete flow with password
  resets.
- **Tokens**: `JWT` (HS256/384/512), `TOTP` (codes,
  provisioning URIs, backup codes), and `has_two_factor` for models.
- **Secrets**: `SECRET_KEY_BASE` or encrypted credentials. Production
  refuses to boot without a secret.

Saci vendors a small AES-GCM binding and pure-Crystal digests. On systems
with OpenSSL ≥ 3.2, the stdlib `OpenSSL::Cipher` and `Digest` modules
fail to link because they reference symbols that were removed.

## Authorization, serializers, search, audit

```crystal
class PostPolicy < Policy
  resource Post
  allow :read
  role :editor do
    can :update, Post
  end
  scope { scope.where(status: "published") }
end

authorize!(:update, post)                      # in a controller
policy_scope(Post)

class PostSerializer < Serializer(Post)
  attributes :id, :title
  has_many :comments, serializer: CommentSerializer
end
render json: PostSerializer.new(post, root: "post", key_transform: :camel)

class Post < ApplicationRecord
  searchable_attributes :title, :status, :created_at
  include Auditable
  audited only: [:title, :status]
end
Post.search(params).page                       # Ransack-style q[title_cont]=...
post.audits
```

## GraphQL

```crystal
class PostType < GraphQL::ObjectType
  source Post
  field :id, GraphQL::ID, null: false
  field :title, String
end

class QueryType < GraphQL::ObjectType
  graphql_name "Query"
  field :posts, [PostType], null: false do |_source, _args, _ctx|
    Post.order(id: :asc).to_a
  end
end

class AppSchema < GraphQL::Schema
  query QueryType
end

GraphQL.mount(router, path: "/graphql", schema: AppSchema)
```

Supports queries, mutations, input objects, enums, variables, fragments,
introspection, batched requests and GraphiQL. Types are compile-time
classes and resolvers are typed blocks.

## Spreadsheets, PDF and CSV

```crystal
require "saci/office"

xlsx = Office::XLSX.from_records(User.all, columns: [:id, :email, :created_at])
send_xlsx xlsx, filename: "users.xlsx"

pdf = Office::PDF.table(title: "Users", headers: ["Name", "Email"], rows: rows)
send_pdf pdf, filename: "users.pdf"

send_csv rows, filename: "users.csv"
```

XLSX is written as a ZIP package using the stdlib DEFLATE implementation.
PDFs use the standard Helvetica fonts. CSV follows RFC 4180.

## Localization and time zones

```crystal
I18n.load_path << "config/locales/*.yml"
I18n.t("greeting", name: "Ada")
I18n.t("items", count: 3)
I18n.with_locale(:es) { I18n.t("hello") }
I18n.l(Time.utc, format: :short)

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

r.get "/metrics", Metrics::Controller, :index    # JSON, or Prometheus with ?format=prom
```

Every request logs one line with the status, duration, method, path,
filtered params and request id, and every SQL statement logs one line
with its duration (source `saci.sql`; turn it off with
`Saci.log_queries = false` or `SACI_LOG_QUERIES=0`). Text lines start with
the local time as `2026/11/14 03:15:02.494236` and are colored on a
terminal (`NO_COLOR` or `SACI_LOG_COLOR=0` disables, `SACI_LOG_COLOR=1`
forces). Set `SACI_LOG_FORMAT=json` for structured output, or
`SACI_LOG_SETUP=0` to keep Crystal's default log backend. `Notifications` publishes instrumentation events
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
  `Credentials.dig("aws.access_key")` and edit them with
  `saci credentials:edit`, or one key at a time with
  `saci credentials:set` (no editor needed).
- `saci new` generates a multi-stage Dockerfile, `bin/docker-entrypoint`,
  a Kamal 2 configuration (`config/deploy.yml`, `.kamal/secrets`), a
  GitHub Actions workflow, `config/server.yml`, public error pages and an
  optional devcontainer. `bin/thrust` documents the proxy setup; Saci
  does not bundle an HTTP/2 proxy.
- The generated image builds on the same Ubuntu release as the Crystal
  image (so the binaries find their glibc), precompiles assets, runs as a
  non-root `saci` user and reads `RAILS_MASTER_KEY`. `config/deploy.yml`
  declares named volumes for `storage/` (and `db/` on SQLite) and notes
  `forward_headers: true` for proxies such as Cloudflare. See the
  generated README for `docker run`.
- `app.listen_gracefully(port, host, shutdown: Deploy::GracefulShutdown.new(timeout: 10.seconds))`
  waits for in-flight requests on SIGTERM. `Deploy.doctor` checks
  the secret, the database URL and writable directories.

## Testing

```crystal
require "saci/testing"

load_fixtures :all
fixture :users, User

factory :post, Post do
  title { "Post #{Testing::Factory.sequence(:post)}" }
end

describe "posts" do
  transactional_tests

  it "publishes" do
    post = Testing::Factory.create_post
    assert_enqueued_jobs(1) { PublishJob.perform_later({id: post.id}) }
    travel_to(Time.utc(2026, 1, 1)) { Time.utc.year.should eq(2026) }
  end

  it "renders the index" do
    TestSession.serve(router) do |app|
      response = app.get("/posts")
      assert_select response, "h1", text: "Posts"
    end
  end
end
```

- `TestSession.serve(router)` starts the full middleware and
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
