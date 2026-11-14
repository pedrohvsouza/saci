# Roadmap

Saci is at **0.8.0**. The 0.x line keeps the freedom to change APIs. The
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

- **Storage**: the S3 service has not been verified against a live
  bucket.
- **Cable**: the database adapter polls on SQLite and MySQL; only
  PostgreSQL has push delivery (`LISTEN/NOTIFY`).
- **Deploy**: there is no bundled HTTP/2 proxy (Thruster is only
  documented).
- **Testing**: there are no browser-driven system tests.

## Out of scope

- Rack compatibility. Saci middleware is plain `HTTP::Handler`.
- GIS / PostGIS types in core.

Bug reports and suggestions are welcome as GitHub issues.
