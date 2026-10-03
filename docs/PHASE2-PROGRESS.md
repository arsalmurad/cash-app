# Phase 2 progress

Updated 2026-10-02. Phase 2 (the shared layer, brief section 6) is in
progress: the cryptographic and sync core, bridge, and household UI exist,
with the runtime evidence and remaining limitations listed below. The relay
is **not deployed**. Design rationale is in `docs/DECISIONS.md` (2026-09-30,
"Shared layer").

## What exists

Strict Rust follow-up (Windows, pinned Rust 1.98.1):
`cargo clippy --manifest-path rust/Cargo.toml --locked --workspace --all-targets
-- -D warnings` and the complete locked default-feature workspace tests passed.
The three-peer/two-offline 1,000-event convergence test passed in 109.89 s; this
also rechecked membership removal, signed history, recovery, checkpoints and
storage. Safety-number v1 retains an independent fixed-key golden vector; the
only production crypto change is equivalent fixed-chunk iteration. Other changes
are lint-only test organization/predicates. No current live HTTP, cloud Actions
or new platform runtime result is implied; those remain separately recorded.

### Current sealed-storage failure checks (2026-10-02)

After the personal correction/ordering bridge changes, the full production
Chrome acceptance journey passed again at app source `4a05a7e` with personal,
CSV, household, quota and offline-font flags enabled (exact combined command
in `PHASE1-PROGRESS.md`). This independently rechecks the newly generated bridge
alongside actual HTTP/CORS join, real quota refusal with no early relay append,
sealed reload, offline conflict, stale-backup fresh-key recovery and old-device
removal, EUR/JPY convergence and private-ledger/HTTP plaintext boundaries. Local
workerd only; not public deployment, final iOS or a physical-device result.

Production Chrome quota follow-up passed with `WEB_HOUSEHOLD=1
WEB_HOUSEHOLD_QUOTA=1 WEB_OFFLINE_FONTS=1 node scripts/verify_web_runtime.mjs`.
The app binary is the unchanged, already-built production source `2804c03`;
this added only a driver. An unrelated owned-profile key filled localStorage
until Chrome itself rejected a new value with QuotaExceededError. A synthetic
large shared expense then required more SQLite pages and failed: confirmed
database bytes stayed byte-identical, and the real local workerd tail did not
advance. After removing only the filler, a later expense still failed until
restart; the RAM unlock phrase reopened only confirmed state. Nothing patched
the app APIs, inserted financial state or overwrote the app's database. The
existing HTTP/CORS two-peer join, protected reload, offline conflict, fresh-key
recovery/removal, EUR/JPY convergence and readable-title HTTP negative checks
also passed. Chrome 154.0.8037.58 on Windows; not a public deployment or general
power-loss guarantee. The manual web workflow now includes this flag, but no
cloud job was dispatched.

The portable failure scenario now runs with real Rust state against retained
frame stores and actual Windows SQLite documents sealed by Rust AEAD. Host
wrapping keys are explicitly an in-memory test backend, not OS secure storage.
Both scenario tests passed, alongside all 258 local app tests and clean static
analysis. Lost-removal acknowledgement/exclusion assertions were added after
that full suite and both affected scenario tests passed again.

`flutter --no-version-check test --no-pub integration_test/household_test.dart
-d emulator-5580 --reporter expanded` then passed on the owned read-only AOSP
ATD Android 16/API 36 x86_64 emulator (WHPX, pinned tools). Debug APK build:
86.8 s; install: 2.281 s; actual runtime: 14 s. The same fixture factories use
real Android OS wrapping keys and sealed SQLite, recreated for every restart.
Checks cover saves rejected before/after durable commit, queued/later write
refusal, sender-ratchet save failure before/after commit without sending early,
exactly-once retry, lost invite/removal replies, lost welcome acknowledgement,
and joined-state saves before/after commit. A removed peer cannot read the
subsequent expense. Physical SQLite bytes contain none of the four readable
failure-fixture expense titles. The original protected household recovery and
native vault checks also passed; only owned test documents/keys were cleaned up,
and the owned emulator was stopped after the run.

These are controlled exceptions and logical peers on one emulator, not actual
power loss, multiple physical devices or real HTTP-failure injection. The relay
is the in-memory fixture; previous real-worker tests are separate evidence.
No new iOS/cloud job or authenticated public deployment is claimed.

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
  (members are shown as `Member <first six hex>`), native-device coverage of
  foreign-currency shared expenses, category assignment on shared
  expenses, and compaction or a peer-snapshot path (the relay keeps the
  whole log and every new member replays a backfill of the whole history).
- Metadata is not hidden: the relay sees group and mailbox IDs, entry count,
  sizes, timing, and client IPs.

## Default-closed relay deployment guard (2026-10-02)

The production worker now refuses all data routes, WebSocket paths and CORS
preflight unless `LOCAL_DEVELOPMENT` is exactly the string `true` and the
request URL uses a literal loopback hostname. The production Wrangler config
does not set that binding. Existing Node/workerd acceptance launchers opt in
explicitly and bind their listener to loopback.

This is not authentication and must not be used to expose a public relay.
Host/Origin headers are not peer identity; spoofed headers do not alter the
URL check. Public authentication, abuse controls and bounded log retention
remain unfinished, and no Cloudflare deployment was made.

All 17 Node/workerd tests passed, including an actual unconfigured workerd
instance refusing data access, disabled/incorrect bindings, non-loopback URLs,
and the existing CAS, paging, WebSocket, mailbox and CORS contracts. The real
Rust three-peer HTTP scenario also passed against the explicitly enabled local
worker; direct inspection found 27 ciphertext log records plus encrypted
mailboxes and rejected the plaintext-injection negative control. Commands:
`npm test` and `CARGO=<existing cargo executable> node test/storage-audit.mjs`
in `relay/`, on Windows with the pinned Node/Miniflare/workerd versions.
The audit emitted a Windows WSASend disconnected warning during worker cleanup
but exited successfully with the assertions above; it is not a deployment or
physical-network failure-recovery claim.

The cached production web build from the offline-font change also passed the
complete household journey against this guarded worker on Windows Chrome:
real HTTP/CORS join, RAM-only unlock after reload, offline conflict convergence,
fresh-key stale-backup recovery, removal and private-ledger separation. The same
run passed LF Unicode CSV import/download with font CDNs blocked:
`WEB_HOUSEHOLD=1 WEB_CSV=1 WEB_OFFLINE_FONTS=1 WEB_CSV_LINE_ENDINGS=LF node scripts/verify_web_runtime.mjs`.
This checks the relay guard with the existing production app; that cached build
predates the separate UTF-8 relay-configuration change, so it is not final-
revision acceptance for the complete current source tree.

## Current Android source runtime (2026-10-02)

On Windows, the cached Android 16/API 36 AOSP ATD x86_64 image ran in an owned
read-only `Phase0Api36` session (`emulator-5580`, WHPX, emulator 37.1.11).
Production app source `6b4c646` passed these device tests with the existing
Flutter 3.47.5, Rust 1.98.1, JDK 17.0.20.1 and NDK 28.2.13676358:

- `flutter --no-version-check test --no-pub integration_test/ledger_test.dart -d emulator-5580 --reporter expanded`:
  personal SQLite persistence and restart passed (24 s runtime).
- The same command targeting `integration_test/household_test.dart`:
  real OS wrapping keys, physical sealed SQLite bytes, protected household
  restart/recovery and removed-member checks passed (6 s runtime).
- Targeting the native CSV test introduced here, with
  `--dart-define=EXPECT_MISSING_DOCUMENT_PICKER=true`: two tests passed (6 s),
  including exact Unicode native clipboard bytes and graceful actual-plugin
  failure/retry without replacing pasted text when the document provider is
  absent. This is not successful native file selection/save coverage.

The debug APK also built. Initial cold dependency/native setup took 1,928.2 s
and installed dependency-required SDK Platform 35 revision 2 and CMake 3.22.1;
it did not change the pinned toolchains. Subsequent instrumented builds reused
caches and took 95.4, 64.1 and 69.3 s. The SDK XML/deprecated manager warnings
remain recorded, not worked around by an unverified tool upgrade. To avoid
exhausting C:, the 3.22 GB/5,219-file generated Rust Android cache was moved to
`D:/cash-app-build/cash-app-native-rust-cache-20261002`, retaining the original
`app/build/rust_lib_cash_app/build` path through a local ignored junction.
These paths are local artifacts, not repository prerequisites.

The minimal ATD image has no activity for OPEN_DOCUMENT or CREATE_DOCUMENT;
the free full API 36 AOSP image is a separate upcoming file-picker verification
target. Final release APK, final production web build, and current-source iOS
acceptance remain separate gates. No paid cloud jobs or relay deployment were
started for these checks.

### Actual Android document-provider journey (2026-10-02)

The free full AOSP Android 16/API 36 x86_64 system image (revision 2,
extension 17) supplies `com.android.documentsui`, unlike the minimal ATD
image. An owned read-only, headless `CashAppCsvApi36` emulator session
(`emulator-5582`, WHPX, SwiftShader, emulator 37.1.11) independently passed
`scripts/verify_android_csv.mjs`, with `ANDROID_RESET_CSV_TEST_APP=1` and the
same pinned toolchains above. The cached APK build took 120.4 s; both native
integration tests passed in 55 s. Production app code remains `6b4c646`.

The driver selected a real 89-byte BOM-prefixed Unicode CSV through Android's
document UI. Flutter assertions proved selection did not mutate the ledger,
explicit Import produced USD -1.23, and a fresh SQLite-backed controller
recovered the exact transaction title. Actual native clipboard bytes matched.
Android's actual Save action completed, and pulling the exported file proved
all 86 UTF-8 bytes matched the LF CSV without its input BOM. This is successful
document-provider coverage, not mocked picker coverage or merely a build.

An earlier manual attempt failed: clipboard readback was null while a System
UI not-responding dialog was observed, and the file journey exceeded its
five-minute timeout before Save completed. That observation does not establish
an app or OS root cause. The bounded driver fixes were absent-package handling,
Windows batch quoting and binary file pull/read instead of `adb shell cat`
(the latter translated LF to CRLF). Those failed attempts are not passes.
Only the named disposable emulator/app and verified synthetic fixture output
are reset; the driver refuses physical devices and unexpected export contents.
The generated instrumented debug APK is a test artifact, not a release APK.
Current-source iOS and final web/release acceptance remain outstanding.

## Shared multi-currency controls (2026-10-02)

The household screen now creates explicit shared USD/EUR/GBP/JPY accounts and
lets a shared expense choose among them, without access to private accounts.
Foreign entries and amount edits ask for USD per source unit and freeze the
Rust-parsed exact ratio. Adjusting an EUR expense uses its actual account
currency instead of the former hard-coded USD. Shared account balances retain
their source-currency labels; the household total remains USD. Reporting-
currency settings, shared categories and native-device UI coverage remain open.

Independently passed on Windows with the existing native Rust DLL: the
real-bridge currency scenario, 40 affected UI/controller checks and then all
224 app tests. The final empty-name guard passed the focused bridge check;
`flutter --no-version-check analyze --no-pub` reported no issues. Negative
checks reject missing/invalid/overflowed rates, private/unknown account IDs,
fractional JPY and missing edit rates without replacing saved journal bytes.
EUR 10 at 1.1 and EUR 10 at 1.2 fold to USD -23.00; adjusting the first to EUR
12 at 1.1 and adding JPY 100 at 0.0067 yields USD -25.87 across a second peer
and journal restart. Later rates do not move the unchanged historical entry.

The production app built with `flutter --no-version-check build web --wasm
--no-web-resources-cdn --no-pub` (206.5 s), reusing unchanged Rust WASM.
`WEB_HOUSEHOLD=1 node scripts/verify_web_runtime.mjs` independently passed in
Windows Chrome 154.0.8037.58 against actual local workerd: encrypted HTTP/CORS
join, sealed restart, offline conflicts, fresh-key stale-backup recovery,
removal, explicit EUR/JPY UI entry, matching USD -74.67 peer totals and private
ledger/readable-request-title separation. Two earlier runs stopped on test
driver exact-label mismatches for the dropdowns, not app assertions; the driver
now reads their actual rendered accessibility labels. CSV/offline-font coverage
passed earlier in the first combined run, before that run stopped at currency
selection; the final household rerun disabled CSV to avoid repeating it.
The web build predates only the final empty-account-name input guard. These are
not new Android/iOS runs or final-source release acceptance.

## Persisted shared checkpoints (2026-10-02)

`cash_core::SharedSnapshot` retains exact variants, canonical state and a per-actor
frontier. Ordered new events extend the fold; late or conflicting-ID events
rebuild safely, including retractions and visible downstream rejections. The
actual `Peer` uses the cache for state/edit-head reads and persists its checked
descriptor in signed v4 archives. Import verifies original proofs before
checking recomputed state/frontiers. v2/v3 remain readable; unsigned v1 remains
restricted. No event/proof is pruned, no peer acknowledgement is inferred from
high-water marks, and bounded relay history/peer-snapshot recovery is not done.

Independently passed on Windows with the pinned tools:

- `cargo test --manifest-path rust/Cargo.toml --workspace --locked`: full core,
  crypto, SQLite, sync and 48 bridge tests; the three-peer/1,000-event scenario
  passed in 184.64 s. New core checks cover 1,000-event incremental equivalence,
  late/conflicting duplicates, rejected events/edit heads and 50 shuffled chunk
  orders with identical checkpoint bytes.
- The final `cash_sync --test restart` run passed all eight checks, including
  tampered state/frontier refusal, v2/v3 compatibility and a persisted checkpoint
  receiving an older offline-peer event before another restart. Initial new
  tests failed as expected before implementation; synthetic old-format fixture
  offsets were then corrected for the added descriptor.
- After rebuilding `rust_lib_cash_app`, all 224 host app tests passed with
  `RUST_LIB_PATH` pointing at that DLL, including real journals, protected
  recovery, failure safety and shared FX. No bridge API/code generation changed.
- Pinned Rust WASM build passed (89 s) and production Flutter WASM build passed
  (180.2 s). The initial wrapper failed before compilation because Dart was
  absent from PATH; retry added the existing pinned executable, not a new SDK.
  The recorded unstable-atomics warning remains.
- `WEB_HOUSEHOLD=1 WEB_CSV=1 WEB_OFFLINE_FONTS=1 WEB_CSV_LINE_ENDINGS=LF node
  scripts/verify_web_runtime.mjs`: current production browser personal SQLite,
  Unicode file import/download without font requests, encrypted household
  checkpoint restart, offline conflicts, stale-backup fresh-key recovery,
  removal and EUR/JPY peer convergence all passed on Windows Chrome 154.0.8037.58.
- `CARGO=C:/Users/ME/.cargo/bin/cargo.exe node test/storage-audit.mjs` in `relay/`:
  27 actual workerd ciphertext records/encrypted mailboxes and plaintext-injection
  refusal passed. Windows workerd emitted WSASend #10054 during cleanup; all
  assertions and exit status passed, not a claim about physical-network recovery.

The checkpoint-enabled source `bfaaa10` subsequently passed
`flutter --no-version-check test --no-pub integration_test/household_test.dart
-d emulator-5580 --reporter expanded` on the owned read-only AOSP ATD Android
16/API 36 x86_64 emulator, with WHPX and the existing pinned mobile tools.
The debug APK build took 301.4 s, installation 5.0 s, and actual runtime passed
in 8 s: real OS wrapping keys, physical sealed SQLite-byte checks, protected
household restart/recovery and member removal. The first emulator launch used
the default AVD directory and failed before any app run; retry set the existing
`ANDROID_AVD_HOME=D:/Android/avd` and booted successfully. It did not install a
new image or upgrade tools. The two logical peers share one emulator, not two
physical phones. New EUR/JPY native UI coverage remains a separate check.

No current-checkpoint iOS runtime or new cloud job is claimed here.
Archive size/memory grow with retained history, and import still replays signed
sources. An end-to-end performance benchmark and acknowledged pruning remain
separate work, not reasons to erase an offline peer's history.

## Retention-receipt prerequisites (2026-10-03)

`RETENTION-RECEIPTS.md` records the new local saved-state verifier and explicit
MLS-encrypted exchange. A conservative cutoff requires every current signing
key, matching signed history/frontiers, epoch, cryptographic group and relay
log ID; the sender must supply its complete latest confirmed archive. New
negative regressions catch copied-key relay relabeling and an old ratchet whose
financial checkpoint happens to match. Receipt control messages do not enter
the financial event set. Normal sync does not automatically generate replies.

All 62 affected sync tests pass, including the existing three-peer/two-offline/
1,000-event case (108.26 s for its binary), old signed-archive compatibility,
recovery and interrupted sync. Strict HTTP-enabled Clippy passes. The actual
Rust-peer/local workerd audit now includes three encrypted receipt messages:
31 ciphertext records plus encrypted mailboxes, with receipt/financial plaintext
sentinels absent and a plaintext-injection negative control rejected. Its final
WSASend #10053 cleanup diagnostic is not independently diagnosed, despite passing
assertions and exit 0. No deployed relay or physical-network claim follows.

Queued receipts persist in checked v6 archives, collected original signed
receipts in checked v7 archives, while ordinary archives retain v5. V7 import
revalidates scope/signatures and rejects noncanonical or malformed collections;
older archives still need explicit recollection. A follow-up app/bridge hook
reads confirmed protected-save bytes, persists queue/ratchet before send, and
generates at most one receipt per history/membership checkpoint (not ACK traffic).
Ten native-bridge coordinator tests and portable sealed-SQLite failure recovery
pass locally; final mobile/WASM verification is not inferred. Bounded coordinated
recollection and authenticated/recoverable
pruning remain open. No ciphertext or original signed financial history is
deleted, and the previous app-platform binaries do not exercise this new API.

The follow-up at `98bc07a` now passes all 315 native-enabled Flutter tests,
66 sync and 64 Rust API tests, strict checks, and the rebuilt production WASM
household/quota/offline-font flow. Browser HTTP checks verify one receipt per
published checkpoint and no control-only ACK loop. The actual-worker storage
audit again passes 31 encrypted records/mailboxes with its negative control.
`RETENTION-RECEIPTS.md` records exact scope, the preceding combined renderer
failure and corrected removed-member idle-driver failure. This does not close
mobile-source acceptance, full accessibility or authenticated pruning gates.

The same unchanged production app/Rust source now also passes actual Android
personal (including whole-JPY entry/two frozen rates/restart) and household
integrations on the pinned API 36 x86_64 ATD/WHPX emulator. Household runtime is
33 s after its 82.5 s cached build, exercising real protected SQLite/OS-key,
interrupted saves, fresh-key recovery/removal and chosen-summary UI. Exact
commands, receipt-test scope and limits are in `RETENTION-RECEIPTS.md`; iOS,
enrolled biometrics, complete accessibility and authenticated pruning are not
inferred. No cloud workflow, public relay deployment or deletion was enabled.

## Non-destructive relay capacity (2026-10-03)

Per-group encoded-ciphertext and record ceilings now bound further log growth
without evicting offline history. Transactional accounting and legacy/corrupt
counter refusal have real workerd boundary tests; actual 64 MiB fill and complete
paged backfill pass. The real encrypted-peer storage audit still passes all 31
records/mailboxes and its negative control, now checking exact accounting too.
See `RELAY-CAPACITY.md` for commands, seeded versus full-volume evidence and
WSASend diagnostic. No app/Rust source changed, and no platform rebuild was
needed. This does not close authentication, account-wide quotas, migration,
pruning/recovery or authorized free-plan deployment.

Following relay-page integrity and bounded/fixed-frontier reads, the app at
`b7b1a3d` passes 44 focused HTTP/native-bridge persistence checks, strict checks,
five Rust HTTP unit checks and the real-workerd encrypted-peer storage audit.
Its rebuilt production web/WASM desktop household/quota/offline-font runtime
also passes with the new streaming HTTP path. `RELAY-CAPACITY.md` records exact
commands, prior RED regressions, limits, source scope and the undiagnosed WSASend
diagnostic. Current-mobile/iOS acceptance and public authenticated deployment
remain separate gates; no server deletion was enabled.

## Saved household change versus failed delivery (2026-10-03)

The expense form already closes before the controller attempts delivery; no
automatic form retry was found. Its relay error, however, omitted the confirmed
local-save outcome. The controller now prefixes relay failures after a successful
local save and successful sync-final save with "Saved on this device. Do not
repeat this change." It preserves the capacity/operator guidance and false
save-and-send return value. Initial/final uncertain storage failures still
require restart and never get this prefix; plain Sync failures do not claim a
new local change. The UX-copy skill guided factual, actionable wording rather
than promising eventual delivery or claiming an unverified save.

Both capacity-prefix assertions failed before the implementation. All 16 focused
native-bridge receipt tests subsequently pass, including four combined capacity/
uncertain-write cases (before and after the store actually saves), lost replies,
restart/idempotency and no ACK loops. The earlier combined receipt/screen/save
safety run passed 42 tests; the final full native-enabled suite includes the new
two widget checks and passes all 331 tests in 2m46s. Command from `app`:
`RUST_LIB_PATH=<cached native DLL> flutter test --no-pub`; local detailed log:
`app/.dart_tool/saved-change-full.log`. Dart analysis reports no issues.
No Rust core/bridge API changed. This is host/runtime/widget evidence, not a
current mobile/iOS or rebuilt production-browser pass for the new wording.

## Confirmed-page backfill persistence (2026-10-03)

Three new native-bridge regressions first reproduced lost progress on a later
HTTP 429 and continued networking before an uncertain save was discovered.
The paged HTTP capability now validates the whole page, ingests it through the
unchanged native MLS bridge and awaits persistence before the next GET. Tests
prove restart from the confirmed cursor, exactly 18 expenses / USD -18.00,
no receipt during interrupted catch-up, no subsequent ACK loop, and no later
networking on save failures both before and after the store actually saves.
Three additional HTTP checks cover partial progress versus atomic list reads,
malformed-page exclusion and awaiting/stopping on consumer failure.

All 344 native-enabled app tests pass in 2m46s with
`RUST_LIB_PATH=<cached native DLL> flutter test --no-pub` from `app`.
Local detailed log: `app/.dart_tool/paged-backfill-full.log`. The new encrypted
tests use a paginated HTTP mock around actual native peers, not an authenticated
workerd quota run. Existing app source reuses the unchanged cached native/WASM
bridge; Rust HTTP list reads are not changed. Current mobile/iOS acceptance,
real authenticated nonce-limit backfill, legacy oversized-history migration,
trusted registration and pruning remain separate gates.

Dart analysis subsequently reports no issues (5.4s); the first analysis found
only three new test-code style issues, corrected without behavior changes.
Production web/WASM rebuild passes in 168.3s, reusing the unchanged Rust bridge:
`flutter --no-version-check build web --wasm --no-web-resources-cdn --no-pub`.
The rebuilt app independently passes
`WEB_HOUSEHOLD=1 WEB_HOUSEHOLD_QUOTA=1 WEB_OFFLINE_FONTS=1
WEB_VIEWPORT=1280x900 node scripts/verify_web_runtime.mjs` on existing Windows
Chrome 154 / Node 24.19 against actual owned loopback workerd. This covers the
paged browser HTTP path, sealed restart/lock, receipt/no-loop checks, real
browser quota failure, private summaries, offline conflict convergence,
fresh-key recovery/removal and frozen EUR/JPY rates. It does not simulate the
new interrupted-page case in the browser or enable signed app networking.
Logs: `app/.dart_tool/paged-backfill-web-build.log` and
`app/.dart_tool/paged-backfill-web-household.log`. No new mobile/iOS claim.
