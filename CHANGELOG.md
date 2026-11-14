# Changelog

## Unreleased

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
