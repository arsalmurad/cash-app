# Saved-state retention receipts

Status: Rust verifier, MLS-encrypted exchange, checked collection persistence
and app protected-save coordination implemented; verification below is scoped.
Recoverable authenticated relay pruning is **not implemented**.
No history is deleted by this component.

## Contract

`Peer::saved_state_receipt(saved)` imports and checks an existing peer archive,
then signs a small receipt with its MLS Ed25519 identity. It does not encrypt
a message, advance a sender ratchet or modify the archive. The caller must
provide the bytes of a **confirmed successful storage write**, not a newly
exported live object or a write that threw. Rust cannot infer OS durability
from a byte array; tests using exports exercise the verifier, not real app
storage confirmation. Missing membership, unsigned legacy state, unsent events
or backfill, and staged membership changes are refused.

The v2 receipt binds both cryptographic MLS group ID and relay log identifier,
membership epoch, processed
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
it contains private MLS material. No relay receipt/pruning endpoint is enabled.

## Explicit encrypted exchange

`Peer::enqueue_saved_state_receipt(saved)` accepts only this device's complete
latest archive: financial checkpoint equality alone does not confirm newer
ratchet/control-message state. It queues an authenticated nonfinancial MLS
payload. The transport must save the queued state and advanced sender ratchet
before append, as for existing financial messages. Normal `sync` does not
automatically generate receipts, so there is no acknowledgement-of-ack loop.

Receipts are checked against the live MLS sender, signature, epoch, cryptographic
group, relay log ID and processed cursor before entering the collection.
Malformed/spoofed/future frames do not change financial state or taint confirmed
receipts. The collector keeps up to two conflicting equal-cursor claims per key,
rather than silently overwrite them; the cutoff verifier refuses that conflict.
A later valid higher-cursor receipt replaces the older collection for that key.
Membership commits/removal clear the collection.

Queued receipts survive a checked v6 peer archive. Archives with collected
receipts use v7, retaining exact original signed bytes in canonical key order.
Import rechecks current roster, epoch, group/log, cursor and signatures; bounded
counts and exact collection round-trip reject duplicates, reordered rows,
oversized lengths, truncation and trailing bytes. Archives without queued or
collected receipts retain v5 encoding; previous signed archives remain readable
and unsigned archives remain restricted. Old apps must update before handling
v6/v7 archives or participating in receipt collection. V1 receipts lack relay-
log binding and are refused: recollect v2 rather than infer missing binding.
All household devices must update before the app's new receipt exchange is used.

Received collections are now included in the peer archive, which callers must
save in protected storage with the private MLS keys. Old archives that lack the
collection still require explicit recollection: never infer receipts from their
saved cursor. Core export/import tests do not establish actual app durability.

## Remaining integration gates

1. Complete final-platform verification of the protected-save hook described
   below. Keep failure-before/after-save and queued-operation coverage.
2. Establish coordinated recollection for missing older archives if needed by
   a future pruning protocol; never infer missing peer receipts from cursors.
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

## Initial verifier verification (`2a966fe`)

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

## Encrypted-exchange follow-up

Tests were written first and fail at the absent queue/collector API, then pass
for unchanged canonical financial state, encrypted exchange, queued restart,
recollection after restart, stale checkpoints, another device's archive,
membership clearing, tampered queued signatures and format downgrade refusal.
Additional member-authored negative frames check spoofing, invalid signatures,
future cursors and conflicting valid claims.

Review exposed two further RED regressions: a receipt could cross relay labels
with the same copied MLS keys, and an old saved ratchet could be queued when only
control traffic had changed. V2 relay-log binding and complete-archive equality
repair those before app integration. All 61 sync tests passed before the last
complete-archive guard (1,000-event binary 111.63 s); final affected checks after
that guard are recorded separately, not inferred from the previous source.

The actual HTTP Rust-peer/workerd storage audit includes three encrypted receipt
messages: 31 ciphertext records and encrypted welcome mailboxes pass, and the
scanner rejects a plaintext-injection negative control. No readable financial
sentinels, v2 receipt marker or exact public receipt bytes occur in inspected
storage. The audit emits Windows WSASend #10054 cleanup diagnostics but exits 0
after its assertions; no physical-network reliability claim is made. These
exports model confirmed archives, not actual app SQLite confirmation. Final
affected verification after the complete-archive guard independently passes:

- All 62 `cash_sync` tests pass with `cargo test --manifest-path rust/Cargo.toml
  --locked --offline -p cash_sync`; the 1,000-event binary takes 108.26 s.
- The final 58-test affected subset passes, including 20 unit, 6 transport,
  5 receipt, 8 restart, 3 recovery and 16 step checks.
- Strict `cargo clippy --manifest-path rust/Cargo.toml --locked --offline
  -p cash_sync --all-targets --features http -- -D warnings` passes (2.72 s).
- The updated actual-worker audit again passes 31 ciphertext records and its
  negative control. This final run emits WSASend #10053 rather than #10054;
  assertions and process status pass, but the socket diagnostic is not diagnosed.

No app-platform rebuild/run or actual app-save confirmation is claimed for this
new core-only exchange. The earlier app/DLL/WASM runtime evidence predates it;
the bridge does not yet expose or automatically invoke receipt queueing.

## Collection-persistence verification

The first collection restart/signature tests were RED because exported archives
contained no collected receipt bytes. Checked v7 persistence repairs that;
three integration tests now pass for byte-identical restart/cutoff/financial
state, corrupted signatures, downgrade, every collection-truncated prefix,
count/length overflow, duplicates, row reordering and trailing bytes. The 20-test
affected persistence/transport/restart/recovery subset passes. All 65 sync tests
pass with `cargo test --manifest-path rust/Cargo.toml --locked --offline
-p cash_sync` (1,000-event binary: 123.60 s). Strict HTTP-enabled all-targets
Clippy also passes (3.81 s). No new app-platform run or actual protected-save
confirmation is inferred from these core-only checks.

## App protected-save hook

The thin bridge exposes `household_needs_saved_state_receipt` and
`household_enqueue_saved_state_receipt`. The serialized app sync considers at
most one new receipt per invocation after financial/backfill work drains. It
skips pending invitations, mailbox acknowledgements, recovery and inactive or
queued peers. An existing own receipt for the same financial checkpoint and
membership suppresses further generation despite control-only cursor changes.
The persisted collection preserves this suppression across restart.

When a receipt is needed, the controller completes a protected journal save,
reads that saved journal back, validates relay/pending/recovery metadata and
passes its state bytes to the complete-archive equality guard. It saves the
queued receipt before encryption; the existing loop saves advanced sender state
before append. Uncertain writes or unconfirmable read-back disable later writes
and require restart. Protected-save success/read-back is not proof against every
OS/power-loss failure; platform storage limits still apply.

Ten real native-bridge coordinator tests cover checkpoint/restart suppression,
six before/after-write failures at checkpoint/queue/ratchet boundaries, failed
or stale read-back, and a lost receipt append reply. They began RED against the
missing app hook, then pass. The lost reply may produce one encrypted retry of
the same signed receipt, just as an uncertain financial append can retry the
same immutable event: logical idempotency and subsequent stable relay tails
are tested, not exactly-once network delivery. The portable interrupted-sync
scenario also passes against actual sealed Rust SQLite (host memory key backend,
not a native OS-key claim); inspected physical bytes contain neither v7 peer/
receipt markers, financial sentinels nor wrapping phrases. Native-platform and
production WASM verification of this hook remain separate until recorded.

Final core/bridge acceptance passes all 66 sync plus 64 API tests with
`cargo test --manifest-path rust/Cargo.toml --locked --offline -p cash_sync
-p rust_lib_cash_app` (1,000-event binary: 133.86 s). HTTP-enabled strict
all-targets Clippy passes for both packages. Regenerated pinned FRB 2.13 bindings
and the cached native DLL pass the ten coordinator tests and two portable
failure scenarios (28 s combined). The broad first app run passes 314 checks
and fails one obsolete exact ciphertext-count assertion; the isolated final
four chosen-summary checks pass after counting its new receipt and requiring
the next sync's tail stay stable. The final analyzer reports no issues (4.2 s).
These scoped results do not stand in for final mobile/browser runtime.

The Rust/WASM release bridge rebuild passes with the existing pinned NDK Clang
and LLVM archive tool, `CFLAGS_wasm32_unknown_unknown=-matomics -mbulk-memory`,
nightly alias and cached dependencies (1m07s). Two initial local command attempts
omitted the compiler path and then these existing CI flags, respectively; their
missing-Clang and shared-memory link errors were corrected without installs,
toolchain upgrades or source workarounds. The tracked atomics warning remains.
Building this bridge is not a Flutter/browser runtime pass.

The final-source full native-enabled Flutter suite subsequently passes all
315 tests (2m40s), including the updated exact message counts, private-publication
boundaries, uncertain-save ownership, sealed SQLite failure scenarios and all
ten receipt-coordinator checks. Command from `app`: `RUST_LIB_PATH=<current
cached DLL> flutter --no-version-check test --no-pub --reporter expanded`.
