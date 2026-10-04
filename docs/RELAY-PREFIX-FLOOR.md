# Internal bounded relay prefix storage

Verified 2026-10-04 on Windows with Node 24.19.0 and cached Miniflare
4.20260730.0/workerd, using actual SQLite-backed Durable Object storage.
This is a storage foundation, **not completed authenticated pruning or peer
recovery**. No production route invokes `GroupLog.prunePrefix`; the authenticated
roster worker refuses `/prune`, even with a valid current-device request proof.

## Implemented boundary

The internal primitive requires an explicit authorizer returning boolean `true`
inside each transaction. It removes at most 16 contiguous records, updates the
absolute prefix floor and exact remaining base64 byte/record counters atomically,
and never renumbers or resets the tail. The validated request target is captured
before awaiting the guard. An absent/denied guard cannot mutate storage; a
stale expected floor conflicts rather than deleting another chunk after a lost
reply. New appends retain their absolute sequence numbers and reclaimed capacity.

Reads below the recorded floor return 410 without numeric floor/tail disclosure;
they never silently jump the client's cursor. Reads refuse incomplete pages,
holes and malformed records with 503. Malformed floor/tail accounting refuses
reads and writes rather than guessing or erasing history. Existing unpruned
logs default to floor zero. The twelve-digit key ceiling is explicit, with the
last sequence readable and further appends refused without wrapping ordering.

The transaction choice follows the pinned runtime's
[SQLite storage transaction contract](https://developers.cloudflare.com/durable-objects/api/sqlite-storage-api/).
Owned local workerd tests exercise rollback; this is not cloud deployment,
arbitrary power-loss or physical storage durability evidence.

## Verification and failures preserved

`node --test test/prefix-retention.test.js` from `relay`: 11 passed, 0 failed
(2.295 s). The fixture wraps the actual production class in an in-memory test
module; seed/inspect/fault routes do not exist in production source. Tests cover
bounded reclamation, interrupted deletion/floor/counter updates, guard rollback,
lost replies, competing requests, append races, malformed accounting, holes,
mutable awaited request targets, the sequence ceiling, and actual runtime object
replacement with preserved SQLite rows. The authorizer is fixture-only, not a
substitute for all-device permission.

Test-first results: old implementation failed 9 cases; added short-page and
mutable-target checks both failed before their repairs. Local ignored logs:
`app/.dart_tool/prefix-retention-red.log`, `prefix-retention-guards-red.log`,
and `prefix-retention-final.log`.

Final `npm test` from `relay`: 80 tests, 77 passed, 0 failed, 3 optional
Rust-request-proof skips (38.689 s). Log:
`app/.dart_tool/prefix-retention-relay-final-retry.log`. An initial sandboxed run
stalled in owned loopback-server checks and was terminated after verifying its
process tree; it is not a pass. The retry had local loopback access.

From `app`, with the existing ABI `-1323392253` native DLL:

```text
flutter --no-version-check test --no-pub --concurrency=1 test/household_scoped_join_http_host_test.dart test/household_authenticated_http_host_test.dart
```

All 8 passed (73 s runtime), including saved-join/restart boundaries and actual
authenticated HTTP SQLite privacy audits. Log:
`app/.dart_tool/prefix-retention-native-http-retry.log`. The initial sandboxed
invocation failed in Flutter telemetry-file access before running tests. No
Rust/app source, bridge ABI or platform artifact changed, so no all-platform
rebuild is claimed or needed for this relay-only concern.

## Still required before enabling deletion

Verify signed acknowledgements from **every current MLS signing key** for the
same exact checkpoint and current policy epoch; bind explicit deletion consent
and recoverable peer availability. Recheck that authority in the same transaction
on every bounded chunk, including membership races and lost replies. Wire actual
protected-save client coordination and stale-device fresh-key recovery against
this real floor. A TTL, cursor high-water mark, matching balances, local computed
cutoff or callback merely returning true is not permission to delete history.
Gate 2 in `COMPLETION.md` remains open; public deployment remains disabled.

## Actual deleted-prefix peer recovery (2026-10-04)

The existing native app controller now has an end-to-end regression against
actual prefix deletion in the production roster worker's SQLite log. The test
driver exposes its deletion command only to its owning process over stdin and
the internal Durable Object stub; external `/g/{id}/prune` remains refused.
Its authorizer deliberately returns true: this fixture verifies storage and
recovery, **not all-device deletion consent**.

Normal authenticated HTTP clients found/enrol two distinct signing identities,
save an early phrase-sealed backup, synchronize later expenses, then lose the
real old log prefix. The older saved device gets HTTP 410, preserves its exact
Rust archive/cursor, and adds no relay records. Recovery creates fresh keys,
retires the old identity, receives a current peer's Welcome and authenticated
history, replaces both controllers before resumed catch-up, and recovers the
same transaction projections and USD -9.75 balance. A subsequent fresh-sender
expense delivers normally (USD -10.75); the stale identity remains unable to
resume. Absolute floor/tail and exact remaining record counters are inspected
through the owned stub, never through a production inspection route.

From `app`, with the cached ABI `-1323392253` native DLL:

```text
flutter --no-version-check test --no-pub --concurrency=1 test/household_prefix_recovery_http_host_test.dart
```

1 passed, 0 failed (7 s runtime), log
`app/.dart_tool/prefix-recovery-native-http-final.log`; targeted Dart analysis
has no issues, and the fixture passes Node syntax checking. The first run
completed the journey assertions but failed in double-disposal of the restarted
controllers during test teardown; cleanup now tracks only live controllers.
Its failure is preserved in `prefix-recovery-native-http.log`.

Stores here are memory-backed confirmed writes, not actual protected OS storage
or arbitrary power-loss evidence. Two initial peers and a replacement with
three expenses are checked, not a new 1,000-event, multi-currency or final-device
acceptance run. No app/Rust production source, bridge ABI, platform artifact,
public route or deployed relay changed. Gate 2 still requires real consent and
recoverable availability, including protected-save/final-platform coordination.
