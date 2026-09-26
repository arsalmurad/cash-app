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

