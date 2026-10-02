# Chosen shared summaries

Implemented 2026-10-02; current verification is local Rust and Windows native
bridge/Flutter host. Production WASM/mobile verification remains open.

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

No new iOS, Android or production WASM runtime is claimed by these checks.
This feature does not close production authentication, retention/compaction,
final-source platform acceptance or the whole-project completion gate.
