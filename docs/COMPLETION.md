# Completion tracker

Updated 2026-10-01. The active objective is to finish the private prototype
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
- [ ] Make household mutations, membership commits, persistence and network
  retries safe under storage failures, concurrency and interrupted invitations.
- [ ] Protect the working household private-key state at rest on native and web;
  keep recovery and wrong-phrase handling independently tested.
- [ ] Drive the complete household scenario in the production web/WASM app,
  including browser-to-worker CORS, restart, offline edits, recovery and removal.
- [ ] Inspect the real worker's stored records for ciphertext-only contents,
  rather than relying solely on the in-memory relay privacy scan.
- [ ] Establish an authenticated, abuse-controlled, bounded-retention relay on
  the free-plan deployment path. Do not purchase services or expose a public
  unauthenticated relay. Account authorization may require the owner.
- [ ] Reconcile the locked Rust-side SQLite storage requirement with the current
  Dart file/localStorage event-store implementation, preserving durable history
  and platform compatibility; record and test the resulting architecture.
- [ ] Wire safe snapshot/compaction or peer-snapshot recovery into actual shared
  persistence, preserving causal frontiers and offline peers' acknowledgements.
- [ ] Check explicit opt-in publication boundaries and chosen shared analytics;
  no private ledger or readable financial fields may reach the relay.
- [ ] Review personal UX coverage against the stated Cashew quality bar, not
  just widget presence; fix functional gaps and verify phone/tablet/web layouts.
- [ ] Pin reproducible CI environments (including WASM nightly) and resolve
  relevant compatibility warnings without discarding known-working caches.
- [ ] Run final acceptance checks on the final source revision for iOS, Android,
  and production web/WASM; record commands, runtime, results and artifact paths.
- [ ] Finish concise setup, recovery, security-limit and verification docs, with
  all deliverable source and evidence synchronized to private GitHub `main`.

App-store publication, billing, telemetry, bank integrations and changing the
repository's visibility are not authorized completion shortcuts or required
prototype features. Existing reported evidence must remain distinguished from
new independent runs. No milestone completion should end the active project goal.
