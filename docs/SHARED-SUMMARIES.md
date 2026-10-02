# Chosen shared summaries

Implemented 2026-10-02; independently verified in local Rust, Windows native
bridge/Flutter host, production Chrome/WASM and an owned Android emulator.
Current-source iOS verification remains open.

## Publication boundary

Open Household from the private ledger, then choose **Choose private totals to
share**. Nothing is selected by default. Choose income, expenses or both, and
an inclusive device-local date range. Preview the exact reporting-currency
amounts and target household, then either keep private or explicitly share.
All members must first update to the summary-capable app; the confirmation
requires acknowledgement of that compatibility requirement.

The preview is detached and immutable. It waits behind preceding private saves
and refuses to read a ledger after an unconfirmed save. Publishing checks the
target group and cannot reuse the same draft twice in the running session.
Restarted users must check existing publications before preparing a retry.
New drafts are separate snapshots, not an automatic subscription or update.

Only currency, selected totals, period endpoints and the household publication's
own event ID/author/timestamp are shared. Private ledger actors, transaction
IDs/titles, accounts, categories, recurring IDs and source frames are not copied.
The original creation date selects transactions; current amount corrections
use their original frozen rates. Removed transactions and transfers are excluded.
Unselected totals are absent, not calculated and not displayed. Zero is a real
selected total. Selected gross-flow overflow fails, never saturates or rounds
the total. Amounts use signed i64 minor units without floating point.

Summaries are nonfinancial events. Their currency can differ from the household
currency; publishing cannot affect shared accounts, transactions or balances.
Members can retain a copy indefinitely. Private corrections do not update an
already shared snapshot, and there is no promise that it can be taken back.
Original-author signatures authenticate publication, not the truth or
completeness of the private source ledger. The UI states this limitation.

## Storage, transport and compatibility

The existing household durable queue saves locally before encryption/send;
uncertain saves freeze subsequent mutations and retain the last confirmed UI.
MLS and original-author signatures cover live delivery, retained signed
history and new-member backfill. Existing recovery/removal protections apply.
Host tests use real AEAD and physical SQLite with a test key holder; they are
not a new OS-key-storage, physical-device or arbitrary power-loss claim.

SQLite reader version 3 upgrades v1/v2 without rewriting tables, source frames,
sealed documents or revisions. Keep existing filename/browser key/Web Lock.
Signed peer archives export v5; v2/v3/v4 import remains supported. Ordinary
summary-free canonical states retain their old bytes and checkpoints.
Older readers refuse new archives/database versions, but this does **not**
negotiate live message capabilities. Old live apps skip unknown payloads.
Mixed-version public release requires explicit capability negotiation; this
private prototype requires all household members to update before sharing.

## Independently verified

- Pinned Rust 1.98.1, Windows: five calculation tests and five publication-core
  tests cover no selection, half-open periods, current corrections/frozen FX,
  zero-decimal currency, overflow, transfer/removal exclusion, frozen previews,
  invalid payloads, canonical convergence and late/duplicate checkpoint rebuild.
- Real local MLS reference relay: three peers with offline publication,
  signed peer-state restart, late writes, new-member signed backfill, signature-total
  tampering rejection and removed-member exclusion. Ciphertext inspection of
  the in-memory reference relay passed; actual production relay audit remains
  a separate check.
- Full locked default-feature Rust workspace suite and strict all-target lint
  passed at the format change. The subsequently added bridge API passed all
  63 API tests and strict workspace lint; bindings were generated with pinned
  flutter_rust_bridge 2.13, not edited by hand.
- Flutter Windows host against the rebuilt DLL: full 270-test run passed before
  the later targeted additions. Four new actual SQLite tests separately passed:
  preview writes nothing, exact snapshot/sealed restart, uncertain saves before
  and after commit do not send prematurely, and queued preview cannot read an
  unconfirmed private correction. Narrow 360×740 layout at 1.5× text and
  keep-private cancellation passed; affected household UI tests passed.
- App analyzer passed after correcting four brace-formatting notices.

## Production browser and actual-worker checks, 2026-10-03

Production app source `26f9563` was rebuilt with the pinned nightly/FRB tools:
Rust WASM release 59.66 s; Flutter `build web --wasm --no-web-resources-cdn --no-pub`
174.5 s. The existing atomics compatibility warning remains unchanged.

`WEB_PERSONAL_LIFECYCLE=1 WEB_HOUSEHOLD=1 WEB_HOUSEHOLD_QUOTA=1 WEB_CSV=1
WEB_CSV_LINE_ENDINGS=LF WEB_OFFLINE_FONTS=1 node scripts/verify_web_runtime.mjs`
passed in actual Windows Chrome 154.0.8037.58 against the compiled release app
and real local workerd relay. The driver creates a private USD 12.34 expense
on Bob's independent browser, verifies default-off selection, exact preview,
keep-private cancellation without relay POST, and explicit publication. Alice
receives only the expense total, no income total or private title; shared balance
stays USD 0.00. Signed summary history survives sealed reload and fresh-key
stale-backup recovery. Existing real quota, personal corrections/recency,
Unicode file import/download, offline conflicts, EUR/JPY FX and removal checks
also pass. Driver-only input focus/value readiness avoids racing rendered forms;
it does not inject app state or call debug APIs.

`CARGO=C:/Users/ME/.cargo/bin/cargo.exe node test/storage-audit.mjs` in `relay/`
passed with the actual production storage methods: 28 encrypted log records,
including a JPY summary, and encrypted welcome mailboxes. Scanned needles include
both byte orders of a distinctive summary amount, original publication author/
event IDs and complete encoded summary payloads. A plaintext-injection negative
control proves the scanner rejects a leak. Windows workerd logged WSASend #10053;
all assertions and process exit status passed. This is local workerd inspection,
not an authenticated public deployment or physical-network reliability claim.

## Android native runtime, 2026-10-03

Source `6942be1` passed
`flutter --no-version-check test --no-pub integration_test/household_test.dart
-d emulator-5580 --reporter expanded` using pinned Flutter/Rust/JDK/SDK tools
on the owned read-only AOSP ATD Android 16/API 36 x86_64 emulator with WHPX.
The debug APK build took 400.5 s, installation 1.946 s, and actual runtime
passed in 26 s. Both Android x86 native targets were built by the existing
debug toolchain; the run itself was x86_64. The known SDK XML warning remains.

The same integration case runs the existing native OS-key/vault and protected
household/failure scenarios, then the new summary UI scenario. A scoped private
USD 12.34 expense produces an exact expense-only preview. Default selection and
sharing are disabled until explicitly chosen/confirmed. Keep-private preserves
the actual sealed SQLite document bytes, private frames and relay tail. Confirmed
sharing leaves shared balances at zero, excludes private transactions, and uses
real native OS wrapping keys. Fresh-store/key objects restore the sealed snapshot
after the private amount changes to USD 20.00; a newly invited logical peer
receives the original signed USD 12.34 snapshot. The two peers share one emulator
and reference relay, not two physical phones or the production HTTP relay.
Only test-scoped vault documents/configuration and OS keys are cleaned up.

The subsequently added lock/leave memory regression was reproduced RED, fixed
at source `c462d5d`, and passed 29 affected host tests. Locking clears the summary
list, phrase unlock restores it, and leaving clears it again. This is not
forensic memory erasure or an XSS-protection claim. The production browser run
above precedes this four-line controller-clearing follow-up; its new browser
runtime remains part of final-source acceptance, not silently claimed here.

No new iOS runtime is claimed by these checks.
This feature does not close production authentication, retention/compaction,
final-source platform acceptance or the whole-project completion gate.

## Browser preview lifecycle follow-up, 2026-10-03

Source `d004ad9` fixes the explicit lock/reload regression added at `890e636`.
The failing trace identified `SummaryDraft` opaque-handle release; the sealed
SQLite image was unchanged, and a separate native probe restored its summary
and shared balance. Preview replacement, cancellation and successful publication
now release their temporary handles explicitly. Locking also releases the old
household handle after queued operations finish. No generated bindings, Rust
codecs, crypto, wire schemas or toolchain versions changed.

Independently verified on Windows with the pinned tools:

- Flutter release WASM rebuild: 147.3 s, reusing the unchanged `26f9563` Rust
  WASM artifact. This build result alone is not runtime evidence.
- `WEB_HOUSEHOLD=1 node scripts/verify_web_runtime.mjs`: actual Chrome
  154.0.8037.58 and local workerd passed preview replacement without relay
  writes, cancellation, publication, explicit lock/unlock, full page reload,
  preserved sealed SQLite bytes and summary, offline conflicts, stale-backup
  fresh-key recovery, removal, EUR/JPY frozen rates and readable-title exclusion
  from HTTP bodies. The driver scrolls to transactions below summary cards and
  observes fatal errors from owned browser workers without debugger pauses.
- `RUST_LIB_PATH=.../rust_lib_cash_app.dll flutter --no-version-check test
  --no-pub --reporter compact`: all **283** host tests passed in 110 s, with
  native cases enabled. The DLL remains the unchanged `26f9563` Rust source.
- `flutter --no-version-check analyze --no-pub`: no issues, 4.4 s.

A failed initial load now shows a persistent unavailable/restart screen instead
of create/join setup; a new widget regression and invalid-storage check pass.
Uncertain saves still keep the last confirmed member view while stopping writes.
The combined CSV/personal/quota browser suite has a separate title-input failure
under investigation and is **not** claimed as passing on this source. An earlier
renderer memory fault on the pre-fix browser artifact is likewise not explained
by this handle-lifetime result. Final-source Android/iOS checks remain open.

At source `43871c4`, the actual Android household integration passed again on
the owned read-only Android 16/API 36 x86_64 AOSP ATD/WHPX emulator. Command:
`flutter --no-version-check test --no-pub integration_test/household_test.dart
-d emulator-5580 --reporter expanded`. Cached build 146.7 s, installation 4.3 s,
runtime 31 s: one complete integration case passed, including real SQLite,
OS wrapping keys, recovery, failed-save safeguards and chosen-summary UI.
The cached general-purpose emulator was initially selected, then stopped in
favor of the previously verified ATD image before any app test. No new SDK or
image was installed. This is one emulator with logical peers, not a physical
multi-device/network run. No current-source iOS runtime is claimed.

## Current combined browser acceptance, 2026-10-03

Production source `43871c4`, driver source `016d5ba`, independently passed the
complete combined browser command on Windows Chrome 154.0.8037.58 and local
workerd, without temporary trace markers, debugger pauses or diagnostic reads:

`WEB_PERSONAL_LIFECYCLE=1 WEB_HOUSEHOLD=1 WEB_HOUSEHOLD_QUOTA=1 WEB_CSV=1
WEB_CSV_LINE_ENDINGS=LF WEB_OFFLINE_FONTS=1 node scripts/verify_web_runtime.mjs`

The current Flutter release WASM build took 209.2 s, with the unchanged Rust
`26f9563` artifact. CSV selection/download and Unicode/font isolation, personal
controls, exact large money, corrections/history/recent ordering, all summary
selection/cancellation/publication boundaries, explicit browser lock/unlock,
actual quota refusal and unchanged SQLite bytes across restart, sealed reload,
offline conflicts, stale-backup fresh-key recovery, removal and EUR/JPY frozen
rates all passed. Local evidence: ignored `.dart_tool/current-web-20261003.log`
and the owned CSV/household screenshots. No phrases or synthetic backups are
committed as evidence.

Earlier combined runs exposed missing titles and one quota-unlock failure.
The driver now targets editable fields by their accessible label (including
multiline hints), verifies the active field and uses real Tab completion for
personal edits; reading an arbitrary stale input is not readiness. Temporary
pointer/frame-wait experiments and extra input diagnostic reads were removed.
The successful combined run closes this runtime regression gate, not a proof
that every earlier browser/renderer fault has a fully explained root cause.
Final-source iOS, public authentication and safe bounded retention remain open.
