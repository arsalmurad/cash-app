#!/usr/bin/env bash
# Own a disposable loopback fixture; preserve Flutter's actual test exit status.
set -euo pipefail
cash_notification_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$cash_notification_root"
source scripts/codex_cloud_env.sh
cash_notification_log="$(mktemp)"
(cd relay && exec node test/notification-client-fixture.mjs 0) >"$cash_notification_log" 2>&1 &
cash_notification_pid=$!
cleanup_cash_notifications() {
  kill "$cash_notification_pid" 2>/dev/null || true
  wait "$cash_notification_pid" 2>/dev/null || true
  rm -f "$cash_notification_log"
}
trap cleanup_cash_notifications EXIT
cash_notification_port=''
for ((cash_notification_attempt=0; cash_notification_attempt<100; cash_notification_attempt++)); do
  while IFS= read -r cash_notification_line; do
    if [[ "$cash_notification_line" =~ ^PORT:([0-9]+)$ ]]; then
      cash_notification_port="${BASH_REMATCH[1]}"
    fi
  done <"$cash_notification_log"
  if [[ -n "$cash_notification_port" ]]; then break; fi
  if ! kill -0 "$cash_notification_pid" 2>/dev/null; then
    cat "$cash_notification_log" >&2
    exit 1
  fi
  sleep 0.1
done
if [[ -z "$cash_notification_port" ]]; then
  printf '%s\n' 'Owned notification fixture did not become ready.' >&2
  exit 1
fi
cd app
flutter --no-version-check test --no-pub --platform chrome \
  --dart-define="NOTIFICATION_TEST_ORIGIN=http://127.0.0.1:$cash_notification_port" \
  test/relay_notifications_browser_test.dart
