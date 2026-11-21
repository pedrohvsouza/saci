#!/usr/bin/env bash
# Generates the public API reference into docs/api (gitignored).
# CI job `docs`; locally: script/docs.sh.
#
# Only ./src is scanned, so spec fixtures, generated apps and test helpers
# outside the framework source never leak into the site.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

out="${SACI_DOCS_OUT:-docs/api}"
version=$(awk '/^version:/{print $2; exit}' shard.yml)

rm -rf "$out"
crystal docs \
  --project-name Saci \
  --project-version "$version" \
  --output "$out"

echo "API docs: $out/index.html"
