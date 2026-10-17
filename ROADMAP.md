# Roadmap — Saci framework + validation apps

Every item traces to a real product need or a limit hit during validation.
Horizons: **P0** correctness/safety, **P1** product depth, **P2** scale/polish.
Effort: **S** < half day, **M** 1–3 days, **L** a week+. Anything marked [x]
was proven by specs and/or live traffic.

Validation: **Forem Lite** (`../forem_lite`, 87 specs) and **Claw**
(`../claw`, a Lobsters port, 357 specs). Framework suite: **339 specs**,
green plain and with `-Dexecution_context`.

## Milestones

- **M1 — Auth complete. [x]** Forem Lite password reset closed signup →
  verify → login → reset; Claw added 2FA TOTP (scannable QR), GitHub/
  Mastodon/Pushover wiring, invitation-gated signup, username history.
- **M2 — Production credible. [~]** Durable jobs [x], backups [x, Claw
  script + drill], alerting [x, Claw webhook + admin inbox], multi-window
  rate limits [x], recurring jobs [x, Claw]. Docker image produced but
  **unbuilt** (daemon permission at the time); live PG/MySQL still unverified.
- **M3 — Community depth. [x]** Threading (Claw depth-3+ threads + reply
  forms), bookmarks (saved stories + `/saved`), markdown (escape-first
  renderer, spec-pinned), drafts/scheduling (Claw suggestions queue +
  `set(wait:)` scheduling; Forem Lite drafts by URL only).
- **M4 — Scale. [~]** Eager loading [x] + N+1 ceilings [x] (`home 51→6`,
  `inbox 153→5`, `modlog 103→5`). Still open: distributed Cable/throttle,
  metrics endpoint.

## Framework — ORM (`Saci::Record`)

- [x] **Live PostgreSQL/MySQL verification.** Dockerized PG 16 + MySQL 8
  + `live/*` harness (26 examples: DDL/CRUD/validations/associations/tx/
  placeholders/quoting/RETURNING/type round-trips) run via `live/run.sh`;
  CI runs it as a services job. Found 3 real bugs: PG jsonb `PullParser`
  reads, MySQL native-JSON wire type (now `TEXT`), MySQL all-default
  `INSERT`. Known limits: MySQL `DATETIME` seconds, PG `TIMESTAMP`
  microseconds, no ENUM (documented in `live/README.md`). Driver notes:
  pg/mysql stay app-opt-in (`development_dependencies` here); pg needs the
  2-symbol OpenSSL shim (`live/ossl_shim.c`) on OpenSSL ≥ 3.2, same class of
  fix as the vendored GCM core; crystal-mysql needs `mysql_native_password`.
- [x] **Composite uniqueness validation.** `validates :x, uniqueness:
  [:a, :b]` (Symbol or Array scope, nil-safe, self-excluding on update).
- [x] **Eager loading + joins + `has_many :through`.** `includes` (nested,
  2-level, N+1-killing), `joins` (string + symbol), `has_one`,
  `through`/`source`, polymorphic `belongs_to` / `has_many as:`,
  `dependent: :destroy/:delete_all/:nullify/:restrict_with_exception`,
  `counter_cache` + `touch:`.
- [x] **Model callbacks.** `before_validation/before_save`,
  `after_save/create/commit(on:)/destroy` (names, blocks, `previous_def`
  chains; `after_commit` deferred to outermost commit, discarded on rollback).
- [x] **Multipart form parsing.** Nested tree (bracket query + JSON +
  urlencoded + multipart): `require().permit(tags: [] of String)`,
  `dig/array/file/files` (`UploadedFile`). Repeated field names keep the last
  file (spec-pinned).
- [x] **Richer column types.** `decimal/date/json` (+ migrations); `t.timestamps`
  PG precision, enums, arrays still missing (see Next).
- [x] **`render` custom content types + template status.** `render xml:`,
  `content_type:`, `render_template :x, status: 422`, `respond_to`
  html/json/rss/xml (+406 `UnknownFormat`).
- [x] **Query polish.** `select/distinct/group` + aggregates
  (`sum/avg/min/max`, grouped hashes), `or`, `where.not`, ranges, `merge`-via-
  chaining, `upsert/update_columns/touch/touch_all/reset_counters`,
  `update_counter(s)`.
- [x] Single-arg `where(sql)` overload; PG + MySQL adapters; SMTP adapter
  (STARTTLS + AUTH LOGIN, verified live via Ethereal).
- [x] **Validations depth.** `length:` (min/max/in/within), `inclusion:`,
  `numericality:`, case-insensitive uniqueness, custom `validate`,
  `if:/unless:`, `on:`, `allow_nil/allow_blank`.
- [x] **FTS5 helper** (`Saci::Record::FTS`: virtual tables + triggers +
  rank-ordered `search_fts`, SQLite-only with clear cross-adapter error).

## Framework — web, jobs, mailers, misc

- [x] **Encrypted cookies/sessions.** `cookies.encrypted` (AES-256-GCM,
  purpose-separated) + opt-in `Session.encrypt` (strict).
- [x] **Durable job adapter (DB).** `saci_jobs` + `saci_dead_jobs`
  (retry/drop ops), kill -9 + reboot proven, conditional-UPDATE claims,
  stale-lock reclamation, per-key `limits_concurrency`, `retry_on` reuse.
  Redis remains roadmap; at-least-once everywhere.
- [x] **Router depth.** Constraints, `member/collection`, nested resources,
  `new/edit`, optional segments, `(.:format)` + defaults, redirects (with
  interpolation), fallback, `~:user`-style prefix segments.
- [x] **Controller depth.** `rescue_from`, `after_action` + skips,
  `respond_to`, extended statuses.
- [x] **Views depth.** Partial locals/collections, model forms (check/select/
  date/file, binding, errors), markdown/pagination/RSS helpers.
- [x] **Mailer depth.** Layouts, `reply_to`, threading `headers:`,
  `deliver_later` renders-now.
- [x] **CSP defaults + escape hatch.** `default-src 'self'` + `skip_csp`/`csp`.
- [x] **Multi-window throttles** (`Throttle.multi`, `throttle_login`,
  429 + `Retry-After`).
- [x] **Page-cache writer** (`Saci::PageCache`: write/read/expire/fetch).
- [x] **Cable Redis adapter.** `Cable::RedisServer` (multiplexed channel,
  resubscribing SUBSCRIBE fiber); two instances fan out in specs.
- [x] **Distributed throttle store.** `Throttle::RedisStore` (atomic
  INCR+EXPIRE Lua) behind a `Store` abstraction; fail-open documented.
- [x] **Metrics endpoint.** `Saci::Metrics` (request/status/route/job/cache
  counters, DB gauges) + mountable controller (JSON + Prometheus).
- [x] **Signed-URL rotation + public-file mode.** Multi-key verification
  (grace = natural expiry) + `public/` prefix served unsigned, traversal
  still rejected.
- [x] **Mailer previews + subject encoding.** Preview registry +
  mountable controller (dev-gated) + RFC 2047 encoded-word subjects.
- [x] **PG column depth.** `t.enum` (native PG ENUM / MySQL ENUM / SQLite
  TEXT+inclusion), string arrays (PG `TEXT[]` / MySQL+SQLite JSON TEXT),
  timestamp/datetime precision (PG/MySQL; SQLite ignores, documented).

## CLI (`saci`)

- [x] Migration filename/class validation.
- [x] `add_index` generator (`AddIndex…` pattern / `--unique`).
- [x] Multidb awareness (`db:migrate --all`, `clean_all!`).
- [x] `saci new --db=postgres|mysql|sqlite` picker.
- [x] Request specs generate real verbs (POST/PATCH/DELETE).
- [x] CI workflow (plain + `-Dexecution_context`).
- [x] **Generator dry-run + conflict handling.** `--pretend` (capped
  previews, writes nothing), overwrite y/n/a/q prompts, identical-skip,
  `--force`, non-TTY never blocks.

## Validation apps

- [x] Forem Lite password reset (M1); 87 specs green.
- [x] CI for the framework repo (Claw carries its own workflow; first push
  still pending — needs `gh auth login` + `gh repo create`).
- [x] Claw: moderation stack, hats, inbox/notifications, feeds (html/json/
  rss + private tokens), filters/tags, users tree/standing, avatars
  (MD5 Gravatar + fetch chain), stats (+SVG), FTS search, 2FA/OAuth,
  recurring jobs, alerting, backup drill, rate limits, N+1 ceilings,
  dogfood seed + live verification (one live-found 500→400 fix).
- [ ] **P1 — Verify the Docker image. [S]** Claw's Dockerfile + Caddyfile +
  logrotate ship; build + boot + migrate where the daemon allows.
- [x] **Staging env.** `config/environments/staging.cr` scaffold
  (production + info logs + request lines), glob requires, `Saci.staging?`,
  secret refusal + no-detailed-exceptions by default in staging.

## Next

The roadmap is closed — every P0/P1/P2 is done. Live verification stands at
542 framework specs (+ 26 live PG/MySQL), 357→383 Claw specs, two live boots,
a kill -9 drill, a seeded dogfood pass, and an N+1 audit. Remaining work is
user-side (real `docker build`, Claw's first push) or new product bets
(ActionText equivalent, job dashboard, framework cron, Turbo story —
each standalone; say which).

## Done this round — 0.2.0 Lobsters port + audit + release

See [CHANGELOG.md](CHANGELOG.md). Framework 339 specs, Claw 357, both
suites green single-threaded and (`saci`) under `-Dexecution_context`;
proven by two live boots, a kill -9 durability drill, a seeded dogfood pass,
and an N+1 audit with count-ceiling specs.
