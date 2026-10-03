# Completion tracker

Updated 2026-10-03. The active objective is to finish the private prototype
against `expense-app-build-brief.md`, not merely merge individual milestones.
Unchecked work is not a completion claim. Keep this file current as gates pass.

## Verified baseline

- [x] Phase 0 OpenMLS bridge runtime on iOS, Android, web/WASM: see exact
  platforms and evidence in `PHASE0-RESULT.md`.
- [x] Phase 1 deterministic ledger acceptance tests and previous clean-checkout
  platform runs: `PHASE1-PROGRESS.md`.
- [x] Torn personal-log recovery repaired before further writes, with backups.
  PR #6, `2107d52`; native host and Chrome storage checks passed.
- [x] Failed saves stop further/queued mutations until restart; native file
  flush; 150 Windows app tests and Linux/Chrome checks. PR #7, `fdbd929`.
- [x] Shared-core three-peer, 1,000-event convergence, visible concurrent
  conflicts, removed-member decryption rejection, frozen FX tests.
- [x] Real Rust-backed two-device household controller scenario on the host;
  previous iOS/Android CI evidence is in `PHASE2-PROGRESS.md`.

## Remaining gates

- [x] Authenticate original authors through live messages **and forwarded
  history**, including tampering, impersonation, replay, restart, removed
  authors' historical events, and explicit legacy-data handling. PR #8,
  `d27bdf1`, passed locked Rust, real-worker and native-bridge scenarios plus
  GitHub Rust/worker and app/Chrome checks; historical membership limitations
  remain explicit in `PHASE2-PROGRESS.md`.
- [x] Make household mutations, membership commits, persistence and network
  retries safe under storage failures, concurrency and interrupted invitations.
  Current host/native-bridge regressions, sealed SQLite/Android OS-key recovery,
  interrupted invite/removal and real production Chrome quota checks passed;
  see `PHASE2-PROGRESS.md`. Tested controlled exceptions, logical peers and actual
  quota exhaustion are not arbitrary hardware/power-loss proof. Final-revision
  cross-platform acceptance and authenticated public deployment remain open.
- [x] Protect the working household private-key state at rest on native and web;
  PR #13, `494253c`: real OS secure-storage/file checks on iOS and Android,
  Chrome RAM-only/exclusive-lock checks, and 185 host app tests passed.
  Production household WASM and stale-backup recovery remain separate gates.
- [x] Drive the complete household scenario in the production web/WASM app,
  including browser-to-worker CORS, restart, offline edits, recovery and removal.
  Independently passed 2026-10-02 on Windows Chrome against the release app and
  real local workerd relay; details and commands are in `PHASE2-PROGRESS.md`.
- [x] Inspect real workerd Durable Object records for ciphertext-only contents,
  with original production storage methods, real encrypted Rust peers, and a
  plaintext-injection negative control: 27 log records and welcome mailboxes
  passed locally; the deployment itself remains unverified and unauthorized.
- [ ] Establish an authenticated, abuse-controlled, bounded-retention relay on
  the free-plan deployment path. Do not purchase services or expose a public
  unauthenticated relay. Account authorization may require the owner.
  The default worker is now closed; only explicit loopback development is
  enabled. This safety guard is not production authentication or deployment.
  Request bodies now have a streamed 512 KiB parsing bound, and decoded
  invitations share the 256 KiB blob limit. Storage reads are limited to 16
  records before values are loaded, with maximum-size page continuation tested.
  All 22 local relay tests and the 28-record real Rust-peer storage audit pass;
  these limits do not bound total
  retained history or authorize a public deployment.
  A subsequent non-destructive per-log ceiling now refuses growth at 10,000
  records or 64 MiB encoded ciphertext; full-volume paged backfill and exact
  real-peer storage accounting pass. `RELAY-CAPACITY.md` records legacy-log
  write refusal and remaining account-wide/authentication/deployment limits.
  `RELAY-AUTH.md` now records a separately tested request-proof primitive, with
  Node-to-workerd signatures and 33 relay tests passing. It is not imported by
  production routing and does not implement trusted registration, replay
  admission or permission to expose the relay publicly.
  An opt-in Rust signer and a separate bounded transactional nonce-admission
  primitive now also pass host-to-workerd and actual SQLite race/rollback tests.
  The full relay suite passes 39 checks plus one explicit Rust-fixture skip;
  that fixture independently passes all seven dedicated interoperability checks.
  Neither primitive is wired into public/app authorization yet.
  Exact namespace/operation grants now pass the full local relay suite: 44
  checks plus its explicit Rust-fixture skip (45 total). Dedicated Rust
  interoperability remains separately verified, not inferred from that skip.
  A separate explicit loopback worker now authenticates actual group read/append
  transactions, with a fixed operator policy, rollback/replay and real launcher
  checks. All 13 Rust/workerd interoperability checks pass; the full relay suite
  passes 49 checks with two separately verified fixture skips. This is not
  public/app authentication: roster transitions, mailbox/socket authorization,
  request/account quotas and authorized deployment remain open in `RELAY-AUTH.md`.
  The experimental group path now also has transaction-local per-device/group
  daily admitted-request budgets, independent of proof expiry. All 14 dedicated
  interoperability checks and 53 full-suite checks pass (two separately verified
  fixture skips). This does not bound anonymous traffic or account spending.
  Confirmed HTTP pages now persist before more networking; later refusal resumes
  from the saved cursor after restart and uncertain saves stop further requests.
  All 344 native-enabled app tests pass, including test-first encrypted restart
  regressions. `PHASE2-PROGRESS.md` and `RELAY-AUTH.md` distinguish mocked HTTP
  interruption from a real authenticated nonce-limit run; signed app networking
  and the deployment gate remain open.
  A subsequent actual SQLite/workerd read regression verifies 320-entry
  resumption after nonce-table refusal and real-time expiry, with unchanged
  history and live-proof replay rejection. The full relay suite passes 54
  checks with two separately verified skips; all 15 dedicated interoperability
  checks pass. Fixture-seeded replay rows and opaque sample entries are not
  evidence of combined app-signed MLS networking.
  The optional sync-peer signer now generates fresh random request nonces from
  the protected existing identity without modifying saved MLS/ledger state.
  Its restored-peer proof is accepted/replay-rejected by actual workerd, with
  all 16 dedicated interoperability checks passing. Full sync acceptance passes
  74 tests (two explicit live-HTTP tests remain ignored), and the complete relay
  suite passes 54 checks plus three separately verified fixture skips. CI now
  includes the peer feature without dispatching any cloud job. App bridge/client
  enablement and trusted registration/membership/mailboxes remain open.
  The app API now exposes public request proofs through regenerated FRB bindings
  (content hash `-155377132`). All 66 API tests, 346 native-enabled Flutter tests
  and the rebuilt production browser household/quota flow pass. Native signing
  itself is directly verified; the browser run exercises existing calls through
  the new ABI, not the new signing method. `PHASE2-PROGRESS.md` records exact
  artifacts/toolchains/failures. The HTTP client is still unsigned; authenticated
  end-to-end transport and final mobile/iOS acceptance remain open.
  The HTTP client now supports an optional exact-byte request-proof callback,
  including fresh invocation per page, bounded/abortable replies and no-network
  failure/deadline behavior. Scoped native/transport regressions pass; the default
  controller still has no protected-key provider, and browser/authenticated
  end-to-end acceptance for this Dart change remains open in `RELAY-AUTH.md`.
  The protected controller provider now connects its existing identity to that
  opt-in callback, with exact-byte verifier conformance and post-await lifetime
  refusal checks. All 353 native-enabled app tests pass. The default factory
  remains unsigned; no enrolment, live authenticated HTTP/MLS exchange or new
  browser/mobile acceptance is inferred from the controlled transport mock.
  A subsequent actual loopback HTTP/workerd test now restores two native app
  identities under an explicit fixed operator policy, exchanges 19 encrypted
  expenses across paged backfill and restart, and verifies `USD -20.50` plus
  replay/body-change/unknown-device refusals without history mutation. All 33
  scoped native proof, paging and HTTP checks pass (35s); analysis is clean.
  This closes native authenticated HTTP/MLS exchange for pre-trusted devices,
  not dynamic enrolment/mailboxes or current browser/mobile acceptance. Wire
  ciphertext checks are not a new audit of every persisted SQLite field.
- [x] Rust-side SQLite stores immutable frames and sealed household documents;
  checked revisions, migration, recovery and process-interruption checks passed.
  PR #18 merged after native host, iOS, Android and production WASM acceptance.
  Browser whole-image/quota and protection limits remain in `SQLITE-STORAGE.md`.
- [x] Persist checked shared fold checkpoints with per-actor frontiers, original
  signed history, late-event/duplicate rebuild and old signed archive migration;
  current native-host and production WASM checks passed. This is not pruning.
- [ ] Finish safe shared compaction or peer-snapshot recovery with offline-peer
  acknowledgements; checkpoints retain all history. Relay growth is now refused
  at per-log ceilings, but safe pruning and peer-snapshot recovery remain open.
  A saved-archive receipt/checkpoint verifier is now implemented locally in Rust;
  see `RETENTION-RECEIPTS.md`. It requires every current MLS key and exact signed
  history/frontiers; explicit encrypted exchange has local Rust/actual-worker
  evidence, and the protected-save hook has native-bridge/host-SQLite checks.
  Final platform verification and authenticated/recoverable pruning remain open.
  A locally computed cutoff is not permission to delete relay history.
  Current-source Android personal/household and separate production WASM flows
  now pass; final iOS and authenticated/recoverable pruning remain open.
- [x] Check explicit opt-in publication boundaries and chosen shared analytics;
  no private ledger or readable financial fields may reach the relay.
  Immutable opt-in totals, nonfinancial signed summary events, compatibility
  guards and publication UI now have local Rust/native-bridge/SQLite/host-widget
  evidence in `SHARED-SUMMARIES.md`. Production WASM UI and actual-worker summary
  storage audit also passed, followed by actual Android native UI/SQLite/OS-key
  restart and signed backfill. Final-source iOS/platform acceptance remains a
  separate gate. Mixed-version live support is not negotiated; all household
  devices must update before summaries are published.
  Confirmed local household writes now distinguish failed delivery from an
  uncertain save, without automatically reopening/repeating the expense form.
  All 331 native-enabled host app tests pass after this change; platform limits
  and exact commands are in `PHASE2-PROGRESS.md`.
  The explicit browser lock/reload regression passes at `d004ad9`, along
  with all 283 native-enabled host tests. The complete combined personal/CSV/
  quota/household browser runtime subsequently passes on production `43871c4`
  with driver `016d5ba`; current Android personal and household runtime also
  pass at `43871c4`. Exact evidence and remaining limits are recorded above.
- [ ] Review personal UX coverage against the stated Cashew quality bar, not
  just widget presence; fix functional gaps and verify phone/tablet/web layouts.
  Budget/goal removal, recurring stop, future-rule management and stale-post
  protection are now implemented. Goal currency/category/deadline controls
  and recurring category selection have native-host/phone widget checks and
  production Chrome runtime evidence. Remaining functional/adaptive review
  remains open. Recent-activity creation ordering is now verified, including
  same-tick queues and six-entry production-browser reload. Personal amount/category
  corrections and non-erasing removal/history have actual SQLite failure/reload
  tests, production Chrome evidence and actual Android emulator runtime evidence.
  These checks do not close the whole UX gate.
  `PERSONAL-UX-REVIEW.md` records the scoped Cashew review, repaired populated
  layout failures, permanent search/clear labels and real-production-theme
  enlarged-text/labeled/48-pixel checks. All 305 host tests and both Android
  integrations pass on app source `eb09a27`. Combined desktop Chrome passes
  there with driver `b07c1c7`, including the uncertain-save household ownership
  repair, actual search/filter and unchanged SQLite bytes. After a subsequent
  narrow title-editor readiness failure, driver `d4561e7` uses real pointer
  activation: the current 360×740 personal/CSV flow and separate desktop
  household/quota flow both pass, the latter with bounded relay pages.
  Final iOS and complete accessibility acceptance remain open; exact earlier
  failures and limited verification scope remain in the progress docs.
  Entry dropdowns now wrap fully at 200% phone text, with 40 scoped host checks
  and current production Chrome keyboard/personal/CSV acceptance passing.
  `PERSONAL-UX-REVIEW.md` distinguishes host enlarged-text checks from browser
  keyboard evidence and records the undiagnosed intermittent renderer failure.
- [x] Pin reproducible CI environments, including explicit WASM nightly,
  action revisions, Node and caches. PR #15 merged; known Flutter/FRB warnings
  remain recorded rather than hidden or upgraded without verification.
- [ ] Run final acceptance checks on the final source revision for iOS, Android,
  and production web/WASM; record commands, runtime, results and artifact paths.
- [ ] Finish concise setup, recovery, security-limit and verification docs, with
  all deliverable source and evidence synchronized to private GitHub `main`.

App-store publication, billing, telemetry, bank integrations and changing the
repository's visibility are not authorized completion shortcuts or required
prototype features. Existing reported evidence must remain distinguished from
new independent runs. No milestone completion should end the active project goal.
