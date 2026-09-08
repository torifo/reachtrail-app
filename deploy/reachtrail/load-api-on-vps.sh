#!/usr/bin/env bash
# Cross-compile the API on the host and ship a runtime-only image to the VPS.
# Building linux/amd64 with the Dart compiler under QEMU (api/Dockerfile) crashes
# with exit code 254 on Apple Silicon, so the binary is produced locally instead.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
IMAGE_TAG="${1:-ghcr.io/torifo/reachtrail-api:latest}"
TARGET_HOST="${2:-X-VPS}"
DEPLOY_DIR="${3:-/home/ubuntu/app/reachtrail/deploy}"
API_DIR="$ROOT_DIR/api"
(cd "$API_DIR" && dart pub get >/dev/null && mkdir -p build \
  && dart compile exe bin/server.dart --target-os=linux --target-arch=x64 -o build/reachtrail_api_linux_x64)
docker buildx build --platform linux/amd64 --load -f "$API_DIR/Dockerfile.prebuilt" -t "$IMAGE_TAG" "$API_DIR"
docker save "$IMAGE_TAG" | gzip | ssh "$TARGET_HOST" 'docker load'
ssh "$TARGET_HOST" "cd '$DEPLOY_DIR' && docker compose up -d --no-build reachtrail-api && docker ps --filter name=reachtrail-api --format '{{.Status}}'"
curl -s -o /dev/null -w 'GET /me -> %{http_code} (expect 401)\n' https://api.reachtrail.riumu.net/me
