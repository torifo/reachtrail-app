#!/usr/bin/env bash
# Build the API image on this machine for the VPS (linux/amd64) and load it
# there directly over SSH. The VPS has 2 GB of RAM, so building on it fails,
# and this path needs no registry push.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
IMAGE_TAG="${1:-ghcr.io/torifo/reachtrail-api:latest}"
TARGET_HOST="${2:-X-VPS}"
DEPLOY_DIR="${3:-/home/ubuntu/app/reachtrail/deploy}"

docker buildx build --platform linux/amd64 -t "$IMAGE_TAG" --load "$ROOT_DIR/api"
docker save "$IMAGE_TAG" | gzip | ssh "$TARGET_HOST" 'docker load'
ssh "$TARGET_HOST" "cd '$DEPLOY_DIR' && docker compose up -d --no-build reachtrail-api && docker ps --filter name=reachtrail-api --format '{{.Status}}'"
