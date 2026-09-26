# Decisions

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
