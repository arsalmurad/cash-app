# Standalone household encryption-key refresh

Updated 2026-10-04. Native-host, production Chrome and actual Android
authenticated acceptance pass below; final-source iOS remains unverified.

## Operation and safety

Household options exposes **Refresh encryption keys** with confirmation.
This stages OpenMLS 0.9.0 `self_update(LeafNodeParameters::default())`, then
saves the exact ciphertext commit and matching next public relay-policy epoch
before any append. Members, device signing keys, safety numbers and financial
history remain unchanged. Actual HPKE leaf encryption-key comparison verifies
the key changes only after the ordered commit is accepted.

Pinned upstream API/source:
[MlsGroup](https://docs.rs/openmls/0.9.0/openmls/group/struct.MlsGroup.html),
[self-update implementation](https://docs.rs/openmls/0.9.0/src/openmls/group/mls_group/updates.rs.html).
The installed 0.9.0 source was inspected, not a newer dependency substituted.

The relay's existing authenticated membership transaction accepts an unchanged
signing roster with its permission epoch incremented once. The relay still
receives only opaque MLS ciphertext and public authorization metadata. No
Welcome, new member, readable expense, or new server endpoint is introduced.
The permission epoch is a relay transition counter, not an exported MLS epoch.

Pending proposals, another staged commit, inactive/removed membership and
unsigned legacy histories refuse a refresh. Application-message encryption
also refuses a staged commit: OpenMLS permits it, but this app must not advance
the sender ratchet before resolving the reserved log slot. Existing archive
encoding and immutable financial history do not change.

Lost replies/offline sends retain exact bytes across restart; use Sync rather
than repeat the action. Missing saved permission intent refuses authenticated
append even when the rotation's signing roster is unchanged. A competing valid
expense can win the reserved slot, reject the staged refresh, and remain visible;
the app must not claim the refresh succeeded. A fresh explicit retry is safe.
Uncertain local saves still disable writes before network I/O.

Accepted rotation clears old-epoch saved-state receipt collections. It never
prunes financial history. Removing a lost/unsafe device and inviting a fresh
identity is still required: self-update is not device revocation or a formal
post-compromise-security proof. Every participating device needs the updated app.

## Independently verified on this Windows host

Pinned stable Rust 1.98.1, Flutter 3.47.5/Dart 3.13.4, FRB 2.13.0.
Generated bridge ABI is now `-1323392253`; the matching native debug DLL was
rebuilt successfully (36.86s). Previous ABI `970902974` mobile/browser runtime
evidence does not verify this source or these new bindings. New Chrome evidence
is recorded separately below.

- Full crypto/sync all-feature suite: **114 passed, 2 explicitly ignored live
  HTTP tests**, including the three-peer/1,000-event acceptance and ten rotation
  checks. Test-first missing methods and staged-message encryption failure were
  fixed without weakening assertions. Exact log:
  `app/.dart_tool/standalone-rotation-rust-regression-final.log`.
- Rust app API: **69 passed**, including two rotation bridge checks and the
  read-only pending-commit projection. Repeated after binding generation:
  **69 passed in 3.60s**, `rotation-generated-api-final.log`.
- Strict Clippy, all affected Rust packages/features/targets: clean.
  `rotation-all-clippy-final.log`.
- Native controller recovery: **18 passed**, including nine standalone refresh
  cases: offline, lost reply, policy refusal, capacity refusal, uncertain save,
  missing intent, foreign policy, exhausted permission epoch, and a real
  competing encrypted expense. Existing removal/invite assertions retained.
- Actual authenticated loopback HTTP/SQLite worker: **6 passed in 61s** through
  normal controllers, including same-roster refresh, peer decryption and exact
  public storage-schema/privacy audit. `rotation-http-final.log`.
- Existing save-failure suite: **15 passed** in the combined run. That combined
  run is not an overall pass: two HTTP timeouts occurred while a separate UI
  check overlapped. The isolated HTTP rerun passed unchanged timeouts/assertions.
  `rotation-controller-http-regression.log` preserves both failures and results.
- A later full native Flutter run exceeded the same audit's 30-second default
  despite its isolated 26-second pass. This case now has a bounded 90-second
  allowance for 21 expense sends, rotation, retirement/rejoin and six poison
  controls; individual startup/request deadlines and every assertion remain
  unchanged. This is not a production timeout or an assertion workaround.
  That full run finished with **408 passed, 1 audit timeout in 11m16s**:
  `rotation-native-flutter-regression.log`. Do not call it a clean full-suite
  pass. The repaired affected-file rerun then passed **all 6 cases in 74s**,
  including the 34-second audit: `rotation-http-bounded-final.log`. No other
  broad-run failure occurred, and no test assertion was removed.
- Household screen: **20 passed in 9s**, including confirmation/cancellation,
  accurate success/failure messages, keyboard Escape, semantic button labels,
  Android touch targets, contrast and 200% text on a 320x700 surface.
  `rotation-ui-final.log`. The first accessibility run passed assertions but
  failed semantics-handle cleanup; cleanup was repaired, checks unchanged.
  Scoped Dart analysis is clean. This is not a VoiceOver/NVDA or whole-app audit.

Repeat from repository root using cached tools:

```powershell
cargo +stable test --manifest-path rust/Cargo.toml -p cash_crypto -p cash_sync --all-features --offline --locked
cargo +stable test --manifest-path rust/api/Cargo.toml --offline --locked
# From app/, with RUST_LIB_PATH pointing at the rebuilt native DLL:
flutter test --no-pub --concurrency=1 test/household_membership_retry_host_test.dart
flutter test --no-pub --concurrency=1 test/household_scoped_join_http_host_test.dart
flutter test --no-pub --concurrency=1 test/household_screen_test.dart
```

Run heavy Flutter/worker/platform checks serially. Logs and caches are ignored;
repeatable source/tests and this evidence summary are tracked. No cloud jobs,
public deployment, purchases or visibility changes were performed.
The Android integration and browser scenario include refresh assertions;
their syntax/static checks pass. Android runtime passes below.

## Production web build at app source `2b43172`

Pinned nightly/FRB release bridge builds successfully in 2m55s; WASM is
6,338,846 bytes, SHA-256
`b80924918204b06056c9e6a47495804aa5e6fa01ef967a27c839183a238c77a3`.
The known unstable-atomics warning remains; compiler versions were not changed.
Log: `app/.dart_tool/rotation-wasm-build.log`.

Flutter production build passes in 430.1s with `--no-version-check build web
--wasm --no-web-resources-cdn --no-pub`; `main.dart.wasm` is 2,747,994 bytes.
The deployed bridge copy matches the source bridge hash above. First attempt
failed at 23.8s because the generated cache entry point was missing; a retry
regenerated it with no app/toolchain changes or cache deletion. Logs:
`rotation-flutter-web-build.log`, `rotation-flutter-web-build-retry.log`.

Relocated dependency stamps switched from the C: alias to the D: backing path.
Pinned Flutter's [previous-output cleanup](https://github.com/flutter/flutter/blob/6a19cca564/packages/flutter_tools/lib/src/build_system/build_system.dart)
compares path strings before deleting obsolete outputs, consistent with deletion
through the old alias after writing the same physical file via the new path.
This is an evidence-backed diagnosis, not a patched SDK or general junction
compatibility claim; both old/new caches and useful artifacts were preserved.

The first Chrome journey reached key-refresh success but its new assertion
counted Bob's requests instead of initiating Alice's. The harness now checks
Alice's exact membership endpoint, one authenticated commit, and a matching
HTTP 200 response. Original failure remains in
`rotation-authenticated-web-runtime.log`. The next run passed refresh, reload
and offline conflicts, then its old-device manual Sync lookup raced successful
background removal. The explicit removal step now accepts an already-rendered
removed state (including if it appears during the lookup); the unchanged final
removed-state assertion still follows. Failure:
`rotation-authenticated-web-runtime-final.log`; complete rerun passes below.

The complete rerun **passes**, terminal exit 0:
`app/.dart_tool/rotation-authenticated-web-runtime-complete.log`.
Windows Chrome 154.0.8037.58, 1280x900, production source `2b43172` and the exact
artifacts above, isolated owned profiles, real authenticated HTTP/CORS and
SQLite-backed roster worker, no seeded financial history or app debug hooks:

```powershell
$env:WEB_HOUSEHOLD='1'
$env:WEB_HOUSEHOLD_AUTH='1'
node scripts/verify_web_runtime.mjs
```

Passes private-ledger persistence/separation; public operator bootstrap; actual
two-identity invite; default-off summaries and precise publication; sealed
lock/unlock/reload; standalone rotation cancellation/one confirmed authenticated
commit/peer catch-up; offline visible-conflict convergence; stale-backup
fresh-key replacement and old-device removal; explicit EUR/JPY accounts with
frozen historical rates through `USD -74.67`. Captured bodies contain no readable
fixture titles and no legacy mailbox downgrade. This verifies actual browser
runtime, not final Android/iOS, physical-network TLS, or public deployment.

## Actual Android authenticated runtime

Production app source `2b43172` / evidence head `8df163d`, ABI `-1323392253`:
owned read-only `Phase0Api36`, serial `emulator-5580`, Android 16/API 36 x86_64,
WHPX. Existing stable Rust 1.98.1, pinned Flutter/JDK/NDK/Gradle and preserved D:
caches; no toolchain upgrade. The known SDK XML compatibility warning persists.

```powershell
# Recorded Android/JDK/Gradle/temp environment from PHASE2-PROGRESS.md:
node scripts/verify_android_authenticated.mjs
```

Build **556.4s**, install **20.6s**, all emulator assertions pass at **42s**;
owning driver exits **0**. Logs: `app/.dart_tool/android-authenticated-http.log`
and `app/.dart_tool/rotation-android-authenticated-driver.log`.
Three independent test identities use actual Android wrapping keys and sealed
SQLite state. Normal authenticated clients bootstrap from public-only founding
setup into a real SQLite worker; unsigned history is refused, Welcomes are
recipient-only/consumed, key refresh preserves signing roster/member IDs and
balances while Bob catches up, and freshly created controllers restore the
protected journal. Later Cara joins, Bob processes removal and cannot write,
Alice/Cara converge at USD -5.00 while Bob retains USD -2.50. Raw stored household
records are sealed and the physical SQLite contains no readable financial marker.

The driver removes its exact reverse tunnel, disposes the worker and cleans its
test namespace/keys. This is actual debug-emulator HTTP/OS-vault runtime, not an
Android release APK, physical-network TLS, physical-device biometrics or iOS.
