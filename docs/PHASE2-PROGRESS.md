# Phase 2 progress

Updated 2026-09-30. Phase 2 (the shared layer, brief section 6) is in
progress: the cryptographic and sync core is built and verified locally, but
it is **not yet reachable from the app** (no bridge, no UI) and the relay is
**not deployed**. Design rationale is in `docs/DECISIONS.md` (2026-09-30,
"Shared layer").

## What exists

| Piece | Location | What it does |
| --- | --- | --- |
| Shared ledger fold | `rust/core/src/shared.rs` | Total, order-independent fold; conflicts and rejected events stay visible; canonical bytes; wire encoding |
| MLS wrapper | `rust/crypto` | Multi-member groups, staged commits, removal, safety numbers, state export/import, recovery phrase and sealed backups |
| Sync engine | `rust/sync` | `Peer`: encrypt, append (compare-and-swap), pull in order, fold; offline outbox; persistence |
| Relay worker | `relay/` | Cloudflare Durable Object: ordered ciphertext log, WebSocket tail notifications, single-use welcome mailboxes |
| Verification | `scripts/verify_relay.sh`, `.github/workflows/phase2-shared.yml` | Worker tests in workerd, and the Rust engine against the running worker |

## Exit test (brief section 6), item by item

Verified locally on 2026-09-30 (`cargo test --workspace`, and
`scripts/verify_relay.sh`); CI evidence is recorded below once the workflow
has run.

| Item | Evidence | Caveat |
| --- | --- | --- |
| Three peers, two offline for part of the run, 1,000 interleaved events including concurrent edits to one expense and an edit-versus-void | `rust/sync/tests/three_peers.rs::three_peers_two_offline_a_thousand_events_converge_byte_identically` (1,000+ events asserted; conflicts and rejections asserted non-empty) | In-memory reference relay. The same engine also converges a smaller scripted run through the real worker (`rust/sync/tests/http_relay.rs`) |
| On reconnection all three fold to byte-identical balances | Same test: every peer's `canonical_bytes` equals an independent fold of every event written | Peers are in one process, not three devices |
| A removed member cannot decrypt any epoch after removal | `a_removed_member_cannot_read_anything_after_removal`; `rust/crypto/tests/group.rs::a_removed_member_cannot_decrypt_any_later_epoch` (also covers a second rotation after removal) | |
| Relay storage inspected directly contains no plaintext field, amount, or member name | Same three-peer test scans every byte string the relay holds for event IDs, actor IDs, titles, account names, and member names. Checked to fail when handshakes are sent in plaintext | Scans `MemoryRelay`'s storage. The worker stores each blob verbatim and never parses it, but its Durable Object storage was not dumped and scanned. Amounts are not searched for (a short binary needle would match ciphertext by chance); they sit inside the same encrypted payloads |
| Multi-currency group with a mid-run FX change keeps historical balances | `rust/core/tests/shared_acceptance.rs::a_multi_currency_shared_ledger_keeps_historical_balances_after_an_fx_change` | Tested on the fold directly; the three-peer run uses EUR entries at one rate |

## Not done

- **Deployment.** The worker has only run in workerd under miniflare. Nobody
  has deployed it to Cloudflare; that needs an account and credentials (an
  owner action). No authentication, rate limiting, abuse controls, or log
  retention policy exist yet; a public relay needs them.
- **App integration.** No flutter_rust_bridge surface for groups, no invite
  flow, no safety-number screen, no recovery-phrase screen, no shared-expense
  UI. `cash_sync`'s `Relay` trait is synchronous; the app will need an
  async transport (Dart's HTTP/WebSocket stack) in front of it.
- **Platforms.** `cash_crypto` and `cash_sync` compile for `wasm32`
  (`cargo check`), and MLS itself ran on iOS, Android, and web in Phase 0, but
  none of this new code has run on a device or in a browser.
- Display names inside the encrypted stream; more than one group per device;
  relay-side compaction or a peer-snapshot recovery path (the relay keeps the
  whole log); push notifications; key-package distribution format (invite
  link/QR).
- Metadata is not hidden: the relay sees group and mailbox IDs, entry count,
  sizes, timing, and client IPs.
