# Roadmap

Saci is at **0.6.2**. The 0.x line keeps the freedom to change APIs. The
interfaces documented in the [README](README.md) are stable in practice,
and breaking changes are listed in the [changelog](CHANGELOG.md).

## Toward 1.0

1.0 is reserved for two things: the developer loop and ecosystem
maturity.

- **Developer loop.** Crystal has no runtime evaluation, so Rails-style
  autoloading, in-process reload and an IRB console cannot be ported
  directly. The goal is the closest compiled equivalent: faster rebuilds
  for `saci serve --watch`, a more capable `saci console`/`saci runner`,
  and a documented debugging workflow.
- **Ecosystem maturity.** Tagged releases that apps can depend on with
  `github:` instead of a `path:` checkout, published API docs, and a
  review of what is public versus internal.

## Open work

These are known gaps in the current release:

- **Jobs**: there is no Redis queue adapter; `:db` is the durable option.
- **Storage**: no image processor ships behind the variant/preview
  interface, and the S3 service has not been verified against a live
  bucket.
- **Cable**: the database adapter polls. PostgreSQL `LISTEN/NOTIFY` is
  not implemented.
- **Deploy**: the generated Dockerfile has not been verified by a
  container build in CI. There is no bundled HTTP/2 proxy (Thruster is
  only documented).
- **ORM**: there is no `default_scope`, no single-table inheritance,
  and no attribute encryption (see
  [COMING_FROM_RAILS.md](COMING_FROM_RAILS.md)).
- **Testing**: there are no browser-driven system tests.

## Out of scope

- Rack compatibility. Saci middleware is plain `HTTP::Handler`.
- GIS / PostGIS types in core.

Bug reports and suggestions are welcome as GitHub issues.
