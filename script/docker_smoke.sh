#!/usr/bin/env bash
# Builds the Dockerfile that `saci new` writes, with this checkout vendored
# into the app (instead of the GitHub release pinned in shard.lock), then
# boots the image and checks that it answers GET /up, GET / and HEAD /.
# CI job `docker`; locally: script/docker_smoke.sh (needs Docker).
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
name=dockapp
image="saci-docker-smoke-$$"
container="$image"
port="${SMOKE_PORT:-3999}"

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker rmi -f "$image" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

echo "==> saci new $name"
crystal build "$root/src/cli.cr" -o "$work/saci"
(cd "$work" && ./saci new "$name" --saci-path vendor/saci --skip-shards --skip-git)
app="$work/$name"

echo "==> vendoring this checkout into $name/vendor/saci"
mkdir -p "$app/vendor/saci"
cp -R "$root/shard.yml" "$root/src" "$app/vendor/saci/"
(cd "$app" && shards lock)
# The generated image installs Saci from GitHub; let it see the vendored copy.
sed -i 's|^COPY shard.yml shard.lock ./$|&\nCOPY vendor vendor|' "$app/Dockerfile"
sed -i '/^vendor$/d' "$app/.dockerignore"
grep -q '^COPY vendor vendor$' "$app/Dockerfile" || { echo "could not patch the Dockerfile" >&2; exit 1; }

echo "==> docker build"
docker build -t "$image" "$app"

echo "==> docker run"
docker run -d --name "$container" -p "127.0.0.1:$port:3000" \
  -e RAILS_MASTER_KEY="$(cat "$app/config/master.key")" "$image" >/dev/null

for _ in $(seq 1 60); do
  curl -fsS "http://127.0.0.1:$port/up" >/dev/null 2>&1 && break
  if [ "$(docker inspect -f '{{.State.Running}}' "$container")" != "true" ]; then
    echo "the container exited:" >&2
    docker logs "$container" >&2
    exit 1
  fi
  sleep 1
done

check() {
  local label=$1 expected=$2
  shift 2
  local status
  status=$(curl -s -o /dev/null -w '%{http_code}' "$@")
  if [ "$status" != "$expected" ]; then
    echo "FAIL $label: got $status, expected $expected" >&2
    docker logs "$container" >&2
    exit 1
  fi
  echo "ok   $label ($status)"
}

check "GET /up" 200 "http://127.0.0.1:$port/up"
check "GET /" 200 "http://127.0.0.1:$port/"
check "HEAD /" 200 -I "http://127.0.0.1:$port/"
check "GET /missing" 404 "http://127.0.0.1:$port/missing"

user=$(docker exec "$container" id -un)
[ "$user" = "saci" ] || { echo "FAIL: the app runs as $user, expected saci" >&2; exit 1; }
echo "ok   runs as $user"
