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
