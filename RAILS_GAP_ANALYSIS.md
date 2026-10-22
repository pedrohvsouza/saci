# Saci vs Ruby on Rails — Gap Analysis

**Revision** — v6 (2026-10-21): added an implementation-status section after a
19-workstream close-out wave (P0/P1 backbone plus most P2 depth; framework suite
590 → 1183 specs, green). The gap catalogue below is unchanged so it remains a
useful comparison against Rails 8.1. v5 (2026-10-19) removed all app-specific
citations and rewrote the case study from the original Rails source only
(anonymized). v4 added the case study and 17 case-derived gaps (G295–G311).
v3 added the scaffold diff, gem inventory, method audit, CLI/middleware/
config/ecosystem matrices, and 80 gaps (G215–G294).

## Implementation status (2026-10-21)

A 19-workstream wave plus a six-workstream depth wave implemented the P0/P1
backbone and much of P2, released as **Saci 0.5.0**. Verified by
the framework suite (**1312 examples, 0 failures, 10 live-gated pending**, plain
and `-Dexecution_context`) and a standalone CLI build.

- **Closed P0s**: D1 scaffold `shard.yml`; G4 named route helpers (compile-time
  `Saci::Routes.define` + runtime `path_for`/`url_for`); G5 middleware stack;
  G6 initializers; G10 dirty tracking; G48 CORS; G297 exact `BigDecimal`-backed
  decimals (`TEXT_DECIMAL` on SQLite, real `NUMERIC`/`DECIMAL` on PG/MySQL).
- **Closed P1 backbone**: G7 config object, G11–G13, G19/G21 partial, G26–G27,
  G35–G40, G42–G45, G49–G51, G58, G62, G63–G69, G77, G89, G105–G113, G115–G120,
  G123–G131, G149–G151, G158, G185–G190, G193, G201, G245, G253, G295–G300,
  G303–G306, G310.
- **P2/P3 depth**: G19–G21, G28, G32–G33, G52–G57, G61, G70–G72, G76,
  G78–G88 partial, G91, G93–G103, G119, G132, G135/G138–G143, G145/G147–G148,
  G152–G161, G163–G166 (config/docs), G169–G182, G186–G187, G191–G192,
  G194–G200, G202–G204, G219, G233, G238, G240, G252, G254–G259, G264,
  G266–G269, G272–G275, G279, G283–G284, G286, G288–G292, G294, G301,
  G307–G308, G311.
- **Structural / intentionally out**: G1–G3 and G207–G214 (Crystal has no
  autoload/reload/runtime eval), G309 (GIS), live-cloud verification for
  G84/G86, a real Thruster proxy (G166: config/docs only).

See `CHANGELOG.md` for the detailed per-area list. The sections below retain the
original audit wording.

---

**Headline findings**

1. **One P0 scaffold bug**: `saci new --db=postgres` emits invalid `shard.yml`, so every new
   PostgreSQL app fails `shards install` (Appendix D1).
2. **The structural gap is the developer loop**: no autoloading, code reloading, real console,
   or debugger (G1–G3). Everything else is smaller than this.
3. **No named route helpers** (G4) — Rails' `posts_path`/`url_for` are absent; routes are strings.
4. **Active Record is a solid vertical slice, not full depth**: dirty tracking, model `enum`,
   nested attributes, locking, encryption, bulk writes, async queries, and STI are missing
   (G10–G34, G233–G244, G287–G294).
5. **No asset pipeline, Importmap, Stimulus, or Turbo Drive** (G63–G72); Saci has Turbo
   Frames/Streams and ECR only.
6. **The HTTP stack is a thin router, not a Rack stack**: no middleware insertion, CORS,
   HostAuthorization, RemoteIp, static serving, compression, or reloading (G5, G48–G51).
7. **Entire Rails components are absent**: Action Mailbox, Active Storage cloud/variants/blobs,
   Action Text attachments, Propshaft/importmap, Solid Queue/Cache/Cable, Kamal/Thruster.
8. **Scaffold/tooling surface is ~2.4× smaller than `rails new --api`**: no Dockerfile, CI,
   binstubs, `config.ru`, static error pages, test tree, fixtures, or dev tooling
   (G215–G232, Appendix B).
9. **PostgreSQL native types are partial**: no UUID, hstore/inet/cidr/macaddr/interval/money,
   point/range/xml, pgvector, or `bytea` DDL (G283–G286).
10. **Testing depth**: no fixtures/factories, transactional tests, parallel DBs, system tests,
    or Rails assertion helpers (G105–G113, G266).
11. **Money precision is a P0**: Saci's `Decimal` is Float64-backed and `t.decimal` maps to
    `DOUBLE PRECISION`/`REAL` (G297). A Rails app handling prices/fees cannot use it as-is.
12. **Real-world validation**: a production Rails 8 app (359 models, 561 GraphQL files,
    44 Sidekiq workers) exercises most of the P0/P1 gaps directly; its anonymized case study is
    in Section 29.

---

**Baseline**

- **Saci** `0.4.0` (`15ad901`), audited directly from `src/saci/` on 2026-10-19.
- **Rails** `8.1` line (`8.1.4` current, released Sep 2026; `8.1` released Oct 2025) — checked
  against the official
  [8.0](https://guides.rubyonrails.org/8_0_release_notes.html) and
  [8.1](https://guides.rubyonrails.org/8_1_release_notes.html) release notes and the guides index.
- **Reference Rails app** `/home/kejsare/dev/projects/lobsters` (Rails `8.1.3.1`, real production
  config: `config/*.yml`, 20+ initializers, Action Mailbox/Text/Storage, Solid Queue/Cache,
  importmap, Puma).

**Method** — three passes: (1) every "missing" claim was verified by symbol search in the Saci
tree (`grep` for the Rails API name), not from memory; (2) a real Rails 8.1.3.1 app and a
`saci new` app were generated and diffed (Appendix B); (3) the Rails 8.1.3.1 gems were
installed and every component's module files enumerated (Appendix C), alongside the official
guides. Items marked *partial* exist but with a narrower contract. This document covers
framework capability, not application code. One scaffold bug was reproduced — see Appendix D.

**Legend**

| Mark | Meaning |
|---|---|
| ✅ | Present, roughly equivalent |
| 🟡 | Present but partial / different contract |
| ❌ | Missing |
| ⛔ | Impossible or not meaningful in Crystal (structural difference) |

---

## 1. Coverage at a glance

| Rails component | Saci equivalent | Coverage |
|---|---|---|
| Railties (boot, config, generators) | `Saci::Application`, `saci` CLI, `src/<app>.cr` | 🟡 ~55% |
| Action Pack / Action Dispatch | `Router`, `Controller`, `Handler`, `Session`, `Cookies`, `CSRF`, `SecureHeaders` | 🟡 ~65% |
| Action View | ECR templates, layouts, partials, `FormBuilder` | 🟡 ~45% |
| Active Record | `Record::Base`, migrations, query builder, associations, validations, callbacks | 🟡 ~70% |
| Active Model | validations/callbacks/secure password fold into `Record::Base` | 🟡 ~35% |
| Active Support | `Inflector`, `Cache`, `Crypto`, `I18n`, `Concurrency` | 🟡 ~30% |
| Active Job | `Job` (`:inline/:async/:test/:db`) + `Recurring` + Dashboard | 🟡 ~65% |
| Action Mailer | `Mailer`, SMTP, previews, layouts, RFC 2047 | 🟡 ~60% |
| Action Mailbox | — | ❌ 0% |
| Action Text | `RichText` (sanitizer + plain text + textarea) | 🟡 ~40% |
| Active Storage | `Storage::DiskService`, signed URLs, rotation, public mode | 🟡 ~35% |
| Action Cable | `Cable` (WS, channels, Redis adapter) | 🟡 ~70% |
| Propshaft / asset pipeline | — | ❌ 0% |
| Importmap / JS bundling | — | ❌ 0% |
| Hotwire (Turbo/Stimulus) | Turbo Frames/Streams only | 🟡 ~30% |
| Solid Queue/Cache/Cable | DB jobs; Redis cache/cable (no SQLite/DB cache/cable) | 🟡 ~50% |
| Kamal / Thruster / deploy | — | ❌ 0% |
| Testing framework | `crystal spec` + `TestSession` | 🟡 ~40% |
| Security shelf | CSRF, CSP, sessions, credentials, throttle, auth helpers | 🟡 ~70% |
| I18n / time zones | locale files + interpolation/count | 🟡 ~40% |

**What Saci already matches well** (so this list is not misleading): routing with
`resources`/`resource`/`namespace`/`scope`/regex constraints; controller filters,
`rescue_from`, `respond_to`, redirects, ETags/`fresh_when`/`expires_in`; CSRF, encrypted
sessions, flash, signed/encrypted cookies, secure headers + CSP; ORM CRUD, `has_many`
(including `through`), `belongs_to` (polymorphic, `counter_cache`, `touch`), `has_one`,
`dependent:`, callbacks, validations, scopes, `pluck`, `where.not`, `or`, `update_all`,
`delete_all`, `touch_all`, `find_each`, `includes`/nested preloading, FTS5, schema
dump/load/drift, foreign keys, enums/arrays/precision, composite indexes; jobs with
retry/discard, dead letter, dashboard; recurring jobs (cron parser); mailers with
layouts/previews/RFC 2047; Cable with Redis fan-out; cache + fragment caching; signed
storage URLs; rich text; Turbo frames/streams; pagination; metrics; throttling; i18n
basics; multithreading.

---

## 2. Architecture & developer loop (highest impact)

| # | Gap | Rails | Saci today | Impact | Effort | Priority |
|---|---|---|---|---|---|---|
| G1 | **Autoloading (Zeitwerk)** | Constants load on demand from `app/**` | Explicit `require`s + globs (`require "./models/*"`); every new file needs a glob or require | New files work only if a glob covers them; no lazy loading | XL | P0 |
| G2 | **Code reloading** | In-process class reload in dev | `saci serve --watch` rebuilds and restarts the process | Edit→see loop is seconds; no stateful REPL iteration | XL | P0 |
| G3 | **Real console / debugger** | `rails console` (IRB), `binding.irb`, `debug` gem breakpoints, step debugging | `saci console` compiles each line (slow); no multi-line defs; no breakpoints | Debugging is print/log-driven | XL | P0 |
| G4 | **Named route helpers** | `posts_path`, `edit_post_path(post)`, `url_for` | Routes are string literals; no name registry | Typos fail at runtime; refactors are manual | M | P0 |
| G5 | **Middleware stack** | `config.middleware.use/insert_before/...`, Rack ecosystem | Handler chain fixed in `Saci::Application.handlers` (WS + router) | Auth/logging/compression/CORS middleware requires forking boot | M | P0 |
| G6 | **Initializers lifecycle** | `config/initializers/*.rb`, `to_prepare`, `after_initialize`, `before_configuration` | No `config/initializers`; boot code lives in `src/<app>.cr` | Configuration is app-entrypoint code; no load-order hooks | S | P0 |
| G7 | **Configuration object** | `Rails.application.config.*` (~150 knobs) | Scattered class-level setters (`Saci.log_level`, `Saci.force_ssl`, …) | No central config, no `config_for(:service)`, no per-env config struct | M | P1 |
| G8 | **Engines / plugins** | Mountable engines bundling routes, migrations, views, assets | Controllers can be mounted as routes; no engine packaging | Reusable feature bundles are copy-paste | XL | P2 |
| G9 | **`rails app:update` / app templates** | Upgrade scaffolding, `--template` generators | None | Framework upgrades are manual | M | P2 |

---

## 3. Active Record / persistence

| # | Gap | Rails | Saci today | Priority |
|---|---|---|---|---|
| G10 | **Dirty tracking** | `changed?`, `changes`, `previous_changes`, `saved_changes`, `will_save_change_to_*` | ❌ (Braxy compares values by hand) | P0 |
| G11 | **Bulk writes** | `insert_all`, `upsert_all`, `insert_all!` | ❌ (`update_all`/`delete_all` exist) | P1 |
| G12 | **Batching** | `find_each`, `find_in_batches`, `in_batches` | 🟡 `find_each` only | P1 |
| G13 | **Model `enum` DSL** | `enum status: {draft: 0, live: 1}` → predicates, bang methods, scopes, validation | ❌ (only migration `t.enum` DDL) | P1 |
| G14 | **STI** | `type` column, subclass scopes, `becomes` | ❌ | P2 |
| G15 | **`default_scope` / `unscoped`** | Default ordering/filters per model | ❌ | P2 |
| G16 | **`delegate`, `delegate_missing_to`** | One-liner delegation | ❌ | P2 |
| G17 | **`serialize` / `store` / `store_accessor`** | JSON/text-backed virtual attributes | 🟡 JSON columns exist; no accessor macro | P2 |
| G18 | **Attribute API** | `attribute :name, :type`, `normalizes`, custom types | ❌ (columns are declared, not typed attributes) | P2 |
| G19 | **Nested attributes** | `accepts_nested_attributes_for`, `fields_for`, `_destroy` | ❌ | P1 |
| G20 | **Optimistic locking** | `lock_version`, `StaleObjectError` | ❌ | P2 |
| G21 | **Pessimistic locking** | `lock!`, `with_lock`, `SELECT … FOR UPDATE`, `transaction(isolation:)` | ❌ | P1 |
| G22 | **Attribute encryption** | `encrypts :ssn`, deterministic encryption, key rotation | ❌ (only credentials/files encrypted) | P1 |
| G23 | **Composite primary keys** | `primary_key: [:shop_id, :id]` (7.1+) | ❌ | P2 |
| G24 | **Read replicas / connection switching** | `connected_to(role: :reading)`, `while_preventing_writes` | ❌ (multidb supports separate DBs, not replicas) | P2 |
| G25 | **Sharding** | `connects_to shards:` | ❌ | P2 |
| G26 | **Eager loading depth** | `includes`, `preload`, `eager_load`, `references`, `strict_loading`, `inverse_of` | 🟡 `includes` preloads `belongs_to`/`has_many` + nested; no `eager_load`/`references`/`strict_loading`/`inverse_of` | P1 |
| G27 | **Query API depth** | `merge`, `rewhere`, `unscope`, `none`, `left_joins`, `find_or_create_by`, `create_or_find_by`, `find_sole_by`, `sole`, `pick`, `in_order_of`, `missing`, `associated` | ❌ (has `where`, `not`, `or`, `joins`, `group`, `pluck`, `find_each`) | P1 |
| G28 | **`explain` / query analysis** | `Relation#explain`, `EXPLAIN ANALYZE` helpers | ❌ | P2 |
| G29 | **Instrumentation / notifications** | `ActiveSupport::Notifications` for SQL, controller, mailer, job; `query_log_tags` | ❌ (request logs only; no SQL events) | P1 |
| G30 | **`after_commit` variants** | `after_commit on: [:create|:update|:destroy]`, `after_rollback` | 🟡 `after_commit` exists; no `on:`/rollback variants | P2 |
| G31 | **`touch_later`, `update_counters`** | Deferred touch, public counter API | 🟡 `counter_cache` internal only | P2 |
| G32 | **Database views / check constraints / generated columns** | `create_view`, `add_check_constraint`, `virtual` columns | ❌ | P2 |
| G33 | **`has_and_belongs_to_many`** | HABTM join tables | ❌ (`has_many through` covers it) | P3 |
| G34 | **`delegated_type`** | Delegation via polymorphic type column | ❌ | P2 |

---

## 4. Migrations & schema

| # | Gap | Rails | Saci today | Priority |
|---|---|---|---|---|
| G35 | **Migration DSL depth** | `execute`, `reversible`, `change_table`, `say`, `suppress_messages`, `revert`, `disable_ddl_transaction!` | ❌ | P1 |
| G36 | **Column helpers** | `change_column_null`, `change_column_default`, `remove_columns`, `add_reference`, `create_join_table`, `add_timestamps`/`remove_timestamps` | ❌ (has `add_column`, `change_column`, `rename_*`, `remove_column`, `add_index`) | P1 |
| G37 | **Idempotent DDL** | `if_not_exists:` / `if_exists:` (7.1+) | ❌ | P2 |
| G38 | **PG concurrency** | `algorithm: :concurrently`, `safety_assured`, `deferrable: :deferred` FKs, `validate_foreign_key` | ❌ | P2 |
| G39 | **DB task surface** | `db:prepare`, `db:setup`, `db:reset`, `db:version`, `db:migrate:status`, `db:fixtures:load`, `db:seed:replant`, `db:schema:cache:dump` | 🟡 only `db:migrate`, `db:rollback`, `db:schema:dump/load/check`, `db:seed` | P1 |
| G40 | **Automatic test DB provisioning** | `db:test:prepare`, test DB created/loaded automatically | ❌ (apps wire `DATABASE_URL` + manual migrate in spec helper) | P1 |
| G41 | **Migration versioning / `app:update`** | `ActiveRecord::Migration[8.1]`, compatibility layers | 🟡 single DSL, no versioned migration classes | P3 |

---

## 5. Controllers, dispatch, HTTP

| # | Gap | Rails | Saci today | Priority |
|---|---|---|---|---|
| G42 | **`around_action`** | Wrap action in a block | ❌ (before/after only) | P1 |
| G43 | **`prepend_before_action`** | Order filters before inherited ones | ❌ | P2 |
| G44 | **`redirect_back`** | Redirect to `referer` with fallback | ❌ | P1 |
| G45 | **`url_for` / polymorphic routing** | Model → URL helpers | ❌ (G4 subset) | P1 |
| G46 | **Streaming / SSE** | `ActionController::Live`, chunked bodies, `send_stream` | ❌ | P2 |
| G47 | **HTTP Range / X-Sendfile** | `send_file` with ranges, `X-Sendfile`, Thruster acceleration | 🟡 `send_file`/`send_data` exist; no ranges or X-Sendfile | P2 |
| G48 | **CORS middleware** | `rack-cors` (ecosystem) or custom middleware | ❌ (Braxy hand-rolled headers in a base controller) | P0 |
| G49 | **Host authorization** | `config.hosts`, `ActionDispatch::HostAuthorization` | ❌ | P1 |
| G50 | **IP spoof protection** | `ActionDispatch::RemoteIp` + trusted proxies | ❌ (no trusted-proxy config) | P1 |
| G51 | **Body size / timeouts** | `config.action_dispatch.*`, server timeouts; Rack limits | ❌ (stdlib server defaults) | P1 |
| G52 | **Permissions-Policy header** | `config.permissions_policy` DSL | ❌ (CSP + frame/referrer headers exist) | P2 |
| G53 | **Per-form CSRF tokens / masked tokens** | `per_form_csrf_tokens`, `masked_authenticity_token` | 🟡 one session token, unmasked | P2 |
| G54 | **CSP nonces** | `content_security_policy_nonce`, per-request directives | 🟡 static CSP only | P2 |
| G55 | **Params wrapping** | `wrap_parameters format: [:json]` | ❌ | P2 |
| G56 | **`params.expect`** | 8.0 explicit param expectations | 🟡 `require`/`permit` | P2 |
| G57 | **Request variants** | `request.variant = :phone`, per-variant templates | ❌ | P3 |
| G58 | **`rate_limit` controller macro** | `rate_limit to: 10, within: 1.minute` | 🟡 `Saci::Throttle.throttle` module API (no controller macro) | P1 |
| G59 | **`allow_browser`** | Block unsupported browsers by UA | ❌ | P3 |
| G60 | **`http_basic_authenticate_with`** | Basic auth helper | ❌ | P3 |
| G61 | **Exceptions app / error pages** | `config.exceptions_app`, custom 404/500, `rescue_responses` | 🟡 dev error page + `rescue_from`; no exceptions app | P2 |
| G62 | **Health endpoint** | Generated `GET /up` | ❌ | P1 |

---

## 6. Views, assets, frontend

| # | Gap | Rails | Saci today | Priority |
|---|---|---|---|---|
| G63 | **Asset pipeline (Propshaft)** | Digest fingerprinting, `asset_path`, precompile, manifest | ❌ | P1 |
| G64 | **Asset tag helpers** | `image_tag`, `stylesheet_link_tag`, `javascript_include_tag`, `favicon_link_tag` | ❌ (only `link_to`) | P1 |
| G65 | **`button_to`, `content_tag`, `tag` builder** | HTML helpers | ❌ | P2 |
| G66 | **`content_for` / `yield(:head)`** | Named view slots | ❌ (`content` for layout body only) | P1 |
| G67 | **Nested forms** | `fields_for`, `collection_select`, `radio_button`, `number_field`, `email_field` | 🟡 basic fields only (`text_field`, `password_field`, `hidden_field`, `textarea`, `check_box`, `select`, `date_field`, `file_field`, `submit`, `error_messages`) | P1 |
| G68 | **Number/date/time helpers** | `number_to_currency`, `number_with_delimiter`, `time_ago_in_words`, `distance_of_time_in_words`, `l()` | ❌ | P2 |
| G69 | **Text helpers** | `simple_format`, `truncate`, `excerpt`, `pluralize`, `strip_tags`, `highlight` | 🟡 `RichText` has `plain_text`/`excerpt`; no general helpers | P2 |
| G70 | **Turbo Drive** | Full-page navigation, morphing, scroll restoration, cache | 🟡 Frames/Streams only; morph documented out of scope | P1 |
| G71 | **Stimulus** | JS behavior framework + generators | ❌ | P2 |
| G72 | **Importmap / JS bundling** | `importmap-rails`, `jsbundling-rails`, `cssbundling-rails` | ❌ (apps use Vite/CDN, e.g. Braxy) | P1 |
| G73 | **View components / partial collections** | `render @posts`, `render partial:`, `as:`, `locals:` | 🟡 `render_partial(path, collection:/as:)` | P2 |
| G74 | **Template engines** | ERB (runtime), Haml/Slim (gems) | 🟡 ECR (compile-time only) | ⛔ structural |
| G75 | **Markdown rendering** | 8.1 `render markdown:` + `.md` format | 🟡 `Views.markdown` exists; no controller renderer/format | P2 |

---

## 7. Mail

| # | Gap | Rails | Saci today | Priority |
|---|---|---|---|---|
| G76 | **Action Mailbox (inbound)** | Ingress → mailboxes → routing, incineration, tests | ❌ | P2 |
| G77 | **Attachments / inline attachments** | `attachments`, `attachments.inline`, multipart | ❌ (text/HTML parts, cc/bcc/reply-to) | P1 |
| G78 | **Delivery providers** | SMTP, SendGrid, Mailgun, Postmark, SES (via gems/adapters) | 🟡 SMTP only | P2 |
| G79 | **DKIM signing** | `dkim` gem | ❌ | P3 |
| G80 | **Parameterized mailers** | `mailer.with(user:).welcome` | ❌ | P3 |
| G81 | **Mailer callbacks** | `before_action` / `after_action` / `rescue_from` in mailers | ❌ | P3 |
| G82 | **Mailer test helpers** | `assert_emails`, `assert_enqueued_email_with` | ❌ | P2 |
| G83 | **`deliver_later` wait/queue** | `deliver_later(wait: 5.minutes)`, `wait_until` | 🟡 `deliver_later` renders now, delivers later (no wait options) | P2 |

---

## 8. Storage & rich text

| # | Gap | Rails | Saci today | Priority |
|---|---|---|---|---|
| G84 | **Cloud services** | S3, GCS, Azure (deprecated in 8.1) | 🟡 Disk only | P1 |
| G85 | **Direct uploads** | Browser → cloud, signed blobs | ❌ (uploads proxy through app) | P2 |
| G86 | **Image variants / transformations** | `variant(resize_to_limit:)`, libvips/minimagick | ❌ | P2 |
| G87 | **Previews** | PDF/video previews | ❌ | P2 |
| G88 | **Metadata analysis** | Width/height/duration, `blob.analyze` | ❌ | P3 |
| G89 | **Model attachment macros** | `has_one_attached`, `has_many_attached`, `attach`, `purge_later` | ❌ (service-level API; Braxy hand-rolled avatars/files) | P1 |
| G90 | **Mirroring / service switching** | `mirror:` across services | ❌ | P3 |
| G91 | **Action Text attachments** | Embedded attachables, `ActionText::Attachment` | ❌ (sanitized HTML + plain text only) | P2 |
| G92 | **Trix bundled** | `action_text:install` ships Trix | 🟡 documented CDN snippet | P3 |

---

## 9. Cable & jobs

| # | Gap | Rails | Saci today | Priority |
|---|---|---|---|---|
| G93 | **Solid Cable** | DB-backed pub/sub, no Redis | 🟡 Redis adapter (Solid Cable absent) | P2 |
| G94 | **`stream_for` / `broadcasting_for`** | Record-derived stream names | 🟡 manual string streams (`room_1`) | P2 |
| G95 | **`periodically` timers** | Channel timer helper | ❌ | P2 |
| G96 | **Remote disconnect** | `ActionCable.server.remote_connections.where(...).disconnect` | ❌ | P2 |
| G97 | **Cable test helpers** | `assert_broadcasts`, `assert_no_broadcasts` | ❌ | P2 |
| G98 | **Solid Queue** | DB-backed jobs with `FOR UPDATE SKIP LOCKED` | 🟡 `:db` adapter (own schema), no SKIP LOCKED/process supervision | P2 |
| G99 | **Job adapters** | Sidekiq, Resque, Delayed Job, Solid Queue, etc. | 🟡 `:inline/:async/:test/:db` | P2 |
| G100 | **Job continuations (8.1)** | Resume interrupted multi-step jobs | ❌ | P2 |
| G101 | **Job priorities / unique jobs / batches** | `queue_as :high`, `limits_concurrency`, `good_job`/Sidekiq features | 🟡 concurrency limits exist; no priorities/uniqueness/batches | P2 |
| G102 | **Job callbacks / middleware** | `before_enqueue`, `around_perform`, `rescue_from`, adapters middleware | 🟡 `retry_on`/`discard_on`/`on_error` | P2 |
| G103 | **GlobalID arguments** | Pass records to jobs | 🟡 JSON args only | P2 |
| G104 | **Job scheduling** | `set(wait:)`, `perform_later`, `wait_until`, mailer `deliver_later(wait:)` | ✅ `set(wait:)`, `wait_until`, `deliver_later(wait:)` all exist | — |

---

## 10. Testing

| # | Gap | Rails | Saci today | Priority |
|---|---|---|---|---|
| G105 | **Fixtures** | YAML fixtures, `fixtures :all` | ❌ | P1 |
| G106 | **Factories** | FactoryBot (ecosystem) | ❌ | P1 |
| G107 | **Transactional tests** | Each test in a rolled-back transaction | ❌ (`clean_database!` truncation) | P1 |
| G108 | **System/browser tests** | `ActionDispatch::SystemTestCase` + Capybara/Selenium | ❌ | P2 |
| G109 | **Mailer/job/cable assertions** | `assert_emails`, `assert_enqueued_with`, `assert_broadcasts` | ❌ | P1 |
| G110 | **Time helpers** | `travel_to`, `freeze_time`, `travel_back` | ❌ | P1 |
| G111 | **Assertion helpers** | `assert_changes`, `assert_difference`, `assert_no_difference`, `assert_queries` | ❌ (Crystal Spec matchers only) | P2 |
| G112 | **Parallel tests** | `parallelize(workers: :number_of_processors)` with DB clones | ❌ (and parallel runs against one SQLite file corrupt WAL — observed) | P1 |
| G113 | **Test DB lifecycle** | Auto create/schema load/clean between runs | ❌ | P1 |
| G114 | **Integration test session** | `ActionDispatch::IntegrationTest`, `open_session` | ✅ `Saci::TestSession` (good) | — |

---

## 11. CLI, generators, Railties

| # | Gap | Rails | Saci today | Priority |
|---|---|---|---|---|
| G115 | **`destroy` generator** | `rails destroy model Post` | ❌ | P2 |
| G116 | **Generator breadth** | `authentication`, `mailbox`, `task`, `helper`, `test`, `system_test`, `benchmark`, `resource`, `channel --no-*`, `scaffold --api` | 🟡 model/controller/migration/channel/job/mailer/scaffold/admin | P2 |
| G117 | **Auth generator** | `rails g authentication` (session, resets, metadata) | 🟡 auth shelf + admin generator, no generator | P2 |
| G118 | **User tasks** | `lib/tasks/*.rake`, `rails g task` | ❌ (`saci runner` scripts only) | P1 |
| G119 | **CLI surface** | `about`, `stats`, `notes`, `middleware`, `dbconsole`, `dev:cache`, `log:clear`, `tmp:clear`, `time:zones`, `initializers`, `routes --expanded/--grep`, `credentials:fetch` | 🟡 new/generate/serve/test/db:*/routes/runner/console/seed/secret/credentials/version | P2 |
| G120 | **`bin/setup`, `bin/dev`, `bin/ci`** | Standard binstubs | ❌ | P1 |
| G121 | **Local CI (8.1)** | `config/ci.rb` + `bin/ci` DSL | ❌ | P2 |
| G122 | **`app:update` / templates** | Framework upgrade + app templates | ❌ | P2 |

---

## 12. Security

| # | Gap | Rails | Saci today | Priority |
|---|---|---|---|---|
| G123 | **Encrypted attributes** | `encrypts` (G22) | ❌ | P1 |
| G124 | **Host authorization** | G49 | ❌ | P1 |
| G125 | **CORS** | G48 | ❌ | P0 |
| G126 | **Permissions-Policy** | G52 | ❌ | P2 |
| G127 | **CSRF hardening** | Per-form + masked tokens | 🟡 single token | P2 |
| G128 | **CSP nonces** | G54 | 🟡 static CSP | P2 |
| G129 | **Session stores** | Cookie, cache, ActiveRecord, Redis; `expire_after`, `secure`, `same_site` | 🟡 encrypted cookie store only (4KB limit) | P1 |
| G130 | **Cookie serializer / rotations** | `:json`/`:hybrid`, `cookies_rotations` | 🟡 signed/encrypted jars; no serializer modes/rotation | P1 |
| G131 | **Rate limiting** | `rate_limit` macro + `rack-attack` | 🟡 module-level Throttle (memory/Redis) | P1 |
| G132 | **Filter parameters** | `filter_parameters` + `filter_redirect`; 12 default keys | 🟡 `filter_parameters` list (4 default keys) + request-log filtering; no redirect filtering | P2 |
| G133 | **Security headers** | Defaults + `default_headers` config | ✅ CSP, frame-options, referrer-policy, nosniff | — |
| G134 | **Credentials** | Multi-env credentials, `fetch`, `diff`, key rotation | 🟡 single encrypted file + master key | P2 |

---

## 13. Operations & deployment

| # | Gap | Rails | Saci today | Priority |
|---|---|---|---|---|
| G135 | **Dockerfile / devcontainer** | Generated with Thruster | ❌ (Braxy hand-wrote one) | P1 |
| G136 | **Kamal deploy** | Kamal 2 config, proxy, secrets | ❌ | P2 |
| G137 | **Thruster** | Compression, X-Sendfile, asset caching | ❌ | P2 |
| G138 | **Puma config** | workers/threads/timeouts/pid/state, phased restart | ❌ (stdlib server; MT threads only) | P1 |
| G139 | **Process cluster / zero-downtime** | Puma cluster + `pumactl`, systemd, Kamal | ❌ (no graceful drain, no process manager) | P1 |
| G140 | **Health endpoint** | `/up` | ❌ | P1 |
| G141 | **Structured logging** | `TaggedLogging`, `config.log_tags`, lograge, `query_log_tags`, slow query log, `BroadcastLogger` | 🟡 `Saci.tagged` + `filter_parameters`; no automatic request tags, structured/lograge output, slow-query log, or multi-logger | P2 |
| G142 | **Error reporting** | `Rails.error`, subscribers, Sentry/Honeybadger | ❌ (logs only) | P2 |
| G143 | **Structured events (8.1)** | `Rails.event.notify`, context/tags, subscribers | ❌ | P2 |
| G144 | **APM / OpenTelemetry** | Ecosystem instrumentation | ❌ | P2 |
| G145 | **Solid Cache** | DB-backed cache, no Redis | 🟡 memory/Redis | P2 |
| G146 | **TLS / HTTP/2 / early hints** | Proxy or server config | ⛔ behind proxy (same as most Rails deploys) | P3 |
| G147 | **`config/database.yml`** | YAML, per-env, pool, replicas | 🟡 `DATABASE_URL` env + `DATABASE_URL_<NAME>` | P2 |
| G148 | **Config files (`cable.yml`, `cache.yml`, `queue.yml`, `recurring.yml`, `storage.yml`, `puma.rb`)** | Declarative per-env config | 🟡 env vars + code | P2 |

---

## 14. Time, I18n, Active Support core

| # | Gap | Rails | Saci today | Priority |
|---|---|---|---|---|
| G149 | **Time zones** | `Time.zone`, `in_time_zone`, per-user zones, DST | ❌ (UTC only) | P1 |
| G150 | **Time/date helpers** | `Time.current`, `Date.current`, `beginning_of_week`, `end_of_month`, `advance`, `change`, `all_day` | ❌ | P1 |
| G151 | **Duration helpers** | `5.minutes`, `2.days.from_now`, `1.megabyte`, `to_fs` | 🟡 `Time::Span` only; no calendar units (`1.month`) | P1 |
| G152 | **String inflections** | `pluralize`, `singularize`, `camelize`, `underscore`, `humanize`, `titleize`, `parameterize`, `tableize`, `classify`, `demodulize`, `constantize` | 🟡 `Inflector` (pluralize/underscore/camelize); no `constantize` (compile-time) | P2 |
| G153 | **Hash/Array core ext** | `symbolize_keys`, `deep_merge`, `slice`, `except`, `to_query`, `to_sentence`, `in_groups_of`, `extract_options!` | ❌ | P2 |
| G154 | **Object core ext** | `try`, `in?`, `presence`, `blank?`, `deep_dup`, `to_param` | 🟡 `blank?`/`present?` in ORM only | P2 |
| G155 | **`ActiveSupport::Concern`** | Mixin with `included`/`class_methods` | 🟡 plain Crystal `module`/`include` | P2 |
| G156 | **`CurrentAttributes`** | Request/job-scoped globals (`Current.user`) | ❌ | P2 |
| G157 | **`ActiveSupport::Deprecation`** | Deprecation warnings with backtraces | ❌ | P3 |
| G158 | **I18n depth** | Locale fallbacks, `l()` date/time formats, pluralization rules per locale, `enforce_available_locales`, exception handler | 🟡 YAML locales, interpolation, `count:`, `with_locale`, header detection | P1 |
| G159 | **`config.i18n.*`** | load_path, fallbacks, default/available locales | 🟡 `Saci::I18n` class setters | P2 |
| G160 | **`Rails.cache` / `Rails.logger` / `Rails.root` globals** | Global facade | 🟡 `Saci::Cache`, `Saci.logger`, `Dir.current` conventions | P2 |
| G161 | **`ActiveSupport::MessageVerifier/Encryptor`** | Signed/encrypted messages, rotations | 🟡 `Saci::Crypto`, vendored AES-GCM, signed IDs | P2 |

---

## 15. Rails 8.x-specific features (Saci has none unless noted)

Size: **S** small, **M** medium, **L** large gap.

| # | Rails 8.x feature | Saci | Size |
|---|---|---|---|
| G162 | **Solid Queue** (DB jobs, 8.0) | 🟡 own `:db` adapter | L |
| G163 | **Solid Cache** (DB cache, 8.0) | 🟡 memory/Redis | L |
| G164 | **Solid Cable** (DB pub/sub, 8.0) | 🟡 Redis only | L |
| G165 | **Kamal 2 deployment** (8.0) | ❌ | L |
| G166 | **Thruster proxy** (8.0) | ❌ | L |
| G167 | **Propshaft default** (8.0) | ❌ | L |
| G168 | **Importmap default** (8.0) | ❌ | L |
| G169 | **Authentication generator** (8.0) | 🟡 auth shelf | M |
| G170 | **`rate_limit` macro** (8.0) | 🟡 Throttle module | M |
| G171 | **`allow_browser`** (8.0) | ❌ | S |
| G172 | **`GET /up` health route** (8.0) | ❌ | S |
| G173 | **Dockerfile + `.dockerignore` generation** (8.0) | ❌ | M |
| G174 | **Devcontainer + CI workflow generation** (8.0) | ❌ (CI is default; devcontainer is opt-in via `--devcontainer`) | M |
| G175 | **`bin/setup`, `bin/dev`, `bin/ci`** (8.0) | ❌ | S |
| G176 | **Active Job continuations** (8.1) | ❌ | M |
| G177 | **Structured event reporting** (`Rails.event`, 8.1) | ❌ | M |
| G178 | **Local CI DSL** (8.1) | ❌ | S |
| G179 | **Markdown rendering** (`render markdown:`, 8.1) | 🟡 `Views.markdown` | S |
| G180 | **`credentials:fetch`** (8.1) | ❌ | S |
| G181 | **Deprecated associations** (`deprecated: true`, 8.1) | ❌ | S |
| G182 | **Registry-free Kamal** (8.1) | ❌ | S |
| G183 | **`params.expect`** (8.0) | 🟡 `permit` | S |
| G184 | **Schema column sorting** (8.1) | n/a | — |

---

## 16. Additional component-level omissions (second-pass audit)

These surfaced while walking the Rails guides component by component (Active Model,
Action View helpers, Action Dispatch, Active Storage/Text internals, config keys). They are
smaller than the sections above but matter for parity.

| # | Gap | Rails | Saci today | Priority |
|---|---|---|---|---|
| G185 | **Non-database models** | `ActiveModel::Model`, `Attributes`, `Type`, `Naming`, `Conversion` for form objects/service inputs | ❌ (everything is a `Record::Base` subclass) | P1 |
| G186 | **`has_one :through`** | One-to-one through a join | ❌ (`has_many :through` exists) | P2 |
| G187 | **Preloading `has_many :through`** | `includes(:tags)` works for through associations | ❌ (`includes` explicitly raises for through) | P1 |
| G188 | **`render` variants** | `render body:`, `file:`, `template:`, `action:`, `partial:`, `render_to_string` | 🟡 only `json/html/xml/text/plain/status/content_type`; templates via compile-time macros | P1 |
| G189 | **HTTP auth helpers** | `authenticate_or_request_with_http_basic`, digest, token | ❌ | P2 |
| G190 | **Static file serving** | `public/` served by `ActionDispatch::Static`, cache headers, `public_file_server` config | ❌ (uploads have a custom controller; no `public/`) | P1 |
| G191 | **Response compression** | gzip/brotli (Thruster or Rack::Deflater) | ❌ | P2 |
| G192 | **View capture/cache helpers** | `capture`, `cache_if`, `cache_unless`, `content_for?` | 🟡 `cache` and `content` only | P2 |
| G193 | **Storage blob/attachment models** | `ActiveStorage::Blob`, `Attachment`, direct-upload and preview endpoints | ❌ (service-level disk files + JSON sidecars) | P1 |
| G194 | **Action Text attachables** | `ActionText::Attachable`, embedded attachments | ❌ | P2 |
| G195 | **SSL config depth** | `config.assume_ssl`, `config.ssl_options`, `force_ssl` host/secure flags | 🟡 `Saci.force_ssl` boolean | P2 |
| G196 | **Dispatch defaults** | `config.action_dispatch.default_headers`, `cookies_same_site_protection`, `cookies_rotations` | 🟡 some headers hardcoded; no rotation | P2 |
| G197 | **MIME registration** | `Mime::Type.register`, custom formats | ❌ (fixed type map) | P2 |
| G198 | **Form tag helpers** | `form_tag`, `text_field_tag`, `select_tag`, `check_box_tag`, … (non-model forms) | ❌ (`FormBuilder` is model/scope oriented) | P2 |
| G199 | **URL helper family** | `link_to_if`, `link_to_unless`, `mail_to`, `phone_to`, `sms_to` | 🟡 `link_to` only | P2 |
| G200 | **Form option/date helpers** | `options_for_select`, `collection_select`, `grouped_collection_select`, `select_date`, `time_zone_select` | 🟡 `select` with simple arrays only | P2 |
| G201 | **Password reset tokens** | `generates_token_for`, `reset_password_token`, `has_secure_password` reset flow | 🟡 `has_secure_password`; no reset-token API | P1 |
| G202 | **Job queue selectors** | `queue_as`, `queue_name_prefix`, `set(queue:)`, priorities | 🟡 queue names exist; no priority or per-enqueue queue selection | P2 |
| G203 | **Cable identifiers** | `identified_by :current_user`, connection objects, `remote_connections` | 🟡 token lookup inside `subscribed` | P2 |
| G204 | **Mailer view helpers** | `mail_to`, `mailer` URL helpers | ❌ | P3 |
| G205 | **General text sanitization** | `sanitize`, `strip_tags`, `strip_links` in views | 🟡 `RichText` sanitizer only | P2 |
| G206 | **Connection pool introspection** | `connection_pool.stat`, `connection_db_config`, `with_connection` | ❌ (pool tunable via URL params only) | P2 |

**Helper families not itemized above** (all absent or partial, grouped for brevity):
`AssetTagHelper` (G63/G64), `AtomFeedHelper` (Saci has `rss_feed`), `BenchmarkHelper`,
`CacheHelper` (`cache_if`/`cache_unless`), `CaptureHelper` (`capture`), `CsrfHelper`
(`csrf_meta_tags`), `CspHelper` (`csp_meta_tag`), `DateHelper` (`time_tag`, selects),
`DebugHelper` (`debug`), `FormOptionsHelper` (G200), `FormTagHelper` (G198),
`JavaScriptHelper` (`javascript_tag`, `escape_javascript`), `NumberHelper` (G68),
`OutputSafetyHelper` (`safe_join`, `escape_once`), `RecordTagHelper` (`div_for`),
`SanitizeHelper` (G205), `TagHelper` (`tag`, `content_tag`), `TextHelper` (`truncate`,
`highlight`, `word_wrap`, `excerpt`), `TranslationHelper` (`t`, `l`), `UrlHelper` (G199).

---

## 17. Structural differences (not fixable, plan around them)

| # | Difference | Consequence |
|---|---|---|
| G207 | **No runtime eval / interpreter** | No real REPL, no `eval`, no `constantize`, no `method_missing`-driven DSLs, no runtime route reloading |
| G208 | **Compile-time everything** | No Zeitwerk/autoload/reload; every change recompiles; macros run at compile time; no monkey patching |
| G209 | **Static typing** | No `send`, no duck-typed metaprogramming; generic libraries must be written against explicit module boundaries (Saci uses `previous_def`/`super` codegen instead) |
| G210 | **No Gems** | Shards are source dependencies at compile time; no Devise/Pundit/Sidekiq/RSpec/Kaminari/ActiveAdmin/FactoryBot ecosystem; no `bundle add` |
| G211 | **ECR instead of ERB** | Templates are compiled into the binary; no runtime template editing, no Haml/Slim gems |
| G212 | **Threads, not processes** | Crystal MT shares one heap; no Puma worker isolation, so a hard crash takes the whole process |
| G213 | **Smaller community** | Fewer answers, fewer third-party integrations, fewer hires |
| G214 | **No Rack middleware ecosystem** | Handlers are Crystal `HTTP::Handler`s; Rack gems are unusable |

---

## 18. Expanded gap catalog (scaffold + module audit)

Method for this section: generated a real `rails new` app with **Rails 8.1.3.1** in a Ruby 3.3
container, generated a `saci new --db=postgres` app, diffed both trees, then installed the
Rails gems and enumerated every component's module files (see Appendices B–D). Items already
covered above are marked *(see G…)*; the rest are new.

### 18.1 Scaffold, tooling, and project conventions

| # | Gap | Rails 8.1 `rails new` | `saci new` today | Priority |
|---|---|---|---|---|
| G215 | **Project binstubs** | `bin/rails`, `bin/rake`, plus `bin/rails restart` | Global `saci` binary only; no project-local wrapper | P2 |
| G216 | **`config.ru` / Rack contract** | Rack entrypoint (`run Rails.application`) | Boots directly via `Saci::Application#listen`; no Rack interface | P2 |
| G217 | **Boot cache** | `config/boot.rb` + Bootsnap precompile (app, gems) | Compiles at build; no boot-time cache/preload | P2 |
| G218 | **`public/` error pages** | `400/404/406/422/500.html`, `robots.txt`, icons | No `public/`; errors rendered by router/dev page | P1 |
| G219 | **PWA files** | `app/views/pwa/manifest.json.erb`, `service-worker.js` + commented routes | None | P3 |
| G220 | **Helper modules** | `app/helpers/application_helper.rb`, per-controller helpers, `helper_method` | View macros only; no helper modules or controller→view exposure | P2 |
| G221 | **Concern directories** | `app/models/concerns`, `app/controllers/concerns`, autoloaded | Plain Crystal modules; no dedicated dirs/autoload | P2 |
| G222 | **Mailer layout files** | `app/views/layouts/mailer.html.erb` + `.text.erb` | Layouts registered in code (`Mailer.register_layout`) | P3 |
| G223 | **Default test tree** | `test/{controllers,models,mailers,helpers,integration,fixtures}/`, `application_system_test_case.rb` | `spec/` only | P1 *(see G105/G108)* |
| G224 | **`storage/` root** | ActiveStorage local root | `uploads/` (custom) | P3 |
| G225 | **Project runtime dirs** | `tmp/pids`, `log/`, `vendor/`, `script/` | Minimal (`tmp/` for runner wrappers only) | P3 |
| G226 | **Runtime pin** | `.ruby-version` (and `.tool-versions` commonly) | `shard.yml` Crystal constraint only | P3 |
| G227 | **Lint/security tooling** | `bin/rubocop`, `.rubocop.yml`, `bin/brakeman`, `bin/bundler-audit`, `config/bundler-audit.yml`, importmap audit, Dependabot | None in generated apps | P2 |
| G228 | **Dependency groups** | `Gemfile` `:development`/`:test` (debug, web-console, etc.) | Single `shard.yml` dependency list | P2 |
| G229 | **Task files** | `Rakefile` + `lib/tasks/*.rake` | `saci runner` scripts; no task file convention | P1 *(see G118)* |
| G230 | **Container entrypoint** | `bin/docker-entrypoint` runs `db:prepare` before server | No entrypoint / boot-time DB preparation | P1 |
| G231 | **`bin/thrust`** | Thruster proxy launcher in the image | No proxy | P2 *(see G137)* |
| G232 | **Devcontainer generator** | Opt-in `--devcontainer` (not default) | None | P3 |

### 18.2 Active Record / Active Model internals

| # | Gap | Rails | Saci today | Priority |
|---|---|---|---|---|
| G233 | **Dynamic finders** | `find_by_email`, `find_by_email!`, `find_or_initialize_by_email` | ❌ (only `find_by(email:)`) | P2 |
| G234 | **`composed_of` value objects** | Map columns to value objects | ❌ | P3 |
| G235 | **Async queries** | `load_async`, async `count`/`sum`/`average`/`minimum`/`maximum`, `FutureResult` | ❌ (synchronous only) | P2 |
| G236 | **Query/statement cache** | Per-request query cache, prepared statement cache | ❌ (each query executes) | P2 |
| G237 | **`attr_readonly`** | Immutable-after-create attributes | ❌ | P3 |
| G238 | **`no_touching`** | Suppress `updated_at` bumps in a block | ❌ | P3 |
| G239 | **`ActiveRecord::Suppressor`** | Suppress callbacks for a block | ❌ | P3 |
| G240 | **Autosave associations** | `autosave: true`, save parent/children together | ❌ (manual nested saves) | P2 |
| G241 | **`disable_joins`** | Through associations without JOINs (sharded/remote) | ❌ | P3 |
| G242 | **Pool checkout API** | `with_connection`, `lease_connection`, `connection_pool.with_connection` | ❌ (global connection only) | P2 |
| G243 | **Model naming / i18n** | `model_name`, `human_attribute_name`, translated validation messages | 🟡 validation messages English; no model-name API | P2 |
| G244 | **Serialization codecs** | Marshal, MessagePack, `ActiveRecord::Base#serializable_hash(options)` | 🟡 JSON via `to_json`; no options/codecs | P3 |

### 18.3 Action Pack / Action View internals

| # | Gap | Rails | Saci today | Priority |
|---|---|---|---|---|
| G245 | **Controller→view helpers** | `helper_method :current_user`, `helper`, `helpers` | ❌ (views cannot call controller methods) | P1 |
| G246 | **ETag variants** | `etag_with_flash`, `etag_with_template_digest` | 🟡 ETag from body/record; flash/templates not included | P2 |
| G247 | **Default headers config** | `ActionController::DefaultHeaders` (configurable) | 🟡 hardcoded defaults | P2 *(see G196)* |
| G248 | **Server-Timing** | `ActionDispatch::ServerTiming` | ❌ | P3 |
| G249 | **Actionable exceptions** | Dev error page "run this fix" actions | ❌ | P3 |
| G250 | **Debug tooling** | `DebugLocks`, `DebugView` middleware | ❌ | P3 |
| G251 | **HTTP cache middleware** | `Rack::Cache` integration | 🟡 ETag/`fresh_when` only; no shared cache | P2 |
| G252 | **Uploaded-file API** | `ActionDispatch::Http::UploadedFile` (tempfile, headers, content type) | 🟡 multipart handling via stdlib/params; data-URL upload in apps | P2 |
| G253 | **URL introspection** | `url_for`, `full_url_for`, `request.domain`, `subdomain`, `port` | 🟡 request has raw headers; no URL builder | P1 *(see G4/G45)* |
| G254 | **Polymorphic routes** | `polymorphic_path`, `edit_polymorphic_path` | ❌ | P2 |
| G255 | **Route mapper depth** | `concern`, `direct`, `resolve`, `mount`, `shallow`, `member`, `collection` | 🟡 `resources`/`resource`/`namespace`/`scope` only | P2 |
| G256 | **Route introspection** | `recognize_path`, `url_helpers`, `routes.inspect` | 🟡 static `saci routes` parser | P2 |
| G257 | **DOM identifiers** | `dom_id`, `dom_class` | ❌ | P2 |
| G258 | **View model naming** | `model_name` / `ModelNaming` for forms/URLs | ❌ | P2 |
| G259 | **Template digests** | `ActionView::Digestor`, dependency tracker | ❌ | P2 |
| G260 | **Template variants/formats/locale** | `variants:`, `formats:`, locale-specific templates | ❌ | P3 |
| G261 | **View path lookup** | `LookupContext`, multiple `view_paths`, resolvers | 🟡 single compile-time views root | P2 |
| G262 | **Controller helper in views** | `controller`, `action_name` available to views | ❌ | P3 |
| G263 | **Form error helpers** | `error_message_on`, `error_messages_for` | 🟡 `error_messages` only | P3 |
| G264 | **Output safety helpers** | `safe_join`, `escape_once` | 🟡 `h`/raw-style output only | P2 |
| G265 | **Benchmark helper** | `benchmark("label") { ... }` in views | ❌ | P3 |
| G266 | **View test helpers** | `ActionView::TestCase`, `assert_select` | ❌ | P2 |

### 18.4 Active Support / Railties / Cable internals

| # | Gap | Rails | Saci today | Priority |
|---|---|---|---|---|
| G267 | **Multi-logger** | `ActiveSupport::BroadcastLogger` | ❌ | P3 |
| G268 | **Execution isolation** | `ActiveSupport::IsolatedExecutionState` (fiber/thread state) | 🟡 fiber-local tag stack only | P2 |
| G269 | **Execution wrapper** | `ExecutionWrapper` (run/complete hooks, reload integration) | ❌ | P2 |
| G270 | **Fork tracking** | `ForkTracker` (reset connections after fork) | ❌ | P3 |
| G271 | **Actionable errors** | `ActiveSupport::ActionableError` | ❌ | P3 |
| G272 | **Option containers** | `OrderedOptions`, `HashWithIndifferentAccess`, `StringInquirer` | 🟡 env predicates; params are string-keyed | P2 |
| G273 | **Class attributes** | `class_attribute`, `cattr_accessor`, `mattr_accessor` | 🟡 class vars by hand | P2 |
| G274 | **Safe buffers** | `ActiveSupport::SafeBuffer`, `ERB::Util.html_escape` | 🟡 view `h()` / raw output | P2 |
| G275 | **JSON options** | `as_json(only:, except:, methods:)`, `to_json` options | 🟡 plain `to_json` | P2 |
| G276 | **XML support** | `ActiveSupport::XmlMini` | ❌ | P3 |
| G277 | **Unicode helpers** | `Multibyte::Chars` (`mb_chars`, grapheme handling) | ❌ (Crystal stdlib Unicode only) | P3 |
| G278 | **Config files** | `ActiveSupport::ConfigurationFile`, `Rails.application.config_for` | ❌ | P2 *(see G7)* |
| G279 | **Descendant tracking** | `DescendantsTracker` (`subclasses`, `descendants`) | 🟡 `inherited` codegen for actions/models | P2 |
| G280 | **File-update checking** | `FileUpdateChecker` / `EventedFileUpdateChecker` (reload) | 🟡 `--watch` polls/rebuilds | P2 *(see G2)* |
| G281 | **Cable concurrency** | Server worker pool, stream event loop, message buffer | 🟡 one fiber per connection; no worker pool | P2 |
| G282 | **Cable PostgreSQL adapter** | `SubscriptionAdapter::PostgreSQL` | 🟡 async + Redis only | P2 *(see G93)* |

### 18.5 PostgreSQL native type coverage

Rails' PostgreSQL adapter ships OID classes for `array`, `bit`, `bit_varying`, `bytea`, `cidr`,
`date`, `datetime`, `decimal`, `enum`, `hstore`, `inet`, `interval`, `jsonb`, `macaddr`,
`money`, `oid`, `point`, `range`, `timestamp`, `timestamptz`, `uuid`, `vector` (pgvector), and
`xml`. Saci covers booleans, integers, floats, decimals, strings, text, dates, timestamps
(with precision), JSON/JSONB, string arrays, and enums. MySQL similarly has `unsigned`,
`zerofill`, `SET`, spatial types (`geometry`, `point`, `linestring`, `polygon`), and
generated/virtual columns; Saci maps enum/array/precision and JSON→TEXT and lacks the rest.

| # | Gap | Rails PG adapter | Saci today | Priority |
|---|---|---|---|---|
| G283 | **UUID columns / primary keys** | `t.uuid`, `gen_random_uuid()`, UUID PKs | ❌ (no `:uuid` DSL or UUID read/write) | P1 |
| G284 | **Structured PG types** | `hstore`, `inet`, `cidr`, `macaddr`, `interval`, `money`, `bit`, `point`, `range`, `xml`, `oid` | ❌ (only enum/array/json/precision) | P2 |
| G285 | **pgvector** | `vector` OID + `t.vector` (Rails 8) | ❌ | P3 |
| G286 | **Binary columns** | `bytea` via `t.binary` / `:binary` | 🟡 `Bytes` read type exists; no migration `:binary` DDL mapping | P2 |

### 18.6 Method-level gaps surfaced by the audit

| # | Gap | Rails | Saci today | Priority |
|---|---|---|---|---|
| G287 | **HTTP cache helpers** | `http_cache_forever`, `expires_now`, `cache_control` | 🟡 `expires_in`, `fresh_when`, `stale?` only | P2 |
| G288 | **Open-redirect protection** | `redirect_to allow_other_host:`, `raise_on_open_redirects`, host allowlist | ❌ (no host check on `redirect_to`) | P1 |
| G289 | **Regexp DoS protection** | Rails 8 sets `Regexp.timeout = 1s` by default | ❌ (no global regex timeout) | P2 |
| G290 | **Extra default headers** | HSTS, `X-Download-Options`, `X-Permitted-Cross-Domain-Policies`, etc. | 🟡 CSP/frame/referrer/nosniff only; no HSTS or the extra headers | P3 |
| G291 | **Relation predicates** | `any?`, `many?`, `none?`, `one?` | ❌ | P2 |
| G292 | **`Relation#ids`** | `ids` (primary keys without loading records) | ❌ (`pluck(:id)` works, no `ids`) | P2 |
| G293 | **Ordinal finders** | `second`, `third`, `fifth`, `forty_two`, `second_to_last`, `third_to_last` | ❌ | P3 |
| G294 | **Persistence helpers** | `update_attribute`, `update_column`, `increment!`, `decrement!`, `toggle!`, `destroy!` | 🟡 `update_columns` exists; the rest absent | P2 |

### 18.7 Case-study gaps from a production Rails 8 + MySQL app

A 359-model production Rails backend with a 561-file GraphQL layer, 44 Sidekiq workers,
14 CarrierWave uploaders, 303 HAML views, and a legacy ActiveAdmin app. These gaps were
exercised by the original code (counts in Section 29), not inferred from the guides.

| # | Gap | Rails usage in the app | Saci today | Priority |
|---|---|---|---|---|
| G295 | **Validator objects** | `validates_with DateRangeValidator` (14 files), custom `ActiveModel::Validator` classes | ❌ (only `validate :method` / built-in `validates`) | P1 |
| G296 | **Validation DSL flexibility** | `length: {is: 15}`, dynamic `inclusion: {in: States.list}`, `validates_presence_of`/`validates_uniqueness_of` aliases | 🟡 `length: {in:/within:}`, literal arrays only, `validates` only | P1 |
| G297 | **Exact decimal/numeric columns** | money, prices, fees (`Decimal` everywhere) | 🟡 `Decimal` is **Float64-backed**; `t.decimal` → `DOUBLE PRECISION`/`REAL` | P0 |
| G298 | **Native date columns** | `birth_date`, `return_date`, invoice dates | 🟡 `Date` is **Time-backed**; no date-only semantics | P1 |
| G299 | **Assigned timestamps on create** | records created with explicit `created_at:`/`updated_at:` (Rails preserves them on create) | ❌ `timestamps` macro always overwrites with `Time.utc` | P2 |
| G300 | **Subdomain/tenant helpers** | `request.subdomain`, host-based chain lookup, `default_url_options` | 🟡 raw `Host` header only; no `subdomain`/host constraints | P1 |
| G301 | **GraphQL server layer** | 561 GraphQL files, 485 references, schema/types/mutations, GraphiQL, batched Apollo | ❌ (no schema/type/mutation layer) | P1 |
| G302 | **Grape/OpenAPI API layer** | `PublicApi::Root` mounted at `/api`, Grape entities, Swagger | ❌ (plain JSON controllers only) | P2 |
| G303 | **Ransack-style filter DSL** | 90 references, 46 files, search forms + `ransackable_*` | ❌ (manual query params/scopes) | P2 |
| G304 | **Serializer layer** | 23 ActiveModelSerializers, `attributes`/`has_many`, JSON shaping | ❌ (hand-written `wire_json`/`to_json`) | P2 |
| G305 | **Audit trail** | custom `Audit` + `Auditable`, 1,573 references, user/tenant context | ❌ | P1 |
| G306 | **Authorization policy DSL** | `Ability` + role matrices, `can?`, `require_feature` | ❌ | P1 |
| G307 | **2FA/TOTP + QR** | admin: `devise-two-factor`, `rqrcode` | ❌ | P2 |
| G308 | **Spreadsheet/PDF generation** | `caxlsx`, `roo`, `xlsxtream`, `prawn`, `wkhtmltopdf` | ❌ | P2 |
| G309 | **GIS/spatial columns** | `rgeo`/polygons, point-in-polygon | ❌ (no spatial types) | P2 |
| G310 | **JWT encode/decode** | `jwt` (14 references), bearer tokens for mobile/public APIs | 🟡 opaque tokens/signed IDs; no JWT | P2 |
| G311 | **MySQL dialect helpers** | `EXTRACT`, `TIMESTAMPDIFF`, `MATCH … AGAINST`, `JSON_EXTRACT`, `CONVERT_TZ` | ❌ (no dialect helpers) | P2 |

---

## 19. Prioritized backlog (suggested order)

**P0 — parity blockers**
0. **Fix `saci new --db=postgres`** (Appendix D1, one-line template bug) — every new PG app
   currently fails `shards install`.
1. G4 named route helpers (M) — biggest daily DX win, self-contained.
2. G10 dirty tracking (M) — needed by almost any nontrivial model.
3. **G297 exact decimal/numeric** (M) — money cannot be stored as Float64/DOUBLE; pricing-heavy
   apps hit this on every price/fee/installment.
4. G5 + G48 middleware insertion + CORS (M) — removes the "fork the boot" ceiling.
5. G1/G2 autoloading/reload (XL) — the structural gap; could start with "glob everything + compile-on-change daemon" rather than true reloading.
6. G6 initializers lifecycle (S) — cheap, unblocks configuration patterns.

**P1 — common Rails app needs**
Dirty tracking follow-ons (G11–G13, G19, G21–G23, G26–G27, G186–G187), migration helpers (G35–G40), `around_action`/`redirect_back` (G42/G44), asset/JS story (G63–G64, G68, G70–G72), non-DB form objects (G185), `render` variants (G188), helper exposure (G245), URL building (G253), mail attachments (G77), attachment macros and blob models (G89, G193), session stores (G129), host/IP hardening (G49–G50), rate-limit macro (G58), health endpoint (G62), static serving + error pages (G190, G218), password resets (G201), test fixtures/transactions/parallelism (G105–G113), time zones/durations (G149–G151), I18n depth (G158), Dockerfile/Puma/deploy (G135, G138–G140), project binstubs/entrypoint/tasks (G215, G229–G230), scaffold test tree (G223), validator objects/dynamic validation (G295–G296), native date semantics (G298), subdomain helpers (G300), GraphQL (G301), audit trail (G305), authorization DSL (G306).

**P2/P3 — depth and ecosystem**
Solid trio (G162–G164), Action Mailbox (G76), Active Storage cloud/variants (G84–G88), Action Text attachments (G91), job continuations/priorities (G100–G103), streaming (G46), CSP nonces/CSRF hardening (G53–G54), engines (G8), sharding/replicas (G24–G25), composite keys (G23), database views (G32), PostgreSQL native types (G283–G286), Kamal/Thruster (G165–G166), structured events (G177), APM (G144), module-depth items (G233–G282), Ransack/serializers (G303–G304), 2FA/QR (G307), XLSX/PDF (G308), GIS (G309), JWT (G310), MySQL dialect helpers (G311).

**Do not attempt** — G207–G214. These are consequences of Crystal's design; the right move is documenting the workaround (as Saci already does for `send`, runtime macros, `__DIR__`, etc.).

---

## 20. Appendix A — verification map

| Claim area | Verified in Saci at |
|---|---|
| Router: `resources`, `namespace`, `scope`, constraints, no names | `src/saci/router.cr` |
| Controller filters, `rescue_from`, `respond_to`, `send_file`, `fresh_when`, `expires_in`; no `around_action`/`redirect_back` | `src/saci/controller.cr`, `src/saci/views.cr` |
| ORM associations, `includes` preload, counter cache, touch, `dependent`, `find_each`, `pluck`, `update_all`, `or`, `where.not`; no dirty tracking/bulk insert/locks | `src/saci/record/base.cr`, `src/saci/record/query.cr` |
| Migration DSL: create/add/change/rename/remove/index/FK/enums/arrays/precision; no `execute`/`reversible`/`change_table`/check constraints | `src/saci/record/migration.cr` |
| Schema dump/load/check, FTS | `src/saci/record/schema.cr`, `schema_check.cr`, `fts.cr` |
| Jobs: adapters inline/async/test/db, retry/discard, dashboard, recurring | `src/saci/job.cr`, `job_db.cr`, `job_dashboard.cr`, `recurring.cr` |
| Mailer: SMTP, layouts, previews, RFC 2047, cc/bcc; no attachments | `src/saci/mailer.cr`, `smtp.cr` |
| Cable: WS channels, Redis adapter; no presence/periodic helper | `src/saci/cable.cr` |
| Storage: disk, sharded keys, signed URLs, rotation, public mode; no cloud/variants | `src/saci/storage.cr` |
| Rich text sanitizer; no attachments | `src/saci/rich_text.cr` |
| Turbo frames/streams; no Drive/Stimulus | `src/saci/turbo.cr` |
| Cache memory/Redis, fragments, page cache | `src/saci/cache.cr`, `page_cache.cr` |
| Security: CSRF, sessions, cookies, secure headers, CSP, throttle, credentials | `src/saci/csrf.cr`, `session.cr`, `cookies.cr`, `secure_headers.cr`, `throttle.cr`, `credentials.cr` |
| I18n: YAML, interpolation, `count:`, locale header; no fallbacks/date formats | `src/saci/i18n.cr` |
| CLI: new/generate/serve/test/db/runner/console/seed/secret/credentials/routes | `src/saci/cli/*`, `src/saci/cli.cr` |
| MT: `-Dexecution_context` + `SACI_MT` | `src/saci/concurrency.cr` |
| No initializers/`config/application.rb`-style config object | repo root + `config/environments/*` glob only |

**Rails sources**

- Rails 8.1 release notes — https://guides.rubyonrails.org/8_1_release_notes.html
- Rails 8.0 release notes — https://guides.rubyonrails.org/8_0_release_notes.html
- Guides index (component list) — https://guides.rubyonrails.org/
- Reference app `lobsters` (Rails 8.1.3.1): `Gemfile.lock`, `config/application.rb`,
  `config/initializers/*` (session store, cookies serializer, wrap_parameters, per-request
  token, permissions policy, CSP, query log tags, IP spoof rejection), `config/cable.yml`,
  `cache.yml`, `queue.yml`, `recurring.yml`, `storage.yml`, `importmap.rb`.

---

## 21. Appendix B — scaffold diff (`rails new` vs `saci new`)

Both apps were generated on 2026-10-19:

- Rails `8.1.3.1`, Ruby 3.3 container, `rails new app --skip-bundle --skip-git`.
- Saci `0.4.0`, `saci new app --db=postgres`.

**Caveat:** `--skip-bundle` prevents Rails' post-bundle install steps (`importmap:install`,
`turbo:install`, `stimulus:install`), so `config/importmap.rb`, `app/javascript/`, and
`bin/importmap` are absent *from this generated copy* but are standard in a normal
`rails new`. Do not read those absences as Rails gaps; they are covered in Section 6.

**Scaffold size (files excluding `.git`):**

| Scaffold | Files |
|---|---:|
| `rails new` (full-stack) | 78 |
| `rails new --api` | 63 |
| `rails new --minimal` | 60 |
| `saci new --db=postgres` | 26 |

The **API scaffold is the fair comparison** for Saci's default (API/ECR-centric), and it is
still ~2.4× the file surface. Rails `--api` keeps the mailer/job bases, `config/initializers/cors.rb`
(with a commented `rack-cors` example), `image_processing`, the Solid trio, CI/tooling, and the
full test/config/puma/database surface; it drops assets, PWA, helpers, and the CSP initializer.
Rails `--minimal` surprisingly keeps assets/PWA/helpers/CSP but drops jobs/mailers. Saci, in
turn, ships staging + Spanish locale by default, which Rails does not (a Saci advantage).

| Category | Rails 8.1 full app | `saci new` | Delta |
|---|---|---|---|
| Total files (scaffold, excl. `.git`) | 78 | 26 | −52 |
| Entrypoints | `config.ru`, `Rakefile`, `bin/rails`, `bin/rake` | `src/app.cr` | no Rack/binstubs |
| Setup/lifecycle | `bin/setup`, `bin/dev`, `bin/ci`, `bin/docker-entrypoint` | README steps only | no binstubs |
| Container | multi-stage `Dockerfile`, `.dockerignore`, `bin/thrust` | none | no deploy artifacts |
| CI / tooling | `.github/workflows/ci.yml` (5 jobs), `dependabot.yml`, `bin/brakeman`, `bin/rubocop`, `bin/bundler-audit` | none | no app CI/lint/security |
| Config | `application.rb`, `boot.rb`, `environment.rb`, `puma.rb`, `database.yml`, `cable.yml`, `cache.yml`, `queue.yml`, `recurring.yml`, `storage.yml`, `ci.rb`, `bundler-audit.yml`, 4 initializers | `config/environments/*.cr`, locales, credentials | fewer config surfaces |
| App structure | `app/{controllers,helpers,jobs,mailers,models,views}` + `concerns/`, `assets/`, `javascript/` | `src/{controllers,channels,jobs,mailers,models,views}` | no helpers/concerns/assets |
| Error/PWA/public | `public/{400,404,406,422,500}.html`, `robots.txt`, icons, `app/views/pwa/*` | none | no static/PWA |
| Tests | `test/test_helper.rb`, `test/{controllers,models,mailers,helpers,integration,fixtures}` | `spec/spec_helper.cr`, `spec/app_spec.cr` | no fixtures/system test tree |
| Runtime dirs | `storage/`, `tmp/pids/`, `log/`, `vendor/`, `script/` | `tmp/` (runner wrappers), `db/` | fewer conventions |
| Runtime pin | `.ruby-version` | `shard.yml` crystal constraint | no project pin |

**Concrete files Saci does not generate** (all Rails 8.1 defaults unless noted):

```
bin/{rails,rake,setup,dev,ci,docker-entrypoint,thrust,brakeman,rubocop,bundler-audit}
config.ru  Rakefile  Dockerfile  .dockerignore  .ruby-version
config/{application.rb,boot.rb,environment.rb,puma.rb,database.yml,cable.yml,
        cache.yml,queue.yml,recurring.yml,storage.yml,ci.rb,bundler-audit.yml}
config/initializers/{assets,content_security_policy,filter_parameter_logging,inflections}.rb
app/{helpers,models/concerns,controllers/concerns}/
app/views/{layouts/mailer.html.erb,layouts/mailer.text.erb,pwa/manifest.json.erb,
           pwa/service-worker.js}
app/assets/{images,stylesheets}/  app/javascript/  config/importmap.rb  bin/importmap (last three after bundle install)
public/{400,404,406,422,500}.html  public/{robots.txt,icon.png,icon.svg}
test/test_helper.rb  test/{controllers,models,mailers,helpers,integration,fixtures}/
storage/  tmp/pids/  log/  vendor/  script/  .github/{workflows/ci.yml,dependabot.yml}
```

**Kamal/devcontainer facts** (verified in the generated app): Rails 8.1 puts the `kamal` and
`thruster` gems in the Gemfile but does **not** generate `config/deploy.yml` or `.kamal/` by
default (run `kamal init` for those); the devcontainer is opt-in via `--devcontainer`. The
Dockerfile, `bin/docker-entrypoint`, `bin/thrust`, and GitHub CI are generated by default.

---

## 22. Appendix C — Rails component inventory vs Saci

Ruby file counts from the installed `8.1.3.1` gems (library code, excluding tests/generators
inside each gem). Saci counts are `src/saci/**/*.cr`.

| Component | Rails gem files | Saci files / equivalent | Ratio | Notable gap groups |
|---|---:|---|---:|---|
| Active Record | 397 | `record/*.cr` + `record.cr` (11) | ~3% | dirty, enum, encryption, locks, nested attrs, insert_all, async, fixtures, explain, STI, serialization, store |
| Action Pack | 156 | `router.cr`, `controller.cr`, `params.cr`, `cookies.cr`, `session.cr`, `csrf.cr`, `secure_headers.cr` (7) | ~4% | middleware stack, host auth, static, streaming/live, URL/polymorphic routes, HTTP auth, instrumentation |
| Action View | 122 | `views.cr`, `pagination.cr`, `rich_text.cr`, `turbo.cr` (4) | ~3% | asset/URL/form-tag helpers, content_for/capture, variants, digestor, view test helpers |
| Active Support | 289 | `cache.cr`, `crypto.cr`, `i18n.cr`, `logging.cr`, `concurrency.cr`, `credentials.cr` (6) | ~2% | time zones/durations, notifications, current attributes, core-ext suite, message verifiers, tag logging |
| Active Job | 54 | `job.cr`, `job_db.cr`, `recurring.cr`, `job_dashboard.cr` (4) | ~7% | adapters, continuations, priorities, serializers, GlobalID, instrumentation, test helpers |
| Action Mailer | 23 | `mailer.cr`, `smtp.cr` (2) | ~9% | attachments, callbacks, parameterized, previews exist, test helpers, inbound (Mailbox separate) |
| Action Mailbox | 22 | — | 0% | entire component |
| Action Text | 27 | `rich_text.cr` (1) | ~4% | attachables, attachments, serialization, encryption, Trix, fixtures |
| Active Storage | 49 | `storage.cr` (1) | ~2% | blobs/attachments, S3/GCS, variants, previews, analyzers, direct upload, mirroring |
| Action Cable | 45 | `cable.cr` (1) | ~2% | periodic timers, stream_for, remote connections, identifiers, test helpers, PostgreSQL adapter, worker pool |
| Railties | 155 | `application.cr`, `cli/*.cr` (12) | ~8% | config object, initializers, engines, generators, app:update, dev/console tooling, binstubs |
| **Total** | **1,339** | **57 files / 17,202 lines** | **~4% file count** | |

These ratios are **file counts, not feature percentages** — one Saci file often replaces a
Rails module (e.g. `record.cr` is a single-file ORM). They are useful for locating where the
long tail is, not for scoring parity.

**Module inventory highlights** (names verified in the gem tree; Saci status from Section 3–16):

- **Active Record**: `aggregations` (composed_of), `asynchronous_queries_tracker` (load_async),
  `autosave_association`, `dynamic_matchers`, `encryption`, `enum`, `explain`, `inheritance`
  (STI), `insert_all`, `marshalling`, `message_pack`, `model_schema`, `nested_attributes`,
  `no_touching`, `promise`, `query_cache`, `query_logs`, `readonly_attributes`, `serialization`,
  `store`, `suppressor`, `token_for`, `touch_later`, `type_caster`, `fixtures`/`test_databases`.
- **Action Pack**: `allow_browser`, `data_streaming`, `default_headers`, `etag_with_flash`,
  `etag_with_template_digest`, `helpers`, `http_authentication`, `instrumentation`, `live`,
  `params_wrapper`, `permissions_policy`, `rate_limiting`, `streaming`, `testing`, `url_for`.
- **Action Dispatch**: `host_authorization`, `static`, `executor`, `reloader`, `remote_ip`,
  `request_id`, `server_timing`, `public_exceptions`, `actionable_exceptions`, `debug_locks`,
  `debug_view`, `rack_cache` (`Http::Cache`), `upload`, `filter_redirect`, `mime_types`,
  `polymorphic_routes`, `redirection`.
- **Action View helpers**: `asset_tag`, `asset_url`, `atom_feed`, `cache`, `capture`, `controller`,
  `csp`, `csrf`, `date`, `debug`, `form`, `form_options`, `form_tag`, `javascript`, `number`,
  `output_safety`, `rendering`, `sanitize`, `tag`, `text`, `translation`, `url`.
- **Active Support core ext**: time/date/zones, numeric/bytes/time, string inflections/filters/
  multibyte, array grouping/extract, hash slice/except/deep_merge/indifferent access, object
  try/blank/duplicable/deep_dup/to_query, module delegation/concerning/attr_internal,
  class attribute/subclasses, kernel concern, range overlap/sole.
- **Active Job**: `arguments` (GlobalID), `continuable`/`continuation`, `configured_job`,
  `enqueue_after_transaction_commit`, `instrumentation`, `queue_priority`, `serializers`,
  `test_helper`.
- **Action Mailer**: `attachments`/`inline_preview_interceptor`, `callbacks`, `parameterized`,
  `mail_helper`, `rescuable`, `test_helper`.
- **Action Mailbox**: `relayer`, `router`, `routing`, `base`, `callbacks`, `test_helper`.
- **Action Text**: `attachable`, `attachments/*`, `serialization`, `encryption`, `fragment`,
  `html_conversion`, `plain_text_conversion`, `trix_attachment`.
- **Active Storage**: `service/{disk,s3,gcs,mirror}`, `previewer/{video,poppler_pdf,mupdf}`,
  `analyzer/{image,video,audio}`, `attached/{one,many,model,changes}`, `reflection`,
  `downloader`, `fixture_set`.
- **Action Cable**: `channel/{streams,periodic_timers,broadcasting,callbacks}`,
  `connection/{identification,authorization,callbacks,message_buffer,stream_event_loop}`,
  `remote_connections`, `subscription_adapter/{async,redis,postgresql,inline,test}`,
  `test_helper`.
- **Railties**: `application`, `autoloaders`, `configuration`, `engine`, `paths`, `commands`,
  `health_controller`, `info_controller`, `welcome_controller`, `pwa_controller`, generators.

---

## 23. Appendix D — reproduced issues and research notes

These are findings from generating and inspecting the two apps, not feature-list claims.

### D1. `saci new --db=postgres` emits invalid `shard.yml` (reproduced)

Generated on 2026-10-19 from `0.4.0`; `shards install` fails with
`mapping values are not allowed in this context at line 14, column 13`:

```yaml
dependencies:
  saci:
    path: /home/kejsare/dev/projects/saci/
          pg:                      # <-- indented under `path:`
            github: will/crystal-pg
            version: "~> 0.30.0"
```

Expected shape (what Braxy was hand-fixed to):

```yaml
dependencies:
  saci:
    path: /home/kejsare/dev/projects/saci/
  pg:
    github: will/crystal-pg
    version: "~> 0.30.0"
```

This is a **P0 scaffold bug**, not just a missing feature: every new PostgreSQL app fails its
first `shards install`. It is a template indentation bug in
`src/saci/cli/new_command.cr` (`shard.yml` generation for the `postgres`/`mysql` branches).

### D2. `saci new` output lacks the Rails default operating surface

Confirmed by file count and direct tree inspection: 26 app files vs 78 (both excluding
`.git`; Rails was generated with `--skip-git`), and none of
`bin/*` (except the global CLI), `config.ru`, `Rakefile`, `Dockerfile`, `.dockerignore`,
`.github/workflows/ci.yml`, `bin/docker-entrypoint`, `bin/thrust`, `public/`, `app/assets/`,
`app/helpers/`, `test/`, `storage/`, `log/`, `vendor/`, `script/`, `.ruby-version`.

### D3. Rails 8.1 defaults verified in the generated app

- `config/environments/production.rb`: `enable_reloading = false`, `eager_load = true`,
  `consider_all_requests_local = false`, `action_controller.perform_caching = true`,
  `public_file_server.headers` (1 year), `active_storage.service = :local`,
  `log_tags = [:request_id]`, `TaggedLogging`, `log_level = info`,
  `silence_healthcheck_path = "/up"`, `i18n.fallbacks = true`,
  `action_mailer.default_url_options = {host: "example.com"}`; `assume_ssl`, `force_ssl`,
  `ssl_options`, `asset_host`, `cache_store`, `active_job.queue_adapter`, `hosts` are
  commented examples.
- `config/database.yml` defines four SQLite databases in production: `primary`, `cache`,
  `queue`, `cable` (Solid triad), each with its own `migrations_paths`.
- `test/test_helper.rb` calls `parallelize(workers: :number_of_processors)` and
  `fixtures :all`.
- `app/controllers/application_controller.rb` calls `allow_browser versions: :modern` and
  `stale_when_importmap_changes`.
- `app/views/layouts/application.html.erb` uses `content_for(:title)`, `csrf_meta_tags`,
  `csp_meta_tag`, `yield :head`, `stylesheet_link_tag :app`, PWA/icon links.
- `.github/workflows/ci.yml` has five jobs: `scan_ruby`, `scan_js`, `lint`, `test`,
  `system-test`.
- `config/initializers/filter_parameter_logging.rb` ships 12 default filters
  (`passw`, `email`, `secret`, `token`, `_key`, `crypt`, `salt`, `certificate`, `otp`, `ssn`,
  `cvv`, `cvc`); Saci's default is four (`password`, `password_confirmation`, `token`,
  `secret`), so G132 is a real depth gap.

### D4. Corrections made after primary-source inspection

- Saci **does** have tagged logging (`Saci.tagged`, fiber-local tag stack) and configurable
  `filter_parameters`; G141/G132 were downgraded from "absent" to partial.
- Rails **does** generate the Dockerfile, CI workflow, `bin/setup|dev|ci`, and
  `bin/docker-entrypoint` by default; the devcontainer and Kamal deploy files are opt-in
  (G174 corrected).
- Rails' default app **does not** ship `config/deploy.yml` or `.kamal/` even though the
  Gemfile includes `kamal`; `kamal init` is a separate step.
- `--skip-bundle` suppresses importmap/Hotwire installation, so the 78-file count is a
  lower bound for a complete default app.

### D5. Supply-chain and scope comparison

- `gem install rails` pulls **66 gems** for the framework itself; a default app's `bundle
  install` adds its own set (Propshaft, Puma, importmap, Turbo, Stimulus, jbuilder, Solid
  trio, Kamal, Thruster, Bootsnap, sqlite3, …). A Saci app installs **4 shards** (`db`,
  `sqlite3`, `pg`, `saci`) plus the Crystal compiler toolchain. Smaller supply chain, but
  also no gem ecosystem (G210).
- Rails' default app is full-stack (assets, Hotwire, PWA, mailboxes, storage, jobs); Saci's
  default is API/ECR-centric, so some deltas are **product scope choices**, not omissions.
  The API-only comparison (`rails new --api`) is closer but still carries Active Record,
  Action Pack, Active Job, Action Mailer, and the test/CI/tooling surface.

### D6. API/minimal scaffold comparison (fair baseline)

Rails `--api` generated **63 files**, `--minimal` **60**, full-stack **78**; `saci new`
generated **26**. The API scaffold:

- Keeps `app/jobs/application_job.rb`, `app/mailers/application_mailer.rb`, mailer layouts,
  `config/initializers/cors.rb` (commented `rack-cors` example + commented gem),
  `image_processing`, Solid trio, CI/tooling, Puma/database/test config.
- Drops `app/assets`, `app/javascript`, `app/helpers`, PWA views, `public/*.html`, and the CSP
  initializer.
- Has no `application.html.erb` layout (only mailer layouts); Saci ships an app layout.
- Has no staging environment; Saci ships `config/environments/staging.cr` and `es.yml`.

`--minimal` keeps assets/PWA/helpers/CSP but drops jobs and mailers. Neither API nor minimal
changes the conclusion: even against `--api`, Saci's scaffold is ~2.4× smaller and lacks the
Docker/CI/test/tooling surface.

---

## 24. Appendix E — Method-level surface audit

Public-ish method names were extracted from Rails `8.1.3.1` source files (obvious internals
named `_*`, `arel_*`, `build_*`, `*_for_alter`, `*_definition`, etc. filtered where practical)
and name-matched against `def`/`macro` in `src/saci/**/*.cr`.

**Read this as a lower bound, not a coverage score.** Saci generates many methods from macros
(`column`, `timestamps`, `validates`, `belongs_to`, etc.) and uses different names for some
concepts; the matcher only sees literal `def`/`macro` names. The testing row is especially
misleading: Saci tests requests through `TestSession` + Crystal Spec rather than Rails'
assertion names.

| Group | Name-matched | Notable absent public methods |
|---|---:|---|
| AR query | 13 / 99 | `and`, `annotate`, `associated`, `create_with`, `eager_load`, `excluding`, `extending`, `from`, `having`, `in_order_of`, `invert_where`, `left_outer_joins`, `lock`, `missing`, `none`, `optimizer_hints`, `preload`, `readonly`, `references`, `regroup`, `reselect`, `strict_loading`, `unscope`, `without`, `with` |
| AR finders | 7 / 39 | `second`, `third`, `fifth`, `forty_two`, `second_to_last`, `third_to_last`, `last`, `take`, `find_nth`, `find_sole_by`, `sole`, `include?` |
| AR calculations | 7 / 33 | `calculate`, `ids`, `pick`, `async_count`, `async_sum`, `async_average`, `async_minimum`, `async_maximum`, `async_pluck`, `async_ids` |
| AR batches | 1 / 10 | `find_in_batches`, `in_batches` (the rest are internals) |
| AR persistence | 17 / 43 | `becomes`, `increment!`, `decrement!`, `toggle!`, `update_attribute`, `update_column`, `previously_new_record?`, `previously_persisted?`, `destroy!`, `strict_loaded_associations` |
| AR migration DDL | 12 / 109 | `add_check_constraint`, `add_reference`, `add_timestamps`, `change_column_default`, `change_column_null`, `change_table`, `column_exists?`, `create_join_table`, `drop_join_table`, `foreign_key_exists?`, `index_exists?`, `remove_columns`, `table_exists?`, `columns`, `indexes`, `foreign_keys`, `data_source_exists?` |
| ActionController | 37 / 250 | `allow_browser`, `authenticate_or_request_with_http_*`, `authenticate_with_http_*`, `content_security_policy_nonce`, `add_flash_types`, `add_renderer`, `append_info_to_payload`, `default_url_options`, `redirect_back`, `helper_method`, `expires_now`, `http_cache_forever`, `send_stream`, `live`, `rate_limit` |
| ActionView helpers | 21 / 270 | `asset_path`, `asset_url`, `audio_tag`, `auto_discovery_link_tag`, `button_to`, `button_tag`, `cache_if`, `cache_unless`, `capture`, `collection_select`, `color_field`, `content_for`, `content_tag`, `csp_meta_tag`, `csrf_meta_tags`, `date_select`, `datetime_select`, `distance_of_time_in_words`, `email_field`, `error_message_on`, `fields_for`, `form_tag`, `grouped_collection_select`, `image_tag`, `javascript_include_tag`, `link_to_if`, `mail_to`, `number_to_currency`, `options_for_select`, `radio_button`, `sanitize`, `select_date`, `simple_format`, `stylesheet_link_tag`, `time_ago_in_words`, `time_zone_select`, `truncate_words`, `url_for` |
| ActiveSupport core_ext | 22 / 317 | `advance`, `ago`, `all_day`, `beginning_of_*`, `end_of_*`, `class_attribute`, `concern`, `constantize`, `days`, `from_now`, `in_time_zone`, `ordinalize`, `parameterize`, `safe_constantize`, `squish`, `to_query`, `to_sentence`, `try`, `with_options`, `deep_merge`, `symbolize_keys`, `slice`, `except`, `in_groups_of` |
| ActiveJob | 14 / 116 | `arguments`/GlobalID, `continuable`, `queue_as`, `queue_priority`, `after_discard`, `around_perform`, `before_enqueue`, `after_enqueue`, `instrumentation`, `serializers`, `enqueue_all`, `perform_all_later`, `set(queue:)` |
| ActionMailer | 14 / 109 | `attachments`, `inline`, `before_deliver`, `after_deliver`, `around_deliver`, `default`, `mail`, `deliver_later!`, `deliver_now!`, `params`/`with`, `assert_emails`, `assert_enqueued_email_with` |
| ActiveStorage | 17 / 161 | `has_one_attached`, `has_many_attached`, `attach`, `attached?`, `attachment`, `attachments`, `blob`, `purge`, `purge_later`, `download`, `url`, `variant`, `preview`, `representable?`, `analyze`, `analyze_later`, `service_url`, `proxy`, `open`, `filename`, `content_type`, `byte_size`, `checksum`, `metadata` |
| ActionCable | 41 / 217 | `stream_for`, `broadcasting_for`, `periodically`, `identified_by`, `remote_connections`, `disconnect`, `action_cable_meta_tag`, `assert_broadcasts`, `assert_has_stream`, `assert_reject_connection`, `broadcasts`, `open_connections` |
| Testing assertions | 2 / 66 | `assert_response`, `assert_redirected_to`, `assert_template`, `assert_select`, `assert_difference`, `assert_changes`, `assert_no_changes`, `assert_emails`, `assert_enqueued_jobs`, `assert_performed_jobs`, `assert_broadcasts`, `assert_has_stream`, `assert_routing`, `assert_generates`, `assert_recognizes`, `assert_queries`, `travel_to` |

---

## 25. Appendix F — CLI and generator matrix

**Commands** (Rails `bin/rails` vs `saci`):

| Rails command | `saci` today | Status |
|---|---|---|
| `new`, `server`, `generate`, `console`, `runner`, `routes`, `test`, `secret`, `version`, `help` | same names (except `serve` for `server`) | ✅ / 🟡 (`console` compiles per line, `routes` is static) |
| `credentials`, `encrypted` | `credentials:show/edit/keygen` | 🟡 |
| `db`, `db:migrate:*`, `db:schema:*`, `db:seed`, `db:prepare`, `db:setup`, `db:reset`, `db:version`, `db:migrate:status`, `db:fixtures:load`, `db:seed:replant`, `db:test:prepare` | `db:migrate`, `db:rollback`, `db:schema:dump/load/check`, `db:seed` | 🟡 |
| `app:update`, `application`, `boot` | — | ❌ |
| `destroy`, `plugin`, `rake`, `dev`, `devcontainer` | — | ❌ |
| `dbconsole`, `about`, `stats`, `notes`, `initializers`, `middleware`, `unused_routes`, `restart` | — | ❌ |
| `assets:*`, `importmap:*`, `turbo:*`, `stimulus:*`, `action_text:*`, `active_storage:*`, `action_mailbox:*` | — | ❌ |
| `time:zones`, `log:clear`, `tmp:clear`, `dev:cache` | — | ❌ |
| `gem_help` | — | ❌ |

**Generators** (Rails `rails g` vs `saci g`):

| Generator | Rails | Saci |
|---|---|---|
| `model`, `controller`, `migration`, `channel`, `job`, `mailer`, `scaffold` | ✅ | ✅ |
| `admin` | — | ✅ (Saci-specific) |
| `authentication`, `scaffold_controller`, `resource`, `resource_route`, `helper`, `task`, `integration_test`, `system_test`, `benchmark`, `mailbox`, `plugin`, `generator`, `app`, `application_record`, `devcontainer`, `encrypted_file`, `encryption_key_file`, `master_key`, `credentials`, `db:system:change`, `script` | ✅ | ❌ |
| `destroy` | ✅ | ❌ |

---

## 26. Appendix G — Rails default middleware stack vs Saci handler chain

Source: `Rails::Application::DefaultMiddlewareStack#build_stack` (8.1.3.1). Saci's chain is
`HTTP::WebSocketHandler` + `Saci::Handler` (router) plus controller-level concerns.

| # | Rails middleware | Purpose | Saci |
|---:|---|---|---|
| 1 | `ActionDispatch::HostAuthorization` | Host allowlist | ❌ |
| 2 | `ActionDispatch::AssumeSSL` | Trust `X-Forwarded-Proto` | ❌ |
| 3 | `ActionDispatch::SSL` | Force SSL/HSTS | 🟡 `Saci.force_ssl` |
| 4 | `Rack::Sendfile` | X-Sendfile acceleration | ❌ |
| 5 | `ActionDispatch::Static` | Serve `public/` | ❌ |
| 6 | `Rack::Cache` | HTTP shared cache | ❌ |
| 7 | `Rack::Lock` | Serialize requests when opted out | n/a (MT) |
| 8 | `ActionDispatch::Executor` | Reload/execution wrapping | ❌ |
| 9 | `ActionDispatch::ServerTiming` | Server-Timing header | ❌ |
| 10 | `Rack::Runtime` | `X-Runtime` header | ❌ |
| 11 | `Rack::MethodOverride` | `_method` form override | ✅ router-level override (`override_method`) |
| 12 | `ActionDispatch::RequestId` | `X-Request-Id` | ✅ |
| 13 | `ActionDispatch::RemoteIp` | Trusted proxies/spoof check | ❌ |
| 14 | `Rails::Rack::SilenceRequest` | Silence health checks | ❌ |
| 15 | `Rails::Rack::Logger` | Tagged request logs | 🟡 `Saci.tagged` |
| 16 | `ActionDispatch::ShowExceptions` | Error page app | 🟡 dev page |
| 17 | `ActionDispatch::DebugExceptions` | Debug page | 🟡 dev page |
| 18 | `ActionDispatch::ActionableExceptions` | Run fixes from error page | ❌ |
| 19 | `ActionDispatch::Reloader` | Code reload | ❌ |
| 20 | `ActionDispatch::Callbacks` | `to_prepare` callbacks | ❌ |
| 21 | `ActionDispatch::Cookies` | Cookie jar | ✅ |
| 22 | Session store | Cookie/cache/AR/Redis | 🟡 cookie only |
| 23 | `ActionDispatch::Flash` | Flash | ✅ |
| 24 | CSP middleware | CSP header | ✅ (static) |
| 25 | PermissionsPolicy middleware | Permissions-Policy | ❌ |
| 26 | `Rack::Head` | HEAD handling | 🟡 `head` helper |
| 27 | `Rack::ConditionalGet` | 304s | 🟡 `fresh_when`/`stale?` |
| 28 | `Rack::ETag` | ETags | ✅ (FNV-1a) |
| 29 | `Rack::TempfileReaper` | Cleanup uploads | ❌ |
| 30 | AR DatabaseSelector/ShardSelector | Read/write splitting | ❌ |

**Takeaway:** Saci's request path is intentionally a thin router, not a Rack stack. Features
Rails gets from middleware (host auth, static, compression, method override, range/tempfile
handling, reloading, server timing) must be implemented per app or added to the boot chain.

---

## 27. Appendix H — Configuration surface

Rails 8.1's `Rails::Application::Configuration` exposes ~40 top-level settings plus namespaces.
Saci uses class-level setters and environment files instead of a config object.

| Area | Rails examples | Saci today |
|---|---|---|
| Runtime | `enable_reloading`, `eager_load`, `consider_all_requests_local`, `cache_classes`, `allow_concurrency`, `file_watcher`, `reload_classes_only_on_change`, `server_timing`, `yjit` | 🟡 env files + `Saci` setters; no reloading/sandbox |
| Paths | `autoload_paths`, `eager_load_paths`, `autoload_lib`, `helpers_paths`, `railties_order`, `relative_url_root` | ❌ compile-time requires/globs |
| HTTP | `hosts`, `host_authorization`, `assume_ssl`, `force_ssl`, `ssl_options`, `public_file_server`, `session_options`, `filter_parameters`, `filter_redirect`, `exceptions_app`, `log_tags`, `silence_healthcheck_path`, `request_id_header` | 🟡 force_ssl, filter_parameters, log tags (manual); rest absent |
| Security | `content_security_policy*`, `permissions_policy`, `require_master_key`, `credentials`, `sandbox` | 🟡 CSP/credentials; no permissions policy/sandbox |
| Assets | `assets.*`, `asset_host`, `precompile_filter_parameters` | ❌ no asset pipeline |
| Mail | `action_mailer.*` (delivery method, SMTP, URL options, preview path, interceptors, raise_delivery_errors) | 🟡 SMTP + layouts + previews; URL options/interceptors absent |
| ORM | `active_record.*` (belongs_to_required, schema format, query log tags, encryption, verify_foreign_keys, dump_schema_after_migration, raise_on_missing_required_finder_order_columns) | 🟡 validations/associations; most knobs absent |
| Jobs | `active_job.*` (queue adapter, retry jitter, enqueue_after_transaction_commit, logger) | 🟡 adapter/queue names; rest absent |
| Cable | `action_cable.*` (adapter, allowed origins, mount path, worker pool, disable request forgery) | 🟡 Redis/async adapter; allowed origins/worker pool absent |
| Storage | `active_storage.*` (service, variants, routes, analyze, purge) | 🟡 disk service; rest absent |
| I18n | `i18n.load_path`, `fallbacks`, `default_locale`, `available_locales`, `enforce_available_locales`, `raise_on_missing_translations` | 🟡 load path/locale/count; fallbacks/missing-translation behavior absent |
| Time | `time_zone`, `beginning_of_week` | ❌ UTC only |
| Caching | `cache_store`, `action_controller.perform_caching`, `action_controller.cache_store`, `fragment_cache_keys` | 🟡 `Saci::Cache` memory/Redis; no per-controller store config |

---

## 28. Appendix I — Common gem equivalents

Saci has no gem ecosystem (G218), so this maps the most common Rails app dependencies to what
exists in the framework today.

| Common gem | Purpose | Saci equivalent |
|---|---|---|
| Devise / Sorcery | Authentication | 🟡 auth shelf (sessions, secure tokens, signed IDs, `authenticate_by`, controller helpers) |
| Pundit / CanCanCan / ActionPolicy | Authorization | ❌ manual controller checks |
| Sidekiq / GoodJob / Solid Queue | Background jobs | 🟡 `:db` job adapter + dashboard; no priorities/unique/batches |
| RSpec / Minitest | Testing | 🟡 Crystal Spec + `TestSession`; no fixtures/factories/assertion helpers |
| FactoryBot / Fabrication | Test data | ❌ |
| Kaminari / Pagy / WillPaginate | Pagination | ✅ `Saci::Pagination` |
| ActiveAdmin / Administrate | Admin UI | 🟡 `saci g admin` generator |
| Draper / ActiveDecorator | Presenters | ❌ |
| Interactor / LightService | Service objects | ❌ (use plain modules/classes) |
| Searchkick / Elasticsearch / Meilisearch | Search | 🟡 SQLite FTS5; no external search |
| PaperTrail / Audited | Audit trail | ❌ |
| FriendlyId | Slugs | ❌ |
| Ahoy / Impressionist | Analytics | 🟡 Metrics counters; no visit tracking |
| Geocoder | Geocoding | ❌ |
| Stripe / Pay | Payments | ❌ |
| OmniAuth | OAuth login | ❌ (Claw has app-level stubs) |
| Jbuilder / ActiveModel::Serializers | JSON views/serializers | 🟡 `render json:` + `wire_json`; no serializer layer |
| GraphQL / graphql-ruby | GraphQL API | ❌ |
| rswag / Apipie | API docs | ❌ |
| Flipper | Feature flags | ❌ |
| ActsAsTaggableOn | Tagging | ❌ |
| Noticed / Mailboxer | Notifications | ❌ |
| ViewComponent / Phlex | View components | 🟡 ECR partials/layouts |
| Turbo / Stimulus | Hotwire | 🟡 Turbo Frames/Streams; no Drive/Stimulus |
| Tailwind / Bootstrap | CSS | ❌ (hand-rolled CSS in apps) |
| Sentry / Honeybadger | Error reporting | ❌ (logs/metrics only) |
| Rack::Attack | Rate limiting | 🟡 `Saci::Throttle` (memory/Redis) |
| rack-cors | CORS | ❌ |
| Bootsnap | Boot cache | ❌ (compiled binary) |
| Kamal / Thruster | Deploy/proxy | ❌ |

---

## 29. Case study: a production Rails 8 + MySQL monolith (anonymized)

Source inspected directly: a production **Rails `8.0.5`** application (MySQL2) plus its legacy
ActiveAdmin app. App names, paths, and domain specifics are omitted. All counts and patterns
below come from the **original Rails code**, not from a rewrite or a secondary summary.

### 29.1 Shape

| Part | Stack | Size / role |
|---|---|---|
| Main Rails app | Rails `8.0.5`, MySQL2, Sidekiq, GraphQL, CarrierWave, Ransack, Kaminari, EnumerateIt, AMS, Grape | 359 models, 98 controllers, 561 GraphQL files, 44 workers, 303 views, 37 enumerations |
| Legacy admin app | Rails `5.1`, ActiveAdmin `1.0`, Devise `4.8` + `devise-two-factor`, CarrierWave/fog, Sidekiq, wkhtmltopdf | 24 ActiveAdmin resources, 54 models, 13 jobs |
| Frontend | React 17 + MUI + Apollo + Vite | SPA/islands calling GraphQL |
| Auxiliary services | Node/Apollo Serverless, Rust (address lookup, TLS/domain gateway), integration workers | separate deployables, not Rails |

Only the two Rails apps are comparable to Saci; the auxiliary services are separate products.

### 29.2 Backend feature usage (evidence)

| Capability | Evidence in the original code | Saci today | Gap |
|---|---|---|---|
| Models / scopes | 359 models, 254 `scope` declarations, 7 `default_scope` | Query DSL/scopes; no default scope | G15 |
| Enumerations | 37 enumeration files, 51 `has_enumeration_for`, 1 Rails `enum` | Migration `t.enum`; no model enum DSL | G13 |
| Dirty tracking | 23 `saved_change_to_*`, 66 `changed?`, 1 `previous_changes` | ❌ | G10 |
| Virtual/JSON attrs | `store_accessor` (custom JSON fields), 5 `serialize` | JSON columns; no accessor/serializer macro | G17 |
| Associations | 54 `has_one`, 30 `through`, 9 polymorphic, 6 HABTM, 2 `counter_cache`, 8 nested attributes | has_one/through/polymorphic/counter_cache exist; HABTM/nested attrs don't | G19, G33, G186 |
| Validations | 14 `validates_with`, 51 EnumerateIt validations, `length: {is:}`, dynamic `in:` values | `validate :method`/built-ins; no validator objects; literal arrays | G295–G296 |
| Query depth | 53 `find_or_create_by`, 158 `merge`, 28 `in_batches`, 7 `find_each`, 1 `insert_all`, 73 `where.not`, 3 `or` | `find_each`, `where.not`, `or` exist; `find_or_create_by`/`merge`/`in_batches`/`insert_all` don't | G11–G12, G27 |
| Eager loading | 134 `includes`, 222 `joins`, 6 `eager_load`, 2 `preload`, 1 `left_joins` | `includes`/`joins`; no preload/eager_load/left_joins | G26–G27 |
| Transactions/locks | 44 `transaction` blocks, 5 `lock!`/`with_lock` | transactions; no row locks | G21 |
| Money | prices, fees, installments as `Decimal` | `Decimal` is Float64-backed; `t.decimal` → DOUBLE/REAL | **G297** |
| Dates | birth dates, return dates, invoice dates | `Date` is Time-backed | G298 |
| Views | 303 views (270 HAML), 29 `simple_form_for`, 34 `best_in_place`, 115 `select2`, jQuery/UI/autocomplete | ECR + basic `FormBuilder`; no HAML/SimpleForm/select2/best_in_place | G63–G73, G198, G200 |
| Search | 90 Ransack references in 46 files, 48 Kaminari `paginate` | `Saci::Pagination`; no Ransack filter DSL | G303 |
| JSON shaping | 23 ActiveModelSerializers | hand-written `wire_json`/`to_json` | G304 |
| GraphQL | 561 files / 485 refs; four schemas, lookahead-driven includes, GraphiQL, batched Apollo | ❌ | **G301** |
| REST API | Grape `PublicApi::Root`, entities, Swagger | plain JSON controllers only | G302 |
| Streaming | 6 controllers include `ActionController::Live` (SSE exports/updates); 7 files reference it | ❌ | G46 |
| Jobs | 44 Sidekiq workers, `retry`/`backtrace`/`unique: :until_executed`, `sidekiq-unique-jobs`, Sidekiq Web | `:db` adapter, retries/dead letter/dashboard; no Sidekiq/unique/backtrace | G99–G101 |
| Uploads | 14 CarrierWave uploaders, 13 `mount_uploader`, S3/fog/AWS, MiniMagick/image_processing, 0 ActiveStorage | disk storage + signed URLs; no model macros/S3/variants | G84, G89, G201 |
| Audit | custom `Audit` + `Auditable`, 1,573 references, polymorphic resource, JSON data | ❌ | G305 |
| Authorization | `Ability` + role matrices, `can?`, `require_feature` | ❌ | G306 |
| Tenancy | `request.subdomain`, host-based lookup, `default_url_options` | raw `Host` only; no subdomain helpers | G300 |
| Auth | bcrypt, JWT, bearer tokens, session; Devise + 2FA in admin | auth shelf (bcrypt/tokens/sessions); no JWT/2FA | G307, G310 |
| Integrations | messaging (80), calendar (43), payment (97), fiscal (66), government APIs (1,024 + 177), NATS (16), an AI API, transactional email | HTTP/JSON/crypto primitives; no SDKs | App-level, not framework |
| Ops | NewRelic, Sentry, Lograge, rack-cors, rack-timeout, secure_headers | metrics/logs/secure headers; no APM/error reporting/CORS/timeouts | G48, G51, G141–G144 |
| Admin | ActiveAdmin 1.0 + Devise + 2FA + wkhtmltopdf + Capybara/Selenium | `saci g admin` + auth shelf; no 2FA/PDF/system tests | G105–G108, G307–G308 |

### 29.3 Patterns the original code relies on that Saci does not support

These are read directly from the Rails source; each is a concrete migration cost.

| Original pattern | Where / how it is used | Saci status |
|---|---|---|
| `default_scope { order(:name) }` | 7 models; every query inherits the ordering | No default scope (G15) |
| `saved_change_to_x?`, `x_changed?`, `changes` | 23 + 66 call sites; guards for notifications/audits | No dirty tracking (G10) |
| `validates_with DateRangeValidator` | 14 files; custom `ActiveModel::Validator` classes | No validator objects (G295) |
| `length: {is: 15}`, dynamic `inclusion: {in: States.list}` | model validations | `length: {in:/within:}` only; literals only (G296) |
| `store_accessor :custom_fields, ...` | custom fields over a JSON column | JSON columns, no accessor macro (G17) |
| `accepts_nested_attributes_for` | 8 models (documents, nested resources) | No nested attributes (G19) |
| `has_and_belongs_to_many` | 6 join tables | No HABTM (G33) |
| `find_or_create_by`, `merge`, `in_batches` | 53 / 158 / 28 call sites | Missing (G12, G27) |
| `Decimal` money columns | prices, fees, installments across billing | Float64-backed (G297) |
| `Date` columns | birth/return/invoice dates | Time-backed (G298) |
| `created_at:`/`updated_at:` passed on create | Rails honors explicitly assigned timestamps on create | Saci overwrites both (G299) |
| `request.subdomain`, `default_url_options` | tenant lookup and URL preservation | Host header only (G300) |
| `delegate` + `helper_method` | controller delegates ~12 auth helpers to a manager and exposes them to views | No delegate/helper exposure (G16, G245) |
| GraphQL schemas/mutations/lookahead | 561 files, four schemas, batched Apollo | No GraphQL layer (G301) |
| Grape API + Swagger | public `/api` mount | Plain JSON controllers (G302) |
| Ransack `ransack(params[:q])` | 90 refs in 46 files; search forms | Manual params/scopes (G303) |
| ActiveModelSerializers | 23 serializers with `attributes`/`has_many` | Hand-written JSON (G304) |
| Custom polymorphic `Audit` | 1,573 refs; user/tenant/resource context, JSON data | No audit trail (G305) |
| Ability matrices + `can?` | role overrides, `require_feature` | No policy DSL (G306) |
| Devise two-factor + QR | legacy admin login | No 2FA/TOTP/QR (G307) |
| caxlsx/roo/xlsxtream/prawn/wkhtmltopdf | exports, reports, invoices | No spreadsheet/PDF layer (G308) |
| RGeo polygons | service areas | No spatial types (G309) |
| `jwt` encode/decode | mobile/public bearer tokens | Opaque tokens only (G310) |
| MySQL `EXTRACT`/`TIMESTAMPDIFF`/`MATCH … AGAINST`/`JSON_EXTRACT`/`CONVERT_TZ` | search, age filters, reports | No dialect helpers (G311) |
| `ActionController::Live` | 7 streaming controllers | No SSE/streaming (G46) |
| Sidekiq `unique`, `retry`, `backtrace` | 44 workers | `:db` jobs, no unique/backtrace (G99–G101) |
| CarrierWave + S3 + MiniMagick | 14 uploaders, avatars/exports/ZIPs | Disk storage only (G84, G89, G201) |
| HAML + SimpleForm + select2 + best_in_place | 303 views, 29 forms, 115 select2 refs | ECR + basic form builder (G63–G73) |
| Mailjet delivery method | transactional mail | SMTP only (G78) |
| NewRelic/Sentry/Lograge/rack-timeout/CORS | production observability/ops | Metrics/logs; no APM/Sentry/CORS/timeouts (G48, G51, G141–G144) |
| ActiveAdmin/Devise | legacy admin | Admin generator + auth shelf (G307) |

### 29.4 How this changes the ranking

- **P0**: exact `decimal`/`numeric` (**G297**) — this app handles money, and Float64 is not
  acceptable for prices/fees. Dirty tracking (G10) and named URL helpers (G4) are also
  constantly worked around.
- **P1**: validator objects/dynamic validation (G295–G296), native date semantics (G298),
  subdomain helpers (G300), GraphQL (G301), audit (G305), policy DSL (G306), streaming (G46),
  S3/CarrierWave-equivalent uploads (G84/G89).
- **P2**: Ransack (G303), serializers (G304), 2FA/QR (G307), XLSX/PDF (G308), GIS (G309),
  JWT (G310), MySQL dialect helpers (G311).
- **Not framework gaps**: payment gateways, government/messaging/calendar integrations, NATS, AI
  services, mail providers, ActiveAdmin/Devise, HAML/SimpleForm/jQuery. These are app-level
  integrations and UI choices; Saci needs the HTTP/JSON/crypto primitives, which it has.
- **Saci advantages observed against this code**: FTS5 replaces MySQL full-text search;
  `Saci::Pagination` covers Kaminari-style paging; ECR can express the same markup; `Saci::Job`
  covers job execution; secure headers are built in; the auth shelf covers session auth without
  Devise.

### 29.5 Limits of this case study

- It is one application; its domain-specific integrations dominate the long tail.
- Counts are file/occurrence counts, not a measure of importance.
- This is capability analysis of the original code; it makes no claim about a rewrite's status.

---

## 30. Rails sources (extended)

- Rails 8.1 release notes — https://guides.rubyonrails.org/8_1_release_notes.html
- Rails 8.0 release notes — https://guides.rubyonrails.org/8_0_release_notes.html
- Guides walked: Getting Started; Active Record Basics, Migrations, Validations, Callbacks,
  Associations, Query Interface; Active Model; Action View Overview, Layouts/Rendering,
  Helpers, Form Helpers; Action Controller Overview/Advanced; Routing; Active Support Core
  Extensions; Action Mailer, Mailbox, Text; Active Job; Active Storage; Action Cable; Testing;
  Debugging; Configuring; Command Line; Asset Pipeline; JavaScript; I18n; Autoloading; API-only;
  Performance Tuning; Caching; Security; Error Reporting; Multiple Databases; Encryption;
  Composite Primary Keys; Rails on Rack; Generators.
- Installed gem source `8.1.3.1` (66 gems, `/tmp/opencode/rails-gems`): module inventory in
  Appendix C and method audit in Appendix E.
- Generated reference apps: `/tmp/opencode/rails-ref/app` (full Rails 8.1.3.1),
  `/tmp/opencode/rails-api/app` (`--api`), `/tmp/opencode/rails-min/app` (`--minimal`), and
  `/tmp/opencode/saci-ref/app` (Saci 0.4.0).
- Reference production app `lobsters` (Rails 8.1.3.1): `Gemfile.lock`, `config/application.rb`,
  `config/initializers/*`, `config/{cable,cache,queue,recurring,storage}.yml`, `importmap.rb`.
