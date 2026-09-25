# Cash app agent instructions

## Product goal

Build a local-first personal budgeting app for iPhone, Android, and web, then
add privacy-preserving household sharing. Each person owns a private ledger and
publishes only chosen shared expenses or analytics. There are no shared logins,
and the relay must never receive readable financial data.

## Read only what the task needs

1. Read `docs/PHASE0-RESULT.md` for the current technical gate.
2. Read the relevant phase of `expense-app-build-brief.md`.
3. Read the market/legal diligence only for product, policy, billing, or
   licensing work. Do not load it for normal implementation tasks.

## Current gate

- Android and Web/WASM pass the Phase 0 OpenMLS bridge flow.
- iOS is untested. Phase 0 is not complete until the iOS simulator workflow
  runs successfully and the result is recorded.
- Do not begin Phase 1 or claim iOS compatibility before that result unless the
  user explicitly accepts a provisional architecture decision.

## Efficient execution

- Inspect installed tools, caches, disk space, and existing artifacts before
  installing or rebuilding.
- Reuse the versions in `docs/PHASE0-RESULT.md`; pin toolchains in CI.
- Run the smallest relevant test first. Do not rebuild every platform after a
  documentation-only or isolated change.
- Use vendor documentation only to resolve an actual uncertainty.
- Keep progress updates and command output concise. Report the first actionable
  failure and preserve useful caches when retrying.
- Never equate "builds" with "runs". Record the exact platform, runtime, command,
  and result used as evidence.
- Keep the repository clean and use one focused commit per concern.

## Ledger invariants

- Money uses signed 64-bit minor units; no floating point in the money path.
- Frozen FX rates use an integer/rational representation and an explicit,
  deterministic rounding rule.
- Events are immutable and idempotent by globally unique event ID.
- Total order is `(HLC physical, HLC logical, actor ID, event ID)`.
- Snapshots store a per-actor causal frontier, not one event ID, and must handle
  late-arriving events safely.
- Equal event sets produce canonically serialized, byte-identical state.
- Conflicts remain visible in history rather than becoming silent overwrites.

## Verification

Before reporting completion, run the affected phase's acceptance tests. Clearly
separate independently verified results from reported, inferred, or untested
claims.
