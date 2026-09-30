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
| Sync engine | `rust/sync` | `Peer`: encrypt, append (compare-and-swap), pull in order, fold; offline outbox; persistence; history backfill for new members; a transport-free step interface |
| Relay worker | `relay/` | Cloudflare Durable Object: ordered ciphertext log, WebSocket tail notifications, single-use expiring welcome mailboxes, CORS for the web app |
| Bridge | `rust/api/src/api/shared.rs` | `Household` (opaque): the step interface, shared overview with labels, safety numbers, recovery phrase |
| App | `app/lib/features/household/` | Relay client (HTTP and in-memory), `HouseholdController`, Household screen: setup, join/invite by text codes, shared expenses with edit/void and visible conflicts, safety numbers, removal, backup/restore, leave |
| Verification | `scripts/verify_relay.sh`, `scripts/verify_household_host.sh`, `.github/workflows/phase2-shared.yml` | Worker tests in workerd; the Rust engine against the running worker; the Dart controller against the real Rust library on a dev machine |

## Exit test (brief section 6), item by item

Verified locally on 2026-09-30 (`cargo test --workspace`, and
`scripts/verify_relay.sh`), and in CI: the `Phase 2 Shared Layer` workflow
passed on `d189ca2`
([run 36768018516](https://github.com/arsalmurad/cash-app/actions/runs/36768018516);
workspace tests, then the worker tests in workerd and the Rust engine against
the running worker, all steps successful).

| Item | Evidence | Caveat |
| --- | --- | --- |
| Three peers, two offline for part of the run, 1,000 interleaved events including concurrent edits to one expense and an edit-versus-void | `rust/sync/tests/three_peers.rs::three_peers_two_offline_a_thousand_events_converge_byte_identically` (1,000+ events asserted; conflicts and rejections asserted non-empty) | In-memory reference relay. The same engine also converges a smaller scripted run through the real worker (`rust/sync/tests/http_relay.rs`) |
| On reconnection all three fold to byte-identical balances | Same test: every peer's `canonical_bytes` equals an independent fold of every event written | Peers are in one process, not three devices |
| A removed member cannot decrypt any epoch after removal | `a_removed_member_cannot_read_anything_after_removal`; `rust/crypto/tests/group.rs::a_removed_member_cannot_decrypt_any_later_epoch` (also covers a second rotation after removal) | |
| Relay storage inspected directly contains no plaintext field, amount, or member name | Same three-peer test scans every byte string the relay holds for event IDs, actor IDs, titles, account names, and member names. Checked to fail when handshakes are sent in plaintext | Scans `MemoryRelay`'s storage. The worker stores each blob verbatim and never parses it, but its Durable Object storage was not dumped and scanned. Amounts are not searched for (a short binary needle would match ciphertext by chance); they sit inside the same encrypted payloads |
| Multi-currency group with a mid-run FX change keeps historical balances | `rust/core/tests/shared_acceptance.rs::a_multi_currency_shared_ledger_keeps_historical_balances_after_an_fx_change` | Tested on the fold directly; the three-peer run uses EUR entries at one rate |

## App-level evidence

The Dart half is checked three ways:

- **Widget tests** (`flutter test test`, 127 passing locally): the panes,
  dialogs, and screen against a fake controller; invite/join/backup codes;
  the HTTP relay client against a mock server; atomic blob storage.
- **The two-device scenario against the real Rust core**
  (`test_support/household_scenario.dart`): found, invite and join by text
  codes, an invite that works once, a shared expense, an offline edit that
  conflicts with a concurrent one (both visible, both devices agree), a
  restart, matching safety numbers, a lost phone restored from a sealed
  backup (and a wrong phrase refused), and a removed member locked out.
  Passed locally via `scripts/verify_household_host.sh`, and is run on iOS
  and Android in CI through `integration_test/household_test.dart`.
- **This scenario found a real bug** that the Rust-only tests had not: a
  member added to a household with existing expenses could not see anything
  written before they joined (MLS gives a new member no history), so the
  account those expenses belong to was missing and their edits were
  rejected. Fixed with a history backfill (see `docs/DECISIONS.md`), with
  Rust tests for batching, restart of the inviter mid-backfill, and removal.

CI for the app-level work (branch `claude/stoic-brahmagupta-1wwxwq`):

- **Android emulator**, `ed2f636`:
  [run 36771485671](https://github.com/arsalmurad/cash-app/actions/runs/36771485671)
  passed: the ledger integration test and the two-device household scenario
  through the real bridge.
- **iOS simulator**, `0e7a706`:
  [run 36779072179](https://github.com/arsalmurad/cash-app/actions/runs/36779072179):
  the ledger integration test and the household scenario both passed. Two
  earlier runs on this code hung after "Xcode build done" with no test output
  (the runner flake recorded earlier in this repo); iOS steps now time out
  after 20 minutes.
- **Web**, `02e9826`:
  [run 36770316184](https://github.com/arsalmurad/cash-app/actions/runs/36770316184)
  passed with MLS compiled into the wasm bundle and the Household screen in
  the app. This checks that it builds and the personal ledger still runs; it
  does not drive the household flows in a browser.
- An earlier Android run (36768664768) failed right after creating an
  account in the existing ledger test, with no relevant change in that
  commit; the integration test now waits for asynchronous bridge results
  before asserting, and the same flow passed in the run above. The cause was
  not proven to be timing.
- `Phase 2 Shared Layer` (Rust workspace, worker tests, Rust engine against
  the worker) passed on `cf1459d`; the later Rust commits (backfill) and the
  CORS change were verified locally but are covered by that workflow only
  once it runs on the PR's final head.

## Not done

- **Deployment.** The worker has only run in workerd under miniflare. Nobody
  has deployed it to Cloudflare; that needs an account and credentials (an
  owner action), and the app has no default relay address: the user enters
  one. No authentication, rate limiting, abuse controls, or log retention
  policy exist yet; a public relay needs them.
- **Secrets at rest.** The saved household state (MLS private keys) lives in
  an app-private file natively and in `localStorage` on the web, not the
  platform keychain. The recovery backup is sealed, but the working copy is
  not.
- **Attribution inside a household.** An event's actor ID is not bound to
  the MLS sender, so a member could write events in another member's name.
  Fine for a household that trusts its members, not for an adversarial
  group.
- **Web.** The web build compiles MLS into its wasm bundle and passed the
  existing web runtime check, but the household flows have not been driven
  in a browser (the CDP script only covers the personal ledger), and the
  worker's CORS support is tested only with preflight and header
  assertions, not from a real browser page.
- **On-device coverage of edge cases.** Push notifications (the worker
  exposes WebSocket tail notifications; the app polls every 30 s instead),
  multiple households per device, display names inside the encrypted stream
  (members are shown as `Member <first six hex>`), foreign-currency shared
  expenses in the UI (the core supports them), category assignment on shared
  expenses, and compaction or a peer-snapshot path (the relay keeps the
  whole log and every new member replays a backfill of the whole history).
- Metadata is not hidden: the relay sees group and mailbox IDs, entry count,
  sizes, timing, and client IPs.
