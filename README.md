# Saci

A Rails-compatible (Rails-like API) web framework in Crystal. Familiar MVC
conventions and directory-free single-shard design, implemented idiomatically
on top of Crystal's `HTTP::Server`.

**Status: 0.2.0** — Router + Controller, ORM (SQLite/PostgreSQL/MySQL),
CLI, Cable, I18n, security, jobs, mailers, views, caching, throttle,
storage, credentials, multidb, FTS5, page-cache — proven by two validation
apps: Forem Lite (87 specs) and Claw, a Lobsters port (357 specs).

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
saci new blog --db=sqlite            # or --db=postgres|mysql (driver deps + require + URL defaults)
cd blog
saci generate model Post title:string views:integer published:boolean
saci generate controller Posts index show
saci generate admin Post title:string published:boolean  # admin namespace scaffold (search/sort/pagination + specs)
saci generate migration AddBioToUsers bio:text
saci generate migration AddIndexToFollows follower_id --unique  # -> add_index
saci db:migrate [--all]              # --all migrates primary + named DBs
saci db:rollback                     # rolls back the last migration
saci db:schema:dump [--all]          # write db/schema.cr snapshot (all DBs with --all)
saci db:schema:load                  # recreate schema from db/schema.cr
saci db:schema:check [--all]         # warn when DB and models disagree
saci serve --port 3000
saci routes                          # VERB PATH -> Controller#action (no boot)
saci runner -e 'puts Post.count'     # or: saci runner script.cr (app context, no boot)
saci console [-e CODE]               # minimal console (per-line compile; `exit` quits)
saci db:seed                         # run db/seed.cr (or db/seeds.cr) in app context
```

- `new [--db=...]` scaffolds `shard.yml` (path-dependency on the framework source),
  `src/<app>.cr` entrypoint, controllers/models dirs, `db/migrate/` +
  `db/migrations.cr` manifest + standalone `db/migrate.cr` runner, and specs.
  `--db=postgres|mysql` emits driver deps (`will/crystal-pg` / `crystal-mysql`),
  `require "pg"` / `require "mysql"` lines and URL defaults (SQLite stays default).
- Generators write files and print next steps (routes to add). The migration
  generator rebuilds `db/migrations.cr` from `db/migrate/*.cr`, so hand-added
  migration files are picked up too. `AddIndex...` names (or `--unique`) emit
  `add_index` instead of `add_column`; `g controller` request specs use real
  verbs (create->POST, update->PATCH, destroy->DELETE); `g admin` writes a
  namespaced `Admin::` controller (search on string columns, sortable
  headers, `Saci::Pagination.paginate` + `paginate_nav` views, deny-by-default
  `require_admin`) plus a namespace route hint — reruns overwrite.
- `serve` execs `crystal run src/<app>.cr` with `PORT`/`HOST` set; anything
  after `--` is forwarded to `crystal` as compiler flags
  (e.g. `--link-flags=...`).
- `db:migrate [--all]` / `db:rollback [STEPS] [--all]` re-sync the manifest, then run the
  standalone runner (models only — the web server is never booted). `--all`
  migrates every database in `Saci::Record.configuration_names`; specs use
  `Saci::Record.clean_all!` to truncate all connections (single-DB apps keep
  `clean_database!`). After every migrate/rollback the runner prints schema
  drift warnings to STDERR (see `db:schema:check` below) — warnings only,
  the migrate itself never fails on drift.
- `db:schema:dump [--all]` writes a standalone runnable `db/schema.cr`
  snapshot (Rails `schema.rb` equivalent, portable across SQLite /
  PostgreSQL / MySQL — see below); `saci db:schema:load` replays it with
  `crystal run`. `--all` dumps primary + named DBs (registered via
  `DATABASE_URL_<NAME>` env vars) into per-database sections.
- `db:schema:check [--all]` compares the database against the registered
  models and prints one line per mismatch (table/columns missing on either
  side). Exits 1 when drift is found, 0 when clean — gate it in CI.
  `--all` checks primary + all named DBs.
- Routes support static prefix/suffix params anywhere in a segment:
  `/~:username`, `/@:username` (redirect to `/~%{username}`), `/avatars/:username_size.png`.
- `routes` statically parses `src/routes.cr` when present, otherwise the
  `src/<app>.cr` entrypoint (where `saci new` draws routes inline), and
  prints `VERB PATH -> Controller#action` without booting the server
  (`resources` expands to the 8 member/collection routes; per-route
  `constraints:` shows as `[constraints]`; block routes as `(block)`).
- `runner -e CODE` / `runner FILE [args] [-- crystal flags]` compiles a
  temp wrapper under `tmp/` (deleted after) that loads models/controllers
  and connects the DB, then runs the code — the Rails runner equivalent
  for seeds and ops scripts (server never booted; extra args become ARGV).
- `console` with no args loops on stdin, compiling and running each line
  in app context (`exit` quits); with `-e CODE`/FILE it is exactly
  `runner`. Crystal has no runtime eval, so loop mode recompiles per line
  (slow but real) and multi-line definitions belong in a file instead.
- `db:seed` runs `db/seed.cr` (or `db/seeds.cr`) through the same runner
  mechanism; `saci new` scaffolds a commented `db/seed.cr` starter. With
  no seed file it prints the conventional template and exits 1.

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
  column score : Decimal
  column posted_on : Date
  column meta : JSON
  timestamps

  validates :title, presence: true, max_length: 200
  validates :email, format: /@/, uniqueness: true
  validates :score, numericality: {greater_than_or_equal_to: 0}
  validates :kind, inclusion: {in: ["a", "b"]}, allow_nil: true
  validates :title, presence: true, if: :published?
  validate :title_is_fine, unless: ->(r : Post) { r.views == 0 }

  belongs_to :user, counter_cache: true, touch: true
  belongs_to :notifiable, polymorphic: true   # notifiable_type + notifiable_id
  has_many :taggings, dependent: :destroy
  has_many :tags, through: :taggings
  has_many :notifications, as: :notifiable    # polymorphic has_many
  has_one :moderation, dependent: :restrict_with_exception

  belongs_to :user, counter_cache: true, touch: true
  has_many :taggings, dependent: :destroy
  has_many :tags, through: :taggings
  has_one :moderation

  before_validation :strip_title, on: :create
  before_save :normalize
  after_create :notify
  after_commit :rebuild_cache, on: :create
  after_destroy :cleanup

  def title_is_fine
    errors.add(:title, "is bad") if title == "bad"
  end
end

post = Post.create!(title: "Hi")          # raises RecordInvalid when invalid
post.update(views: 10)
post.update_columns(views: 11)            # skips validations + callbacks
post.touch                                # bumps updated_at, skips validations
post.destroy                              # runs dependents, then callbacks
Post.find(1)                              # raises RecordNotFound when missing
Post.find_by(title: "Hi")
Post.where(published: true).where("views > ?", 5)
    .order(views: :desc).limit(10).offset(5).to_a
Post.where(created_at: 1.day.ago..Time.utc).to_a   # Range where
Post.where(a: 1).or(Post.where(b: 2)).to_a         # or
Post.where.not(published: true).to_a               # hash negation
Post.joins("INNER JOIN users ON users.id = posts.user_id").to_a
Post.joins(:user).where("users.email = ?", "a@b").to_a  # symbol joins via FK
Post.includes(:user, :tags).to_a                   # preload (no N+1)
Post.includes(story: :user).to_a                   # nested preload, 2 levels
Post.select(:id, :title).to_a                      # partial models
Post.select("title", "views + 1 AS more").first!.read_attribute("more")
Post.distinct.pluck(:title)
Post.group(:published).count                        # => {true => 2, ...}
Post.sum(:views) / Post.average(:views) / Post.minimum(:views)
Post.count / Post.exists?(published: true) / Post.pluck(:title)
Post.where(published: false).update_all({published: true})
Post.upsert({id: 1, title: "Hi"})                  # skips validations/callbacks
Post.update_counter(1, :views)                     # atomic COALESCE + delta
Post.reset_counters(1, :comments)                  # recount counter_cache
Post.where(published: true).touch_all              # bump updated_at, no callbacks
Saci::Pagination.paginate(Post.where(published: true).order(created_at: :desc), page: 1, per_page: 25)
Saci::Record::FTS.setup(Post, [:title, :body])     # SQLite FTS5 index + triggers
Post.search_fts("crystal").where(published: true).limit(10).to_a  # rank-ordered
user.posts.where(published: true).to_a    # has_many returns a chainable Query
Saci::Record.transaction { ... }          # raise DB::Rollback to roll back
```

Notes:

- Table names are inferred (`SpecUser` → `spec_users`, `Shelf` →
  `shelves`); override with `table "custom"`. Column types:
  `Int32/Int64/Float64/String/Bool/Time/Bytes` (all nilable) plus logical
  `Decimal` (Float64-backed), `Date` (Time-backed) and `JSON`
  (String-backed, with `<col>_json` / `<col>_json=` helpers);
  `timestamps` maintains `created_at/updated_at`. Migrations add
  `t.decimal` / `t.date` / `t.json`.
- Validations: `presence`, `length:` (`minimum:`/`maximum:`/`in:`/`within:`),
  `format:`, `uniqueness:` (`true`, `:scope`, `[:scopes]`,
  `{scope:, case_sensitive: false}` — `COLLATE NOCASE` on SQLite,
  `LOWER()` elsewhere), `inclusion: {in: [...]}`, `numericality:`
  (`only_integer:`, `greater_than[_or_equal_to]:`,
  `less_than[_or_equal_to]:`, `equal_to:`), custom `validate :method` /
  `validate { }`, `allow_nil:` / `allow_blank:`, `on: :create`/`:update`,
  plus `if:`/`unless:` (method-name Symbol or `->(r) { }` Proc) on both
  `validates` and `validate`.
- Callbacks (`previous_def`-chained, parents first): `before_validation`
  (with `on:`), `before_save`, `after_save`, `after_create`,
  `after_commit` (with `on:`, deferred to the outermost transaction commit
  and discarded on rollback), `after_destroy`. Each takes method names,
  lambdas (`-> { }`) and/or a block (`|record|` optional).
- Queries: base-table columns render qualified (`"posts"."id"`) so `joins`
  never ambiguates; `joins(:assoc)` resolves the FK alongside raw-SQL
  `joins("...")`; `select` symbols give partial models while raw
  expressions land in `read_attribute`/`#[]`; `includes` preloads
  `belongs_to`/`has_many`/`has_one` (`has_many :through` raises — preload
  the join instead) plus nested `includes(a: :b)` to 2 levels (grouped by
  concrete class, so polymorphic parents work); `touch`/`update_columns`/
  `upsert`/`touch_all` skip validations and callbacks; `belongs_to`
  supports `counter_cache:` / `touch:` plus `polymorphic: true`
  (`<name>_type` + `<name>_id` via the polymorphic registry) with
  `has_many ..., as: :interface`; `has_many` /
  `has_one` support `dependent: :destroy`/`:delete_all`/`:nullify`/
  `:restrict_with_exception` (`DeleteRestrictionError`); counters polish:
  `update_counter`/`update_counters`/`reset_counters`/`touch_all`.
- `change`-style migrations roll back automatically (`create_table`,
  `add_column`, `add_index`, `add_foreign_key`, `rename_table`,
  `rename_column`); `drop_table`/`remove_column`/`remove_index`/
  `remove_foreign_key`/`change_column` inside `change` raise
  `IrreversibleMigration` on rollback — use `up`/`down`.
- Foreign keys: `t.references :user, foreign_key: true` (bigint `user_id` +
  index + `REFERENCES users(id)`; `foreign_key:` defaults to `false` —
  unlike Rails 5+, Saci never adds a constraint you did not ask for) or
  `t.foreign_key :users, column: :user_id, on_delete: :cascade` inside
  `create_table` (the only form SQLite parses — FKs are CREATE-time clauses
  there, so standalone `add_foreign_key` raises on SQLite and table rebuilds
  are out of scope). `add_foreign_key :stories, :users, on_delete:
  :cascade`/`:nullify`/`:restrict` uses the same `ADD CONSTRAINT` syntax on
  PostgreSQL and MySQL (InnoDB assumed); `rename_table`/`rename_column` work
  on all three adapters, while `change_column` is PostgreSQL (`ALTER COLUMN
  TYPE ... USING`) / MySQL (`MODIFY COLUMN`) only.
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

## Schema snapshots (`schema.rb` equivalent)

```sh
saci db:schema:dump [--all]   # write db/schema.cr (all DBs with --all)
saci db:schema:load           # recreate tables + indexes from db/schema.cr
```

`db/schema.cr` is a standalone runnable (`crystal run db/schema.cr`):
it connects via `DATABASE_URL`-or-default (the same default expression
as your `db/migrate.cr`, so it tracks `APP_ENV` too) and calls
`Saci::Record::Schema.load` with an embedded snapshot. The snapshot is
*data* (column/index definitions) plus a loader call — never raw SQL —
so one `schema.cr` loads on SQLite, PostgreSQL and MySQL through
adapter-aware DDL. `saci new` scaffolds nothing for this (the file is
generated output).

Table choice: every table is dumped EXCEPT `schema_migrations`
(rebuilt by the Migrator on each database) and SQLite internals.
Durable queue tables (`saci_jobs`, `saci_dead_jobs`) ARE included so a
schema-loaded database boots queue workers without extra steps.

Two normalizations to know:

- `t.timestamps` is detected (`created_at` + `updated_at`, both
  NOT NULL without defaults) and re-emitted as a pair on load.
- SQLite shares storage across logical types, so BOOLEAN / DATE /
  DATETIME / JSON reload as `:integer` / `:text` and DECIMAL / BIGINT
  as `:float` / `:integer` (likewise `:decimal` reads back as `:float`
  on PostgreSQL/MySQL, where the forward map itself stores doubles).
  Re-dumping a loaded database is byte-stable. Defaults that cannot
  round-trip exactly are normalized to no default and reported as
  `# NOTE:` lines in the generated file.

Multidb: with `--all`, the dump runner also snapshots every database
registered through `DATABASE_URL_<NAME>` env vars (plus primary) into
per-database sections; loading re-establishes each one the same way.

Programmatic API: `Saci::Record::Schema.introspect(db)` (canonical
`TableInfo` list), `Saci::Record::Schema.dump(db, url_default,
others)` (renders `db/schema.cr`), `Saci::Record::Schema.load(db,
tables)` (recreate).

## Schema drift check

Every `Saci::Record::Base` subclass self-registers in
`Saci::Record.models`, so the framework can compare the database against
the models and warn when they disagree (forgotten migration, hand-edited
table, stale column declaration):

```crystal
Saci::Record.check_schema!.each { |w| STDERR.puts "warning: #{w}" }
```

`check_schema!` returns one warning string per mismatch and never raises
on drift. Four kinds, compared by NAME only (types are ignored):

- table in the DB with no registered model (`schema_migrations`,
  `saci_jobs`/`saci_dead_jobs` are skipped — queue tables have no models
  by design, as are column-less intermediates like `ApplicationRecord`);
- model whose table is missing from the DB;
- DB column with no mapping in the model;
- model column missing from the DB table.

`saci db:schema:check [--all]` runs the same check through your app's
`db/migrate.cr` runner (models loaded, server never booted) and exits 1
when drift is found. `saci db:migrate` / `saci db:rollback` print the
same warnings to STDERR after every run.

Existing apps (generated before this feature — e.g. `forem_lite`, `claw`)
get both by copying the `print_schema_drift!` helper plus one
`targets.each { |db_name| print_schema_drift!(db_name) }` call after the
`up`/`down` branches of their `db/migrate.cr` (or diff against a fresh
`saci new` scaffold's `db/migrate.cr`). One-liner for scripts/specs
instead:

```crystal
Saci::Record.check_schema!(db).each { |w| STDERR.puts "warning: schema drift: #{w}" }
```

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
- Single-process pub/sub by default; for multi-process deploys (no sticky
  sessions) point at Redis — no shard dependency, the client is a vendored
  pure-socket RESP2 implementation (`Saci::Cable::RedisWire`, no OpenSSL
  linkage, so plain builds link unchanged):

  ```crystal
  Saci::Cable.server = Saci::Cable::RedisServer.new(ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379"))
  ```

  One Redis channel (default `"saci:cable"`) multiplexes every stream via a
  `{sender, stream, message}` envelope; each server delivers locally, then
  publishes (own echoes are skipped by sender id). A background fiber holds
  the SUBSCRIBE connection and reconnects with backoff (0.1s → 5s),
  resubscribing automatically (`server.subscribed?` reports the confirmed
  state; `server.disconnect!` drops the sub connection, `server.close`
  stops the loop). Degradation is fail-open per broadcast: Redis down drops
  the remote hop with a STDERR warning while local delivery still happens —
  broadcasts never raise, and the constructor never touches the network, so
  a bad URL fails at first broadcast, not at boot. Per-app override still
  works: `r.cable "/cable", ChatChannel, server: my_server`.
  Opt-in per deploy with `REDIS_URL` (e.g. export it in production and pick
  it up with the `ENV.fetch` line above; wiring a commented default into
  the `saci new` production env template is left to the integrator —
  `cli/` is untouched by this change).

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

class ApiKey < ApplicationRecord
  column token : String
  has_secure_token              # auto-generates on create (never overwrites)
  # has_secure_token :api_token # named variant (+ regenerate_api_token!)
end

sid = user.signed_id(purpose: "login", expires_in: 15.minutes)
User.find_signed(sid, purpose: "login")   # => user or nil (never raises)
User.authenticate_by(email: "a@b.c", password: "secret") # => user or nil
```

- **CSRF** uses the stateless double-submit-cookie pattern: safe methods set
  the `saci_csrf` cookie (`SameSite=Lax`); POST/PUT/PATCH/DELETE must echo it
  via the `authenticity_token` param or `X-CSRF-Token` header (compared in
  constant time). `form_authenticity_token` returns the token for forms.
  Failures raise `InvalidAuthenticityToken`, rendered as 422.
- **Secure headers** (`X-Frame-Options: SAMEORIGIN`,
  `X-Content-Type-Options: nosniff`, `Referrer-Policy`,
  `Content-Security-Policy: default-src 'self'`) are applied to every
  controller response unless already set; tune via
  `Saci::SecureHeaders.configure`. Per-action escape hatches:
  `skip_csp only: [...]` (no CSP on those actions), `csp false` (whole
  controller), or `csp "default-src 'none'"` (custom policy).
- **Passwords**: `has_secure_password` digests with bcrypt on assignment,
  validates presence-on-create, confirmation match, and the 72-byte bcrypt
  limit. `Saci::Record.bcrypt_min_cost = true` speeds up specs (like
  `ActiveModel::SecurePassword.min_cost`).
- **Authentication** (devise-lite): `login(user)` is fixation-safe
  (`reset_session` first, then stores the id under `session_key`, plus a
  rolling `session_token` when the record has one — rotating it
  invalidates old sessions); `logout` resets fully; `current_user`
  (memoized via `memoize_current_user User`, `nil` when absent) and
  `logged_in?`; `require_login` (redirects to `login_path`, remembering
  GET targets in `session[:redirect_to]`) / `require_no_login` filters;
  `allow_unauthenticated_access only: [...]` opens public actions.
  Resolve users by overriding `find_current_user(id)` (e.g.
  `User.find?(id)`) — any class with `id` works — and tune paths/keys via
  `Saci::Auth.configure`. Note: a finder lambda cannot be assigned through
  `configure` (Crystal cannot store `Proc(Int64, YourUser?)` in framework
  state, so `c.user_finder = ...` raises with directions); override the
  hook or reopen `Saci::Auth.user_finder` instead.
- **Tokens**: `has_secure_token` (bare fills `token`, or
  `has_secure_token :api_token`) generates a 24-byte URL-safe random token
  in `before_validation on: :create`, only when blank — explicit values are
  kept and updates never overwrite. `regenerate_api_token!` issues a fresh
  token and saves. Uniqueness is validated at the model level; add a DB
  unique index too (model validation alone races under concurrency):
  `add_index :users, :api_token, unique: true`.
- **Signed IDs**: `record.signed_id(purpose: "login", expires_in: 15.minutes)`
  returns a tamper-proof string (id + class + purpose + expiry, HMAC-signed
  with `secret_key_base`); `Model.find_signed(token, purpose:)` returns the
  record or nil — bad signature, tampering, expiry, wrong purpose,
  cross-model use and missing rows never raise.
- **Login**: `Model.authenticate_by(email: "...", password: "...")` finds by
  the non-password attributes (single query) then `authenticate`s. Unknown
  login and wrong password both return nil (no user enumeration, matching
  password-reset conventions); misses still cost one bcrypt digest so the
  two failures take ~the same time. Missing `password`, no identifying
  attributes, or unknown finder attributes raise (`ArgumentError` /
  `UnknownAttributeError`).
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

## Metrics

```crystal
r.get "/metrics", Saci::Metrics::Controller, :index
```

In-process counters (mutex-guarded, no dependencies): request totals +
per-status buckets, per-route (`Controller#action`) counts with average
durations, job ok/failed counts, cache hits/misses, plus best-effort DB
gauges (durable-queue pending/dead rows, database size — SQLite file
bytes, `pg_database_size`, summed MySQL table bytes; `nil` when
unavailable). JSON by default, Prometheus text exposition on
`?format=prom` or `Accept: text/plain`
(`saci_requests_total`, `saci_request_duration_ms_sum`,
`saci_jobs_failed_total`, `saci_cache_hits_total`, …).

```crystal
Saci::Metrics.track_request("Posts#index", 200, 3.2)  # ~free no-op when disabled
Saci::Metrics.enabled = false   # pause tracking (default true)
Saci::Metrics.reset!            # blank slate (spec isolation)
Saci::Job.on_error { |_, _| Saci::Metrics.job_failed! }  # decoupled job wiring
```

Request tracking is explicit (wire `track_request` from an
`after_action` — see `Saci::Metrics` docs), as are job/cache hooks
(`job_ok!`, `cache_hit!`/`cache_miss!`): the framework stays decoupled.
No auth is built in — mount behind your own admin gate.

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
- `limits_concurrency to: 1, key: "cache-page"` caps concurrent runs per key
  (extra runs skip while the slot is held); honored by `:inline`, `:async`
  and `:db` adapters (explicit `perform_now` always runs).

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
- `layout "mailer"` wraps text/html parts with a registered layout
  (`Saci::Mailer.register_layout("mailer", text:, html:)` templates using
  `<%= content %>`); `default_reply_to` plus per-mail `reply_to:`; threading
  headers via `mail(..., headers: {"Message-Id" => "<..>", "In-Reply-To" => "<..>"})`
  (a custom `Message-Id` replaces the generated one).

## Views

```crystal
class PostsController < ApplicationController
  def show
    @post = Post.find(params["id"])
    render_template(:show)         # views/posts/show.ecr + layout
  end

  def feed
    respond_to do |f|
      f.html { render_template(:index) }
      f.json { render json: Post.all }
      f.rss { render xml: rss_feed(title: "Posts", link: "/posts", description: "latest", items: rss_items) }
    end
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
  the layout; `render_template(:new, status: 422)` re-renders with an error
  code. `<%= %>` does NOT escape — use `h()` (documented loudly).
- `render_partial("comments/comment", comment: c)` passes locals;
  `render_partial("comments/comment", collection: list)` renders once per
  item (variable inferred from the partial name, `as:` overrides it).
- `cache("sidebar") { render_partial("shared/sidebar") }` fragment-caches
  template output in `Saci::Cache` (miss renders + stores, hit returns the
  stored HTML, `expires_in:` TTLs, fail-open when the store is down). Keys:
  `cache_key(record)` (`table/id-updated_at`, same etag logic as `stale?`),
  `cache_key(records)` (count + max `updated_at`),
  `cache_key("name", version: 2)` (`"name:v2"`). Russian-doll: nest `cache`
  calls (inner hits are reused inside outer misses); bust outer entries with
  `Saci::Cache.delete` or a version bump — an inner delete alone does not
  expire an outer entry, so embed the inner key in the outer key
  (`cache("page/#{cache_key(@post)}")`) to couple them.
- `form_with(url) { |f| f.text_field("name") + f.submit }` builds escaped
  forms with `_method` override + CSRF token; `link_to("Delete", url,
  method: :delete)` renders a self-contained mini-form (works with the
  `_method` routing override, no JavaScript). With `model:` + `scope:`,
  fields bind to the model (`story[title]` names) and render
  `record.errors`: `f.text_field/check_box/select/date_field/file_field` +
  `f.error_messages` (`multipart: true` sets the upload encoding).
- Helpers: `markdown(text)` (XSS-safe minimal: fences, code, bold/italic,
  safe links, headings, paragraphs), `page_numbers(page, total, base)`
  (`"/stories"` → `/stories/page/N`, `:page` placeholders honored), `Saci::Pagination.paginate_nav(page, base)`
  (same URL conventions, windowed numbers with `aria-current`, `""` for a single page),
  `rss_feed(title:, link:, description:, items:)` (render with
  `render xml:`).

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
File page cache (a `CachePageJob` calls these): `Saci::PageCache.write(path, html)`
/ `.read` / `.expire` / `.expire_dir(dir)` under `tmp/page_cache`, with
write-through `.fetch(path) { render }`.

## General cache (`Rails.cache` equivalent)

```crystal
Saci::Cache.write("greeting", "hello", expires_in: 60.seconds)
Saci::Cache.read("greeting")                    # => "hello"
Saci::Cache.fetch("expensive", expires_in: 5.minutes) { compute }
Saci::Cache.increment("page-views")
Saci::Cache.namespace = "v2"                    # key prefix ("v2:...")

# Multi-process deploys share entries over Redis — same vendored
# pure-socket RESP2 client as Cable/Throttle, no new link requirements:
Saci::Cache.store = Saci::Cache::RedisStore.new(ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379"))
```

- The String fast-path (`read`/`write`/`fetch` returning `String`) is the
  primary API; typed values (`Int64`, `Float64`, `Bool`, `Time`, `Nil`)
  round-trip through `write` overloads plus `read_value`/`fetch_value`
  (a stored `Nil` is present — `exist?` is true — and `fetch` treats it
  as a hit). Values use an explicit type-tagged encoding (`S:`/`I:`/
  `F:`/`B:`/`T:`/`N:` prefixes, spec-pinned) — no `Marshal`, no
  deserialization gadgets; keys written by other clients read back as
  plain Strings. `read` on a non-String entry returns nil (use
  `read_value`).
- Backends: `MemoryStore` (default; mutex-guarded, `max_entries: 1000`
  with LRU eviction, entries purged on read) and `RedisStore(url,
  prefix: "saci:cache:")` (one key per entry, `SET ... EX` TTLs).
  `Saci::Cache.reset!` restores the default store (spec isolation).
- `fetch` memoizes on miss; `MemoryStore#fetch` also takes
  `race_condition_ttl:` for stampede protection (expired-within-grace
  serves stale immediately while one background fiber refreshes —
  concurrent fetchers keep getting stale instead of piling onto the
  recomputation; past the grace window it recomputes synchronously).
  `RedisStore` accepts the option for API parity but ignores it
  (server-side TTLs drop stale values, so there is nothing to serve)
  and its `increment` is read-modify-write (atomic per instance, not
  across processes).
- Fail behavior: `MemoryStore` never fails; `RedisStore` raises
  `Saci::Cache::RedisDown` on connection failure — rescue to a miss
  when fail-open is what you want (fragment caching does). `clear`
  deletes only keys written through that instance (never FLUSHDB).

## Rate limiting

```crystal
Saci::Throttle.throttle("logins/ip", limit: 5, period: 1.minute) do |ctx|
  ctx.request.path == "/login" ? Saci::Throttle.client_ip(ctx) : nil
end
Saci::Throttle.safelist { |ctx| Saci::Throttle.client_ip(ctx) == "127.0.0.1" }
Saci::Throttle.blocklist { |ctx| banned?(ctx) }
```

Fixed windows (nil discriminator skips); throttled → 429 + `Retry-After`,
blocklisted → 403. Counters live in `Saci::Throttle.store` (default:
in-process `MemoryStore`; `reset!`/`clear_counts!` for specs). For
multi-process deploys (same sticky-session caveat as Cable) share the
windows over Redis — same vendored pure-socket client, no new link
requirements:

```crystal
Saci::Throttle.store = Saci::Throttle::RedisStore.new(ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379"))
```

Each bucket is one key (`saci:throttle:<rule>:<key>:<window>`, prefix
overridable) bumped by an atomic INCR + conditional-EXPIRE Lua script, so
concurrent processes never lose expirations; keys rotate every window and
expire on their own. 429 + `Retry-After` and safelist/blocklist behavior are
unchanged. `RedisStore#clear` deletes only keys written through that
instance (never FLUSHDB). Degradation is fail-open: a dead store logs a
STDERR warning and the request is allowed (an outage must not become a
self-inflicted site-wide 429); direct `increment` calls raise the explicit
`Saci::Throttle::RedisDown` (Cable's equivalent: `Saci::Cable::RedisDown`,
raised from direct client use — broadcasts degrade to local-only instead).
Prefer fail-closed? Subclass `Store` and raise from your backend.

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
  `root`, `resources` (index/new/show/create/update/destroy/edit, with
  `only:`/`except:`; block form adds `member` (`m.post :upvote` →
  `POST /base/:id/upvote`), `collection` (`c.get :search`), and nested
  `resources` → `/base/:parent_id/...`), `namespace`/`scope` (Symbol or
  String, `mod:` documents the controller module), and block routes via
  `add`/arity overloads. Segment regexes via per-route `constraints:` or a
  `constraints({...}) do` block; `(...)` groups are optional
  (`/top(/:length(/page/:page))`, `(.:format)` → `params["format"]`);
  `*splat` wildcards plus a `fallback` catch-all. Redirects:
  `r.redirect("/u/:username", to: "/~%{username}", status: 301)` (`:name`
  and `%{name}` interpolation). Unknown routes render JSON 404.
- **Params**: path + query + JSON/form/multipart body merged into `params`,
  with `require` (raises `Saci::ParameterMissing` → 400),
  `permit`, `int`, `to_h`. Nested bracket keys and JSON bodies build a
  tree: `params.require(:story).permit(:title, tags: [] of String)`
  (bare `[]` needs the annotation — Crystal can't infer empty literals),
  `params.dig(:story, :title)`, `params.array("tags")`, and
  `params.file("avatar")` (multipart uploads: filename, content type,
  bytes; repeated field names keep the last file).
- **Rendering**: `render json:/html:/text:/plain:/xml:` with `status:`
  (integer or `:ok`, `:created`, `:no_content`, `:unauthorized`,
  `:unprocessable_content`, …) and `content_type:` override,
  `render_template :x, status: 422`, `redirect_to`, `head`.
  `respond_to do |f| f.html/json/rss/xml/text/any end` negotiates via
  `params["format"]` (`.json` URLs, `?format=`) then the `Accept` header
  (no match → `UnknownFormat` → 406).
- **Filters**: `before_action :name, only: [...], except: [...]`,
  `after_action` (symbol or block form; child-first, runs even when a
  before filter halts), `skip_before/after_action` (with `only:`/`except:`).
  Parent before-filters run before child filters; rendering/redirecting
  inside a before filter halts the chain (the action is skipped).
  `rescue_from ErrorClass do ... end` handles filter/action exceptions per
  controller (child handlers first).
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
src/saci/job.cr           # background jobs (+ limits_concurrency)
src/saci/page_cache.cr  # file page cache (CachePageJob-friendly)
src/saci/job_db.cr        # durable DB-backed queue (:db adapter)
src/saci/logging.cr       # logger, tags, filtering, request lines
src/saci/metrics.cr       # in-process metrics + /metrics endpoint (JSON/Prometheus)
src/saci/mailer.cr        # mailers + delivery (+ layouts, reply_to, headers)
src/saci/smtp.cr          # dependency-free SMTP client (STARTTLS + AUTH)
src/saci/views.cr         # ECR templates, forms, links, caching, files
src/saci/throttle.cr      # rate limiting
src/saci/cache.cr         # general cache (Rails.cache equivalent)
src/saci/storage.cr       # disk uploads + signed serving
src/saci/crypto.cr        # vendored AES-256-GCM (see note)
src/saci/credentials.cr   # encrypted credentials file
src/saci/record/base.cr # Saci::Record::Base (models)
src/saci/record/fts.cr        # SQLite FTS5 search (setup + search_fts)
src/saci/record/query.cr      # chainable queries
src/saci/record/migration.cr  # migrations + Migrator
src/saci/record/schema.cr     # db:schema:dump/load (schema.rb equivalent)
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
spec/metrics_spec.cr    # counters, JSON/Prometheus shapes, endpoint mount
spec/mailers_spec.cr    # building, adapters, deliver_later round-trip
spec/smtp_spec.cr       # SMTP framing/auth/errors against a fake server
spec/views_spec.cr      # templates, layouts, partials, forms, links
spec/fragment_spec.cr   # fragment caching (cache/cache_key, russian-doll)
spec/caching_spec.cr    # etag/last-modified flows, expires_in, records
spec/throttle_spec.cr   # limits, safelist, blocklist, windows
spec/cache_spec.cr      # general cache (memory + fake/live redis)
spec/storage_spec.cr    # disk service, signed URLs, FilesController
spec/credentials_spec.cr  # AES-GCM, credentials file, CLI commands
spec/multidb_spec.cr    # named DBs, connects_to, connected_to, tx routing
spec/env_spec.cr        # env, log levels, force_ssl, error pages
spec/cli_spec.cr        # CLI generator specs (temp dirs, no compilation)
spec/schema_spec.cr     # schema dump/load round-trips (SQLite + live PG/MySQL when URLs present)
spec/test_session_spec.cr  # TestSession request specs (ephemeral ports)
spec/cable_spec.cr      # Cable specs (live two-client broadcast, reject, unsubscribe)
spec/security_spec.cr   # CSRF/headers/escaping/bcrypt specs
spec/csp_spec.cr        # CSP default + skip_csp/csp escape hatches
spec/fts_spec.cr        # FTS5 setup/triggers/ranked search
spec/page_cache_spec.cr # file page-cache writer
spec/job_concurrency_spec.cr # limits_concurrency skip-if-running
spec/mailer_layout_spec.cr   # layouts, reply_to, threading headers
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
- [x] ORM upgrades: `has_one` / `has_many :through`, callbacks
  (`before_validation` … `after_commit`), extended validations (case-insensitive
  uniqueness, inclusion, numericality, custom `validate`, `allow_nil` /
  `allow_blank`, `on:`), query surface (`select`, `distinct`, `group` +
  aggregates, `or`, `where.not`, ranges, `joins`, `includes`, `upsert`,
  `update_columns`, `touch`), `decimal` / `date` / `json` columns,
  `counter_cache` / `touch:` / `dependent:` (`:destroy`, `:delete_all`, `:nullify`)
- ECR-based views / layouts
- ActiveJob durable Redis adapters; encrypted cookies

> The living plan — framework, CLI, Forem Lite app and ops, prioritized
> P0/P1/P2 with the validation story behind each item — is [ROADMAP.md](ROADMAP.md).
