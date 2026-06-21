#!/usr/bin/env bash
set -euo pipefail

INTERVAL="${APPROVE_ROUTES_INTERVAL_SECONDS:-300}"

while true; do
  /usr/local/bin/approve-gateway-routes.sh || true
  sleep "$INTERVAL"
done
