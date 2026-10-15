# Changelog

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
