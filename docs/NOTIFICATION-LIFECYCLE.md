# Household live updates

Linux continuation, 2026-10-18. Implementation checkpoint `7aaae2d` on
`codex/notification-lifecycle-20261018`, starting from handoff `b867ad2`.
This is an owned-loopback client implementation with scoped production-browser
acceptance, not public relay deployment or final iPhone/Android acceptance.

## Behavior and invariants

Authenticated household members can select **Live updates while open** in
Household options. This is an explicit, default-off choice for the current app
session. The relay operator must also enable the existing socket route; no
registration, grants or production credentials are created by the switch.
The existing manual/30-second HTTP sync remains available.

`NotificationSession` owns one connection, one in-flight sync, a dirty bit and
bounded timers. Open and reconnect always backfill through the existing
serialized authenticated HTTP path, even without a hint. A close also catches
up over HTTP so a removed reader can learn its removal through the existing
retired-reader path. Increasing hints coalesce over 250 ms; there is at most one
follow-up sync during a slow save. A hint is never a cursor, event, delivery ACK,
retention receipt or consent. The Rust money/MLS APIs and journal format did not
change. Durable encryption/save-before-send and confirmed-save-before-ACK remain
in the existing controller sync implementation.

Reconnect delays are 2, 4, 8, 16, 32, then 60 seconds, resetting only after a
connection has stayed open for a minute. Refusal/offline errors cannot make a
tight reconnect loop. Controller-wide single-flight guards prevent session churn
or a timed-out signer from accumulating queued signing/sync work behind a blocked
save. Generation and identity checks discard abandoned callbacks and proofs.

Household screen disposal, background/inactive lifecycle, native lock gate,
browser vault lock, forget/recovery/relay or identity changes, removal, uncertain
saves and controller disposal close listeners and cancel retries. Foreground
and unlock create a fresh session and HTTP backfill. Already-running HTTP work
drains through its durable-save path; stopping notifications is not a rollback
of an in-flight financial operation. Native read borrows defer handle retirement;
queued cleanup releases keys after their current operation ends. A disposed
controller cannot initialize again or return a late safety number/proof.

The transport signs the canonical HTTP origin/path with fresh protected-key
proofs, then connects via WS(S) with the exact selected subprotocol. It has no
application send API. Native handshakes own a cancellable HTTP client, disable
compression and refuse redirects of the proof. Early frames are dropped until
the consumer is attached; open backfill handles that loss. Pausing a hint
consumer closes it rather than buffering indefinitely. Only canonical safe
integer `{"tail":n}` text is accepted. The 64-character bound is **after platform
frame reception**, not a pre-allocation network-frame-size limit.

## Verification and reproduction

Source `scripts/codex_cloud_env.sh` in each Linux shell. It reuses pinned tools
and prepared caches and sets supported writable Flutter/analyzer state paths;
explicit cache bindings are preserved. `bash scripts/codex_cloud_setup.sh` and
its `--check` mode pass with a read-only home directory. No lockfile or pinned
version was replaced.

From `app/`, focused commands are:

```bash
flutter --no-version-check test --no-pub --timeout 20s test/relay_notifications_test.dart test/notification_session_test.dart test/household_handle_lifetime_test.dart test/biometric_lock_gate_test.dart
RUST_LIB_PATH="$PWD/../rust/target/debug/librust_lib_cash_app.so" flutter --no-version-check test --no-pub --timeout 90s test/household_notifications_http_host_test.dart test/household_screen_test.dart
```

Observed results include:

- Full host Flutter suite with the actual native bridge: **477 pass, exit 0,
  no skips**, at `7aaae2d` (5m 06s with concurrent tool compilation).
  Full analysis reports no issues. The suite includes both unit doubles and
  native/runtime tests; this is not a final mobile or production-web result.
- 23 transport tests and five session tests pass. Actual loopback tests verify
  receive-only text, aborting a stalled HTTP upgrade and refusing redirects.
  Session doubles exercise 10,000 hints, slow sync, retries, late ready and close.
- Actual native Rust identities and real loopback workerd/SQLite pass automatic
  expense delivery, missed-history backfill after background/lock, 100 rapid
  foreground transitions during a blocked save, uncertain-save-after-write
  refusal/restart, and current-member removal. Synthetic app journals are in
  memory; this is not an OS vault, biometric enrollment or mobile runtime test.
  The enhanced scenario separately passes with **both** peers subscribed and
  proves their actual HTTP traffic drains to two seconds of silence after
  confirmed-save receipt hints (one case, 20 s). No HTTP responses are mocked.
- Borrow/disposal regressions pass, including a delayed public-key query across
  forget/disposal, no restored keys after disposal and uncertain saved-state
  failures. The lock widget rejects authentication completed after backgrounding.
- Six 200%-text phone/tablet/desktop light/dark menu cases pass pointer selection
  and Escape cancellation. This is scoped reachability, not a complete screen
  reader or accessibility audit.
- Chromium runs six actual browser transport tests: canonical text, wrong
  selected protocol, binary/noncanonical frames, close before signing completes
  and cancellation during an actual pending upgrade. The fixture signs `{}`;
  it deliberately does not claim Rust/workerd authorization. Three separate
  browser storage tests pass, including the RAM-only phrase and second-tab
  identity-lease refusal. These are separate from the actual native signed test.

The repeatable Linux runner is `bash scripts/verify_notification_transport.sh`
from the repository root. It owns an ephemeral port/fixture, preserves the test
exit status and cleans up only its own process. Set `CHROME_EXECUTABLE` as needed.
For manual browser transport, start `node test/notification-client-fixture.mjs 8799`
from `relay/`, then from `app/` run:

```bash
flutter --no-version-check test --no-pub --platform chrome --dart-define=NOTIFICATION_TEST_ORIGIN=http://127.0.0.1:8799 test/relay_notifications_browser_test.dart
flutter --no-version-check test --no-pub --platform chrome test/event_store_web_test.dart test/vault_keys_web_test.dart
```

Set `CHROME_EXECUTABLE` to the installed browser/owned wrapper as needed; the
isolated Linux runner used Chromium with `--no-sandbox --disable-dev-shm-usage`.
Without the fixture define the transport cases are explicitly skipped. Those
skips are not browser acceptance. Stop the owned fixture after testing.

The rebuilt release WASM app passes the complete production-browser driver
(Chromium 154.0.8037.57, Linux x86_64, 1280x900, exit 0):

```bash
source scripts/codex_cloud_env.sh
WEB_HOUSEHOLD=1 WEB_HOUSEHOLD_AUTH=1 WEB_HOUSEHOLD_NOTIFICATIONS=1 CHROME_BINARY=/usr/bin/chromium CHROME_NO_SANDBOX=1 node scripts/verify_web_runtime.mjs
```

Actual public roster bootstrap and protected Rust signing authorize a selected
101 socket handshake against workerd/SQLite. A received tail hint precedes an
authenticated GET and successful response; the rendered `USD -40.00` balance
appears within ten seconds of publication without manual sync. No application
frames are sent. Browser vault lock closes the socket and phrase unlock opens a
new signed connection. An expanded complete repeat also verifies opt-out closes
the socket without retry, re-enable opens it, and reload/unlock retains the
default-off choice. Before member removal, Bob explicitly subscribes again;
revocation closes his real socket, automatic HTTP backfill renders his removal
within ten seconds without manual sync, and no reconnect is observed. The same run passes sealed reload, offline conflicting
edits, explicit unanimous pruning, same-origin identity lease refusal/transfer,
stale-backup fresh-key recovery/removal, frozen EUR/JPY rates and private-ledger
separation. Other stages use their existing explicit sync controls; they are not
claims of notification-triggered offline socket recovery.

The first attempt missed the animated menu click; its screenshot showed the
menu still open. The next reached handshake/hint/rendering, then failed an
overly narrow lock-button selector. Settled pointer selection and the existing
text-or-ARIA label lookup fixed the driver, with no product change. The complete
subsequent run passes; earlier partial runs are not counted as suite passes.
See the cloud handoff for exact build/tool status and source hash.

The expanded repeat exposed a real relay close-handshake defect: a browser
`close()` without a status reports reserved observation code `1005`; echoing
that forbidden wire status left the client in `CLOSING`. A real TCP test fails
before the fix and passes after mapping local-only `1005`/`1006`/`1015` to `1000`
(`50c3e02`). A separate missed DOM lock click during background sync was fixed
in the driver by waiting for bounded network silence and using physical pointer
input. The final complete run passes at the changed relay source; the earlier
single green journey did not establish repeatability of close handshakes.

After the relay fix, the manifest's 16-file suite passes **88/92 tests, four
explicit optional Rust skips, exit 0** (128.36s, concurrency one). Dedicated
`npm run test:request-proof-rust` passes **22, no skips**; separate
`npm run test:prefix-consent-rust` passes **one, no skips**. The actual native
controller scenario passes again (one case, 22s). An intervening wildcard
invocation wrongly included the fixture-only consent test without generating
its input: 88 pass, one fixture-input failure, four skips. Use the package test
list and dedicated generators rather than `test/*.test.js`.

### Production fault acceptance, 2026-10-18

Source `aad0f8f` was built from a separate clean local clone with pinned
toolchains/offline locked packages. The complete wide production journey passes
(Linux Chromium 154.0.8037.57, 1280x900, exit 0):

```bash
source scripts/codex_cloud_env.sh
WEB_HOUSEHOLD=1 WEB_HOUSEHOLD_AUTH=1 WEB_HOUSEHOLD_NOTIFICATIONS=1 WEB_HOUSEHOLD_NOTIFICATION_FAULTS=1 WEB_HOUSEHOLD_LARGE_AMOUNTS=1 WEB_HOUSEHOLD_QUOTA=1 CHROME_BINARY=/usr/bin/chromium CHROME_NO_SANDBOX=1 node scripts/verify_web_runtime.mjs
```

The browser actually minimizes to `visibilityState=hidden`: its socket closes
and stays closed, then foreground opens a fresh signed connection/HTTP backfill
and renders missed history. Real offline network failures produce bounded
reconnect attempts and preserve the previous balance; restoring networking
automatically reconnects and converges. No tail hint becomes ledger state.

An unrelated localStorage filler produces actual quota refusal while incoming
history requires a larger sealed database. The app closes notifications,
requires restart, and sends no receipt/other relay POST before a confirmed
save. Clearing pressure does not revive the failed session. Reload preserves
the last confirmed sealed SQLite image; explicit phrase unlock and re-enabling
the default-off session setting recover history. A normal UI void removes
only the synthetic quota expense. Local mutation quota refusal is also covered.
Catch-up can save smaller control prefixes before a later financial frame fails:
this is save-before-ACK evidence, not a promise of whole-page rollback.

Normal expense actions edit to `92233720368547758.07` and back to `40.00`;
the peer automatically renders exact balances with all digits preserved.
The same complete run passes the existing summary/privacy, key rotation,
conflict, explicit pruning, identity lease, removal/rejoin and frozen EUR/JPY
journeys. Log: `/tmp/notification-browser-final-bounded-quota.log` (ignored).
Earlier partial runs exposed fixture assumptions about SQLite free pages,
valid earlier saves and default-off restart settings; they are not suite passes.
Lazy rows are now verified by physical scrolling, not controller inspection.

The complete native-bridge host suite passes **484 tests**, no reported skips,
serial execution in 7m28s; full analyzer passes after adding braces to an
existing fixture assertion. One earlier contended run hit the existing 15s
HTTP fixture startup deadline (477/478); its isolated rerun and the later full
suite pass without deadline changes. Logs are listed in the cloud handoff.

Public authorization, hosted eviction/revival/billing, final mobile runtimes,
other platform lifecycle faults and the wider completion gates remain open.
No Actions job, PR, deployment, purchase, production secret or repository
visibility change is part of this work.
