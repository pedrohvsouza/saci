# Changelog

## Unreleased — Rails gap close-out wave (2026-10-21)

A 19-workstream implementation wave against `RAILS_GAP_ANALYSIS.md`. Framework
suite: **1312 specs, 0 failures** (from 590), plain and
`-Dexecution_context`.

- **P0**: fixed `saci new --db=postgres|mysql` invalid `shard.yml` (D1);
  dirty tracking (`changed?`/`changes`/`previous_changes`/`saved_changes`/
  `*_changed?`); exact BigDecimal-backed `Decimal` (`TEXT_DECIMAL` on SQLite,
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

Still structural/out of scope: true autoloading/code reloading/REPL debugger
(G1–G3, G207–G214), GIS (G309), live S3/variant processing (G84/G86), a real
Thruster proxy (config/docs only), and P3 polish.

## 0.4.0 — Scale, snapshots, and roadmap zero

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
- Live PG/MySQL harness (26 examples, 3 adapter bugs fixed); CI services job.
- Suite: 542 specs green.

## 0.3.0 — Rails-closeness shelf + scale

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
- Suite: 491 specs green (+ live PG/MySQL 26, live Redis gated).

## 0.2.0 — Lobsters port (Claw)

Framework grew up porting [Lobsters](https://github.com/lobsters/lobsters)
to the validation app **Claw** (`../claw`, 357 live specs green):

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
PG/MySQL SQL adapters. 223 specs green, validated by Forem Lite (87).
