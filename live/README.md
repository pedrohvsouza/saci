# Live database verification (PostgreSQL + MySQL)

The default suite (`crystal spec`, SQLite) never touches these files.
`live/pg_live_spec.cr` and `live/mysql_live_spec.cr` exercise the same
coverage against real servers: connect, migration DDL (all column types,
`add_column`/`add_index` incl. unique, drop/rollback via `Migrator`),
CRUD + `find`/`find_by`, validations (presence/length/format,
scoped + case-insensitive uniqueness), `belongs_to`/`has_many`/`through`
+ `counter_cache`, transactions (commit + `DB::Rollback`), `$n`
placeholder rewriting (PG), reserved-word quoting (column `order`),
`RETURNING` (PG) vs `last_insert_id` (MySQL) inserts,
Time/Bool/Decimal/JSON round-trips, `update_all`/`delete_all`/`count`/`pluck`,
`clean_database!`.

Run: `live/run.sh` (see it for `PG_URL`/`MYSQL_URL` defaults).

## Servers

Local development uses non-standard ports (see `docker-compose.live.yml`
for the Docker equivalent):

- PostgreSQL: `postgres://saci:saci@127.0.0.1:55432/saci_test`
- MySQL: `mysql://saci:saci@127.0.0.1:53306/saci_test`

Each spec file aborts with a clear message when its URL env var
(`PG_URL` / `MYSQL_URL`) is missing, and creates its tables in
`before_all` / drops them in `after_all` (models are `PgLive*` /
`MyLive*` so both files can share one spec process).

## OpenSSL link shim (`live/ossl_shim.c`)

`crystal-pg` fails to link on OpenSSL ≥ 3.2: it references
`SSL_get_peer_certificate` and `EVP_MD_size`, both removed from the
shared library (renamed to `SSL_get1_peer_certificate` /
`EVP_MD_get_size`). The two-symbol C shim maps the old names to the new
ones; `live/run.sh` compiles it (`cc -c live/ossl_shim.c`) and passes
the object via `--link-flags`. `crystal-mysql` links without it, but the
flag is harmless when both drivers are in one binary.

## MySQL auth note

`crystal-mysql` only speaks `mysql_native_password`, which MySQL 8.4
disables by default. The server must enable it (`--mysql-native-password=ON`)
and the user must use it
(`ALTER USER 'saci'@'%' IDENTIFIED WITH mysql_native_password BY 'saci'`).
Same for CI services (Docker `mysql:8` image or GitHub `mysql` service:
start with `--mysql-native-password=ON` or equivalent
`command` override).

## CI services note

```yaml
services:
  postgres:
    image: postgres:16-alpine
    env: {POSTGRES_USER: saci, POSTGRES_PASSWORD: saci, POSTGRES_DB: saci_test}
    ports: ["55432:5432"]
  mysql:
    image: mysql:8
    env: {MYSQL_USER: saci, MYSQL_PASSWORD: saci, MYSQL_DATABASE: saci_test, MYSQL_ROOT_PASSWORD: root}
    ports: ["53306:3306"]
    options: --mysql-native-password=ON   # exact flag varies by runner
```

Then: `shards install && PG_URL=... MYSQL_URL=... live/run.sh`.

## Known gaps (documented, not fixed)

- Timestamp precision: MySQL `DATETIME` defaults to seconds resolution
  (sub-second truncated); PostgreSQL `TIMESTAMP` keeps microseconds
  (Crystal `Time` nanoseconds truncated). Specs assert whole-second times
  exactly and recent timestamps with tolerance.
- No `ENUM`/native-JSON assertions on MySQL: `JSON` columns map to `TEXT`
  there because `crystal-mysql` cannot decode the native JSON wire type;
  content round-trips as text.
- The framework never requires drivers itself (`require "pg"` /
  `require "mysql"` live only in `live/*` + the owning app); `pg`/`mysql`
  are `development_dependencies` so plain `crystal spec` links SQLite only.
