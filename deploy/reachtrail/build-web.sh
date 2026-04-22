#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
OUTPUT_DIR="${1:-$ROOT_DIR/build/web}"

cd "$ROOT_DIR"

flutter build web --release \
  --output "$OUTPUT_DIR" \
  --dart-define=PLACE_SEARCH_PROVIDER=yahoo \
  --dart-define=YAHOO_PROXY_BASE_URL=https://api.reachtrail.riumu.net/yahoo/localSearch \
  --dart-define=API_BASE_URL=https://api.reachtrail.riumu.net
