# Architecture

## Product boundary

The app is local-first. During Phase 1, each installation owns one private
personal ledger and has no account, server, cloud sync, shared group, or
telemetry dependency. Phase 2 may exchange encrypted events, so Phase 1 stores
data in the same merge-safe shape from the beginning.

## Ledger source of truth

The source of truth is an immutable event set in `rust/core`. UI models,
balances, transaction lists, and reports are derived views. Incoming events are
deduplicated by globally unique event ID and folded in the total order:

```text
(HLC physical milliseconds, HLC logical counter, actor ID, event ID)
```

Replaying the same event is idempotent. Reusing an event ID for different
content is an error. Mutations such as amount changes, category changes, and
voids are new events; existing event payloads are never updated.

## Money and FX

Money is a signed 64-bit count of currency minor units. Currency exponent is
explicit, including the ISO zero-decimal and three-decimal sets. Every
transaction keeps its original money value and a frozen rational FX rate into
the ledger's reporting currency. Conversion uses a wider integer intermediate
and half-away-from-zero rounding, then returns to a checked signed 64-bit
result. No floating-point type is permitted in the core money path.

## Snapshots and late events

A snapshot contains the folded state, the highest included HLC for every
actor, the included event IDs retained for idempotency, and the greatest total
order key included. A new event that sorts at or before that greatest key and
is not already included invalidates the snapshot; callers must rebuild from
the event log. Events are not eligible for deletion until relevant peers have
acknowledged the causal frontier. This favors correctness over premature
compaction.

## Persistence

The ledger core has no storage or platform dependency (see Boundaries below),
so persistence is a codec plus a place to put bytes, not a schema.

- `rust/core` defines a durable log frame format: one event per frame,
  length-prefixed and checksummed, so a frame is self-describing and a torn
  write can only ever corrupt the last, still-in-flight frame. Decoding a log
  stops at the first frame that fails its checksum or runs out of bytes and
  reports how many trailing bytes were unreadable; it never discards a
  successfully decoded prefix or panics on corrupt input. A domain-level
  conflict between two fully valid frames (the same event ID with different
  content) is a different problem — real corruption, not a torn write — and
  is left to `fold` to reject.
- `rust/api::load_personal_ledger` is the ledger's only constructor: a fresh
  installation and a restart both replay a byte log (empty on first launch)
  through the same path, so there is no separate "create" code that could
  drift from "restore". `add_account`/`record_transaction` return the
  frame for the event they just appended only when the ledger accepted it,
  so a rejected write can never reach durable storage.
- Native file access is not available from Rust running as WASM in a
  browser, so the app (Dart), not the core, owns *where* the bytes live:
  `app/lib/data/storage/event_store_io.dart` appends to a plain file in the
  OS-sandboxed app support directory on iOS/Android/desktop, and
  `event_store_web.dart` base64-encodes the log into `window.localStorage`
  for Flutter web, since a page has no filesystem. Both implement the same
  `EventStore` interface, selected at compile time the same way the
  generated `frb_generated.io.dart`/`frb_generated.web.dart` bridge files
  already are, so everything above the storage layer — including the Rust
  ledger — stays platform-agnostic.
- The actor ID is generated once on first launch, persisted next to the
  event log, and reused on every later launch. It must never change once
  events exist: the total order and idempotency both key on it, and the
  Rust core has no way to detect or migrate an actor ID change.
- A mutation only counts as durable once its frame has been appended to
  storage; the controller does that before updating the on-screen balance.
  If the process dies first, the event is simply not there on the next
  launch — there is no half-applied state to reconcile, only a clean prefix
  of history.

## Categories: soft state, a separate mechanism

Categories are last-writer-wins state, not ledger events (build brief §2.5):
a category's name and icon are fine to settle by picking the highest
`(HLC timestamp, actor ID)` writer, unlike a transaction, where a conflict
must stay visible in history rather than resolve silently. `rust/core`
implements this as its own module (`categories.rs`) with its own upsert
type, its own fold (`fold_categories`, which never rejects — there is no
invariant a category write could violate), and its own durable log, sharing
only the low-level frame codec (`frame.rs`) with the financial event log.
The two states are never merged into one `EventKind` enum or one fold
function, so a change to one can't accidentally weaken the other's
guarantee. The bridge mirrors this split: `PersonalLedger` and
`CategoryBook` are separate opaque types with separate durable logs, but
share the device's one actor ID (`DeviceIdentity`, distinct from either
`EventStore`), since both logs are still one device's writes.

"Custom titles that auto-assign on repeat" (also in scope for Phase 1) needs
no new state at all: it looks up the most recent past transaction whose
title matches and reuses its category, reading the ledger's existing
`TransactionRecorded` events directly.

## Transfers

A transfer moves money between two of the ledger's own accounts and is one
more `EventKind` variant (`TransferRecorded`), folded with the same
strict, error-on-conflict rules as `TransactionRecorded` — unlike categories,
a transfer is genuinely financial state, not soft state, so it belongs in
the same mechanism, not a separate one. It carries two independent amounts,
`sent` (leaving the source account, in that account's currency) and
`received` (arriving in the destination account, in its currency), each
with its own frozen reporting-currency rate. A same-currency transfer
normally has `sent == received`, but the fold never assumes that: a
cross-currency transfer may legitimately receive less than it sent (a
conversion spread or fee), and that difference shows up as a real, visible
change to the reporting balance rather than being silently normalized away.
`LedgerState` keeps transfers in their own map (`transfers`), separate from
`transactions`, since a transfer touches two accounts and has no single
`category_id` or expense/income `kind` the way a transaction does.

## Budgets

Budgets are also last-writer-wins soft state, following the same rationale
as categories: a budget's name, limit, or period is a definition to settle
by LWW, not a fact whose conflicting history must stay visible. `rust/core`
implements this as its own module (`budgets.rs`), independent of both
`ledger.rs` and `categories.rs`, with its own upsert type (`BudgetUpsert`),
never-rejecting fold (`fold_budgets`), and durable log — again sharing only
the frame codec. A `BudgetPeriod` is one of `Weekly`, `Monthly`, `Yearly`, or
`Custom { days }`; `period_start_millis` finds a period's calendar-aligned
start using Howard Hinnant's integer `civil_from_days`/`days_from_civil`
algorithm (see `docs/BORROWED.md`) rather than a date/chrono dependency, so
"this month" always means the 1st of the current calendar month, not a
rolling 30-day window (`Custom` is the only rolling-window period, by
design, for budgets like "$50 every 2 weeks" that don't align to a
calendar boundary).

A budget's progress is never stored — it's computed fresh each time from
the ledger's own expense transactions (`budget_progress`, in
`rust/api/src/api/budgets.rs`), summing non-voided expenses whose
`recorded_at_millis` falls within the current period and whose category
matches the budget's (or all categories, when the budget has none). This
keeps budgets from becoming a second source of truth for spending: the
ledger's fold remains the only place "how much was spent" is decided.
`recorded_at_millis` is fixed on a `TransactionState` at the moment its
`TransactionRecorded` event is folded and untouched by later
`AmountAdjusted` events, so a transaction never jumps between budget
periods just because its amount was later corrected.

The bridge's `BudgetPeriodKind` enum is deliberately kept field-less
(`Weekly`, `Monthly`, `Yearly`, `Custom`), with the day count for `Custom`
passed as a separate `custom_period_days` parameter to `upsert_budget`: a
data-carrying enum variant here would require `flutter_rust_bridge` to
generate a Dart `freezed` union type, pulling in a code-generation
dependency the project has no other use for, for one field. This mirrors
the existing `EntryKind`/`TransactionKind` bridge pattern.

## Goals

Goals are also last-writer-wins soft state, same as categories and budgets:
a goal's name, kind, target, linked account, category, and deadline are
definitions to settle by LWW. `rust/core` implements this as its own module
(`goals.rs`), independent of `budgets.rs`, `categories.rs`, and `ledger.rs`.
A goal is one of two kinds: `Save` (accumulate a linked account's balance
toward a target) or `Spend` (cap total matching expenses against a target,
optionally scoped to one category). The bridge validates the pairing —
`Save` requires `linked_account_id` and forbids `category_id`; `Spend`
forbids `linked_account_id` — since the two kinds measure fundamentally
different things and mixing their fields would produce a goal whose
progress has no defined meaning.

A goal's progress, like a budget's, is never stored: `goal_progress`
(`rust/api/src/api/goals.rs`) computes it fresh on every call. A save
goal's progress is simply its linked account's current
`native_balance_minor` (accounts already exist as ledger state; no new
tracking is needed). A spend goal's progress sums matching non-voided
expenses from the goal's own creation — the earliest upsert recorded for
that `goal_id`, found by scanning the goal book's full upsert history, not
a separately stored "created at" field — up to its deadline, if any. Unlike
a budget's period, a goal's window never rolls forward: once past, a
spend goal's cap either holds or it doesn't, there is no "next month" to
reset it the way a recurring budget has.

## CSV import and export

CSV export and import (`app/lib/features/ledger/csv_transactions.dart`) are
pure Dart, entirely client-side, for the same reason search and filter are
(see `docs/DECISIONS.md`): the data is already loaded in memory, and there
is no canonical-convergence requirement a Rust-side implementation would
protect. The CSV codec (`parseCsv`/`encodeCsvField`) is a small
hand-written RFC 4180 parser rather than a dependency, since this app only
ever needs to round-trip its own export format. Export covers non-transfer
transactions only — a transfer describes money moving between two of this
ledger's own accounts, not income or an expense, so it has no natural fit
in a `title,amount,kind,account,category` row. Import replays each valid
row through the controller's existing `record` method, so an imported
transaction goes through the exact same validation and durable-persistence
path as one entered by hand; a row that fails to parse or fails the
ledger's own validation is skipped and reported, never silently dropped.

There is no native file picker or file-save integration: export copies CSV
text to the clipboard and shows it for review, and import reads pasted CSV
text, both through `Clipboard`/`TextField` from the Flutter SDK alone. See
`docs/DECISIONS.md` for why.

## Recurring transactions and upcoming occurrences

Recurring rules are a fourth independent LWW mechanism (`rust/core/src/recurring.rs`),
alongside categories, budgets, and goals: a rule's title, amount, account,
category, and frequency (`Daily`/`Weekly`/`Monthly`/`Yearly`) settle by
last-writer-wins. The calendar math it shares with budgets
(`civil_from_days`/`days_from_civil`, plus a new `add_months` that clamps to
a shorter target month) was factored out into `rust/core/src/calendar.rs` so
neither module duplicates Howard Hinnant's algorithm (see `docs/BORROWED.md`).

Which occurrences are "upcoming" is never stored, following the same
principle as a budget's spend or a goal's progress: `upcoming_occurrences`
(`rust/api/src/api/recurring.rs`) computes each rule's next due date fresh,
by finding the latest ledger transaction tagged with that rule's ID and
calling `next_occurrence_millis` to step forward from there (or from the
rule's own `start_millis`, if nothing has been recorded yet). This requires
`EventKind::TransactionRecorded` and `TransactionState` to carry an optional
`recurring_id`, set when a transaction is created by recording a due
occurrence — the only new field this feature adds to the ledger's own event
shape, and it participates in `canonical_bytes()` like every other field.
"Recording" a due occurrence is not a special operation: the UI calls the
same `record`/`record_transaction` path as a hand-entered transaction,
simply passing the rule's ID along, so there is exactly one way a
transaction ever gets created.

## Biometric lock

The biometric lock (`app/lib/features/lock/biometric_lock_gate.dart`) gates
the whole app behind `local_auth`, a native plugin — the one departure from
this app's otherwise pure-Dart, no-native-dependency features (categories,
budgets, goals, recurring rules, search, CSV). It has no Rust involvement at
all: whether the app is locked is UI state, not ledger state, so it doesn't
belong in either the strict event-sourced fold or any of the LWW
mechanisms. `LockPreferenceStore` (`app/lib/data/storage/lock_preference.dart`)
persists the user's on/off choice using the same native-file/`localStorage`
split as `EventStore`, but as its own small store (`lock_preference_io.dart`/
`lock_preference_web.dart`) rather than folded into `EventStore`, since it
holds a UI preference with no fold, no frame codec, and no crash-recovery
story of its own.

`local_auth` has no web implementation, so `BiometricLockGate` always shows
its child directly on web (`kIsWeb`) rather than a lock screen nobody could
pass — see `docs/DECISIONS.md`. The gate also re-locks whenever the app
resumes from the background (a `WidgetsBindingObserver` on
`AppLifecycleState.resumed`), so a device left unlocked and set down can't
be picked up and read without unlocking again.

## Boundaries

- `rust/core`: deterministic domain types, validation, event fold, and snapshot
  policy. It has no UI, storage, network, or wall-clock dependency.
- `rust/api`: thin `flutter_rust_bridge` surface. Added when the first personal
  app vertical slice is connected.
- `rust/crypto`: MLS wrapper promoted from the proven Phase 0 spike when Phase
  2 begins; it is not part of the Phase 1 personal app.
- `app`: Flutter Material 3 UI organized by feature. It receives presentation
  models through the bridge and does not implement ledger rules. `app/lib/data`
  holds the generated bridge bindings and the `EventStore` persistence layer
  (native file vs. browser storage) described above; both stay data plumbing,
  never a second copy of ledger rules.

