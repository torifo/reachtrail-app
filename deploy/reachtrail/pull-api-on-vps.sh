#!/usr/bin/env bash

set -euo pipefail

TARGET_HOST="${1:-root@X-VPS}"
DEPLOY_DIR="${2:-/home/ubuntu/app/reachtrail/deploy}"

ssh "$TARGET_HOST" "cd '$DEPLOY_DIR' && docker compose pull reachtrail-api && docker compose up -d reachtrail-api"
