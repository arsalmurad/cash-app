# Phase 2 progress

Updated 2026-10-02. Phase 2 (the shared layer, brief section 6) is in
progress: the cryptographic and sync core, bridge, and household UI exist,
with the runtime evidence and remaining limitations listed below. The relay
is **not deployed**. Design rationale is in `docs/DECISIONS.md` (2026-09-30,
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
| Relay storage inspected directly contains no plaintext field, amount, or member name | In-memory scan plus the actual Durable Object storage audit below, using production storage methods and real Rust peers | Local workerd, not a deployed Cloudflare account; synthetic fixtures and meaningful integer amount marker avoid short-needle false positives |
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
  the ledger integration test, the household scenario, and the unsigned
  release build all passed. Two
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
- `Phase 2 Shared Layer` (Rust workspace, worker tests with CORS, Rust engine
  against the worker) passed on the final head `a466b75`:
  [run 36781383594](https://github.com/arsalmurad/cash-app/actions/runs/36781383594).

## Authenticated history verification (2026-10-01)

Original event proofs now carry group-bound signatures using the existing MLS
identity. Actors are hashes of signing keys, event IDs include their actor's
namespace plus randomness, and live messages must match the authenticated MLS
sender. Backfills retain original signatures; proof-hash deduplication preserves
conflicting signed versions of an event ID through restart and forwarding.
Unsigned v1 archives remain readable/exportable but cannot write or synchronize,
and the overview includes a visible legacy warning.

Independently passed on the Windows host for this change:

- `cargo test --manifest-path rust/Cargo.toml --workspace --locked`, including
  the three-peer 1,000-event scenario, signature tampering, impersonation,
  cross-household replay, legacy archives and conflicting-proof preservation.
- `cargo build --manifest-path rust/Cargo.toml -p rust_lib_cash_app --locked`,
  then `flutter --no-version-check test --no-pub test/household_host_test.dart
  --reporter failures-only` with `RUST_LIB_PATH` pointing to that rebuilt DLL:
  the real-bridge two-device household scenario passed.
- `npm test` in `relay/`: all 12 tests passed in actual workerd/Miniflare after
  correcting file-URL conversion in the Windows worker launchers.
- With that worker listening at `http://127.0.0.1:8787`,
  `RELAY_URL=http://127.0.0.1:8787 cargo test --manifest-path rust/Cargo.toml
  -p cash_sync --features http --test http_relay --locked -- --ignored
  --test-threads=1`: both relay-contract and real-worker three-peer tests passed.

These are not new iOS, Android or production WASM runtime claims. A forwarded
proof authenticates its originating key, not when it held membership: the
current transport member authorizes publishing that history. It cannot stop an
authorized member forwarding a collaborator's signed history or sharing
plaintext out of band. Durability, recovery and relay authorization are separate
gates in `COMPLETION.md`.

## Membership and delivery recovery (2026-10-01)

Peer v3 exports include the exact pending commit and OpenMLS staged state.
Signed v2 imports retain their ledger, and v1 remains a read-only archive.
An exact commit in its reserved ordered-log slot resolves a lost acknowledgement;
a valid competing frame rejects it, while malformed evidence preserves the
journal. Focused Rust checks pass 16 step and 6 restart tests, including removal
after a lost reply and wrong-slot acknowledgement rejection.

The app saves its Rust state, relay address, pending encrypted welcome, mailbox
and original commit together in one atomic journal before sending. Confirmed
membership is persisted before mailbox delivery; exact mailbox PUT retries are
idempotent and do not resurrect a consumed welcome. The last invite can be
copied again after restart, and sealed backups include pending delivery and its
relay address. All 165 Windows app tests passed through the rebuilt native
bridge, with clean analyzer output; 12 workerd tests passed for the updated
mailbox contract. No new mobile or production WASM runtime is claimed here.

The locked full Rust workspace suite also passed on this revision, including
the three-peer 1,000-event scenario (93.48 s), and both HTTP contract/three-peer
tests passed against a freshly restarted workerd with the updated mailbox code.
Commands are the same workspace/HTTP commands recorded above. The native bridge
was rebuilt again at the committed revision before the focused household runs.

GitHub checks passed at `a848ca6` after fixing an existing probabilistic BIP-39
checksum assertion (a reordered phrase can also have a valid checksum):
[Rust/worker run](https://github.com/arsalmurad/cash-app/actions/runs/36887960667)
and [app/Chrome run](https://github.com/arsalmurad/cash-app/actions/runs/36887965972).
This was merged as PR #10; backup authentication itself was unchanged.

## Acknowledged welcome retrieval (2026-10-01)

The app now reads a welcome without consuming it, saves joined keys and receipt
intent together, and only then acknowledges it. A lost read or acknowledgement
reply can be retried, including after restart; a failed atomic save leaves either
the original join identity or complete joined state, both recoverable. Sealed
backups include outstanding acknowledgements, and an empty acknowledgement does
not poison a later delivery. The legacy `/take` endpoint remains for old clients;
new durable app joins use `GET /m/{id}` and `POST /m/{id}/ack`.

Independently passed: 171 Windows app tests through the existing rebuilt bridge,
clean analyzer, 13 workerd tests, 13 Rust sync unit tests with the HTTP feature,
and both HTTP relay-contract/three-peer checks against fresh current workerd.
The four receiver restart cases cover lost read replies, lost ack replies, and
save failures before or after the complete joined snapshot reached storage.
No new mobile or production WASM runtime is claimed. Working journals still
contain unsealed private keys; the full durability/security gate remains open.

## Actual worker storage audit (2026-10-01)

`CARGO=C:/Users/ME/.cargo/bin/cargo.exe node test/storage-audit.mjs` in `relay/`
passed on Windows with the pinned Node 24.19.0/Miniflare 4.20260730.0/workerd
1.20260730.1. It runs the real Rust three-peer HTTP scenario, enumerates every
actual Durable Object record through a test-only subclass, and checks both
stored values and decoded ciphertext against synthetic member/account/title,
event/actor ID, canonical-event and integer amount needles (both byte orders).
The storage schema is also asserted to contain only log/ciphertext/mailbox
metadata. All 27 log records and both welcome mailboxes passed; deliberately
injecting plaintext into a record made the scanner reject it.

The storage reader is a separately injected module under `relay/test/`, never
part of the deployment worker or its configuration. This closes the local real
worker storage gate, not production deployment, metadata hiding or at-rest key
protection. Windows workerd emitted a connection-reset diagnostic but all audit
assertions and the process exit status passed. CI now runs `npm run test:storage`
after the already-built HTTP peer checks, reusing their dependencies and cache.

## Protected working journals (2026-10-01, mobile/browser checks pending)

The default household store now seals its whole atomic journal using the
existing Rust AEAD and a purpose-bound plaintext domain. Native clients put only
a fresh random wrapping phrase in OS secure storage, with key readback and no
silent reset. Browser clients persist ciphertext only and keep a user-saved
24-word unlock phrase in RAM; reopening requires the phrase, and an exclusive
Web Lock prevents two tabs using one MLS sender state simultaneously. This
phrase is separate from the sealed recovery backup's independently generated
phrase. Correctly authenticated backup recovery can adopt a new browser key.

Independently passed on Windows: 185 app tests with the real Rust bridge and
clean analyzer. Eleven new real-AEAD tests cover concealed bytes, wrong/missing
keys, tampering, purpose substitution, failed/unconfirmed key saves, concurrent
initial key creation, uncertain blob saves, validated legacy migration, browser
lock/reload/wrong-phrase retry, and independent backup recovery. Two widget
checks require phrase-saving confirmation and exercise obscured unlock input
and recovery; one OS-plugin mock contract is explicitly not an OS runtime test.

Commands: with `RUST_LIB_PATH` set to the existing rebuilt Windows bridge,
`flutter --no-version-check test --no-pub --reporter failures-only` and
`flutter --no-version-check analyze --no-pub`, in `app/`.
`integration_test/household_test.dart` now includes a real OS secure-key write,
fresh-provider reread, ciphertext-file inspection and scoped test-data cleanup
on mobile. The Chrome-only test checks RAM-only keys and an independent frame's
exclusive-lock rejection. Those new mobile and browser checks remain pending;
the overall at-rest gate is not yet marked complete.

Encryption does not hide relay metadata, secure a compromised unlocked device
or page, encrypt the separate personal ledger, erase old plaintext remnants,
or guarantee protection from copying an old MLS backup and forking its identity.
Android automatic backup/transfer is disabled; use explicit encrypted household
backups and personal export instead. No new production WASM runtime is claimed.

### Protected-store platform evidence

PR #13 merged as `494253c`. The browser-release fix was independently verified
by [Linux app/Chrome run](https://github.com/arsalmurad/cash-app/actions/runs/36907999062)
at `0d4c68d`. Mobile checks at `99c7887` (identical native source; the subsequent
change only fixes browser lease release) passed actual secure storage/file
write, new-provider readback and ciphertext inspection in the household scenario:
[iOS simulator and unsigned release](https://github.com/arsalmurad/cash-app/actions/runs/36907364313)
and [Android emulator and release APK](https://github.com/arsalmurad/cash-app/actions/runs/36907370476).
Android's first attempt failed downloading an emulator archive before boot; the
retry passed. These are runtime checks, not just compilation or plugin mocks.

## Fresh-key backup recovery (2026-10-02, platform checks pending)

A new regression reproduced a stale-backup failure after the original device
sent messages: OpenMLS identified its own newer private message, whose plaintext
is unavailable to the restored snapshot. Skipping it would lose history and
still risk rewinding the sender ratchet. Working-journal restart is unchanged;
explicit backup restoration now recovers an encrypted history archive and a
fresh identity, never resumes old messaging keys or outstanding old invitations.

Another household member removes the old signing key and invites the replacement.
The Rust merge checks both relay and cryptographic MLS group identity, validates
every original signature before mutation, preserves original authors/conflicts,
and queues missing saved events as authenticated backfill. A correctly joined
replacement can wait through restart if removal happens after invitation; it
cannot share changes or alter membership before recovery finishes. Wrong-group
welcomes roll back the unused replacement identity without consuming its mailbox.
Journal v2 carries the archive and rejects silent downgrade; v1/raw Rust state
remain readable. A household with no other available member retains its backup
as a read-only archive rather than pretending old messaging keys are safe.

Independently passed: three new Rust recovery tests; the locked full Rust
workspace suite, including three-peer 1,000-event convergence (142.80 s); and
187 Windows app tests through the rebuilt bridge with clean analyzer. The
real-bridge recovery test covers an early invitation, newer old-device sends,
restart while waiting, denied premature publication, and later convergence and
old-device removal. Separate read-only archive UI checks and mobile protected
file/keychain scenarios are being verified; no new production WASM claim.

Commands: `cargo test --manifest-path rust/Cargo.toml --workspace --locked`,
`cargo build --manifest-path rust/Cargo.toml -p rust_lib_cash_app --locked`, and
the same app commands listed above. Full mobile household tests now use sealed
app-private files and distinct OS keys for the simulated devices, recreating
storage/key providers on restart; they no longer substitute in-memory working
journals. The relay in that mobile scenario remains in memory and the browser
HTTP/production-app gate stays open.

## 2026-10-02 — Production browser household acceptance

Independently passed on Windows Chrome 154.0.8037.58 using the normal `lib/main.dart` production
Flutter/WASM release, three isolated Chrome storage contexts, and the original
relay worker running in local workerd/Miniflare. No application debug hook,
injected ledger state, real user data, or public deployment was used.

Commands (from `app`, with the existing pinned tools on PATH):
`flutter_rust_bridge_codegen build-web --rust-root ../rust/api --release
--wasm-pack-rustup-toolchain nightly` (the installed alias manifest is dated
2026-09-24), then `flutter --no-version-check build web --wasm
--no-web-resources-cdn --no-pub`. From the repository root, set
`WEB_HOUSEHOLD=1` and run `node scripts/verify_web_runtime.mjs` (Node 24.19.0).
CI uses the explicit `nightly-2026-09-24` override instead of the alias.

The rendered UI passed join/invite through real browser HTTP/CORS, shared
expense delivery, reload with a required RAM-only unlock phrase, sealed
localStorage inspection, offline concurrent amount edits with visible conflict,
stale backup recovery after later old-device sends with a fresh identity,
old-key removal and future-message exclusion, and private-ledger isolation.
Both surviving members converged to USD -51.00. Captured HTTP bodies contained
none of the synthetic financial titles; direct Durable Object storage auditing
remains the separate evidence above. Screenshot:
`app/.dart_tool/household-web-pass.png` (local, ignored synthetic artifact).

The run found and fixed an accessibility issue: generated phrases and copyable
codes were visible but exposed as empty textboxes in Chrome's accessibility
tree. Explicit read-only semantic labels preserve pointer selection/copying;
13 focused widget tests and analyzer passed. This is not a full WCAG or
VoiceOver/NVDA audit. The aggregate iOS simulator run subsequently passed in
[run 36922253563](https://github.com/arsalmurad/cash-app/actions/runs/36922253563)
at `2cf81b4`: personal runtime, protected household recovery runtime, and unsigned
release build. Earlier simulator timeouts remain recorded as failed attempts,
not successful runs. This result predates the SQLite storage change. Android's
protected native household scenario and release APK passed in
[run 36913443159](https://github.com/arsalmurad/cash-app/actions/runs/36913443159)
at recovery revision `e5bf1e2`, before the accessibility-only UI change.

## Not done

Household save-safety changes were independently exercised through the rebuilt
native bridge on 2026-10-01: failures before/after a complete atomic save refuse
queued and later writes; restart reflects the bytes actually saved; a failed
sender-ratchet save sends no ciphertext; 20 simultaneous writes and fixed-clock
restart retain distinct transaction IDs. All 154 host app tests passed.
Those initial checks are now supplemented by membership/delivery/retrieval
journals above, but do not alone close the full durability gate.

- **Deployment.** The worker has only run in workerd under miniflare. Nobody
  has deployed it to Cloudflare; that needs an account and credentials (an
  owner action), and the app has no default relay address: the user enters
  one. No authentication, rate limiting, abuse controls, or log retention
  policy exist yet; a public relay needs them.
- **Recovery after later sends.** At-rest platform checks passed above. Stale
  backup recovery and duplicate restored sender identities require the separate
  fresh-membership recovery checks, not just successful decryption of a backup.
- **Historical membership policy.** Origin keys and live MLS senders are now
  authenticated as described above; signatures are not historical membership
  attestations. Current members still control publication of forwarded history.
- **Web deployment.** Production browser household flows passed against a
  real local worker above; the authenticated public deployment, other browsers,
  and final-revision cross-platform acceptance remain separate gates.
- **On-device coverage of edge cases.** Push notifications (the worker
  exposes WebSocket tail notifications; the app polls every 30 s instead),
  multiple households per device, display names inside the encrypted stream
  (members are shown as `Member <first six hex>`), foreign-currency shared
  expenses in the UI (the core supports them), category assignment on shared
  expenses, and compaction or a peer-snapshot path (the relay keeps the
  whole log and every new member replays a backfill of the whole history).
- Metadata is not hidden: the relay sees group and mailbox IDs, entry count,
  sizes, timing, and client IPs.
