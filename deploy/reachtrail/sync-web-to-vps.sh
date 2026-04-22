#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SOURCE_DIR="${1:-$ROOT_DIR/build/web/}"
TARGET="${2:-root@X-VPS:/home/ubuntu/app/reachtrail/app/}"

rsync -av --delete \
  --exclude 'assets/assets/config/.env' \
  "$SOURCE_DIR" "$TARGET"
