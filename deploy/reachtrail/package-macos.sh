#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD_DIR="$ROOT_DIR/build/macos/Build/Products/Release"
TEMPLATE_PATH="$ROOT_DIR/deploy/reachtrail/download-index.html"
APP_PATH="${1:-$BUILD_DIR/reachtrail_app.app}"
OUTPUT_DIR="${2:-$ROOT_DIR/build/macos-dist}"
ARCHIVE_BASENAME="${3:-reachtrail-macos}"
ZIP_PATH="$OUTPUT_DIR/$ARCHIVE_BASENAME.zip"
INDEX_PATH="$OUTPUT_DIR/index.html"

if [[ ! -d "$APP_PATH" ]]; then
  echo "macOS app bundle not found: $APP_PATH" >&2
  echo "Run a signed release build first:" >&2
  echo "  flutter build macos --release" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
rm -f "$ZIP_PATH"

ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

if [[ -f "$TEMPLATE_PATH" ]]; then
  cp "$TEMPLATE_PATH" "$INDEX_PATH"
fi

echo "Created: $ZIP_PATH"
