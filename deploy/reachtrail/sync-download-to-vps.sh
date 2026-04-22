#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SOURCE_DIR="${1:-$ROOT_DIR/build/macos-dist/}"
TARGET="${2:-root@X-VPS:/home/ubuntu/app/reachtrail/download/}"

rsync -av --delete "$SOURCE_DIR" "$TARGET"
