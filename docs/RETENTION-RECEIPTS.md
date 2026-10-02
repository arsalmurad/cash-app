# Saved-state retention receipts

Status: local Rust verifier implemented; persistence/transport and recoverable
relay pruning are **not implemented**. No history is deleted by this component.

## Contract

`Peer::saved_state_receipt(saved)` imports and checks an existing peer archive,
then signs a small receipt with its MLS Ed25519 identity. It does not encrypt
a message, advance a sender ratchet or modify the archive. The caller must
provide the bytes of a **confirmed successful storage write**, not a newly
exported live object or a write that threw. Rust cannot infer OS durability
from a byte array; tests using exports exercise the verifier, not real app
storage confirmation. Missing membership, unsigned legacy state, unsent events
or backfill, and staged membership changes are refused.

The receipt binds the cryptographic MLS group ID, membership epoch, processed
relay cursor, original signing key, and a SHA-256 checkpoint digest. That digest
covers canonical folded state, the per-actor causal frontier, and every exact
original signed proof in canonical order. Equal balances or a single high-water
timestamp are not sufficient. A lower-timestamp offline event changes the
digest even if it arrives after a newer checkpoint.

`Peer::retention_cutoff(receipts)` verifies signatures against the **current
MLS roster** and requires a matching checkpoint and epoch from every current
signing key. Unknown/removed keys, another group, stale checkpoints/epochs,
future cursors, malformed receipts, and conflicting duplicates fail closed.
Identical retries are idempotent. The result is the minimum acknowledged cursor,
not the greatest received timestamp. Receipt order is irrelevant. Membership
changes invalidate the previous collection and require new receipts, including
one from a newly added device.

The codec bounds receipt size and checks lengths, truncation and trailing data.
Receipts contain no financial fields, event IDs, display names or private keys,
but still carry linkable cryptographic metadata. They must travel **encrypted**
through an authenticated channel. Never send the saved archive to the relay:
it contains private MLS material. No receipt endpoint or bridge API is enabled.

## Remaining integration gates

1. Issue and retain a receipt only after the actual protected SQLite save has
   completed. Refuse issuance during uncertain saves, pending invitation/mailbox
   work or recovery. Test failures before/after durability and queued operations.
2. Exchange receipts inside authenticated encrypted transport, preserving
   ordering/retry/restart semantics without an endless acknowledgement loop.
3. Collect them against a checked current roster/checkpoint. A relay read or a
   highest actor timestamp must never be treated as another peer's durable ack.
4. Establish authenticated pruning authorization and crash-safe cursor/floor
   transitions. This local cutoff is **not** a server deletion capability.
5. Verify retained signed-history/peer recovery, old backups with fresh-key
   rejoin, membership changes, unknown/missing receipts and late offline events
   before deleting any relay ciphertext. Keep immutable local history until its
   separate compaction requirements are satisfied.

An offline device without a current receipt blocks a new cutoff. Retention is
therefore not globally bounded yet. No expiry, timeout, inferred acknowledgement
or automatic device removal is used to route around that safety requirement.
Archive import/hash cost remains proportional to retained history.

## Verification scope

New tests were written before implementation and initially fail to compile
because the receipt API did not exist. Five Rust integration checks subsequently
pass for three-peer collection, late offline events, restart, tampering/replay,
foreign households, membership changes, removed/staged/unjoined peers and
unsent backfill. Additional unit checks cover every truncated codec prefix,
length overflow/trailing/oversize data, validly signed future cursors,
conflicting receipts, unchanged sender state, and unsigned legacy refusal.
`cargo test --manifest-path rust/Cargo.toml --locked -p cash_sync` passes all
54 unit/integration tests, including the existing three-peer/two-offline/
1,000-event canonical convergence acceptance (112.71 s for that test binary).
Five new receipt integration tests take 0.90 s, and the 18 sync unit tests,
including three new receipt checks, take 0.67 s. The HTTP-feature test is not
enabled by this command; no app save adapter, encrypted receipt transport,
app-platform runtime or deployed pruning pass is inferred from these tests.
Strict cached-dependency `cargo clippy --locked --offline -p cash_sync
--all-targets -- -D warnings` also passes (2.15 s) after two test-only style
findings were corrected; checks were not disabled. The final 18-test unit rerun
passes (0.50 s) after those test-only edits, without repeating all platforms.
