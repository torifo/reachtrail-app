#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
IMAGE_TAG="${1:-ghcr.io/torifo/reachtrail-api:latest}"

docker build -t "$IMAGE_TAG" "$ROOT_DIR/api"
