#!/usr/bin/env bash
# Live S3 harness: runs live/s3_live_spec.cr against an S3-compatible server.
#
# Usage:
#   live/s3.sh                                  # starts RustFS in Docker on 127.0.0.1:59000
#   S3_ENDPOINT=https://... S3_BUCKET=... \
#   S3_ACCESS_KEY_ID=... S3_SECRET_ACCESS_KEY=... S3_REGION=... live/s3.sh
#
# The bucket is created when missing (a signed PUT through curl), so a
# real AWS/R2 bucket works too. The container is left running for
# reruns; stop it with `docker rm -f saci-live-s3`.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${S3_BUCKET:=saci-test}"
: "${S3_ACCESS_KEY_ID:=saciaccess}"
: "${S3_SECRET_ACCESS_KEY:=saci-secret-key-123}"
: "${S3_REGION:=us-east-1}"
RUSTFS_IMAGE="${RUSTFS_IMAGE:-rustfs/rustfs:1.0.5}"

if [ -z "${S3_ENDPOINT:-}" ]; then
  S3_ENDPOINT="http://127.0.0.1:59000"
  if ! curl -s -o /dev/null "$S3_ENDPOINT"; then
    docker run -d --rm --name saci-live-s3 -p 127.0.0.1:59000:9000 \
      -e RUSTFS_ACCESS_KEY="$S3_ACCESS_KEY_ID" -e RUSTFS_SECRET_KEY="$S3_SECRET_ACCESS_KEY" \
      "$RUSTFS_IMAGE" /data >/dev/null
    for _ in $(seq 1 60); do
      curl -s -o /dev/null "$S3_ENDPOINT" && break
      sleep 1
    done
  fi
fi
export S3_ENDPOINT S3_BUCKET S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY S3_REGION

status=$(curl -s -o /dev/null -w '%{http_code}' -X PUT \
  --aws-sigv4 "aws:amz:${S3_REGION}:s3" --user "${S3_ACCESS_KEY_ID}:${S3_SECRET_ACCESS_KEY}" \
  "${S3_ENDPOINT%/}/${S3_BUCKET}")
case "$status" in
  200 | 409) ;; # created, or already there
  *) echo "could not create bucket ${S3_BUCKET} at ${S3_ENDPOINT} (HTTP ${status})" >&2; exit 1 ;;
esac

crystal spec live/s3_live_spec.cr "$@"
