# Decisions

## 2026-10-01 — Acknowledge a welcome only after the receiver saves its keys

Retryable mailbox reads replace destructive collection in the app, and joined
keys plus receipt intent are saved atomically before an idempotent acknowledgement
consumes the welcome. Lost read/ack replies and failed saves therefore resume
after restart, without weakening expiry or reactivating a consumed mailbox.
The legacy destructive endpoint remains for compatibility, not for durable app
joining; mailbox identifiers remain bearer capabilities until relay auth lands.

## 2026-10-01 — Recovery checksums detect typos, backup authentication proves the key

CI exposed a random test that assumed swapping any two recovery words must
invalidate the BIP-39 checksum; some changed phrases also have valid checksums.
The test now distinguishes invalid phrases from a valid but different key,
with a deterministic wrong-key backup-authentication check rather than a
probabilistic checksum assertion. No encryption or recovery encoding changed.

## 2026-10-01 — Invitation delivery retries must not overwrite or resurrect

Mailbox PUT is now atomically idempotent for exactly the same encrypted item,
but rejects changed contents and retains a consumed marker until original expiry.
Retries do not extend expiry or make a consumed welcome available again; client
delivery journals also refuse retries past their original seven-day lifetime.
This resolves indeterminate PUT replies, not interrupted single-use retrieval.

## 2026-10-01 — Journal pending MLS commits rather than guessing after timeout

Peer state v3 persists the exact staged commit and OpenMLS pending group state,
while retaining v2 signed-state import and read-only v1 archives. Ordered-log
ingestion confirms an exact matching commit or rejects it only after a valid
competing frame, restoring the pending journal when evidence is malformed;
guessing rejection from an unavailable relay was rejected because its append
may already have succeeded. App invitation delivery still needs its own durable
journal and retry path before the household durability gate is complete.
## 2026-10-01 — Serialize household operations and fail closed on uncertain saves

Household writes, synchronization and configuration changes now share one queue;
an uncertain blob save drops the live Rust handle and requires restart while
preserving the last confirmed view. Sender ratchet state is saved before a relay
append, preventing a crash after sending from restoring an earlier encryption
generation; membership-commit and invitation journals remain a separate gate.
Transaction IDs use secure randomness rather than a restartable clock/counter.

## 2026-10-01 — Signed history keeps original proofs, not the forwarder's identity

Shared event actors are now self-certifying hashes of their signing public key,
and event IDs include that actor namespace plus randomness so a restored device
cannot accidentally reproduce an ID at the same HLC. Live envelopes must match
the MLS sender's key; backfills retain and verify original group-bound signatures.
Proof hashes preserve conflicting versions of an event ID, while unsigned v1
archives remain explicitly read-only rather than being silently re-signed;
forwarded signatures prove the originating key, not historical membership.

## 2026-10-01 — Preserve authorship through household history forwarding

Retain OpenMLS-authenticated sender metadata and use domain-separated,
group-bound detached signatures from the existing pinned Ed25519 identity for
immutable history. Checking every event against the current transport sender
was rejected because inviters must forward other members' historical events;
signatures alone still require actor binding and authorization in the sync layer.
APIs were checked against
the pinned source and [OpenMLS ProcessedMessage documentation](https://docs.rs/openmls/0.9.0/openmls/framing/struct.ProcessedMessage.html)
and [Signer documentation](https://docs.rs/openmls_traits/0.6.0/openmls_traits/signatures/trait.Signer.html).

## 2026-09-24 — Keep Phase 0 isolated

The OpenMLS experiment will live in `mls_spike/`, as the build brief specifies,
until its platform results are known. Starting the Phase 1 app before the
three-platform question is answered was rejected because the bridge and WASM
compatibility are the architecture gate.

## 2026-09-24 — Record an untested iOS target explicitly

This Windows host can test Android and web after toolchain setup but cannot run
an iOS simulator. Treating a Rust desktop build or an Android run as evidence
for iOS was rejected; the required iOS run needs macOS and Xcode according to
the [Flutter iOS setup guide](https://docs.flutter.dev/get-started/install/macos/mobile-ios).

## 2026-09-24 — Use the current OpenMLS release and RustCrypto provider

The spike pins OpenMLS 0.9.0 with `openmls_rust_crypto` 0.6.0 and enables the
OpenMLS `js` feature for WASM. An older 0.8.x release was rejected because the
spike should test the current API and its current platform behavior; the
[OpenMLS release history](https://github.com/openmls/openmls/blob/main/CHANGELOG.md)
and [WASM compile guard](https://docs.rs/openmls/0.9.0/src/openmls/lib.rs.html#148-149)
support that choice.

## 2026-09-24 — Adapt the OpenMLS quickstart inside the spike

The credential, key-package, Welcome, and commit flow in `mls_spike/rust/src/crypto.rs`
follows the [OpenMLS quickstart](https://docs.rs/openmls/0.9.0/src/openmls/lib.rs.html).
Writing a different handshake sequence from scratch was rejected because it
would add uncertainty to a platform compatibility experiment.

## 2026-09-24 — Enable the browser RNG backend for `getrandom` 0.2

The first WASM compile reached a transitive `getrandom` 0.2.17 dependency and
failed because its `js` feature was absent. The spike enables that feature only
for `wasm32`; relying on OpenMLS's `js` feature alone was rejected because it
did not activate the older `getrandom` dependency's backend. See the
[getrandom 0.2 feature list](https://docs.rs/crate/getrandom/0.2.17/features).

## 2026-09-25 — Keep Phase 1 blocked after the partial finding

Android and web/WASM both passed the complete MLS bridge flow. iOS remains
untested because no macOS/Xcode environment is available. The brief defines a
three-target pass condition, so Phase 1 remains blocked and the result is
reported as a partial finding.

## 2026-09-25 — Use matched release baselines for size deltas

The Android and web size deltas compare the spike with fresh minimal Flutter
projects built by the same Flutter version, in the same release mode, and for
the same target. Comparing debug and release artifacts, or using published size
estimates, was rejected because either would obscure the cost of the Rust and
OpenMLS payload.

## 2026-09-25 — Move Android toolchains and generated builds to D:

The system drive did not have enough room for the Android SDK, NDK, emulator,
Gradle cache, and Cargokit objects. Those generated and external files live on
`D:`. The repository's ignored `mls_spike/build` path is a local junction to the
generated build directory on `D:`; no source path depends on that drive.

## 2026-09-25 — Close the iOS gate on a standard GitHub-hosted runner

Use a manual-only `macos-15` GitHub Actions workflow to run the existing bridge
test in an iOS simulator and measure an unsigned release bundle. Leaving iOS
untested or starting Phase 1 provisionally was rejected because iOS is the
primary commercial platform and the Phase 0 brief makes it an explicit gate.
The workflow has a 45-minute timeout and no push trigger so it cannot consume
the private repository's included runner allowance repeatedly.

## 2026-09-25 — Complete Phase 0 and unblock Phase 1

The complete OpenMLS bridge flow passed at runtime on an iPhone 16 Pro
simulator, an Android 16 emulator, and Chrome with the generated WebAssembly
artifact. Matching release baselines were also measured on all three targets.
This satisfies the build brief's three-platform Phase 0 pass condition, so
Phase 1 may begin. The Swift Package Manager and Rust `atomics` warnings remain
recorded compatibility risks; they do not invalidate the pinned, passing
toolchain.

## 2026-09-25 — Build the deterministic ledger before the Flutter screens

Phase 1 starts with a dependency-free Rust core and executable acceptance
tests for ordering, frozen FX, zero-decimal currencies, idempotency, and
snapshots. Building screens against temporary Dart models was rejected because
those models would either duplicate the money rules or become an accidental
CRUD source of truth. The first Flutter vertical slice will consume this core
through a thin bridge.

## 2026-09-26 — Durable storage lives in Dart, not Rust

Rust running as WASM in a browser has no filesystem, so `rust/core` cannot own
*where* the event log's bytes are kept without a WASM-only code path
contradicting its "no storage dependency" boundary. Instead `rust/core` only
defines the durable frame codec (encode/decode, checksum, corruption
recovery), and Dart owns the actual store: a plain file on iOS/Android/desktop,
`window.localStorage` on web, selected at compile time the same way the
generated `frb_generated.io.dart`/`.web.dart` bridge files already are. Putting
file I/O in Rust via `std::fs` and passing it a path from Dart was rejected
because it would still need a completely different, WASM-incompatible code
path for web, duplicating the platform split one layer down instead of
avoiding it.

## 2026-09-26 — One ledger constructor, not create-vs-load

`load_personal_ledger` replaces the old `create_personal_ledger`: a brand-new
install passes an empty byte log and gets the same code path a restart does.
Keeping a separate `create_personal_ledger` for first launch was rejected
because two constructors are two chances for "new" and "restored" ledgers to
compute HLC continuity or validation differently, exactly the kind of drift
this milestone is trying to close off in the first change that touches
startup.

## 2026-09-26 — A rejected write is unrepresentable in the persisted log

`add_account`/`record_transaction` return the newly appended event's durable
frame only on `Ok`; a duplicate or otherwise-rejected write is an `Err` with
no frame attached, so there is no value the caller could accidentally persist.
Returning a frame alongside an error result (or persisting speculatively
before validating) was rejected because it would let a caller bug — not a
Rust bug — put a rejected write into durable history, which is exactly the
silent-corruption failure mode event sourcing exists to prevent.

## 2026-09-26 — Frame checksums, not file-format assumptions, define recovery

The durable log's corruption test is "does this frame's checksum verify",
not "did this file end where a normal write would end". A length-prefixed,
FNV-1a-checksummed frame lets `decode_event_log` tell a torn write (checksum
or length fails) apart from a genuine version mismatch without inspecting the
storage backend at all, so the same recovery logic runs unchanged whether the
bytes came from a native file or a browser's `localStorage`. Trusting the
storage layer to report a clean vs. truncated read (e.g. comparing byte
counts) was rejected because `localStorage`'s read/write API gives no such
signal, and the codec would otherwise need a different corruption story per
platform.

## 2026-09-26 — Categories are a second, independent state mechanism

The build brief (§2.5) calls out categories as soft state suited to
last-writer-wins, explicitly separate from the ledger's event-sourced
financial state. Implemented as a new `cash_core::categories` module with
its own upsert type, its own commutative/idempotent fold
(`fold_categories`, which never rejects), and its own durable log and bridge
type (`CategoryBook`), sharing only the byte-level frame codec with the
financial event log. Adding a `CategoryAssigned`-style variant to the
existing `EventKind` enum instead was rejected: that enum's fold is the one
place the brief requires strict, error-on-conflict semantics, and folding a
last-writer-wins field through it would either weaken that guarantee for
every variant or require per-variant special-casing inside a fold that is
supposed to be uniform.

## 2026-09-26 — One actor ID, one identity store, many logs

Adding the categories log meant two durable logs needed a stable actor ID,
not one. Introduced `DeviceIdentity` as a store separate from `EventStore`
(which is now parameterized by a log name), so both logs read the same
persisted ID instead of each generating and persisting their own. Letting
each log manage its own actor ID independently was rejected: two IDs for one
device would let the ledger and the category book each think they were a
different actor, which breaks the total order's assumption that an actor ID
identifies one physical writer.

## 2026-09-26 — A transfer's two legs are independent amounts, not one conversion

`EventKind::TransferRecorded` stores `sent` and `received` as two separate
`Money` + frozen-`FxRate` pairs rather than one amount plus a transfer rate
applied to derive the other. Deriving `received` from `sent` at a fixed rate
was rejected because a real transfer can lose value in transit (a bank fee,
a conversion spread) that the user needs to see and that later balances must
reflect; assuming `received = convert(sent)` would silently hide that loss
inside the transfer rate rather than recording what actually happened, which
is the same silent-overwrite failure mode event sourcing exists to avoid
elsewhere in this ledger.

## 2026-09-26 — Transfers stay in the ledger's own fold, not alongside categories

Unlike categories, a transfer is genuinely financial state — it changes
account balances and the reporting total — so it is a new `EventKind`
variant folded by the ledger's existing strict, error-on-conflict `fold`,
not a second last-writer-wins mechanism. Treating "a second account is
involved" as a reason to split it out the way categories were was rejected:
the deciding question is which consistency guarantee the state needs, not
how many entities it touches, and a transfer needs the ledger's guarantee.

## 2026-09-26 — Search and filter run in Dart over the loaded overview, not in Rust

`ActivityFilter` (`app/lib/features/ledger/activity_filter.dart`) is a pure
Dart function over the `LedgerOverview` already loaded in memory. Adding a
Rust-side query API (e.g. `search_transactions(ledger, query)`) was rejected:
a personal ledger's entire history already crosses the bridge on every load
for display, so filtering client-side costs nothing extra and avoids growing
the bridge's surface for a feature with no correctness or determinism
requirement — unlike the ledger's fold or the category upserts, there is no
canonical answer a search result needs to converge to across devices.

## 2026-09-26 — Budgets are LWW soft state, like categories, not a ledger event

A budget's name, limit, category, and period are definitions, not facts
about what happened financially — two conflicting edits should settle by
last-writer-wins, the same as a category's name or icon, rather than stay
visible in history the way a transaction conflict must. `rust/core` gives
budgets their own module (`budgets.rs`), upsert type, and durable log,
independent of both `ledger.rs` and `categories.rs`. Folding budgets into
the categories module instead (since both are LWW) was rejected: a budget
and a category answer unrelated questions and evolve independently, and
merging them would make a future change to one module's shape (e.g. a
category gaining a color) risk an unrelated migration for the other.

## 2026-09-26 — Budget progress is computed, never stored

`budget_progress` recomputes a budget's spend from the ledger's expense
transactions on every call rather than maintaining a running total inside
`BudgetBookState`. Storing a running total was rejected: it would become a
second source of truth for "how much was spent," one that could drift from
the ledger's own fold after a late-arriving or voided transaction, and
budgets already need the ledger's transactions to enforce category matching
and period boundaries, so recomputing costs nothing a stored total would
have saved. This is also why `TransactionState` gained a fixed
`recorded_at_millis` field (the `TransactionRecorded` event's own
timestamp): using "now" or a mutable last-modified time to decide a
transaction's period would let a later `AmountAdjusted` correction move a
transaction into a different budget period than the one it was actually
spent in.

## 2026-09-26 — `BudgetPeriodKind` is a field-less bridge enum

`cash_core::BudgetPeriod::Custom` carries a `days: u32` field, but the
bridge-visible `BudgetPeriodKind` does not — `Custom`'s day count is passed
as a separate `custom_period_days: Option<u32>` parameter to `upsert_budget`
instead. A data-carrying Dart-side enum was rejected: `flutter_rust_bridge`
2.13.0 requires the `freezed` package to generate a union type for an enum
with fields, and pulling in a code-generation dependency for one field was
not worth it. This mirrors the existing `EntryKind`/`TransactionKind`
pattern already used for the ledger's own bridge surface.

## 2026-09-26 — A goal's kind determines which fields are legal, enforced at the bridge

`upsert_goal` rejects a `Save` goal missing `linked_account_id` or carrying
a `category_id`, and rejects a `Spend` goal carrying `linked_account_id`.
Letting `rust/core`'s `GoalUpsert` accept any combination and leaving the
UI to only ever send valid ones was rejected: a stored goal with a nonsense
combination (e.g. `Save` with no account) would have no defined progress,
and by the time `goal_progress` discovered that, the failure would surface
far from its cause. Validating at the one function that creates a goal
catches the mistake at its source instead.

## 2026-09-26 — A spend goal's window starts at its own creation, found from history

A spend goal's progress counts expenses from the earliest upsert ever
recorded for its `goal_id` — computed by scanning the goal book's full
upsert history in `goal_progress`, not read from a dedicated `created_at`
field on `GoalUpsert`/`GoalRecord`. Adding such a field was rejected: the
upsert log already answers "when was this goal first written" without it,
and a stored field would need its own rule for what an edit does to it
(carry it forward? let the last writer overwrite it?) that scanning avoids
by construction — the earliest timestamp for a `goal_id` is unambiguous and
never a last-writer-wins question in the first place.

## 2026-09-26 — `goal_progress` has no `now_millis` parameter, unlike `budget_progress`

A budget's period rolls forward with the wall clock (this month, this
week), so `budget_progress` must be told "now" to find the current
window's start. A goal's window is fixed at its own creation and never
rolls forward — it either counts everything since then (no deadline) or up
to a fixed deadline — so nothing in `goal_progress` depends on the caller's
wall clock, and adding an unused parameter to match `budget_progress`'s
shape for consistency's sake was rejected as needless bridge surface.

## 2026-09-26 — CSV import/export uses the clipboard, not a native file picker

`ExportCsvDialog`/`ImportCsvDialog` (`app/lib/features/ledger/csv_import_export.dart`)
copy CSV text to the clipboard and read it back from a pasted `TextField`,
using only `Clipboard`/`TextField` from the Flutter SDK. Adding a file
picker/file-save package (e.g. `file_picker`, `share_plus`) was rejected
for this pass: those need per-platform setup (iOS entitlements, Android
scoped-storage permissions, a web download shim) that can't be verified
without a real device per platform, which this session doesn't have for
Android or web, and the build brief's "CSV import and export" requirement
doesn't specify the transport. The clipboard path works identically and
verifiably on phone, tablet, and web today; swapping in a native file
picker later is a UI-layer change, not a data-format one, since the CSV
codec itself has no dependency on how its text arrives.

## 2026-09-26 — CSV import replays through `record`, not a bulk bridge call

Importing a CSV calls the controller's existing `record` once per row
rather than adding a Rust-side bulk-import function. A bulk function was
rejected: every imported transaction still needs the ledger's own
validation (a valid account, a parseable amount) and still needs to be
durably persisted one event at a time, so a bulk path would either
duplicate that logic or just loop internally — the same work `record`
already does — while adding bridge surface and a second way to create a
transaction that could drift from the first.

## 2026-09-26 — A recurring transaction is tagged, not a separate event type

`EventKind::TransactionRecorded` gained an optional `recurring_id` field
rather than introducing a new `RecurringTransactionRecorded` event variant.
A due occurrence is, financially, exactly a normal expense or income
transaction; the only difference is that the UI populated it from a rule
instead of a blank form. Making it a distinct event type was rejected: it
would duplicate the fold logic `TransactionRecorded` already has (balance
update, reporting conversion, duplicate-ID rejection) for no behavioral
difference, and would need its own case everywhere `TransactionRecorded`
is already handled (budgets' spend sum, goals' spend sum, search/filter,
CSV export). Tagging keeps "how a transaction was created" as metadata on
one event shape rather than a second financial event to keep in sync with
the first.

## 2026-09-26 — An occurrence's "next due date" is derived, not a stored pointer

`upcoming_occurrences` finds each rule's most recently recorded occurrence
by scanning the ledger's own transactions for a matching `recurring_id`,
rather than the recurring book maintaining a `last_recorded_millis` field
that advances when an occurrence is recorded. A stored pointer was
rejected for the same reason a goal's `created_at` isn't stored (see the
2026-09-26 goals entries above): it would be a second thing that could
drift from what the ledger actually recorded — for instance if recording a
transaction succeeded but updating the pointer failed, or if an occurrence
was recorded through some future path that forgot to advance it. Deriving
the anchor from the ledger's own data means there is only ever one source
of truth for "was this occurrence recorded," and it can never disagree
with itself.

## 2026-09-26 — Recurring frequency has no `Custom { days }` variant

Unlike `budgets::BudgetPeriod`, `RecurringFrequency` is only
`Daily`/`Weekly`/`Monthly`/`Yearly`. A rolling custom-day-count period was
rejected here: a budget's `Custom` period always measures a window ending
"now," which is unambiguous, but a recurring rule's occurrences must be
independently addressable events (each one gets recorded or not), and a
rolling window has no natural anchor to step from once an occurrence is
skipped or recorded late. The four fixed frequencies all have an
unambiguous "next occurrence after this one," which `next_occurrence_millis`
depends on.

## 2026-09-26 — Calendar math is shared, not duplicated, between budgets and recurring rules

`civil_from_days`/`days_from_civil` moved from `budgets.rs` into a new
`calendar.rs` module when `recurring.rs` needed the same conversions plus a
new `add_months` helper. Leaving a second copy in `recurring.rs` (as
`goals.rs` does for its own small amount of logic that doesn't overlap with
budgets) was rejected specifically here because the risk is different: two
independent implementations of the same date algorithm can silently drift
apart under a future edit (an off-by-one fixed in one copy but not the
other), which a shared module makes structurally impossible.

## 2026-09-26 — The biometric lock is unsupported on web rather than unlockable

`BiometricLockGate` always renders its child directly on web, skipping the
lock screen entirely, rather than showing a lock screen with no way to pass
it. `local_auth` has no web implementation at all (there is no
`local_auth_web` package), so the only alternatives were: block web users
out of their own ledger permanently, fabricate some other web-only
authentication scheme not asked for in the build brief, or treat web as a
lesser peer for this one feature the way `docs/PHASE0-RESULT.md` already
established for the shared-layer spike. The third option was chosen: this
is a real, documented platform gap, not silently dropped functionality —
the lock is simply off by default and cannot be turned on in a browser.

## 2026-09-26 — The lock preference is its own store, not folded into EventStore

`LockPreferenceStore` is a new, small storage interface alongside
`EventStore`/`DeviceIdentity` in `data/storage/`, not a third capability
bolted onto `EventStore`. Reusing `EventStore` (e.g. a fake "lock" log with
one frame) was rejected: a preference toggle has no fold, no frame codec,
no durability requirement beyond "read the last value written," and no
actor ID to speak of — modeling it as a durable append-only log would add
all of that machinery for a single boolean with no history worth keeping.

## 2026-09-26 — Re-locking on app resume, not just on cold start

`BiometricLockGate` observes `AppLifecycleState.resumed` and re-locks
(when the lock is enabled) every time the app returns from the background,
not only when the process starts fresh. Locking only at cold start was
rejected: on mobile, backgrounding and resuming an app is the common case
(a phone call, switching apps, glancing away), and a lock that only guards
process launch would leave the ledger visible to anyone who picks up an
already-running, backgrounded phone — which defeats the point of a
biometric lock for exactly the scenario it exists to cover.

## 2026-09-28 — Android/web verification gets its own CI workflow, not a manual-only gap

`.github/workflows/phase1-android.yml` and `phase1-web.yml` were added
(mirroring `phase1-ios.yml`'s manual `workflow_dispatch` pattern) rather
than leaving Android/web runtime verification as a permanent note in
`docs/PHASE1-PROGRESS.md` that no session in this environment can ever
resolve. This environment has no Android emulator or browser capable of
driving Flutter's `integration_test` harness, but a GitHub Actions runner
does — the blocker was the environment, not the codebase, so the fix is
infrastructure this environment *can* build, even though it can't run it
to completion itself. Both workflows were partially verified locally in
this session before being committed (see their own comments and
`docs/PHASE1-PROGRESS.md` for exactly what was and wasn't confirmed here
versus left for a real run).

## 2026-09-28 — `wasm-opt` is disabled for the WASM build

`rust/api/Cargo.toml` sets `[package.metadata.wasm-pack.profile.release]
wasm-opt = false`. `wasm-pack`'s default release profile runs `wasm-opt`
(from the `binaryen` project), which downloads a prebuilt binary from a
GitHub release on first use — a network dependency with no bearing on
correctness, only binary size. Leaving it enabled was rejected: it adds a
point of CI flakiness (a single flaky download can fail an otherwise
successful build) for an optimization Phase 1 doesn't need yet; it can be
turned back on later if the WASM binary's size becomes a real problem.

## 2026-09-28 — The web integration test uses `flutter drive`, not `flutter test`

`flutter test` (the command every other test in this project runs through)
refuses to run `integration_test`-based tests against a web device at all
("Web devices are not supported for integration tests yet") — this is a
hard limitation of the Flutter tooling itself, not a choice. The only way
to run `integration_test/ledger_test.dart` on web is `flutter drive` with
a WebDriver (ChromeDriver) session, which is why `phase1-web.yml` and the
new `app/test_driver/integration_test.dart` driver entrypoint exist
alongside the `flutter test` calls the other workflows use.

## 2026-09-28 — `default_dart_async: false` tried and reverted: broke iOS, didn't actually fix web

Attempted fix for the web `WorkerPool` panic above: set
`default_dart_async: false` in `flutter_rust_bridge.yaml` so every
generated Rust-bridge call runs synchronously instead of being dispatched
to a worker/isolate. This is a single global codegen setting with no
per-platform override in this `flutter_rust_bridge` version, so it
applied to iOS and Android too, not just web — a known, accepted
trade-off at the time.

Real CI evidence on all three platforms (not assumed) showed this was
the wrong fix:

- **Android**: passed clean.
- **iOS**: the integration test step hung for the full 45-minute job
  timeout and was killed (`conclusion: cancelled`) — a real regression,
  not flakiness. A synchronous call on the calling thread/isolate is safe
  for a fast in-memory operation; something about the native sync-call
  path apparently blocks in a way the isolate-dispatched async path
  didn't, most likely a deadlock between the calling thread and whatever
  the FFI call needs free to complete. Not root-caused further, since the
  fix was reverted rather than debugged.
- **Web**: the `WorkerPool` panic was genuinely gone — the app ran real
  test logic on web for the first time — but the very first
  `recordTransaction` call silently no-op'd: `LedgerController.record()`
  returned success (`errorMessage=null`, `isLoading=false`), yet
  `overview.transactions` stayed empty and the balance stayed `USD 0.00`,
  confirmed twice by reading `LedgerController`'s state directly off the
  widget tree in the failing test (bypassing `find.text` entirely, so
  this wasn't a UI-rebuild timing issue). The synchronous call path
  apparently doesn't work through wasm-bindgen's web transport at all in
  this build — worse than the original panic, since it fails silently
  instead of loudly.

Reverted in full (`flutter_rust_bridge.yaml`, the regenerated bridge, and
`ledger_controller.dart`'s five `_mutate*` helpers) back to the async
dispatch this file's previous entry describes. iOS and Android return to
their previously-verified-green state; web returns to the documented,
honest `WorkerPool` panic — a real, upstream, maintainer-acknowledged
limitation ([fzyzcjy/flutter_rust_bridge#2914](https://github.com/fzyzcjy/flutter_rust_bridge/issues/2914))
with no known fix as of this entry, rather than a fix that trades a loud
crash for silently dropped data. Diagnostic assertions added to
`integration_test/ledger_test.dart` during this investigation (SnackBar
text and live controller-state dumps on failure) were kept — they're
generically useful and independent of this revert.

## 2026-09-29 — Category rename reuses the existing "new category" dialog

`CategoryEditDialog` (`app/lib/features/ledger/category_edit_dialog.dart`)
generalizes what was previously `AddTransactionSheet`'s private
`_NewCategoryDialog`, taking optional `initialName`/`initialIconKey` to
switch it into edit mode. Writing a second, separate rename-only dialog was
rejected: creating and renaming a category collect exactly the same two
fields (name, icon) and differ only in whether they start blank, so a
second copy would just be the same form duplicated with no behavioral
difference to justify it. `LedgerController.updateCategory` calls the same
`upsertCategory` bridge function `addCategory` already uses, passing the
existing category's ID instead of a freshly slugified one — `upsertCategory`
already replaces-in-place on a repeated ID (see the categories LWW design,
2026-09-26 entries above), so no bridge or core change was needed.
`CategoriesScreen` is a new destination (reachable from `LedgerScreen`'s
overflow menu, "Manage categories") listing every category with an edit
action per row, rather than folding rename into the existing category
dropdown inside `AddTransactionSheet`: that dropdown's job is picking a
category for one transaction, and overloading it with a management UI would
conflate the two.

## 2026-09-30 — Budget/goal/recurring-rule dialogs edit in place, not a second dialog

`NewBudgetDialog`, `NewGoalDialog`, and `NewRecurringDialog` each gained an
optional `existing` parameter rather than a parallel `EditBudgetDialog`
etc.: the same reasoning as `CategoryEditDialog` applies to each — creating
and editing collect the same fields, just starting blank or pre-filled, so
a second dialog would duplicate the form for no behavioral difference. A
budget's `periodLabel` is a display string, not its `BudgetPeriodKind`, so
pre-filling the edit form parses it back from the four fixed shapes
`period_label` in `rust/api/src/api/budgets.rs` produces ("This week" /
"This month" / "This year" / "Last N days") rather than adding a bridge
field only the edit dialog would ever read.

A goal's `categoryId`/`deadlineMillis` and a recurring rule's `categoryId`
have never had UI to set them (neither creation dialog collects them), so
editing without addressing that would silently null them out on save for
anything that already had one. Rejected fixing this by adding that UI now:
it's a real, separate feature gap (see `docs/PHASE1-PROGRESS.md`'s
"Remaining work"), out of scope for a rename fix, and would have expanded
this change well past "let an existing value survive an edit." Instead
`GoalDraft`/`RecurringDraft` carry the existing value through unchanged
when editing, so the edit is safe today and the missing UI stays a single,
clearly-scoped follow-up rather than two problems tangled into one fix.

## 2026-09-30 — Web is verified by a runtime script against the production build, not `flutter drive`

Correction to the two entries above about the web `WorkerPool` panic: web
support was never broken, only the way the integration test reached it was.
`flutter drive -d web-server` compiles the test target to JavaScript
(`main.dart.js`), and there the first Rust bridge call panicked on every
build mode. The production build the app actually ships —
`flutter build web --wasm` (dart2wasm) — runs the Rust bridge fine:
`scripts/verify_web_runtime.mjs` serves it with COOP/COEP headers, drives
real Chrome over the DevTools protocol, records expenses through the bridge,
and reloads the page twice to prove the ledger is rebuilt from
`localStorage` alone. It passed locally (Chromium 141) on the current
async-dispatch code. Two things were needed to make it hermetic and
portable: `--no-web-resources-cdn` (otherwise Flutter fetches CanvasKit from
Google's CDN at load, so the app never boots without outbound network), and
a Chrome window larger than the 780x388 default (the add-entry sheet was cut
off; making the sheet scrollable fixed the underlying small-screen bug too).

`phase1-web.yml` now runs that script instead of `flutter drive`, and the
ChromeDriver/`reportData` machinery that existed only to debug the drive
path was deleted (`app/test_driver/`, the try/catch in
`integration_test/ledger_test.dart`). Keeping `flutter drive` as a second,
failing check was rejected: a check known to fail for a reason unrelated to
the product trains everyone to ignore red CI. What this does not do is run
`integration_test/ledger_test.dart` on web — the script covers the same
record/restart flow through the real UI instead, but not the account,
transfer, and category steps; extending it to those is tracked in
`docs/PHASE1-PROGRESS.md`. The root cause of the JS-path panic itself
(`fzyzcjy/flutter_rust_bridge#2914`) remains unfixed upstream and is not
needed to ship web.

## 2026-09-30 — Foreign-currency entries need a typed, frozen rate

Until now `record`/`transfer` hardcoded a 1:1 reporting rate, which silently
mis-valued any account outside the reporting currency (a EUR 80.00 expense
would have counted as USD 80.00). The core already froze a rate per event;
the gap was input and display.

Decision: an entry or transfer leg on an account whose currency differs from
the reporting currency must carry a user-typed decimal rate ("USD per 1
EUR"). It is never prefilled, remembered, or fetched: a stale or guessed
rate is a wrong number in the ledger, and an empty required field is
visible. `FxRate::from_decimal_rate` parses the text into an exact reduced
integer ratio of target minor units per source minor unit (accounting for
each currency's exponent, so EUR→JPY works) with no floating point;
malformed, zero, negative, or overflowing input is rejected. Recurring rules
carry no rate (it would go stale), so recording an occurrence on a foreign
account asks for that day's rate. CSV import rows on foreign accounts fail
with the same "enter the exchange rate" error per line rather than being
valued at 1:1; a rate column is future work.

Per-account reporting balances (`AccountView.reporting_balance_label`) are
derived from folded state at display time (transactions at their frozen
reporting amounts, voids excluded, transfer legs at their own frozen
rates), never stored, so equal event sets still give byte-identical state.
Reporting-currency accounts show no conversion line.

## 2026-09-30 — Shared layer: a dumb ordered relay, a total fold, pseudonymous credentials

Phase 1's exit test passed, which opens Phase 2 (brief section 6). The design
choices, each with the option rejected:

- **One totally ordered log per group, with compare-and-swap on the tail.**
  Every entry, commits included, is appended with the sequence number the
  writer last saw; a stale writer is refused, catches up, and retries. Every
  member therefore processes the same MLS messages in the same order, which
  MLS requires. Rejected: letting clients broadcast freely and resolve
  competing commits themselves; two members committing in the same epoch
  forks the group, and recovering from that without an authority is the
  hardest part of MLS deployment. The relay is still only an ordering
  service and sees no plaintext.
- **The relay knows nothing but sequence numbers and opaque bytes.** No
  sender, no message kind, no size classes. Rejected: a `kind` tag (commit
  vs message), which would let the relay see membership churn for no gain.
- **Credentials carry a pseudonymous member ID, never a name.** A key
  package and a welcome are signed, not secret, so a real name there would
  reach the relay. Display names travel inside the encrypted stream.
  Rejected: names in credentials (visible in key packages).
- **Key packages travel out of band** (the invite link or QR), not through
  the relay. This is also what makes the brief's out-of-band safety-number
  check meaningful. Welcomes go through single-use, expiring mailboxes.
- **The shared fold is total.** `fold_shared` never aborts: an event that
  cannot apply (an edit after a void) or a duplicate ID with different
  content is reported in the state, and two edits written without seeing
  each other are reported as a `Conflict` with the later one in the total
  order winning. Each edit carries `base`, the last event it had seen for
  that field, instead of vector clocks. The personal `fold` stays strict:
  one trusted writer, where an invalid event means corruption. Rejected:
  reusing the strict fold (one bad or racing event would wedge every peer)
  and silent last-writer-wins (violates "conflicts stay visible").
- **Recovery phrase = BIP-39 encoding of 32 random bytes**, from which an
  HKDF key seals device backups with ChaCha20-Poly1305. Rejected: deriving
  keys from a user-chosen passphrase (weak) and inventing a word list.
  Restoring a lost device from a backup forks that device's MLS leaf if the
  old device is ever found and used again; the app must tell the user to
  treat the old device as gone.

## 2026-09-30 — The app owns the network; new members get a history backfill

- **Dart does the I/O; Rust is a state machine.** `cash_sync::Peer` exposes
  `ingest` / `next_outgoing` / `outgoing_accepted` / `begin_invite` /
  `begin_removal` / `commit_accepted` / `commit_rejected` / `join`, and the
  bridge (`api::shared::Household`) wraps exactly those. Dart fetches relay
  entries, hands them in, and appends what comes out. Rejected: giving the
  Rust engine its own HTTP client (would need an async runtime and a
  different TLS story on each of iOS, Android, and wasm, and a second place
  to configure the network). The Rust `sync`/`invite`/`remove` convenience
  methods are the same steps driven through a `Relay`, which is why the
  three-peer tests still cover the path the app takes.
- **MLS gives a new member nothing written before their commit, so the
  inviter backfills.** Found by running the Dart scenario against the real
  core: a member added to a household that already had an account and
  expenses saw none of it, and every later edit referring to that account
  was rejected. Accepting an invite commit now queues every known event,
  oldest first, as batched messages (at most 200 events or 48 KiB each);
  receivers ignore events they already hold, so the cost is bandwidth, not
  correctness. Rejected: sending history inside the welcome (MLS has no
  place for it) and making the new member replay from another peer's
  snapshot (needs a second protocol).
- **Joining is a short copy/paste exchange** (join request, then invite),
  carried as plain-text codes that are validated before use (http(s) relay,
  32-hex identifiers). Rejected: a key-package directory on the relay,
  which would expose key packages (and so credentials) to it and remove the
  out-of-band step that gives safety numbers their meaning.
- **The household is its own screen, not a sixth tab,** opened from the
  ledger menu only when a household controller is supplied, so the personal
  ledger's navigation and tests are unchanged.
- **Known limits, accepted for now** (also in `docs/PHASE2-PROGRESS.md`):
  the actor ID inside an event is not bound to the MLS sender, so a member
  could write events attributed to another member (the threat model is a
  household of people who trust each other, not an adversarial group);
  secret state is stored in an app-private file (native) or `localStorage`
  (web), not the platform keychain; the relay has no authentication or rate
  limiting.

## 2026-10-01 — Seal working household journals before storing them

- The existing Rust recovery AEAD seals the whole atomic household journal,
  with an authenticated purpose prefix; its independent random wrapping phrase
  is the only value stored through pinned `flutter_secure_storage` 11.2.0.
  Native storage uses the OS keychain/keystore, disables Android reset-on-error
  and automatic backup/transfer, and reads back new keys before saving ciphertext
  ([maintainer documentation](https://pub.dev/packages/flutter_secure_storage)).
- Web households require a user-saved random 24-word unlock phrase kept only in
  memory and an exclusive origin Web Lock until locking or closing the page;
  persisting a browser encryption key beside its ciphertext would not protect
  the saved MLS secrets. Legacy bytes are validated before migration, and a
  separately authenticated recovery backup can replace a lost browser key;
  this does not protect an unlocked page from malicious same-origin scripts,
  erase forensic remnants, or stop someone cloning a recovery backup.

The older September entries above describe the state at those dates; signed
origin history, durable invitations and protected working state supersede
their corresponding implementation limits, with verification recorded in
`PHASE2-PROGRESS.md`.

## 2026-10-02 — Recover signed history, never rewind MLS sender state

Normal restart resumes the latest confirmed working journal; restoring an
arbitrary older backup instead creates fresh signing/leaf keys and preserves
the old signed history as an encrypted, read-only archive until re-invitation
and cryptographic removal of the old key. Only the original MLS group can
import those original proofs (including saved unsent events), and an early
invitation waits durably for retirement without publishing; otherwise a stale
or cloned snapshot could reuse the old sender ratchet, and its own later
ciphertext cannot recover the missing plaintext.

## 2026-10-02 — Checked hybrid-clock advancement

Every personal book and shared peer now uses the core's checked clock step.
A logical `u32::MAX` carries into the next physical millisecond instead of
saturating and reusing a timestamp/personal event ID. Exhausting both fields
returns an error before changing the clock, history, proof set or outbox.
An authenticated incoming event can reach this boundary, so it is not treated
as an impossible local-only counter. Existing on-disk and wire formats remain
unchanged. Tests cover skew, carry, terminal exhaustion, observed signed history,
peer restart, and all four personal books; the initial personal carry regression
failed before the fix. The locked full Rust acceptance suite passed, including
three-peer 1,000-event convergence (112.56 s); all 48 bridge unit tests passed.

## 2026-10-02 — Rust-owned SQLite, with a single-threaded browser boundary

The locked SQLite requirement is implemented in `rust/storage`, keeping event
frames immutable and revisions transactional instead of introducing financial
CRUD rows. Native files use bundled SQLite; browser persistence serializes an
in-memory database under an origin Web Lock because the pinned SQLite/WASM
binding must remain on one synchronous caller thread, not the bridge worker
pool. Whole-image copies, quota, retained legacy data and mobile verification
status are explicit in `SQLITE-STORAGE.md`; no OPFS or encrypted-private-ledger
claim is made.

## 2026-10-02 — Snapshot replay checks immutable content, not only IDs

A regression test reproduced a snapshot accepting changed content under an
already included event ID, unlike the full fold. Snapshots now retain exact
included events and reject conflicting replays, including events added by
`fold_forward`; byte-identical replay remains idempotent. This is correctness
metadata, not safe pruning: original history remains necessary until peer
frontier acknowledgement and late-event recovery are wired into persistence.

## 2026-10-02 — Bundle the adaptive controls' Cupertino icon font

The release web build requested CupertinoIcons but no corresponding font asset
was declared. Pin the already cached `cupertino_icons` 1.0.9 package rather than
leaving adaptive framework controls with missing glyphs. The asset test passed,
and the production release now bundles the tree-shaken 1,472-byte font without
the missing-family warning; no Flutter/Rust toolchain change was required.

## 2026-10-02 — Reject malformed CSV before any ledger mutation

Regression tests reproduced unfinished/misplaced quotes being accepted and
empty quoted fields or carriage returns being lost. The parser now validates
quote boundaries, preserves quoted CR/LF and empty fields, and handles CR,
LF and CRLF row endings; export quotes carriage returns. Import parses the
entire input first and returns a readable zero-import error on malformed CSV
instead of interpreting altered fields or saving a partial prefix. All 18
CSV parsing/dialog checks passed, including a valid first row followed by a
malformed row causing no writes.

## 2026-10-02 — Explicit CSV files, not just clipboard text

Pin `file_picker` 13.1.0 and its resolved platform implementations to offer file
import/save on the existing iOS 15+, Android and web targets; the Flutter-owned
`file_selector` was considered but does not expose save-location selection on
mobile/web ([maintainer API](https://pub.dev/packages/file_picker),
[file_selector support table](https://pub.dev/packages/file_selector)). Streamed
UTF-8 reads are bounded to 5 MB, preserve Unicode and strip a BOM; the user
reviews text before choosing Import. Plaintext/partial-backup limits are shown.
The pinned web implementation requests a download and returns null, so its
result is not treated as either cancellation or proof of a completed save.

All 202 app tests passed before the added narrow-phone/1.5x-text layout test;
that test and seven file/dialog checks then passed, with clean static analysis.
An independent production Chrome/WASM journey selected a real synthetic BOM/
Unicode CSV through the browser file dialog, verified no SQLite change before
Import, reloaded the persisted transaction, and read back the actual downloaded
CSV bytes. Mobile native file-dialog interaction and non-Latin offline font
coverage remain separate verification/UX work; plugin compatibility is not a
claim that those dialogs have been exercised on a phone.

