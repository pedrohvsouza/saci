# Changelog

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
