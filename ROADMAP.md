# Roadmap — Saci framework + Forem Lite

Consolidated plan from building Forem Lite (`../forem_lite`) against Saci.
Every item traces to a real product need or a limit hit during validation.
Horizons: **P0** correctness/safety, **P1** product depth, **P2** scale/polish.
Effort: **S** < half day, **M** 1–3 days, **L** a week+. Depends-on noted where
it matters. Anything marked [x] was proven by specs and/or live traffic.

## Milestones

- **M1 — Auth complete.** Password reset (below) closes signup → verify →
  login → reset. After M1 no auth flow is missing.
- **M2 — Production credible.** Durable jobs + backups + alerting + verified
  Docker image. After M2 a small community could run here for real.
- **M3 — Community depth.** Threading, bookmarks, markdown, drafts/scheduling.
- **M4 — Scale.** Eager loading, distributed Cable/throttle, metrics.

## Framework — ORM (`Saci::Record`)

- [ ] **P0 — Live PostgreSQL/MySQL verification. [M]** Adapters are
  implemented and SQL-specced (`spec/adapters_spec.cr`), but no servers exist
  here. Done when: dockerized PG 16 + MySQL 8 + a `spec/*_live` harness
  behind env flags exercises CRUD/validations/associations/migrations on both.
  (Discovered: drivers must stay app-opt-in — `DB.open`'s virtual dispatch
  links every driver's connect path, and pg's `Digest` auth can't link on
  OpenSSL ≥ 3.2.)
- [x] **Composite uniqueness validation.** `validates :x, uniqueness:
  [:a, :b]` (Symbol or Array scope, nil-safe, self-excluding on update);
  reactions/follows carry model-level guards alongside their DB indexes.
- [ ] **P1 — Eager loading (`includes`) + joins. [M]** The bell `COUNT`, tag
  lists and notification actors are N+1 by construction today; feeds cap rows
  to cope. Done when: `includes(:user)` kills the notification-page N+1 in a
  spec. `joins` first, `has_many :through` after (tags currently traverse
  joins with hand-written subselects).
- [ ] **P1 — Model callbacks. [M]** (`before_save`, `after_create`, …). Forem
  semantics (score recalcs, counter caches, slug generation) are currently
  hand-called in controllers/jobs. Done when: score recalc moves into an
  `after_save` on Reaction/Comment and the job becomes a thin wrapper.
- [ ] **P1 — Multipart form parsing. [M]** `Params` reads JSON + urlencoded
  only; browser `<input type=file>` silently loses fields (spec-pinned).
  Blocks avatar/cover uploads from HTML forms. Done when: the multipart-gap
  spec flips to green (fields + file bytes available, size-capped).
- [ ] **P1 — Richer column types. [S]** No `decimal`, `json`, enums, arrays;
  no PG-native `t.timestamps` precision. Needed before any serious PG app.
- [ ] **P2 — `render` custom content types + template status. [S]** RSS writes
  `response` directly and sets `@performed`; validation re-renders return
  200 instead of 422. Done when: `render xml:, status:` / `render_template
  :x, status:` exist.
- [ ] **P2 — Query polish. [S]** `select` column lists, `distinct`, `group`
  + aggregates, `or` combinator, `find_each` batching beyond basics.
- [x] Single-arg `where(sql)` overload (was overload error; added with spec).
- [x] PostgreSQL + MySQL adapters, SMTP adapter (both verified live).

## Framework — web, jobs, mailers, misc

- [x] **Encrypted cookies/sessions.** `cookies.encrypted` (AES-256-GCM via
  the vendored core, purpose-separated keys) + opt-in `Session.encrypt`
  (strict, invalidates signed sessions; generated production envs enable it).
- [x] **Durable job adapter (DB).** `:db` persists to `saci_jobs`
  (+ `saci_dead_jobs` dead letters with retry/drop ops), survives restarts
  (proven live via kill -9 + reboot), atomic conditional-UPDATE claims,
  stale-lock reclamation, reuses jobs' own `retry_on` rules. Redis remains
  roadmap; at-least-once everywhere, so jobs MUST be idempotent.
- [ ] **P1 — Cable Redis adapter. [M]** Pub/sub is single-process;
  multi-replica deploys need sticky sessions today (documented). Done when:
  two processes on one Redis fan out in a spec.
- [ ] **P1 — Distributed throttle store. [S/M]** Counters are in-process;
  same replica caveat as Cable. Redis- or DB-backed buckets.
- [ ] **P1 — CSP defaults + security headers review. [S]** Secure headers
  exist; no Content-Security-Policy story (inline Cable JS would need
  nonces/hashes). Done when: default policy + per-action escape hatch.
- [ ] **P1 — Signed-URL expiry strategy for public assets. [S]** Cover images
  use 30-day signed URLs; needs rotation story or public-file mode.
- [ ] **P2 — Mailer previews + multipart/alternative polish. [S]** Dev
  preview route for mails (Mailpit covers local, but in-app preview helps);
  subject encoding for non-ASCII (currently raw UTF-8 — legal but unpolished).

## CLI (`saci`)

- [x] **Migration filename/class validation.** `regenerate_manifest!`
  fails fast on filename↔class mismatches and duplicate classes (was cryptic
  `undefined constant`). Also fixed `cli_spec` missing the
  `credentials_command` require (passed only via load-order luck).
- [ ] **P1 — `add_index` generator. [S]** `AddXToY` only emits `add_column`;
  every unique index so far is hand-written. `saci g migration
  AddIndexToFollows follower_id:integer … --unique` (or an `AddIndex…` name
  pattern).
- [ ] **P1 — Multidb awareness. [M]** `db:migrate`, `clean_database!` and
  generators only know the primary DB; analytics manifests are hand-wired.
  Done when: `saci db:migrate --all` + a `clean_all!` test helper exist.
- [ ] **P1 — `saci new` database picker. [S]** `--db=postgres` emitting driver
  deps + `require "pg"` + URL defaults (templates already carry the comments).
- [ ] **P2 — Request specs generate real verbs. [S]** `g controller` emits
  `GET` for create/update/destroy in specs (always rewritten by hand so far).
- [ ] **P2 — Generator dry-run + conflict handling. [S]** `--pretend` and
  overwrite prompts; today generators silently overwrite.

## Forem Lite app

- [ ] **P0 — Password reset flow. [S, closes M1]** Token mailer + 2h expiry,
  sibling of verification. **In progress below.**
- [ ] **P0 — CI for both repos. [S]** Neither repo has CI; app suite (79+) and
  framework suite (201) each run on one `crystal spec` invocation. Plain
  GitHub Actions with the pcre2 link flags baked in.
- [ ] **P1 — Bookmarks / reading list. [S]** Save-for-later join (same
  patterns as follows; exercises the same query shapes). Needs: toggle,
  `/bookmarks` page, feed affordance.
- [ ] **P1 — Comment threading. [M]** `parent_id` + nested display; currently
  flat. Needs pagination thought (deep threads vs page size) and a reply
  form per comment.
- [ ] **P1 — API tokens. [S/M]** JSON API is session-cookie-only; token auth
  (per-user `api_token`, `Authorization: Bearer`) unlocks non-browser
  clients. Depends on: encrypted-at-rest preference (see framework).
- [ ] **P1 — Admin moderation queue. [M]** Flagged-content view + user list +
  analytics counts; admins currently moderate one-by-one from article pages.
  Needs: report/flag model first.
- [ ] **P1 — Markdown rendering. [M]** Bodies are plaintext; minimal
  code-fence/paragraph renderer (no dependency) or a shard. Must stay
  XSS-safe by construction (escape-then-render, spec-pinned).
- [ ] **P1 — "My drafts" page + scheduled publishing. [M]** Drafts exist but
  are reachable only by URL; add listing + `published_at` future scheduling
  via a job. Depends on: durable jobs for reliability (else M2 first).
- [ ] **P2 — SQLite FTS5 search. [M]** Current search is escaped `LIKE`
  (correct but ranks nothing); FTS5 virtual table + triggers.
- [ ] **P2 — Single-read notifications + email digests. [S]** Mark-one-read
  endpoint; optional mailer digest reusing the SMTP adapter.
- [ ] **P2 — Avatars. [S, blocked on framework multipart]** Storage-backed
  avatars with variants once HTML file upload works.
- [ ] **P2 — SEO/sitemap/robots + meta tags. [S]** `/sitemap.xml` sibling of
  `/feed.xml`; OpenGraph tags in the layout.
- [ ] **P2 — Bell COUNT caching. [S]** Per-render `COUNT` is fine now;
  counter cache or short TTL when traffic matters.
- [ ] **P2 — I18n completion. [S]** Views use `t()` for feed strings but
  hardcoded English for auth/settings copy; extract remaining keys + fill es.

## Ops / release

- [ ] **P0 — Backup story beyond docs. [S]** WAL-mode snapshot script
  (`.db` + `-wal`/`-shm` or checkpoint-first) + a restore drill against a
  scratch copy.
- [ ] **P0 — `on_error` alerting. [S]** Job/mail failures only hit logs today;
  document wiring to a tracker (or add a webhook hook in the app).
- [ ] **P1 — Verify the Docker image. [S]** Unbuilt here (daemon permission);
  build + boot + migrate on a machine with Docker access.
- [ ] **P1 — Log rotation + access logs. [S]** Only app-level `Completed`
  lines exist; reverse-proxy logging is assumed but unstated. Caddy snippet
  already ships; add rotation + retention.
- [ ] **P2 — Staging env + seed variants. [S]** `APP_ENV=staging` config and a
  richer `db/seed.cr` demo dataset (tags, threads, follows).
- [ ] **P2 — Metrics endpoint. [M]** Request counts, job stats, DB sizes for
  the systemd/Caddy layout (or Prometheus format).

## Done this round — P0 password reset (M1 auth complete)

Token mailer + 2h expiry + single-use, mirroring verification:
`GET /password/new` → `POST /password` (always succeeds publicly — no account
enumeration) → mail with `/password/:token/edit` → `PUT /password/:token`
(min-8 rule, auto-login on success).
Proven by `spec/requests/password_resets_controller_spec.cr` (84 app examples
green) and live via Mailpit (request → mail → weak-reject → update → login
with the new password).
