#!/usr/bin/env bash

set -euo pipefail

IMAGE_TAG="${1:-ghcr.io/torifo/reachtrail-api:latest}"

docker push "$IMAGE_TAG"
