#!/usr/bin/env bash
# Live PostgreSQL/MySQL harness (P0 roadmap item).
#
# Usage:
#   live/run.sh                                   # both adapters, local defaults
#   PG_URL=... MYSQL_URL=... live/run.sh         # custom servers
#   crystal spec live/pg_live_spec.cr --link-flags="$PWD/live/ossl_shim.o"
#
# Prerequisites: reachable PostgreSQL + MySQL (see live/README.md) and
# `shards install` (pg + mysql live under development_dependencies).
set -euo pipefail
cd "$(dirname "$0")/.." # repo root

export PATH="$HOME/.local/bin:$PATH"
export LD_LIBRARY_PATH="$HOME/.local/pcre2/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LIBRARY_PATH="$HOME/.local/lib:$HOME/.local/pcre2/usr/lib/x86_64-linux-gnu${LIBRARY_PATH:+:$LIBRARY_PATH}"

: "${PG_URL:=postgres://saci:saci@127.0.0.1:55432/saci_test}"
: "${MYSQL_URL:=mysql://saci:saci@127.0.0.1:53306/saci_test}"
export PG_URL MYSQL_URL

cc -c live/ossl_shim.c -o live/ossl_shim.o
crystal spec live/pg_live_spec.cr live/mysql_live_spec.cr \
  --link-flags="$PWD/live/ossl_shim.o"
