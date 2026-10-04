# Explicit relay prefix consent

Implemented and locally verified 2026-10-04. **Not a completed end-to-end app
retention feature.** The Rust signer and actual SQLite roster worker now enforce
separate, unanimous deletion consent. Normal launch remains disabled; only an
explicit `LOCAL_AUTH_RETENTION=true` in owned loopback roster mode enables
`POST /g/{id}/prune`. Public routing remains closed. No cloud jobs were dispatched.

## Permission, not a receipt cutoff

`Peer::sign_prefix_consent(saved, request)` is read-only. It requires the exact
latest archive, active unstaged membership, no unsent work, authenticated history,
and a valid collected saved-state receipt from every current MLS signing key for
the same checkpoint. It refuses a target beyond the minimum acknowledged cursor,
an incorrect policy/MLS epoch, unknown recovery holder, invalid origin or expiry.
The caller still owes a confirmed protected-storage read-back and retention of a
recoverable archive: Rust cannot infer those from bytes.

The binary consent has a separate `cash-app prefix retention consent v1` domain,
canonical HTTPS/owned-loopback origin, random relay group ID, cryptographic MLS
group ID, current epoch, absolute cutoff, opaque checkpoint commitment, designated
recovery holder, expiry and signing key. It is signed using the existing
group-bound authenticated-history Ed25519 envelope. Expiry is at most 60 seconds;
this is a permission lifetime, **never a financial-history TTL**. No private keys,
archives, amounts, titles, names or causal frontiers are sent as consent fields.
Public keys, groups, epochs and commitments are linkable metadata, not anonymity.

The request contains exactly `expectedFloor`, `through` and `consents` (hex-encoded
binary consents), plus the existing protected device request proof over its exact
bytes. The designated holder must be a current read/membership-authorized device
and sign this request. Every current device, including offline devices, must
previously acknowledge the exact saved checkpoint and explicitly sign the same
consent; duplicate, missing, foreign, conflicting or expired signatures fail.
The server never reinterprets an ordinary saved-state receipt as consent.

## Transaction boundary

The verifier copies/parses bounded inputs before crypto awaits and produces an
identity-local capability, not an authorizable JSON object. Every chunk checks
the exact current roster, epoch, origin/group, holder, cutoff and expiry against
the stored admitted monotonic clock in the same SQLite transaction as nonce,
budget admission and deletion. A membership change invalidates old permission
even when all public signing keys remain unchanged (for example key refresh).

Authentication precedes conflict metadata. A stale expected floor returns a
conflict without deleting another chunk and rolls back guard writes. Failed
authority, replay or quota admission preserves records and counters. Successful
requests delete at most 16 records, keep absolute tail/sequence numbers, and
reclaim exact stored base64 bytes. The same approved cutoff can be retried with
fresh proofs and the next confirmed floor; it never grants a larger target.
Consent bodies/commitments are not persisted in relay KV storage.

See [RELAY-PREFIX-FLOOR.md](RELAY-PREFIX-FLOOR.md) for storage faults, actual
runtime replacement and fresh-key recovery after genuinely deleted records.

## Verified scope

Windows, pinned stable Rust 1.98.1, Node 24.19.0 and cached Miniflare
4.20260730.0/workerd with actual SQLite storage. All commands use existing tools
and offline Rust dependencies; no install or toolchain upgrade occurred.

- Rust consent tests: 3 passed. Missing receipts, mismatched/latest/unsent saves,
  stale epochs, unknown holders, cutoff/origin/expiry boundaries, restart,
  pending refresh and removal are covered; signing preserves exported state.
- Affected receipt/transport/persistence/recovery suite: 22 passed with
  `cargo +stable test --manifest-path rust/Cargo.toml --locked --offline
  -p cash_sync --features http,relay-auth --test prefix_consent
  --test retention_receipts --test retention_transport
  --test retention_persistence --test recovery_gap` (26.14 s compilation).
  Log `app/.dart_tool/prefix-consent-rust-regression.log`.
- `cargo +stable clippy --manifest-path rust/Cargo.toml --locked --offline
  -p cash_sync --all-targets --features http,relay-auth -- -D warnings` passes
  (10.87 s), log `prefix-consent-clippy.log`.
- Actual relay consent cases pass: normal bounded deletion; exact all-key
  authority; duplicate/missing/foreign signatures; wrong request holder;
  checkpoint/group/cutoff/epoch/origin/expiry mismatches; replay/stale retry;
  real authenticated epoch transition; a holder without membership permission;
  full quota; monotonic-clock expiry; default-disabled/public refusal.
- Final `npm test` from `relay`: 85 tests, 82 passed, 0 failed, 3 optional
  Rust-request-proof skips (37.48 s), log
  `app/.dart_tool/prefix-consent-relay-final.log`. The dedicated Rust consent
  interoperability command below ran independently and did not skip.
- `npm run test:prefix-consent-rust` from `relay` passes (1 workerd test,
  9.55 s): real Rust consent signatures, group-bound envelope and request
  proof authorize deletion of the actual synthetic Rust ciphertext prefix,
  while later control messages and exact remaining capacity are preserved.
  Log `app/.dart_tool/prefix-consent-rust-interop.log`. Set `CARGO` to the
  installed cargo executable and `RUSTUP_TOOLCHAIN=stable` on this host.

Test-first Rust compilation failed on the absent consent API; the first
sandboxed attempt could not execute the installed compiler. The JavaScript
test-first run failed on the absent consent module. Integration then caught
guard writes surviving a stale conflict, which now throws a transaction rollback
before returning the authenticated conflict. Logs are preserved in
`prefix-consent-rust-red-retry.log`, `prefix-consent-relay-red.log` and
`prefix-consent-relay-tests.log`. An initial formatter invocation used the wrong
working-directory-relative manifest; it was corrected with the absolute path.

## App controller coordination (2026-10-04)

The generated bridge now exposes holder proposals, countersigning and complete
bundle validation. Every signer independently verifies the original holder's
signature, scope, current roster/epoch, acknowledged cutoff and exact latest
checkpoint; an approval cannot masquerade as a proposal. Bundle validation
exports/hashes the archive once, then checks every unique current signing key.

The controller synchronizes and reads back the exact complete household journal
before releasing either code, checks storage again after the bridge await, and
checks storage plus current policy before every authenticated deletion chunk.
Uncertain or stale storage disables writes and requires restart. Codes are
bounded, distinct request/approval formats. Permission expires after 50 seconds;
there is no automatic pruning, persisted permission or unauthenticated fallback.
Retry starts at floor zero and accepts only authenticated conflict progress,
never changing the household delivery cursor or retained local history.

Independently verified on the Windows native host, ABI `1237803201`:

- Affected Rust consent/receipt/transport/persistence/recovery tests: **23 passed**.
  Same command as above, log `prefix-consent-client-regression-final.log`.
- Regenerated API suite: **70 passed**, log
  `prefix-consent-client-api-regression.log`. Strict Clippy for `cash_sync` and
  `rust_lib_cash_app`, all targets with `cash_sync/http,cash_sync/relay-auth`,
  passes with warnings denied (`prefix-consent-client-clippy-final.log`).
- Pinned bridge generation and offline native DLL build pass. The matching
  Flutter native controller performs real signed deletion through normal HTTP,
  refuses missing approvals/wrong holder, blocks failed/stale archive reads,
  restarts, and recovers an old saved device through fresh-key rejoin: **1 passed,
  6 seconds**, `prefix-consent-controller-http-faults.log`.
- Its relay fixture has **no deletion bypass**: owning stdin only inspects
  counters; all pruning uses the real authenticated production route and
  unanimous signatures. This supersedes the earlier bypass-based test evidence
  described in `RELAY-PREFIX-FLOOR.md` without changing that historical result.
- Receipt/save/membership-retry and new code/HTTP transport regressions:
  **40 passed**, `prefix-consent-controller-regression.log`. The separate
  transport/HTTP suite passed 28 tests (`prefix-consent-transport-tests.log`).
- Targeted Dart analysis has no issues; relay fixture syntax and `git diff
  --check` pass. No new platform-wide rebuild was needed for these native checks.

Test-first builds failed on the then-missing Rust/transport APIs. Clippy caught
an unnecessary test clone, fixed before the passing rerun. The actual route
correctly returned 401 to an anonymous caller; the previous disabled-route
expectation of 403 was updated. Wrong-directory Flutter/formatter invocations
were corrected without installations. Full local diagnostics remain ignored
under `app/.dart_tool`; tracked tests are repeatable evidence.

## Remaining integration and limits

The loopback authenticated household menu now offers **Manage relay copies**
only for an active, unlocked, idle, confirmed member. Opening/closing does not
sign. Prepare a request, have every other current device review/approve it, then
paste one complete approval per line and review deletion. Both approval and
deletion require explicit consequences-first confirmation. Renewal clears prior
approvals; editing a received request hides its old approval. The holder keeps
its complete archive. Collection pauses this screen's background sync, not other
devices; any intervening change still invalidates signatures through core checks.
Keep encrypted backups and a current device available. The operator must opt in;
this screen does not enable retention or deploy/register a relay.

Windows widget tests for this dialog and household screen: **27 passed**, 16 s
runtime, from `app` with pinned Flutter:

```text
flutter --no-version-check test --no-pub --concurrency=1 test/retention_dialog_test.dart test/household_screen_test.dart
```

Log `app/.dart_tool/prefix-consent-dialog-final-retry.log`. Tests verify no
automatic signing, separate confirmations/cancellation, exact copied codes,
renewal, malformed-code refusal, partial-deletion failure wording, conditional
menu, suspended/resumed background sync, disabled busy controls, and 360x740
phone layout at 200% text. Scoped Android tap-target, labeled-target and text
contrast guidelines pass; Tab/Enter reaches Close without signing. This is
not real VoiceOver/NVDA or full app accessibility evidence. Targeted Dart
analysis and diff whitespace checks pass. An initial test invocation used the
wrong directory; corrected before running. Tests caught an unnecessary progress
animation during confirmation, now suppressed. A semantics test cleanup ordering
failure was corrected before the passing rerun.

The actual native HTTP recovery test additionally discards the first successful
production pruning response **after** its SQLite transaction, returning a
controlled 503 with no deletion metadata. The controller reports failure, keeps
its delivery cursor and complete saved archive, restarts from that archive, and
retries the identical signed target with a fresh request proof. The genuine
committed-floor conflict resumes/finishes deletion and fresh-key recovery still
passes. **1 passed, 10 seconds**, log
`app/.dart_tool/prefix-consent-controller-lost-reply.log`; same host command as
the controller recovery test. This is a post-commit lost-confirmation simulation,
not arbitrary network interruption or OS power loss. No production relay fault
switch was added; the owning test wrapper only replaces that successful reply.

Verify actual protected OS/browser store
availability and lifecycle faults, and exercise roster
changes in the normal controller flow. Current recovery stores are memory-backed
confirmed writes, not OS storage or arbitrary power-loss proof. No new production
Chrome/Android/iOS artifact or final-platform runtime is claimed here.
Existing three-peer/1,000-event and platform results remain revision-scoped, not
fresh consent-runtime evidence. Gate 2 remains open; enable no default app
pruning or public deployment on the strength of these protocol tests alone.

### Controller disposal boundary

A delayed confirmed-archive read with controller disposal now releases no request
code, and an approval queued behind it does not execute after closure. The first
native test found a late `notifyListeners` call on the disposed controller, not a
signature release. The serialized operation runner now refuses closed queued
work, cannot report successful results after closure, and suppresses its final
notification after disposal. The saved archive still restarts normally and the
actual pruning/lost-reply/fresh-recovery journey remains successful.

From `app` with the matching native DLL, the recovery, saved-receipt and durable
membership-retry tests pass **35 tests, 28 seconds**:

```text
flutter --no-version-check test --no-pub --concurrency=1 test/household_prefix_recovery_http_host_test.dart test/household_retention_host_test.dart test/household_membership_retry_host_test.dart
```

Logs `prefix-consent-controller-disposal-red.log` and
`prefix-consent-controller-disposal-final.log`; the added queued-approval assertion
then passes the recovery test independently in 10 seconds
(`prefix-consent-controller-disposal-queued.log`). Targeted Dart analysis is
clean. This is native memory-backed archive fault evidence, not browser Web Locks
or actual OS-key-store lifecycle proof.

### Actual storage after signed pruning and recovery

The owning native fixture now audits the actual SQLite-backed KV after real
signed pruning, lost-response/restart handling and fresh-key recovery. A separate
pruned audit entry point requires the independently expected positive floor,
exact remaining sequence range, `entries = tail - floor`, and exact ciphertext
base64 byte capacity. It retains the original strict current-policy/public-key,
two-Welcome, one-retirement and one-invitation-authority coverage requirements.
The older unpruned entry point still refuses a floor; it is not weakened to
accept either state implicitly.

Known synthetic titles, private member/account names, transaction IDs, balance
labels and signed i64 amounts in both endian representations are absent from
remaining ciphertext, Welcomes and serialized metadata. Negative controls on
copies reject plaintext/binary amounts, readable Welcome data, extra fields in
each public inventory, missing inventories/log records, persisted consent data
and a corrupted floor. This is an exact-schema known-fixture KV audit, not
raw SQLite-file forensics, metadata anonymity or formal cryptographic proof.
Only the owning stdin command can inspect/audit; no production audit route exists.

- Pruned/recovery actual native test: **1 passed, 7 seconds**,
  `app/.dart_tool/prefix-consent-storage-audit-retry.log` (same recovery command).
- Original actual unpruned roster/privacy audit, all original poison controls:
  **1 passed, 15 seconds**,
  `app/.dart_tool/prefix-consent-unpruned-audit-regression.log`, using
  `flutter --no-version-check test --no-pub --concurrency=1
  test/household_scoped_join_http_host_test.dart --plain-name storage-audit`.
- Targeted Dart analysis, both Node fixture/auditor syntax checks and diff
  whitespace checks pass. The first new audit invocation failed on a test-only
  cast syntax error before executing; fixed before the passing runtime rerun.

The first post-format final invocation was **not executed**: automatic approval
review returned an account usage-limit error, not an unsafe-action decision. No
test process started, and review was not bypassed. Once normal approval review
worked again, the identical command passed **1 test, 28 seconds**, terminal exit
0 (`app/.dart_tool/prefix-consent-storage-audit-final.log`). The final tracked
test source, actual signed pruning/recovery and all storage controls are verified
on this native host; this still does not claim final phone/browser coverage.

## Actual protected Android consent and recovery

Production app/bridge source through `1239746`, evidence head `8716ac0`, ABI
`1237803201`, with the extended tracked Android integration test and owning
driver. Windows, pinned Flutter 3.47.5/Rust stable 1.98.1/JDK 17.0.20.1/NDK
28.2.13676358; existing `Phase0Api36`, `emulator-5580`, Android 16/API 36 x86_64.
The same recorded D: Android/JDK/Gradle/temp environment is used; no cloud jobs,
public deployment or toolchain upgrades. The owned worker alone explicitly sets
`LOCAL_AUTH_RETENTION=true`; normal/default/public launch is unchanged.

```text
node scripts/verify_android_authenticated.mjs
```

Final driver exits **0**: build **84.1 seconds**, install **1.990 seconds**,
all emulator assertions pass at **33 seconds**. Logs
`app/.dart_tool/consent-android-authenticated-driver-complete.log` and
`app/.dart_tool/android-authenticated-http.log`.

Four independently OS-wrapped test identities use the normal HTTP factory,
real Android secure storage and sealed SQLite journals. Alice/Bob confirm their
current saved histories after standalone key refresh, prepare/countersign a
request, refuse missing approval, and prune through actual unanimous authority.
An authenticated zero-cursor read gets **410**, proving actual prefix deletion.
A controlled restoration of an older sealed Bob archive in its owned test
namespace gets 410, preserves the exact decrypted journal/Rust state/cursor,
and does not bypass the gap. The current protected archive still restarts.

After Cara joins and old Bob is removed, an early phrase backup creates a fresh
fourth identity, receives current authenticated history, replaces both recovering
and holder controllers, and restores USD -5.00 with identical transaction views.
A fresh-sender expense reaches Alice/Cara at USD -6.00; the retired sender cannot
write. Stored household envelopes and actual physical SQLite contain no readable
fixture title. Only this test's namespace/wrapping keys and exact reverse tunnel
are cleaned up; unrelated app records remain intact.

Initial builds failed before testing because relocated generated intermediate
directories were ReadOnly: first `cleanMergeDebugAssets`, then
`mergeDebugNativeLibs/out/lib/arm64-v8a`. After verifying the exact D: backing
root/no reparse targets, only directory ReadOnly flags (411 in intermediates)
were cleared; no files, source, junctions or caches were deleted. The native
libraries were reused. The first actual test reached real pruning/410, then
wrongly required identical AEAD envelopes: `_sync` reseals the unchanged journal
with a fresh nonce in its `finally` save. The corrected, passing assertion still
requires **byte-identical full decrypted journal** and original Rust state/cursor;
it also checks the envelope remains sealed and hides the marker. Failure logs:
`consent-android-native-merge-failure.log`,
`consent-android-protected-snapshot-failure.log` and the initial/retry driver logs.
Cargokit's reported one dependency change was only `c:` to `C:` spelling of the
same local build-tool path, not a package version upgrade. Targeted Dart analysis,
driver Node syntax and diff checks pass.

This is actual debug-emulator/controller/OS-vault HTTP evidence. It is not a
release APK, UI pointer/assistive-technology journey, physical-device biometrics,
arbitrary power loss, TLS over a physical network, current Chrome/WASM or iOS.

## Production Chrome consent and recovery (2026-10-04)

App source through `7b7e045` plus the complete-code semantics repair, ABI
`1237803201`. Windows Chrome 154.0.8037.58, Node 24.19, 1280x900, isolated
owned browser identities and the actual local Miniflare/workerd SQLite roster
worker. Only the owning fixture enables `LOCAL_AUTH_RETENTION=true`; no public
route, account registration, deployment or default permission changes.

```text
cd app
flutter --no-version-check test --no-pub test/retention_dialog_test.dart test/household_screen_test.dart
flutter --no-version-check build web --wasm --no-web-resources-cdn --no-pub
cd ..
WEB_HOUSEHOLD=1 WEB_HOUSEHOLD_AUTH=1 node scripts/verify_web_runtime.mjs
```

The 28 focused widget tests pass (19 s); a further maximum-length request and
approval semantics test passes (3 s). Targeted analysis and Node syntax checks
are clean. The Dart-only production build passes (259.1 s), with
`main.dart.wasm` 2,774,501 bytes. The matching Rust bridge is 6,394,850 bytes,
SHA-256 `558BE010D2207A4CAB39F52168FFB3C29E8A7BB6ACF6FD57D3DAFCA4432FF1D3`.
The pinned Rust bridge build had passed separately; this interface repair did
not rebuild or change it.

The actual production browser driver exits **0**. It verifies no prune request
on opening, cancelled approval/deletion or missing approval; unanimous explicit
consent uses signed real HTTP chunks, each receiving 200. The confirmed sealed
SQLite image survives reload byte-identically, requires the RAM-only unlock
phrase, and restores balances and the chosen summary. An earlier phrase backup
rejoins with fresh keys after pruning; old-key removal, later expenses, EUR/JPY
frozen rates (USD -74.67), private-ledger separation and readable-title HTTP
checks all pass. Existing standalone key refresh and offline visible conflicts
also pass in this same run.

The initial production run failed because its visibly rendered request code
was absent from the accessible DOM. Explicit complete-code semantics, following
the existing invitation/backup display, fixes that without app hooks or weakened
assertions. The accessibility-review skill guided this scoped name/value repair;
it is not actual NVDA/VoiceOver, an overall WCAG pass, arbitrary power loss,
browser quota/Web Locks fault coverage, Android release or final iOS evidence.
Logs under `app/.dart_tool`: `consent-authenticated-web-runtime.log` (failure),
`consent-code-semantics-tests.log`, `consent-max-code-semantics-test.log`,
`consent-code-semantics-analysis.log`, `consent-code-semantics-web-build.log`,
and `consent-code-semantics-web-runtime.log` (pass). Diagnostics remain ignored;
the repeatable tests and evidence summary are tracked. Gate 2 remains open.
