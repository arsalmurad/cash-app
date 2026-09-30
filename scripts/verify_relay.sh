#!/usr/bin/env bash
# Verifies the Cloudflare relay worker two ways, both in workerd (miniflare):
#   1. the worker's own tests (relay/test), and
#   2. the real Rust sync engine against the running worker
#      (rust/sync/tests/http_relay.rs, ignored unless RELAY_URL is set).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
port="${RELAY_PORT:-8787}"

(cd "$root/relay" && npm ci --no-audit --no-fund && npm test)

(cd "$root/relay" && node dev-server.mjs "$port") &
server=$!
trap 'kill "$server" 2>/dev/null || true' EXIT

for _ in $(seq 1 60); do
  if curl -fsS -o /dev/null "http://127.0.0.1:$port/g/short" 2>/dev/null || \
     [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/g/short")" = "404" ]; then
    break
  fi
  sleep 0.5
done

cd "$root/rust"
RELAY_URL="http://127.0.0.1:$port" \
  cargo test -p cash_sync --features http --test http_relay -- --ignored --test-threads=1
