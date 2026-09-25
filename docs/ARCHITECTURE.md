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

## Boundaries

- `rust/core`: deterministic domain types, validation, event fold, and snapshot
  policy. It has no UI, storage, network, or wall-clock dependency.
- `rust/api`: thin `flutter_rust_bridge` surface. Added when the first personal
  app vertical slice is connected.
- `rust/crypto`: MLS wrapper promoted from the proven Phase 0 spike when Phase
  2 begins; it is not part of the Phase 1 personal app.
- `app`: Flutter Material 3 UI organized by feature. It receives presentation
  models through the bridge and does not implement ledger rules.

