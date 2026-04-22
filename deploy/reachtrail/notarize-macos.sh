#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
ARCHIVE_PATH="${1:-$ROOT_DIR/build/macos-dist/reachtrail-macos.zip}"
KEYCHAIN_PROFILE="${2:-AC_NOTARY}"

if [[ ! -f "$ARCHIVE_PATH" ]]; then
  echo "Archive not found: $ARCHIVE_PATH" >&2
  echo "Run ./deploy/reachtrail/package-macos.sh first." >&2
  exit 1
fi

xcrun notarytool submit "$ARCHIVE_PATH" \
  --keychain-profile "$KEYCHAIN_PROFILE" \
  --wait

echo
echo "Notarization completed for: $ARCHIVE_PATH"
