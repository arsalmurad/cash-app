# Completion tracker

Updated 2026-10-05. Complete the private prototype against
`expense-app-build-brief.md`, not just individual milestones. This is a
current-status index; detailed history, failures and exact commands remain in
the linked evidence documents and Git. Unchecked gates are not achieved.

## Verified implementation and scoped evidence

- [x] Phase 0 OpenMLS add/remove/decryption bridge runtime on iOS, Android and
  web/WASM; pinned tools, size deltas and compatibility warnings:
  [PHASE0-RESULT.md](PHASE0-RESULT.md).
- [x] Personal app/core acceptance: deterministic 1,000-event folds, frozen FX,
  zero-decimal currencies, per-actor-frontier snapshots and no floating money.
  Earlier clean-checkout platform runs and personal feature/runtime history:
  [PHASE1-PROGRESS.md](PHASE1-PROGRESS.md).
- [x] Immutable storage and save safety: torn-log repair, checked SQLite
  revisions/migration, uncertain-save write refusal and sealed household state.
  [SQLITE-STORAGE.md](SQLITE-STORAGE.md), [PHASE2-PROGRESS.md](PHASE2-PROGRESS.md).
  Controlled faults/process interruption are not arbitrary power-loss proof.
- [x] Shared crypto/sync core: three-peer 1,000-event convergence, visible
  conflicts, original-author authentication including forwarded signed history,
  removed-member decryption rejection and frozen historical FX.
  [PHASE2-PROGRESS.md](PHASE2-PROGRESS.md) records historical-author limitations.
- [x] Invite safety-number comparison and phrase-sealed backup/wrong-phrase/
  replacement recovery have scoped native/Chrome evidence in
  [PHASE2-PROGRESS.md](PHASE2-PROGRESS.md); final-platform coverage remains below.
- [x] Opt-in chosen sharing, immutable summary events and publication UI with
  native/Chrome/Android evidence: [SHARED-SUMMARIES.md](SHARED-SUMMARIES.md).
  Private ledgers remain separate; all devices must update before summaries.
- [x] Authenticated owned-loopback HTTP: normal factory, protected request
  signatures, public operator bootstrap, atomic MLS/relay roster transitions,
  recipient-only Welcomes, saved-before-ACK/restart/downgrade guards and bounded
  retired-device catch-up. Native host, production Chrome and actual Android
  three-identity/OS-vault runs pass: [RELAY-AUTH.md](RELAY-AUTH.md),
  [PHASE2-PROGRESS.md](PHASE2-PROGRESS.md).
- [x] Real SQLite relay KV privacy audits, including roster/Welcome/retirement
  fields, exact public schemas and deliberate plaintext/binary/metadata controls.
  [RELAY-AUTH.md](RELAY-AUTH.md). Known-fixture KV inspection is not raw-file
  forensics, metadata anonymity or a formal encryption proof.
- [x] Non-destructive relay limits: streamed bodies, bounded pages, 10,000-record/
  64MiB log ceilings, replay inventories and admitted device/group budgets.
  [RELAY-CAPACITY.md](RELAY-CAPACITY.md), [RELAY-AUTH.md](RELAY-AUTH.md).
- [x] Checked shared checkpoints and encrypted saved-state receipts with exact
  signed history/frontiers; stale-prefix retirement/fresh-key rejoin recovery:
  [RETENTION-RECEIPTS.md](RETENTION-RECEIPTS.md). These do not prune history.
- [x] Pinned CI/toolchains and action revisions. Existing source-specific iOS/
  Android/Chrome runs are evidence only for their recorded revisions.

## Remaining completion gates

1. [ ] Authorized free-plan relay: trusted public registration/authorization,
   anonymous/account-wide abuse and spending bounds, authenticated sockets with
   hibernation, and actual deployment verification. Default public routing stays
   closed. Do not deploy or dispatch cloud jobs until the owner verifies a $0
   spending cap; do not buy services or expose an anonymous relay.
   An explicit local authenticated notification path now passes actual workerd
   native/browser-compatible signatures, current-roster removal/read revocation,
   128-socket caps/quota rollback and host Rust interoperability:
   [RELAY-NOTIFICATIONS.md](RELAY-NOTIFICATIONS.md). App notification lifecycle,
   actual cloud hibernation and public registration/deployment stay open.
2. [ ] Crash-safe authenticated pruning or peer-snapshot recovery with confirmed
   offline-peer acknowledgements and recoverable availability. Every current MLS
   key must acknowledge the exact checkpoint; a computed cutoff/TTL is never
   permission to delete financial history. Retained checkpoints/receipts and
   per-log growth refusal alone do not close this gate. Internal bounded SQLite
   prefix mechanics now have fault/restart and app-compatibility evidence in
   [RELAY-PREFIX-FLOOR.md](RELAY-PREFIX-FLOOR.md). Separate all-current-key
   consent now authorizes bounded deletion only in explicit loopback opt-in mode
   ([PREFIX-CONSENT.md](PREFIX-CONSENT.md)); default routes remain disabled,
   and signed app-controller coordination now passes actual native HTTP deletion,
   failed/stale archive reads and fresh-key recovery. Explicit app controls pass
   scoped confirmation/phone/keyboard widget tests. Actual Android OS-protected
   consent/pruning, stale sealed-archive refusal and fresh-key/restart recovery
   now pass. Production Chrome explicit consent/pruning, protected reload and
   fresh-key recovery also pass after repairing complete-code accessibility.
   Actual same-origin duplicate unlock refusal and foreground lock/close lease
   transfer pass; the full matching native-enabled suite passes 424 tests.
   Actual authenticated browser quota refusal/restart and observed asynchronous
   lock release also pass in the complete production consent/recovery journey.
   Remaining lifecycle faults and final-platform coordination remain open.
3. [x] Implement and verify the brief's explicit MLS key-rotation operation,
   including immutable/durable commit retry and authenticated epoch coordination.
   Standalone self-update now has native core/bridge/controller, actual
   authenticated HTTP and production Chrome evidence in
   [KEY-ROTATION.md](KEY-ROTATION.md), plus actual authenticated Android with
   protected-store restart and later removal. Final iOS remains under gate 5.
4. [ ] Finish the personal functional/adaptive/accessibility review against the
   requested Cashew quality bar and Phase 1 scope, across phone/tablet/web.
   Accounts/multi-currency; expense/income/transfer/recurring/upcoming; categories/
   icons/custom titles with automatic category assignment; custom-period/category
   budgets; saving/spending goals; search/filter; local persistence/native
   biometric lock; CSV; light/dark Material 3.
   [PERSONAL-UX-REVIEW.md](PERSONAL-UX-REVIEW.md) records scoped repairs and
   unverified behavior. Widget presence or limited guideline checks are not an
   overall UX/accessibility pass.
   The latest category-list bottom-action repair passes a six-case 200%-text
   pointer/cancel matrix and 28 adjacent host tests; updated production
   narrow thirty-row production Chrome pointer/edit/reload now also passes;
   updated mobile and 200% browser-zoom verification remain open. The icon
   picker now exposes twelve human-readable names and selected states, with
   36 adjacent host tests and rebuilt narrow production Chrome personal/CSV/
   keyboard/offline-font acceptance passing. Updated Android x86_64 release
   also passes actual native picker names/selected states/cancellation and
   exact-balance process restart; both rebuilt splits pass packaging checks.
   Thirty-row mobile, screen-reader and complete accessibility gates stay open.
5. [ ] Final-source acceptance on iOS, Android and production web/WASM, including
   reproducible release artifacts, exact runtime commands and platform limits.
   Previous ABI `970902974` passed production authenticated Chrome and Android
   journeys. New key-refresh ABI `-1323392253` passes native-host and production
   Chrome and authenticated Android acceptance. New consent ABI `1237803201` passes regenerated native API
   tests, actual native controller pruning/recovery and authenticated Android
   debug-emulator OS-vault pruning/recovery, plus production Chrome explicit
   consent/pruning, protected reload and fresh-key recovery. A correctly filtered
   current x86_64 production release APK also passes actual UI expense/exact
   balance, process restart and confirmed removal: [ANDROID-RELEASE.md](ANDROID-RELEASE.md).
   Current ARM64 and x86_64 release splits now pass exact-ABI/ELF/16 KB ZIP and
   segment-layout packaging checks, with explicit final-library Android link
   boundaries. The rebuilt x86_64 split repeats the actual production UI and
   process-restart pass; ARM packaging is not a phone runtime claim.
   ARM phone/16 KB OS/release household runtime, clean-checkout and final iOS remain
   unverified. Older runs are not a
   final-source completion claim.
6. [ ] Concise setup/recovery/security/verification handoff, complete deliverable
   source and evidence synchronized to GitHub `main`. Local diagnostic
   logs/caches are ignored; repeatable tests and evidence summaries are tracked.
   Start with [LOCAL-RELAY-SETUP.md](LOCAL-RELAY-SETUP.md),
   [RELAY-AUTH.md](RELAY-AUTH.md), [PHASE2-PROGRESS.md](PHASE2-PROGRESS.md).

## Scope and local build safety

Preserve private ledgers, ciphertext-only selected sharing, no shared login,
i64/rational money, immutable idempotent events, deterministic total order,
causal frontiers, canonical convergence and visible conflicts (`AGENTS.md`).
App-store publication, billing, telemetry, bank integration and repo visibility
changes are not completion shortcuts or required prototype features.

On 2026-10-05, the authenticated repository API reports
`arsalmurad/cash-app` as public (`private: false`, owner type `User`), contrary
to earlier private-repository handoff wording. No visibility change was made.
Private financial ledgers and ciphertext-only relay requirements are unchanged.
GitHub documents standard `macos-15` runner time as free for public repositories
([runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners),
[billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions));
the existing iOS workflow adds no artifact uploads or action-cache storage.
Nevertheless, the cloud-dispatch safety review refused execution without the
owner's verified $0 Actions spending cap. No job was dispatched. Final iOS
acceptance remains pending; do not bypass that rejection or change visibility.

On this Windows host, generated Android output, Flutter build cache and native
Rust cache use ignored junctions to D:. Preserve the junctions and backing
directories, including the native plugin's `intermediates` and four-file
`jniLibs` cache relocations recorded
in [ANDROID-RELEASE.md](ANDROID-RELEASE.md); check free space before builds. A full-disk APK once omitted its
Dart kernel despite a successful build. Exact recovery/toolchain details are
in [PHASE2-PROGRESS.md](PHASE2-PROGRESS.md).

Keep the full active objective. Never mark completion from a milestone, build
alone, older platform evidence or merely compatible/narrow tests.
