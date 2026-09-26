# Phase 1 progress

Updated 2026-09-26. Phase 1 is in progress; its complete exit test has not passed.

## Multiple accounts and transfers between them

Implementation: this change, on top of the categories slice below. A
transfer is a new `EventKind::TransferRecorded` variant folded by the
ledger's existing strict fold (unlike categories, a transfer is genuinely
financial state — see `docs/DECISIONS.md`), carrying two independent
amounts (`sent`/`received`, each with its own frozen reporting-fx rate) so a
cross-currency transfer's conversion spread stays visible rather than
assumed to be zero. `LedgerState` gained a `transfers` map alongside
`transactions`; `canonical_bytes()` includes it so the byte-identical-state
exit-test property still holds with transfers present. The bridge exposes
`record_transfer` and a `transfers: Vec<TransferView>` field on
`LedgerOverview`. `AccountView` gained a `currency_code` field (previously
only encoded inside the formatted balance label), needed so the UI can tell
whether a transfer crosses currencies.

On the Flutter side, `AddTransactionSheet` is now a 3-mode entry sheet
(Expense / Income / Transfer) via a `sealed class EntryDraft` result
(`TransactionDraft` and `TransferDraft`), and expense/income entries now
pick which account they apply to instead of a hardcoded `'everyday'`. The
Overview pane's accounts card gained a "+" button to create additional
accounts (name and a currency picked from a short preset list: USD, EUR,
GBP, JPY), and the Activity pane shows transfers alongside transactions via
a new `TransferTile`.

Verified evidence, same toolchain as below (Rust 1.98.1; Flutter 3.47.5 /
Dart 3.13.4):

- Rust: `cargo test --manifest-path rust/Cargo.toml --locked --all-targets`
  passed all 45 tests (up from 35): 7 new core-level transfer tests (a
  same-currency transfer moves balance without changing the reporting total;
  a cross-currency transfer keeps its conversion spread visible in the
  reporting balance; a transfer to the same account, from an unknown
  account, or with a currency that doesn't match either account is
  rejected; a duplicate transfer ID with different content is rejected;
  transfers fold identically regardless of arrival order, matching
  `canonical_bytes()`) plus 3 new bridge-level tests (a transfer moves
  balance between two accounts and appears in the overview; a
  same-account transfer is rejected by the bridge too; a transfer survives
  restart from its persisted frame).
- Flutter: `flutter analyze` reported no issues. `flutter test test` passed
  all 13 tests across 5 files: the prior 12, plus a new
  `AddTransactionSheet` test that switching to transfer mode returns a
  `TransferDraft` between two accounts with the right default "from"/"to"
  selection. Two prior tests needed a small fix once the sheet grew a second
  dropdown (account, alongside category): they now target
  `find.byKey(const Key('categoryDropdown'))` instead of the now-ambiguous
  `find.byType(DropdownButtonFormField<String>)`.
- Extended `integration_test/ledger_test.dart` to create a second account
  ("Savings") and transfer 100.00 from the existing account into it,
  asserting the net balance stays the same total while each account's own
  balance changes correctly, then confirming a further simulated restart
  still shows it. iOS result: not yet run against this specific change as
  of writing this section — see below once the manual `phase1-ios` workflow
  completes.
- Not verified this session (no Android emulator or browser available in
  this container, same limitation as every slice above): the Android
  integration test and the web runtime check.

## Categories with icons, and titles that auto-assign on repeat

Implementation: this change, on top of the persistence slice below.
Categories are last-writer-wins soft state (build brief §2.5), kept as a
second, independent mechanism from the financial ledger: `rust/core`'s new
`categories` module has its own upsert type, its own fold that never rejects
(there is no financial invariant a category write could violate), and its
own durable log, sharing only the low-level frame codec
(`rust/core/src/frame.rs`, factored out of the existing event-log codec) with
the ledger. The bridge exposes this as a separate opaque `CategoryBook` type
alongside `PersonalLedger`; both share one `DeviceIdentity` (the actor ID is
per-device, not per-log). "Custom titles that auto-assign on repeat" needed
no new state: `suggest_category_for_title` looks up the most recent past
transaction with a matching title directly from the ledger's existing
events. The Flutter app seeds five default categories on first launch, lets
`AddTransactionSheet` pick from them (with icons) or create a new one, and
auto-selects a suggested category as the user types a title, backing off the
moment they choose one themselves. Full rationale is in `docs/DECISIONS.md`
(2026-09-26 entries) and the new Categories section of `docs/ARCHITECTURE.md`.

Verified evidence, same toolchain as below (Rust 1.98.1; Flutter 3.47.5 /
Dart 3.13.4):

- Rust: `cargo test --manifest-path rust/Cargo.toml --locked --all-targets`
  passed all 35 tests (up from 22): 13 new core tests (frame round-trip and
  checksum-failure recovery in isolation; category LWW semantics — a later
  write wins regardless of arrival order, replaying the same upsert is a
  no-op, independent categories don't interfere; category frame round-trip
  and truncation recovery), 4 new bridge tests for `CategoryBook` (upsert
  and list, re-upserting the same ID replaces it, an empty name is rejected
  and never persisted, restart recovers identical categories from persisted
  frames), and 2 new bridge tests for title-based category suggestion
  (case-insensitive/trimmed match, and following the *most recent* matching
  transaction when titles repeat with different categories).
- Flutter: `flutter analyze` reported no issues. `flutter test test` passed
  all 12 tests across 5 files: the prior 8, plus 4 new `AddTransactionSheet`
  tests (typing a title auto-selects its previous category after a debounce;
  manually choosing a category stops later auto-suggestion from overriding
  it; creating a new category selects it immediately; submitting returns the
  chosen category and amount). The existing screen tests were updated for
  the category-aware `TransactionTile` (resolves an icon and display name
  from the category list, falling back to a direction arrow and
  "Uncategorized" when a transaction's category isn't found).
- iOS: ran the manual `phase1-ios` GitHub Actions workflow on an iPhone 16
  Pro simulator against this change —
  [passing run](https://github.com/arsalmurad/cash-app/actions/runs/36266023728),
  first attempt. `flutter analyze`, `flutter test test` (12/12), the
  integration test (now including selecting "Food" from the seeded category
  dropdown for the Groceries expense, and confirming that category survives
  both simulated restarts), and `flutter build ios --release --no-codesign`
  all passed.
- Not verified this session (no Android emulator or browser available in
  this container, same limitation as the persistence slice): the Android
  integration test and the web runtime check.

## Durable local persistence and actor identity

Implementation: this change. Rust core gets a durable event-log codec
(`rust/core/src/codec.rs`); the Rust bridge gets a single load-or-create
ledger constructor plus per-mutation frame bytes for the caller to persist
(`rust/api/src/api/ledger.rs`); the Flutter app gets a platform-conditional
`EventStore` (`app/lib/data/storage/`) and a `LedgerController` that loads
from and durably appends to it. Design rationale for each choice is in
`docs/DECISIONS.md` (2026-09-26 entries) and the persistence section of
`docs/ARCHITECTURE.md`.

Design in one paragraph: `rust/core` defines a self-checking, checksummed
frame format for one event and nothing about where frames live, because Rust
compiled to WASM has no filesystem and cannot own that decision. Dart owns
storage instead: a plain append-only file in the OS-sandboxed app support
directory on iOS/Android/desktop, and base64 inside `window.localStorage` on
web — the same compile-time platform split the generated bridge bindings
already use. `load_personal_ledger` is the ledger's only constructor (an
empty log is a fresh install), so first launch and every later restart take
the same code path. A mutation only returns its event's durable frame when
the ledger actually accepted the write, so a rejected write has no bytes a
caller could persist by mistake.

Verified evidence (this session, in a Linux cloud container with no Android
emulator, iOS simulator, or browser available — see "Not verified this
session" below):

- Toolchain used: Rust 1.98.1 (rustup, matching `docs/PHASE0-RESULT.md`);
  Flutter 3.47.5 / Dart 3.13.4 (shallow clone of the `3.47.5` tag, matching
  the pinned version); `flutter_rust_bridge_codegen` 2.13.0 (`cargo install`,
  matching the pinned `flutter_rust_bridge` crate version) to regenerate the
  bridge bindings after the Rust API changed.
- Rust: `cargo test --manifest-path rust/Cargo.toml --locked --all-targets`
  passed all 22 tests (up from 9): the prior 15 (9 phase 1 + 6 renamed/updated
  api tests) plus 6 new codec unit tests, 3 new core-level persistence
  acceptance tests, and 1 additional api-level HLC-continuity test. Coverage
  added:
  - Every `EventKind` round-trips through a frame byte-for-byte, and the same
    event always encodes identically.
  - A log of 1,000 events persists and decodes back to a fold identical to
    the in-memory fold (byte-identical `canonical_bytes`).
  - A log truncated mid-frame (simulating a crash during `flush`) recovers
    every complete event before the tear and reports the exact trailing
    byte count, rather than losing everything or panicking.
  - A bit flip inside a frame is caught by its checksum and treated the same
    as truncation.
  - A write the ledger would reject (e.g. a duplicate account ID) never
    produces a frame, so replaying only the accepted frames reproduces
    exactly the pre-rejection state; if a conflicting event were persisted
    anyway, replay fails loudly instead of silently overwriting.
  - After "restart" (`load_personal_ledger` on the persisted bytes), the
    hybrid clock resumes from the persisted maximum timestamp even when the
    next wall-clock reading is lower (clock skew/reset across a restart), so
    new events still sort strictly after everything already persisted.
- Flutter: `flutter analyze` reported no issues. `flutter test test`
  (host-only, no native Rust library involved) passed all 6 tests across 3
  files: the pre-existing 2 screen tests, a new 3-test suite for
  `IoEventStore` (empty on first run, frames accumulate and survive a new
  instance, actor ID persists across a simulated restart — using a fake
  `PathProviderPlatform` pointed at a temp directory), and a new test that
  generated actor IDs are 128-bit hex and unique across 100 draws.
- Added `integration_test/ledger_test.dart` coverage for a real restart:
  after recording a transaction, the test builds a *new* `LedgerController`
  (re-reading the same on-device `IoEventStore` file and actor ID) into a
  fresh widget tree, and asserts the same and then a second transaction are
  still shown. This exercises the full on-device stack (Rust ledger +
  `IoEventStore` + controller) without depending on a device/emulator to
  author, but did need one to actually run — see below.

iOS: ran the manual `phase1-ios` GitHub Actions workflow on an iPhone 16 Pro
simulator (macOS 15 runner) against this branch. It took two fixes to get a
clean run, both real bugs the real-hardware run caught that local analysis
and host-only `flutter test` could not:

- [Run 1](https://github.com/arsalmurad/cash-app/actions/runs/36248319551)
  failed: the restart test called `app.main()` a second time, and
  `flutter_rust_bridge` refuses `RustLib.init()` twice in one process. `flutter
  analyze` and `flutter test test` (6/6) passed, and the pre-existing "records
  an expense" test passed unchanged on real hardware — the failure was in the
  new test's restart simulation, not in `EventStore`/`LedgerController`.
- [Run 2](https://github.com/arsalmurad/cash-app/actions/runs/36249302115)
  still failed the same way: fixing only the explicit second `app.main()` call
  wasn't enough, because every `testWidgets` block in the file runs in the
  same process, so the *second test's own opening* `app.main()` call was
  itself the second `RustLib.init()`. The real fix was structural: one
  `app.main()` call per file, with the restart(s) simulated afterwards by
  building a fresh `LedgerController` into a new widget tree — folded into a
  single test rather than two.
- [Run 3](https://github.com/arsalmurad/cash-app/actions/runs/36250177072),
  with that structural fix, **passed** end to end: `flutter analyze`,
  `flutter test test` (6/6), the merged `ledger_test.dart` integration test
  (record an expense, simulated restart, record a second transaction,
  simulated restart again — all on the iPhone 16 Pro simulator, UDID
  `DC4CD8B3-4457-4153-9087-A0D7A2F9BFD9`), and
  `flutter build ios --release --no-codesign` all succeeded.

Not verified this session (no Android emulator or browser available in this
container): the Android integration test and the web runtime check
(`scripts/verify_web_runtime.mjs`). These are the same manual paths the prior
milestone used and should be run before treating this slice as fully proven
end to end; results will be appended here once run.

## Personal ledger vertical slice

Implementation: `b01dd47`; clean-checkout analyzer fix: `407be59`.
The Flutter app supports a prototype USD account, expense and income entry,
balance display, and transaction history. Rust parses decimal amounts exactly
and folds immutable ledger events; Dart displays Rust-produced money labels.

Verified evidence:

- Rust: `cargo test --manifest-path rust/Cargo.toml --locked --all-targets`
  passed all 9 tests. Includes convergence over 1,000 events, frozen FX,
  zero-decimal entry/fold/display, snapshot equivalence, duplicate handling,
  and the core no-floating-point guard.
- Flutter: analysis and both widget tests passed.
- Android: x86_64 debug APK built; `flutter test
  integration_test/ledger_test.dart -d emulator-5554` passed on Android 16,
  API 36, x86_64. The real UI recorded Groceries at USD 12.34 and displayed
  the Rust-derived net balance USD -12.34.
- Web: Rust WASM and Flutter WASM builds passed; the headless Chrome runtime
  check in `scripts/verify_web_runtime.mjs` recorded the same expense and
  verified USD -12.34. This used local build artifacts, not a clean checkout.
- iOS: a clean GitHub macOS checkout passed analysis, widget tests, the same
  expense-entry integration test on an iPhone simulator, and
  `flutter build ios --release --no-codesign`.
  [Successful run](https://github.com/arsalmurad/cash-app/actions/runs/36231879830).

The first iOS run failed because app analysis included the separate vendored
Cargokit build-tool package without its dependency setup. Excluding that
tooling from application analysis resolved it; native builds still execute it.

## Remaining work

Ledger events now persist locally and survive a restart, each device keeps a
stable actor ID, categories (with icons, and titles that auto-assign on
repeat) are built, and multiple accounts plus transfers between them are
built (see above; iOS confirmed for persistence and categories, pending for
transfers as of this writing). Still open before Phase 1's exit test can be
called complete:

- Run the Android integration test and the web runtime check against every
  change above (see each section's "Not verified this session").
- The web `EventStore`'s append is read-decode-concatenate-reencode-write
  over the whole log (see `event_store_web.dart`), which is O(log size) per
  write; fine at this milestone's scale, worth revisiting (e.g. IndexedDB
  with one record per frame) if local history grows large.
- Categories can be created and assigned but not renamed, re-iconed, or
  deleted from the UI yet (the Rust/bridge upsert already supports rename;
  only the "new category" entry point exists in `AddTransactionSheet`).
- Account currency is fixed at creation (no display-currency conversion
  toggle yet); the net balance card sums accounts' reporting-currency
  equivalents but never shows the same amount converted between two
  currencies side by side.
- Recurring/upcoming transactions, budgets, goals, search and filter, CSV
  import/export, and biometric lock remain unbuilt.
- Snapshot/compaction (`cash_core::Snapshot`) exists and is tested at the
  core level but is not yet wired into the persisted log or the bridge; the
  log currently replays from event zero on every load.

Household sharing and all server/cloud features remain outside Phase 1.
