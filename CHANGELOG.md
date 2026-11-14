# Changelog

## 0.8.0 — 2026-11-14

Models gain single-table inheritance and `default_scope`/`unscoped`.
Storage ships image variant processors (vips, ImageMagick) with PDF and
video previews, and the PostgreSQL Cable adapter can push broadcasts
with `LISTEN/NOTIFY` instead of waiting for the next poll. Specs keep
Saci's log format.

- **Fixed: specs switched to Crystal's log format halfway through.**
  `crystal spec` resets logging right before the examples run, so log
  lines printed during the examples lost Saci's format. Saci now
  reinstalls its backend before the suite. Specs stay quiet unless
  `LOG_LEVEL` is set, and `SACI_LOG_SETUP=0` still keeps Crystal's
  backend. `Saci.setup_logging` takes a `default_level:`.
- **PostgreSQL `LISTEN/NOTIFY` for Cable.** `Cable::PostgresServer`
  accepts `listen_notify: true` once the app requires `pg` and
  `saci/cable_pg`. Each broadcast runs `pg_notify` after its INSERT, and a
  listener connection wakes the peers' pollers, so cross-process delivery
  no longer waits for the poll interval. In this mode the poll interval
  defaults to 5 seconds and only acts as a safety net. The listener
  reconnects with backoff when its connection drops, and also when its
  own pings (every `listen_heartbeat`, 10 seconds by default) stop
  arriving. `DbServer#wake` triggers an immediate poll. Without
  `saci/cable_pg`, `listen_notify: true` still raises, and the error now
  names the requires to add.
- **Image variants and previews work out of the box.**
  `Storage::Processors::Vips` (`vipsthumbnail`) and
  `Storage::Processors::ImageMagick` (`magick`/`convert`) handle
  `resize_to_limit`, `resize_to_fit`, `resize_to_fill`, `format:`,
  `quality:` and `strip:`. `Storage::Processors.detect` picks whichever
  is installed. Previews render the first page of a PDF (`pdftoppm`) or
  the first frame of an MP4/WebM (`ffmpeg`) as PNG, and take the same
  options: `blob.preview(resize_to_limit: [400, 400])`. The tools run as
  child processes. Each one gets its input format named explicitly,
  sniffed from the bytes. Images over `max_pixels` are refused and each
  command has a `timeout`. Install one with
  `Storage.variant_processor = Storage::Processors::Vips.new`.
- **Fixed: every `variant(...).url` call processed and uploaded a new
  blob.** A variant is now stored under a key derived from the original's
  key and its options. The next request, from any process, finds it and
  skips processing. `Blob#purge` also deletes the original's variants.
  The order of options no longer changes the variant's filename.
- Variants that change the format (`format: "webp"`, or a preview of a
  PDF) get the new content type and file extension. `Variant::Processor`
  has three new methods with defaults: `output_content_type`, `variable?`
  and `previewable?`. Attachments have `preview`, `variable?` and
  `previewable?`, and so does `Blob`. Variant blobs now record their
  dimensions in `metadata`.
- **`default_scope` and `unscoped`.** `default_scope { where(deleted_at:
  nil) }` applies to every query on the model (`find`, `count`, `where`
  chains, scopes, association queries); several combine, and subclasses
  inherit them. `Model.unscoped` returns a query without them, and
  `Model.unscoped { ... }` turns them off for that model inside the
  block, on the current fiber. `unscope(:where)` drops their conditions.
  Uniqueness validations and `reload` ignore the default scope, as in
  Rails.
- **Single-table inheritance.** Subclassing a model whose table has a
  `type` column (`class Car < Vehicle`) makes the subclass share the
  table. It stores its class name in `type`, and its queries only return
  its own rows and its subclasses' rows (`WHERE type IN (...)`). The base
  class sees every row and loads each one as the class `type` names,
  with the columns subclasses declare. A `type` that names no loaded
  subclass raises `Saci::Record::SubclassNotFound`. `inheritance_column
  :kind` uses another column, and `inheritance_column nil` keeps a
  `type` column as plain data. Uniqueness validations check the whole
  table. Models whose table has no `type` column behave as before. If an
  app subclasses a model that has a `type` column and gives the subclass
  its own table, add `inheritance_column nil` to the parent.

## 0.7.0 — 2026-11-14

Models get the rest of the Rails callback chain, `throw_abort` to halt
it, and a chainable `scope` macro. Every generator's output now
compiles, passes its own specs and is formatted, and `form_with` takes
ECR blocks. Read the callback entries before upgrading:
`after_commit on: :update` no longer runs after `destroy`, and
timestamps are set after `before_create`/`before_update`.

- **More model callbacks.** `before_create`, `before_update`,
  `after_update`, `before_destroy` and `around_save`, `around_create`,
  `around_update`, `around_destroy` join the existing ones and run in
  Rails order. `around_*` takes method names that `yield` or a
  `|record, proceed|` block. `after_commit` accepts `on: :destroy`.
- **Halting callbacks.** `throw_abort` (Rails `throw :abort`) in
  `before_validation`, any `before_*` callback, or an `around_*` one
  before it yields stops the save or destroy without writing: `save` and
  `destroy` return false, `save!` raises `RecordNotSaved` and `destroy!`
  raises `RecordNotDestroyed`. An `around_*` callback that never yields
  halts the same way, and `halted?` tells a halt from a validation
  failure. `before_destroy` runs before `dependent:` cleanup, so a halt
  keeps the children.
- **`scope` macro.** `scope :published, -> { where(published: true) }`
  defines `Post.published` and a chainable `Query#published`, so
  `Post.where(...).published`, `author.posts.published` and scopes
  calling other scopes work. Arguments need types
  (`->(id : Int64) { ... }`); a body that returns nil leaves the query
  unchanged; a name that would shadow a `Query` method is a compile
  error.
- **Fixed: `after_commit on: :update` callbacks also ran after
  `destroy`.** They now run only after updates; use `on: :destroy` for
  destroys.
- Timestamps are now set after `before_create`/`before_update`, as in
  Rails.
- **Fixed: `saci generate authentication` wrote views that did not
  compile.** ECR has no `<%= helper do %>` tag. `form_with` now takes an
  ECR block written with `<% %>` and puts the form into the page:
  `<% form_with("/login") do |f| %> … <% end %>`. A block that returns
  the fields as a String still works with `<%= %>`. The scaffold, admin
  and password views use the new form.
- **Fixed: generated code that did not compile or failed its own
  specs.** `scaffold_controller` and `admin` controllers now declare
  typed defaults for their instance variables. `admin` controllers under
  `src/controllers/admin/` are loaded, because the entrypoint,
  `spec/spec_helper.cr` and `db/migrate.cr` now use recursive `**`
  globs. The `db:*` runners load `application_record.cr` before the
  other models. Migration and controller-spec templates are indented the
  way `crystal tool format` expects, and every generated file ends with a
  newline.
- `render_template` treats a name with a slash (`"shared/feed"` or
  `:"admin/posts/index"`) as a path from `src/views/`, as in Rails. Bare
  names stay relative to the controller.
- `saci generate authentication` keeps the stock `HomeController` and
  `HealthController` public with `allow_unauthenticated_access`, so the
  welcome page and the `/up` probe are not redirected to `/login`.
  Edited controllers get a note instead, and `saci destroy
  authentication` restores the stock files.
- A smoke spec (`SACI_SMOKE=1 crystal spec
  spec/generated_app_smoke_spec.cr`, CI job `smoke`) generates an app,
  runs every generator, then checks that the app is formatted, compiles
  and passes its own specs.

## 0.6.2 — 2026-11-14

App code can drop the `Saci::` prefix, the generators lean on
`Application*` base classes, and the CLI shows progress while it
compiles. The repository now passes `crystal tool format --check`, and
CI enforces it.

- **Framework types without the `Saci::` prefix.** `require "saci"` now
  includes `Saci` at the top level, so app code can write
  `class PostsController < Controller`, `rescue Record::RecordNotFound` or
  `TestSession.serve(router)`. Top-level names from the app or the stdlib
  still win (an app `Session` model stays the app's, `Time` and `DB` are
  the stdlib/crystal-db ones), and the full `Saci::` path keeps working.
  Compile with `-Dsaci_namespaced` to turn the include off.
- `saci new` generates `ApplicationJob`, `ApplicationMailer` and
  `ApplicationChannel`, and `saci generate job/mailer/channel` (and the
  authentication mailer) subclass them, creating the base file in older
  apps. Base classes, `config/`, `spec/spec_helper.cr` and `db/migrate.cr`
  keep the prefix; generated models, controllers, jobs, mailers,
  channels, migrations, specs and routes use the short names. Apps whose
  installed Saci predates the include still get prefixed code.
- **Fixed: generated apps failed to compile when a model, controller, job,
  mailer or channel sorted before its base class** (`account.cr`,
  `admin_controller.cr`). The entrypoint, `spec/spec_helper.cr` and
  `db/migrate.cr` now require the `application_*` files before the globs.
  Existing apps can add the same requires.
- The CLI shows a progress line while it compiles: `serve` (and each
  `--watch` rebuild), `test`, `runner`, `console`, `routes --boot`,
  `db:migrate` and the other `db:*` commands print `⠹ Compiling …` with
  the elapsed time, then `✓ Compiled … in 11.8s` or `✗ … failed`, with the
  compiler output right below. It animates only on a terminal
  (`SACI_SPINNER=0|1` overrides; `CI` and `TERM=dumb` turn it off).
  These commands now build with `crystal build` and run the binary
  (`saci test` builds what `crystal spec` would, `file:line` filters
  included) instead of `crystal run`, and no longer print the full
  compiler command line.

## 0.6.1 — 2026-11-14

- **Fixed: `HEAD` requests returned 404.** A `HEAD` with no route of its
  own now runs the `GET` route, as in Rails, and the new
  `Middleware::Head` (first in the stack) sends that route's headers,
  including `Content-Length`, without the body. Crystal's server writes
  the body even for `HEAD`, which would also desync keep-alive
  connections. Uptime monitors and crawlers that probe with `HEAD` now get
  the page's real status.

## 0.6.0 — 2026-11-14

Fixes from building and deploying a real app with Saci (phvsz.com), plus
adaptive GC pacing, Cable and router throughput work, and safer threading.
Read the behavior changes before upgrading an app that runs behind a proxy.

### Behavior changes

- `saci serve` and `Application#listen` / `#listen_gracefully` no longer
  stop when the port is taken: they bind the next free port (up to 100
  tries) and print which one they picked.
- Saci installs its own log backend when required. Text lines start with
  the local time as `2026/11/14 03:15:02.494236`, have colored severities
  on a terminal (`NO_COLOR` / `SACI_LOG_COLOR` control it), and every SQL
  statement is logged with its duration (`Saci.log_queries = false` or
  `SACI_LOG_QUERIES=0` turns that off). `SACI_LOG_SETUP=0` keeps Crystal's
  default backend.
- `JsonLogFormatter` lines carry microsecond timestamps and the entry's
  data fields (`duration_ms`, `adapter` on query lines).

- **Security: `Throttle.client_ip` no longer reads `X-Forwarded-For`.** It
  returns the address `Middleware::RemoteIp` resolved, which honors the
  header only from `config.trusted_proxies`. Before, any client could send
  a new address in the header on every request and get past rate limits.
  Apps behind a proxy or CDN that is not listed in `trusted_proxies` now
  see the proxy's address for every request, so add its ranges there.
- The CSRF cookie is set only when a page asks for a token, not on every
  GET. It is now `HttpOnly` and, on HTTPS requests or with `force_ssl` /
  `assume_ssl`, `Secure`.
- `Static` sends `Cache-Control: no-cache` in development and test and
  `public, max-age=3600` elsewhere, unless `cache_control` is set.
  Fingerprinted files get `public, max-age=31536000, immutable`.
- Unknown routes render `public/404.html` (or a built-in HTML page) for
  browsers instead of JSON, and the production exceptions app uses the
  app's `public/<status>.html` pages.
- `saci new` depends on Saci from GitHub (`version: ~> 0.5.0`) instead of
  an absolute `path:`. `--saci-path PATH` keeps the local checkout.

### Added

- `saci assets:precompile` / `assets:clobber` (`Saci::Assets.precompile`,
  `Saci::Assets.clobber`) and `Middleware::DevAssets`, which serves
  `src/assets` under `/assets/` in development.
- Development warnings for markup the response's CSP blocks (inline
  styles and scripts, `style` attributes, `on*` handlers, other hosts such
  as Google Fonts), logged once per path.
- `saci routes --boot`, which prints the routes the compiled app actually
  draws, including those drawn in loops.
- `saci credentials:set` / `credentials:get` / `credentials:unset` and
  `Saci::Credentials.set` / `unset`.
- `http_basic_authenticate_with credentials: "key"`. Nil or empty
  credentials deny every request.
- `attach(..., public:)`, and `DiskService.new(public: true)` now applies
  to attachments.
- I18n keys for `paginate_nav` labels (`saci.pagination.*`).
- `Middleware::RemoteIp::PRIVATE_NETWORKS`.
- Adaptive GC pacing under a memory budget: `SACI_MEMORY_LIMIT` (whole
  resident set) or `SACI_GC_HEAP_LIMIT` (GC heap only) picks Boehm's
  free-space divisor, and the bytes allocated between collections, from
  the live heap.
- `saci serve --host` with no value exposes the app on the local network
  and prints the network URLs (not inside containers).
- `serve --watch` also watches path dependencies.
- Cable connections expose the handshake request, cookies and session.

### Performance

- Cable: each broadcast is encoded once for all subscribers, remote
  broadcasts without local listeners are not decoded, Redis uses one
  channel per stream with pipelined publishes, frame workers are bounded,
  and idle sockets and connection stacks are trimmed.
- Router: routes are indexed by method and idle per-request work is
  skipped. `Static` skips the filesystem for paths outside the public
  root.
- Smaller per-socket and WebSocket buffers; memoized cookie key
  derivation and verified encrypted cookies.

### Fixed

- `content_for` and `capture` with ECR blocks wrote the block's markup to
  the page instead of the slot.
- Length and numericality validation messages showed the constant's name
  (`maximum is NICKNAME_MAX characters`) instead of its value.
- `db:schema:check` warned about framework models (`Saci::*`) and their
  `saci_*` tables in apps that do not use them.
- The database pool could hand one connection to two threads under
  `-Dexecution_context`.
- `saci runner` loads services and initializers.
- The GC tuner subtracted memory unmapped to the OS twice and could raise
  `OverflowError` while sampling the heap.
- Generated Dockerfile: builds with SQLite, installs from `shard.lock`,
  precompiles assets, runs on the Crystal image's Ubuntu release (the
  older base could not start the binaries), and copies the encrypted
  credentials. `config/deploy.yml` declares named volumes and passes
  `RAILS_MASTER_KEY`; `.kamal/secrets` reads it from `config/master.key`.
- Generated apps ship a layout with a viewport and stylesheet tag,
  `src/assets/application.css`, and initializers for the CSP and trusted
  proxies.

## 0.5.0 — 2026-10-21

The largest release so far. It covers most of the surface a Rails
developer expects day to day: configuration and middleware, named routes,
a much deeper ORM, frontend tooling, inbound email, storage attachments,
GraphQL, office documents, a testing kit, and deployment scaffolding.
Verified against SQLite and live PostgreSQL 16, MySQL 8.0 and Redis 7,
both single-threaded and with `-Dexecution_context`.

- **Core**: fixed the invalid `shard.yml` generated by
  `saci new --db=postgres|mysql`; dirty tracking (`changed?`/`changes`/
  `previous_changes`/`saved_changes`/`*_changed?`); exact BigDecimal-backed `Decimal` (`TEXT_DECIMAL` on SQLite,
  real `NUMERIC`/`DECIMAL` on PG/MySQL); configurable middleware stack with
  `use`/`insert_before`/`insert_after`/`swap`/`delete`; CORS; named route
  helpers (`Saci::Routes.define` compile-time `posts_path`, runtime
  `path_for`/`url_for`); initializer lifecycle (`before_configuration`,
  `to_prepare`, `after_initialize`, `reload!`); central `Saci::Configuration`.
- **HTTP**: host authorization, trusted-proxy `RemoteIp`, static `public/`
  serving (ETag/304/traversal guards), gzip, built-in `/up`, request body
  limits, exceptions app + production error pages, SSL/assume-SSL options,
  `X-Request-Id`/request tags, error reporter.
- **ORM**: `insert_all`/`upsert_all`/`insert_all!`, `find_in_batches`/
  `in_batches`, `merge`/`rewhere`/`unscope`/`none`/`left_joins`/
  `find_or_create_by`/`find_sole_by`/`pick`/`in_order_of`/`ids`/predicates/
  ordinals/`explain`, `define_finders`, MySQL dialect helpers; model enum
  (`model_enum`), validator objects, `length: {is:}`, dynamic inclusion,
  timestamps honoring explicit assignment, `update_attribute`/`update_column`/
  `increment!`/`decrement!`/`toggle!`/`destroy!`; nested attributes
  (`accepts_nested_attributes_for`), pessimistic (`lock!`/`with_lock`/
  isolation transactions) and optimistic (`lock_version`/`StaleObjectError`)
  locking, `no_touching`, `has_one :through`, through-association preloading
  (including polymorphic sources), autosave associations, and HABTM.
- **Migrations**: `execute`/`reversible`/`change_table`/`revert`/
  `disable_ddl_transaction!`; `change_column_null/default`, `remove_columns`,
  `add_reference`, join tables, timestamps; idempotent DDL; concurrent
  indexes/check constraints/views; introspection (`table_exists?`,
  `columns`, `indexes`, `foreign_keys`, …); UUIDs and native PG types
  (`hstore`, `inet`, `cidr`, `macaddr`, `interval`, `money`, `bit`, `point`,
  range, `xml`, `oid`, `bytea`); binary/generated columns.
- **Controllers**: `around_action`, `prepend_before_action`, `redirect_back`,
  open-redirect protection, HTTP basic/token auth, `allow_browser`, `render
  body:/file:/template:/action:/partial:` + `render_to_string`, parameter
  wrapping, `params.expect`, `rate_limit`, request host/subdomain helpers,
  `UploadedFile` API, `rescue_responses`.
- **Views/assets/frontend**: manifest+digest asset pipeline, importmap
  (`Saci::Importmap` + CLI), Turbo Drive and a minimal Stimulus loader
  (vendored JS), PWA manifest/service worker, asset tag helpers,
  `tag`/`content_tag`/`button_to`/`div_for`, `content_for`/`capture`,
  form tag/option/collection helpers, number/date/time/text/sanitize
  helpers, `link_to_if`/`mail_to`/`phone_to`, `dom_id`/`dom_class`, cache
  helpers, CSRF/CSP meta tags.
- **Security**: session store abstraction (cookie/memory/cache/DB),
  cookie serializers + rotations, masked/per-form CSRF tokens, CSP nonces,
  Permissions-Policy, HSTS/extra default headers, configurable dispatch
  defaults.
- **Routing**: compile-time named helpers for resources/nesting/namespaces/
  member/collection/shallow, runtime `path_for`/`url_for`, polymorphic
  path/url, `recognize_path`, mapper `concern`/`direct`/`resolve`/`mount`/
  `shallow`, route introspection, `model_name`.
- **Jobs**: callbacks + middleware, queue priority, unique jobs, batches,
  GlobalID args, continuations/checkpoints, `SKIP LOCKED` DB claiming,
  adapter registry, queue selectors.
- **Cable**: `stream_for`/`broadcasting_for`, `periodically`, identifiers,
  remote disconnect, test helpers, DB-backed adapter (polling), bounded
  writer fibers + backpressure.
- **Mail/storage/text**: mail attachments + inline MIME, callbacks,
  parameterized mailers, `deliver_later(wait:/queue:)`, SendGrid/Mailgun/
  Postmark/SES adapters, DKIM, mail test helpers; Action Mailbox (MIME
  parsing, routing, ingress, persistence, incineration); blob/attachment
  models + `has_one_attached`/`has_many_attached`, mirror/S3-signing service,
  direct uploads, metadata analysis, variants/previews interface, Action
  Text attachables.
- **Deploy/config**: `config/database.yml` + `Saci::ConfigFile` ENV
  interpolation, per-env `cache/queue/cable/recurring/storage/server` YAML,
  `ServerConfig`, graceful SIGTERM/SIGINT shutdown, Kamal 2 (`config/deploy.yml`,
  `.kamal/secrets`, `bin/kamal`), Thruster docs/wrapper, `--devcontainer`,
  environment doctor, generated `config/ci.cr`.
- **Data/API extras**: XLSX/PDF/CSV generation (`Saci::Office`, controller
  `send_xlsx`/`send_pdf`/`send_csv`); GraphQL schema/type DSL, parser,
  executor, mutations, introspection, batching, HTTP `/graphql` + GraphiQL.
- **Testing/support/auth**: fixtures, factories, transactional tests,
  mailer/job/cable assertions, time travel, `assert_changes`/`_difference`/
  `_queries`, `assert_select`, test DB lifecycle, parallel worker helper;
  time zones/DST, durations, inflections, core extensions, CurrentAttributes,
  I18n fallbacks/plurals/formats, notifications + structured/JSON logging,
  Rails 12-key filter parameters; password-reset tokens, JWT (HS256/384/512),
  TOTP; serializers, audit trail, policy DSL, Ransack-style search, OpenAPI
  skeleton.
- **CLI/scaffold**: Rails-like scaffold (`bin/*`, Dockerfile, CI, public
  error pages, test tree, runtime dirs, `/up`); `destroy` + auth/task/helper/
  resource/scaffold_controller/test generators; `lib/tasks` DSL; `db:prepare/
  setup/reset/version/migrate:status/fixtures:load/seed:replant/schema:cache:
  dump/test:prepare/create/drop`; `about/stats/notes/middleware/initializers/
  dbconsole/dev:cache/log:clear/tmp:clear/time:zones/restart/routes --grep`;
  `credentials:fetch`; local CI DSL; `app:update`.

See [ROADMAP.md](ROADMAP.md) for what is still open.

## 0.4.0 — Metrics, schema snapshots, Redis fan-out

- Metrics endpoint (`Saci::Metrics`: request/status/route/job/cache counters,
  DB gauges; JSON + Prometheus; mountable controller).
- Schema snapshots (`db:schema:dump/load`, adapter-aware, byte-stable) +
  drift check (model registry, `check_schema!`, `db:schema:check`,
  post-migrate warnings).
- Redis Cable + throttle stores (vendored RESP2, fail-open, live-verified).
- `Saci::Cache` + fragment caching (record/collection keys, versions).
- Migration depth: foreign keys, renames, `change_column`, `references`,
  PG enums/arrays/precision.
- CLI: `routes`, `runner`, `console`, `db:seed`, `--pretend`/`--force`,
  staging scaffold; `Saci.staging?`, staging secret refusal.
- Mailer previews + RFC 2047 subjects; URL rotation + public-file mode.
- Production refuses to boot without `SECRET_KEY_BASE`.
- Live PostgreSQL/MySQL test harness (`live/`), with three adapter bugs fixed; CI services job.

## 0.3.0 — Auth helpers, pagination, cache

- Auth shelf: `has_secure_token` / `regenerate_x!`, `signed_id` /
  `find_signed` (purpose + expiry), `authenticate_by` (no-enumeration,
  timing parity); controller `login`/`logout`/`current_user`/`logged_in?`,
  `require_login` (redirect-target saving), `require_no_login`,
  `allow_unauthenticated_access`, `Saci::Auth.configure`, typed
  `memoize_current_user`.
- `Saci::Pagination` (`paginate` + `Page` + `paginate_nav`, clamped pages,
  per-page cap) and `saci g admin` (namespaced CRUD with search/sort/
  pagination views, deny-by-default admin gate, real-verb specs).
- `Saci::Cache` (Memory + Redis stores, namespaces, stampede-grace fetch,
  typed values) + view fragment caching (`cache` blocks, record/collection
  keys, `:vN` versions, fail-open).
- Migration depth: `references`, inline + standalone foreign keys
  (`on_delete` cascade/nullify/restrict), `rename_table/column`
  (auto-invert), `change_column` (PG `USING`, MySQL `MODIFY`, honest
  SQLite error + irreversible rollback).
- CLI: `routes` (static, no boot), `runner -e/file`, `console` (documented
  per-line recompile), `db:seed` (+ starter file in `saci new`).
- Redis Cable + throttle stores (vendored RESP2, zero new deps, fail-open,
  live-verified two-instance fan-out, `REDIS_URL` scaffold).
- Fixes: single-run validations via intermediate bases, same-controller
  filter halt, `RoutingError`→404, partial buffer scoping, PG jsonb reads,
  MySQL JSON→TEXT mapping + all-default inserts.

## 0.2.0 — Associations, callbacks, routing depth

Shaped by building a full link-aggregator application on top of the
framework:

- ORM: `has_one`, `has_many :through`, polymorphic `belongs_to` / `has_many
  as:`, model callbacks (`before_validation/save`, `after_save/create/commit/
  destroy`), case-insensitive uniqueness, inclusion/numericality/custom
  `validate`, `if:/unless:`, `select/distinct/group` + aggregates,
  `or`/`not`/range `where`, symbol + string `joins`, nested `includes`
  preloading, `upsert`/`update_columns`/`touch`/`touch_all`/`reset_counters`,
  `decimal/date/json` columns, `counter_cache` + `touch:` + full `dependent:`
  set (`destroy/delete_all/nullify/restrict_with_exception`).
- Web: route constraints, `member/collection`, nested resources, `new/edit`,
  optional segments, `(.:format)`, defaults, redirects, fallback, `~:user`
  prefix segments; `rescue_from`, `after_action` + skips, `respond_to`
  html/json/rss/xml, `render xml/status/template-status`; nested params
  (`require().permit(tags: [] of String)`), `dig/array/file` uploads;
  partial locals/collections, model forms + errors, markdown/pagination/RSS
  helpers; CSP defaults + escape hatch.
- Jobs/mailers/caching: FTS5 helper + triggers, file page-cache writer,
  per-key job concurrency limits, mailer layouts + `reply_to` + threading
  headers, multi-window throttles + login throttle.
- CLI: `add_index` generator, `db:migrate --all` + `clean_all!`, `new
  --db=postgres|mysql`, real verbs in generated request specs, CI workflow.

## 0.1.0 — Initial import

Router + Controller, SQLite ORM, CLI, Cable channels, I18n, CSRF/sessions,
jobs (`:async/:inline/:test/:db`), mailers (file/test/sendmail/SMTP),
ECR views, HTTP caching, throttle, disk storage, credentials, multidb,
PG/MySQL SQL adapters, and the Forem Lite example app.
