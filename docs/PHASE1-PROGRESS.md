# Phase 1 progress

Updated 2026-09-30. Phase 1 is in progress; its complete exit test has not passed.

## Web runtime verification

Web support works; the earlier "blocked on an upstream limitation" finding
(see "Web: root cause found, not fixed" below, kept for the history) only
applied to running the integration test through `flutter drive`, which
compiles to JavaScript. The production `flutter build web --wasm` build
runs the Rust bridge correctly. `scripts/verify_web_runtime.mjs` (now
cross-platform: Windows, Linux, CI) serves that build with COOP/COEP
headers and drives real Chrome: it records "Groceries" (USD 12.34) through
the UI and the Rust bridge, reloads the page, confirms the ledger is rebuilt
from `localStorage`, records "Rent" (USD 500.00), reloads again, and
confirms both entries and the USD -512.34 balance. See `docs/DECISIONS.md`
(2026-09-30) for why this replaced `flutter drive` in `phase1-web.yml`.

Verified evidence:

- Local: the script passed against a fresh `flutter_rust_bridge_codegen
  build-web` + `flutter build web --wasm --no-web-resources-cdn` of the
  current code, in Chromium 141 (`Web runtime verification passed.`, all
  four `Verified ...` lines).
- CI: `phase1-web.yml` was rewritten to run the same script; its first real
  run is recorded under "Web runtime verification: CI result" once
  dispatched (not yet run at the time of writing).
- Found and fixed along the way: the add-entry sheet was not scrollable, so
  it overflowed on short viewports; `AddTransactionSheet` now scrolls, with
  a test that fails without the fix. `flutter test` passes 65 tests;
  `flutter analyze` is clean.
- Not covered on web: the account-creation, transfer, and category-dropdown
  steps that `integration_test/ledger_test.dart` exercises on iOS/Android.

## Budget, goal, and recurring-rule rename

Implementation: this change. `NewBudgetDialog`, `NewGoalDialog`, and
`NewRecurringDialog` each gained an optional `existing` parameter that
pre-fills the form and switches the title to "Edit ..." — the same pattern
`CategoryEditDialog` established (see "Category rename" below and
`docs/DECISIONS.md`). `LedgerController.addOrUpdateBudget`/`addOrUpdateGoal`/
`addOrUpdateRecurring` already accepted an optional ID for exactly this
(see their Phase 1 slices above); only the UI edit entry point and
pre-filling were missing. `BudgetsPane`/`GoalsPane`/`RecurringPane` each
gained an `onEdit` callback and an edit icon per row/card, wired in
`LedgerScreen` by refactoring `_addBudget`/`_addGoal`/`_addRecurring` into
`_editBudget`/`_editGoal`/`_editRecurring` that accept an optional existing
view (`null` for the original "Add" entry points).

Two pre-filling wrinkles worth recording:

- `BudgetView.periodLabel` is a display string ("This week", "This month",
  "This year", "Last N days" — see `period_label` in
  `rust/api/src/api/budgets.rs`), not the `BudgetPeriodKind` enum the dialog
  needs to pre-select. It's parsed back from those four deterministic shapes
  rather than adding a bridge field just to round-trip what the label
  already encodes.
- Neither `NewGoalDialog` nor `NewRecurringDialog` has ever had UI for a
  goal's `categoryId`/`deadlineMillis` or a recurring rule's `categoryId`
  (see each feature's original Phase 1 slice above) — editing without also
  collecting them would have silently cleared them on save. `GoalDraft`
  and `RecurringDraft` now carry those fields through unchanged from
  `existing` rather than defaulting them to null, so editing a goal or rule
  that already has one doesn't lose it; adding UI to actually set them
  remains open (see "Remaining work" below, unchanged from before this
  change for goals' category/deadline, newly noted here for recurring's
  category).

Verified evidence, same toolchain as below (Rust 1.98.1; Flutter 3.47.5 /
Dart 3.13.4):

- No Rust changes were needed — same reasoning as category rename below.
- Flutter: `flutter analyze` reported no issues. `flutter test` passed all
  64 tests across 14 files: the prior 58, plus 6 new tests (2 per pane:
  tapping a card/row's edit icon invokes `onEdit` with the right
  budget/goal/rule; the corresponding dialog in edit mode pre-fills its
  fields from `existing` and, for the budget case, correctly parses a
  custom period back out of its label; the recurring case also confirms an
  edited rule's existing `categoryId` survives the round trip even though
  the dialog has no field for it).
- `cargo test --workspace` still passes all 84 tests, confirming no Rust
  behavior changed.
- iOS/Android/web runtime verification not run, for the same reason as
  category rename below (UI-only, no bridge/native surface, already
  covered by widget tests).

## Category rename

Implementation: this change. `CategoryEditDialog` generalizes the "new
category" dialog to also handle editing (see `docs/DECISIONS.md`), and
`LedgerController.updateCategory` reuses the existing `upsertCategory`
bridge call with the category's existing ID rather than needing any
Rust/bridge change. `CategoriesScreen`, reachable from `LedgerScreen`'s
overflow menu ("Manage categories"), lists every category with an edit
action per row.

Verified evidence, same toolchain as below (Rust 1.98.1; Flutter 3.47.5 /
Dart 3.13.4):

- No Rust changes were needed — this feature only calls the existing
  `upsert_category` bridge function with a different (pre-existing) ID.
- Flutter: `flutter analyze` reported no issues. `flutter test` passed all
  58 tests across 14 files: the prior 54, plus 4 new `categories_screen.dart`
  tests (the empty state shows no categories; each category lists its name
  and icon; editing a category opens the dialog pre-filled and saves the
  rename through `onUpdate`; the "New category" button still creates a
  category through `onCreate`).
- iOS/Android/web runtime verification not run for this change — it has no
  bridge surface and is fully covered by the widget tests above; a full CI
  dispatch was judged unnecessary for a UI-only change with no native or
  Rust-bridge risk (unlike the Phase 1 slices above, which each touched the
  bridge, native platform config, or WASM build).

## Biometric lock

Implementation: this change. The one feature in Phase 1 so far that needs a
native plugin (`local_auth`) rather than pure Dart: `BiometricLockGate`
(`app/lib/features/lock/biometric_lock_gate.dart`) gates the whole app
behind device authentication when the user turns it on, persisted via a new
`LockPreferenceStore` (`app/lib/data/storage/lock_preference.dart`, same
native-file/`localStorage` split as `EventStore`, but its own small store —
see `docs/DECISIONS.md`). No Rust or bridge changes were needed: whether the
app is locked is UI state, not ledger state. `local_auth` has no web
implementation, so the gate always shows its content directly on web rather
than an unpassable lock screen; it also re-locks on every app resume from
the background, not just at cold start (see `docs/DECISIONS.md` for both).
A new `LockSettingsDialog`, reachable from `LedgerScreen`'s overflow menu
("Screen lock"), lets the user turn the lock on or off, showing an
unsupported message when the platform reports no usable biometric/passcode
setup.

Native platform config changed for this feature: `ios/Runner/Info.plist`
gained `NSFaceIDUsageDescription` (required by iOS for any Face ID prompt),
and Android's `MainActivity.kt` now extends `FlutterFragmentActivity`
instead of `FlutterActivity` (`local_auth`'s Android implementation requires
a `FragmentActivity` to show its biometric prompt).

While building this, found and fixed a real bug before it shipped: the
settings dialog's initial load had no error handling, so if reading the
lock preference or checking device support ever threw, the dialog would
show a loading spinner forever instead of surfacing a state — caught by a
widget test whose `pumpAndSettle` never completed. Fixed by wrapping the
load in a `try`/`catch` that falls back to "unsupported" on failure, and by
making `LockSettingsDialog` accept an injectable `LockPreferenceStore` (the
same constructor-injection pattern already used throughout this app) so
tests don't need to fake `path_provider` just to exercise the dialog.

Verified evidence, same toolchain as below (Rust 1.98.1; Flutter 3.47.5 /
Dart 3.13.4):

- Rust: no changes; `cargo test --workspace` still passes all 84 tests,
  unchanged from the recurring-transactions milestone above.
- Flutter: `flutter analyze` reported no issues. `flutter test` passed all
  54 tests across 13 files: the prior 49, plus 3 new `BiometricLockGate`
  widget tests (shows the child directly when the lock is off; shows a lock
  screen and unlocks after successful authentication, using a fake
  `LocalAuthPlatform`; stays locked when authentication fails) and 2 new
  `LockSettingsDialog` widget tests (shows an unsupported message when the
  device has no lock; toggling the switch persists the preference).
- iOS: verified. This is the first feature this session that changes
  native platform files (`Info.plist`, `MainActivity.kt`) rather than only
  Dart/Rust, so it carried more build risk than earlier milestones. Run
  36274318774 completed and passed on real iOS hardware:
  https://github.com/arsalmurad/cash-app/actions/runs/36274318774. (The
  recurring-transactions run dispatched just before it, 36273467653, was
  superseded and auto-cancelled when this one started — same pattern as
  the earlier budgets/goals runs — but since this commit's tree includes
  the recurring-transactions code too, this run verifies both.)
- Android/web runtime verification is not yet run this session — see
  "Remaining work" below.

## Recurring transactions and upcoming occurrences

Implementation: this change. A fourth independent LWW mechanism,
`recurring.rs` in `rust/core`, alongside `categories.rs`, `budgets.rs`, and
`goals.rs`. Extracted the Hinnant calendar conversions shared with budgets
into a new `calendar.rs` module (adding `add_months`, which clamps to a
shorter target month) so the two features can't silently drift apart under
a future edit — see `docs/DECISIONS.md`. `EventKind::TransactionRecorded`
and `TransactionState` gained an optional `recurring_id` (a real, if small,
change to the ledger's own event shape, folded into `canonical_bytes()`),
tagging a transaction with the rule that generated it rather than adding a
second event type for "a recurring transaction happened." The bridge
(`rust/api/src/api/recurring.rs`) adds `RecurringBook`, `upsert_recurring`,
and `upcoming_occurrences`, which computes each rule's next due date fresh
by finding the latest matching transaction in the ledger and stepping
forward — no separate "last generated" pointer that could drift from what
was actually recorded (see `docs/DECISIONS.md`).

On the Flutter side, `LedgerController` gained a fifth durable log
(`EventStore('recurring')`), a `RecurringBook`, and an `upcoming` list
(14-day horizon) refreshed after every ledger mutation (recording an
occurrence advances its own rule) and every recurring mutation.
`recordUpcoming` records a due occurrence through the same `record` method
as a hand-entered transaction, just passing the rule's ID along.
`RecurringPane` (`app/lib/features/ledger/recurring_pane.dart`) is a fifth
destination in `LedgerScreen`'s navigation, listing occurrences soonest
first with a "Record" button per row (overdue ones highlighted); a
`NewRecurringDialog` collects a title, kind, amount, account, frequency,
and start date.

Verified evidence, same toolchain as below (Rust 1.98.1; Flutter 3.47.5 /
Dart 3.13.4):

- Rust: `cargo test --workspace` passed all 84 tests (37 core + 1
  money_lint + 3 persistence_acceptance + 6 phase1_acceptance + 7
  transfer_acceptance + 30 api — up from 64 before this change), including
  3 new `calendar.rs` tests (leap-year round trip, `add_months` clamps to
  a shorter month, `add_months` handles a full year rollover), 10 new
  `recurring.rs` unit tests (last-writer-wins ordering; a rule round-trips
  through the frame codec for every frequency; a rule with no category
  round-trips; the first occurrence is the start date itself; daily/
  weekly/monthly/yearly steps advance correctly, with monthly clamping at
  a shorter month's end; a start date in the past resumes after the last
  recorded occurrence; an `after` before the start date still returns the
  start date), and 4 new bridge-level tests in `api::recurring` (a new
  rule is upcoming at its start date; a rule outside the horizon is not
  returned; recording the current occurrence advances the next one; a
  restart recovers a rule from its persisted frame).
- Flutter: `flutter analyze` reported no issues. `flutter test` passed all
  49 tests across 11 files: the prior 46, plus 3 new `RecurringPane`/
  `NewRecurringDialog` widget tests (the empty state prompts to add a
  recurring rule; an upcoming occurrence shows its title, amount, and due
  date, and records on tap; the dialog returns a `RecurringDraft`).
- iOS: verified. The run dispatched directly on this commit (ab4147b, run
  36273467653) was superseded and auto-cancelled by the biometric-lock
  dispatch that followed it; that later run (36274318774, whose tree
  includes this commit's code) completed and passed — see the
  biometric-lock section above for the link.
- Android/web runtime verification is not yet run this session — see
  "Remaining work" below.

## CSV import and export

Implementation: this change. Entirely client-side, like search/filter: a
hand-written RFC 4180 CSV codec (`app/lib/features/ledger/csv_transactions.dart`)
with `buildTransactionsCsv` (export) and `parseTransactionsCsv` (import),
covering non-transfer transactions only (see `docs/DECISIONS.md` for why
transfers are excluded). `LedgerController.exportTransactionsCsv()` and
`importTransactionsCsv(csvText)` wire this to the loaded overview; import
replays each valid row through the existing `record` method, so an
imported transaction is validated and persisted exactly the way a
hand-entered one is, and a row that fails is reported rather than silently
dropped. The UI adds an overflow menu to `LedgerScreen`'s app bar with
"Export CSV" (shows the CSV text with a copy-to-clipboard button,
`ExportCsvDialog`) and "Import CSV" (a paste-CSV text field,
`ImportCsvDialog`) — the clipboard stands in for a native file
picker/file-save integration this session can't verify on Android or web
(see `docs/DECISIONS.md`).

Verified evidence, same toolchain as below (Rust 1.98.1; Flutter 3.47.5 /
Dart 3.13.4):

- No Rust changes were needed — this feature is entirely Dart, reusing the
  existing `record` bridge call. `cargo test --workspace` still passes all
  64 tests, unchanged from the goals milestone above.
- Flutter: `flutter analyze` reported no issues. `flutter test` passed all
  46 tests across 10 files: the prior 31, plus 13 new `csv_transactions.dart`
  unit tests (CSV parsing handles plain rows, quoted fields with embedded
  commas and doubled quotes, and a final row with no trailing newline;
  field encoding quotes only when needed; export produces the expected
  header and rows; import matches accounts/categories by name, accepts a
  header-less CSV, treats a blank category as valid, rejects an unknown
  account or invalid kind, rejects a missing title or amount, and ignores
  blank lines) and 2 new `csv_import_export.dart` widget tests (the export
  dialog shows the CSV text; the import dialog's Import button stays
  disabled until text is entered, then returns that text).
- iOS: verified, covered by run 36274318774 (see the biometric-lock section
  above), whose commit tree includes this feature's code.
- Android/web runtime verification is not yet run this session — see
  "Remaining work" below.

## Goals for saving and spending

Implementation: this change. A third independent LWW mechanism, `goals.rs`
in `rust/core`, alongside `categories.rs` and `budgets.rs`. A goal is
`Save` (progress is a linked account's current balance) or `Spend`
(progress is the total of matching expenses since the goal's own creation,
optionally scoped to a category, up to an optional deadline). The bridge
(`rust/api/src/api/goals.rs`) validates the kind/field pairing at
`upsert_goal` — a save goal must link an account and must not set a
category; a spend goal must not link an account — and `goal_progress`
computes each goal's progress fresh: a save goal's from `AccountState`'s
existing `native_balance_minor` (no new ledger state needed), a spend
goal's by scanning the ledger's expenses and the goal book's own upsert
history to find when the goal was first created (see `docs/DECISIONS.md`
for why that isn't a stored field).

On the Flutter side, `LedgerController` gained a fourth durable log
(`EventStore('goals')`), a `GoalBook`, and a `goals` list refreshed via
`_refreshGoalProgress()` after every ledger mutation (an expense or a
linked account's balance change moves a goal's progress) and every goal
mutation, mirroring the budgets wiring exactly. `GoalsPane`
(`app/lib/features/ledger/goals_pane.dart`) is a fourth destination in
`LedgerScreen`'s navigation, showing each goal as a card with a progress
bar and "progress of target"/percent text; a save goal's bar fills toward
completion, a spend goal's bar turns red past 100%. `NewGoalDialog` picks a
name, kind (Save toward a target / Spend under a cap), target amount, and
— for a save goal — which account to link.

Verified evidence, same toolchain as below (Rust 1.98.1; Flutter 3.47.5 /
Dart 3.13.4):

- Rust: `cargo test --workspace` passed all 64 tests (25 core + 1
  money_lint + 3 persistence_acceptance + 6 phase1_acceptance + 7
  transfer_acceptance + 26 api — up from 58 before budgets), including 4
  new `goals.rs` unit tests (a later write wins regardless of arrival
  order; a save goal round-trips through the frame codec; a spend goal
  with no category or deadline round-trips; a spend goal with a category
  round-trips) and 6 new bridge-level tests in `api::goals` (a save goal
  tracks its linked account's balance; a spend goal sums matching expenses
  since its own creation; a spend goal ignores expenses recorded before it
  was created; a save goal must link an account; a spend goal cannot link
  an account; a restart recovers a goal from its persisted frame).
- Flutter: `flutter analyze` reported no issues. `flutter test` passed all
  31 tests across 8 files: the prior 26, plus 5 new `GoalsPane`/
  `NewGoalDialog` widget tests (the empty state prompts to add a goal; a
  save goal card shows its progress toward the target; a spend goal past
  its cap is shown as over; the dialog returns a save `GoalDraft` with a
  linked account; the dialog returns a spend `GoalDraft` with no account).
- iOS: verified. Run 36271282667 (commit bd482c2, the budgets commit) hung
  at the "Prepare and test Flutter project" step for over an hour with no
  step progress, unlike the 6-10 minute runs typical on this branch — that
  run was superseded and cancelled. A fresh dispatch on this goals commit
  (8f7a931, run 36271793365) completed normally and passed:
  https://github.com/arsalmurad/cash-app/actions/runs/36271793365. Since
  that commit's tree includes both the budgets and goals code, this run
  verifies both features on real iOS hardware, not just goals.
- Android/web runtime verification for both budgets and goals is not yet
  run this session — see "Remaining work" below.

## Budgets with custom time periods and per-category limits

Implementation: this change. A new independent LWW mechanism, `budgets.rs`
in `rust/core`, mirroring `categories.rs`'s pattern (own upsert type, own
never-rejecting fold, own durable log). A `BudgetPeriod` is `Weekly`,
`Monthly`, `Yearly`, or a rolling `Custom { days }`; calendar-aligned
periods use Howard Hinnant's integer civil-calendar algorithm (see
`docs/BORROWED.md`) rather than a date/chrono dependency. `TransactionState`
gained a fixed `recorded_at_millis` field (the creating event's own
timestamp, never touched by later amount adjustments) so a budget's period
filtering has a stable answer to "when did this happen." The bridge module
`rust/api/src/api/budgets.rs` adds `BudgetBook`, `upsert_budget`, and
`budget_progress` (which recomputes spend fresh from the ledger's expenses
on every call rather than storing a running total — see `docs/DECISIONS.md`
for why). `BudgetPeriodKind` is a field-less bridge enum, with `Custom`'s
day count passed as a separate parameter, avoiding a `freezed` Dart
dependency for one field.

On the Flutter side, `LedgerController` gained a third durable log
(`EventStore('budgets')`), a `BudgetBook`, and a `budgets` list refreshed
via `_refreshBudgetProgress()` after *every* ledger mutation (not just
budget mutations, since recording an expense changes every matching
budget's progress) and after every budget mutation. `BudgetsPane`
(`app/lib/features/ledger/budgets_pane.dart`) is a new third destination in
`LedgerScreen`'s navigation (rail on wide layouts, bottom nav otherwise),
showing each budget as a card with its period label, a progress bar
(colored to indicate overspend), and "spent of limit"/percent-used text.
`NewBudgetDialog` collects a name, an optional category (or "All
categories"), a limit amount, and a period, including a day count when
`Custom` is chosen. The floating action button switches from "Add"
(transaction) to "Add budget" when the Budgets tab is selected.

Verified evidence, same toolchain as below (Rust 1.98.1; Flutter 3.47.5 /
Dart 3.13.4):

- Rust: `cargo test --workspace` passed all 58 tests (21 core + 1
  money_lint + 3 persistence_acceptance + 6 phase1_acceptance + 7
  transfer_acceptance + 20 api), including 8 new `budgets.rs` unit tests
  (calendar round-trips across a leap-year boundary; weekly periods start
  on Monday; monthly periods start on the 1st; yearly periods start on
  January 1st; a custom period is a rolling window including today; upsert
  round-trips through the frame codec; last-writer-wins ordering) and 5 new
  bridge-level tests in `api::budgets` (upserting a budget lists it with
  zero progress; spending in a budget's category advances its progress;
  a budget with no category covers every expense; spending before the
  period start does not count; a restart recovers a budget from its
  persisted frame).
- Flutter: `flutter analyze` reported no issues. `flutter test` passed all
  26 tests across 6 files: the prior 22, plus 4 new `BudgetsPane`/
  `NewBudgetDialog` widget tests (the empty state prompts to add a budget;
  a budget card shows its name, period, resolved category name, spend, and
  percent; a budget with no category shows "All categories"; the dialog
  returns a `BudgetDraft` with a custom period and day count).
- iOS: verified. The run dispatched directly on this commit (bd482c2, run
  36271282667) hung and was superseded; a later run on the goals commit
  (8f7a931, run 36271793365, whose tree includes this commit's code)
  completed and passed — see the goals section above for the link.
  Android/web runtime verification is not yet run this session.

## Search and filter

Implementation: this change. `ActivityFilter`
(`app/lib/features/ledger/activity_filter.dart`) is a pure Dart function
over the already-loaded `LedgerOverview` — text search (title or resolved
category name, case-insensitive), a kind filter (All/Expense/Income/
Transfer), and an account filter, composed together. No Rust or bridge
change was needed except adding `account_id` to `TransactionView` (a real
gap: transactions were tied to an account in the core all along, but the
bridge never surfaced it, so per-account filtering had nothing to filter
on). Rationale for keeping this entirely client-side is in
`docs/DECISIONS.md`.

`ActivityPane` gained a search box and filter chips above the activity
list; both `TransactionTile`/`TransferTile` lists narrow live as the query
or filters change, with a distinct empty state ("Nothing matches this
search or filter") from the true first-run empty state.

Verified evidence, same toolchain as below (Rust 1.98.1; Flutter 3.47.5 /
Dart 3.13.4):

- Rust: `cargo test --manifest-path rust/Cargo.toml --locked --all-targets`
  passed all 45 tests (the `TransactionView.account_id` addition is a bridge
  field, not new core logic, so no new Rust test was needed beyond
  confirming the existing suite still passes with the field threaded
  through).
- Flutter: `flutter analyze` reported no issues. `flutter test test` passed
  all 22 tests across 6 files: the prior 13, plus 7 new `ActivityFilter`
  unit tests (inactive filter is a no-op; query matches title
  case-insensitively; query matches the *resolved category name*, not just
  the title; kind filter narrows correctly for transactions and transfers;
  account filter matches a transaction's own account and either leg of a
  transfer; `copyWith` composes correctly) and 2 new `ActivityPane` widget
  tests (typing in the search box narrows the shown entries; choosing the
  Income chip filters to income only).
- iOS/Android/web runtime verification for this change specifically is
  batched with the next feature below rather than run separately — see its
  section for the combined result, to avoid a CI round trip for a
  low-bridge-risk, UI-only feature that `flutter analyze`/`flutter test`
  already covers thoroughly.

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
  still shows it. Ran the manual `phase1-ios` GitHub Actions workflow on an
  iPhone 16 Pro simulator against this change —
  [passing run](https://github.com/arsalmurad/cash-app/actions/runs/36267872047),
  first attempt: `flutter analyze`, `flutter test test` (13/13), the full
  integration test including the new account-creation and transfer steps,
  and `flutter build ios --release --no-codesign` all passed.
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

## Android and web CI infrastructure

Implementation: this change. Every feature above was verified on real iOS
hardware but had no path to Android or web verification, because this
session's environment has neither an Android emulator nor a browser capable
of driving Flutter's `integration_test` harness. Rather than leave that as
a permanent gap, added `.github/workflows/phase1-android.yml` and
`phase1-web.yml`, mirroring `phase1-ios.yml`'s manual `workflow_dispatch`
pattern, so the same personal-ledger integration test
(`integration_test/ledger_test.dart`) can actually run on both platforms
via GitHub Actions' macOS runners (which have the Android emulator's
hardware acceleration and a real Chrome) rather than staying unverifiable.

What was actually confirmed in this session, directly, before committing
either workflow (not on GitHub Actions — this environment has a system
Rust/Flutter toolchain and a Playwright-provisioned Chromium, which made
this possible without waiting on CI):

- Compiling `rust/api`'s crate to `wasm32-unknown-unknown` via
  `flutter_rust_bridge_codegen build-web` succeeds, using a nightly Rust
  toolchain that `build-web` requires regardless of this project's own
  pinned stable Rust (confirmed by trying the pinned 1.98.1 stable
  toolchain first, which fails immediately with a `-Z build-std` error) —
  matching what `docs/PHASE0-RESULT.md` already found for the earlier
  OpenMLS spike's own WASM build, even though Phase 1's own crates have no
  OpenMLS/crypto dependency and so were not guaranteed to hit the same
  nightly requirement.
- `wasm-pack`'s bundled `wasm-opt` step failed to download its `binaryen`
  release asset in this environment; since it's a size optimization with no
  bearing on correctness, it's now disabled via Cargo package metadata
  (`wasm-opt = false`) rather than treated as a build failure to work
  around every time — see `docs/DECISIONS.md`.
- Installing `wasm-bindgen-cli` 0.2.129 directly (rather than letting
  `wasm-pack` auto-install it) was necessary: `wasm-pack` leaks the WASM
  target's `RUSTFLAGS` into that auto-install's own native host build,
  breaking its linker step. This is a `wasm-pack` behavior, not a project
  bug, but the workflow installs it explicitly up front to avoid hitting it.
- `flutter build web --wasm` succeeds and produces a working `build/web`
  deployment.
- Running `integration_test/ledger_test.dart` against that build failed
  locally: `flutter test` flatly refuses web devices for `integration_test`
  ("Web devices are not supported for integration tests yet"), and the
  `flutter drive` + ChromeDriver path that Flutter's own docs prescribe
  instead hung waiting for Chrome's debug connection in this specific
  sandbox (headless Chromium running as root, no GPU, a
  several-major-versions-mismatched ChromeDriver were all in play at once,
  any of which could be the cause) — this looks like an artifact of this
  particular container rather than of the app, but it was not resolved
  here, and `phase1-web.yml` has not actually been run end-to-end yet.
- The Android workflow (`phase1-android.yml`) was not tried locally at
  all — a hardware-accelerated Android emulator isn't something this
  environment has, unlike the Chromium binary that made the web
  investigation above possible.

In short: both new workflows are informed by real, direct investigation
of what Phase 1's own code needs for the WASM/web toolchain (not assumed
from the Phase 0 spike's requirements), but **neither had completed a
real run yet at the time they were written** — both needed to actually be
dispatched and their results recorded honestly, the same way every iOS
workflow run above was, before Android/web verification could be marked
done. That dispatching happened next; see below for the real results and
what it took to get there.

### Android: real result

`phase1-android.yml`'s first several real runs failed, each for a distinct,
diagnosed reason rather than being retried blindly:

- **`runs-on: macos-15` can't run any Android emulator at all.** Once
  dispatched for real, every boot attempt failed with `HVF error:
  HV_UNSUPPORTED` from QEMU, regardless of AVD architecture or API level.
  GitHub-hosted Apple Silicon macOS runners are themselves nested VMs and
  don't expose `Hypervisor.framework` to processes running inside them, so
  no Android emulator architecture can be hardware-accelerated there — a
  hard platform limitation, not a workflow bug
  ([actions/runner-images#9472](https://github.com/actions/runner-images/issues/9472),
  [ReactiveCircus/android-emulator-runner#350](https://github.com/ReactiveCircus/android-emulator-runner/issues/350)).
  Fixed by moving the job to `runs-on: ubuntu-latest` with a
  `sudo udevadm`-based "Enable KVM group perms" step and `arch: x86_64`
  (the host's own architecture) — this is also this action's own
  documented recommended setup, not just a workaround.
- **The action tears the emulator down as soon as its `script` input
  returns.** The first `ubuntu-latest` run booted the emulator
  successfully (`Boot completed in 41130 ms`), but a *separate*,
  subsequent workflow step then saw "No devices are connected" — the
  emulator was already gone. Fixed by moving the actual
  `flutter test integration_test/ledger_test.dart` invocation into the
  `script:` block itself, after `adb devices`.
- **`-d android` is not a valid flutter device selector.** With the
  emulator alive at test time, `flutter test ... -d android` still failed:
  "No supported devices found with name or id matching 'android'". Fixed
  by selecting the emulator by its real listed id, `-d emulator-5554`.
- One run at that point failed a real test assertion (creating a
  "Savings" account, then not finding it rendered) but did not recur on
  the next run with no logic changes — apparently a one-off timing flake
  rather than a reproducible bug; a logcat-on-failure diagnostic was added
  to the workflow in case it recurs.

With all of that fixed,
[run 36455584025](https://github.com/arsalmurad/cash-app/actions/runs/36455584025)
(commit `fb6289b`, `ubuntu-latest`, KVM-accelerated `x86_64` emulator,
API 34, `google_apis`, Pixel 6 profile) passed end to end: `flutter
analyze`, `flutter test test`, `integration_test/ledger_test.dart` on the
real emulator (`emulator-5554`), and `flutter build apk --release`.

### Web: real result

`phase1-web.yml`'s WASM/build steps (Rust→WASM via
`flutter_rust_bridge_codegen build-web`, `flutter build web --wasm`,
ChromeDriver install) passed on the very first real CI run — the local
sandbox investigation above transferred directly. The integration test
step did not: it hung at "Waiting for connection from debug service on
Chrome..." until the 45-minute job timeout killed it, confirming this was
a real bug and not specific to the local sandbox as first suspected. Root
cause investigation went through two rounds:

- First suspected `flutter drive`'s two independent headless controls —
  `--headless` (the WebDriver-controlled browser, defaults on) and
  `--web-run-headless` (the separate Chrome instance that actually hosts
  the Flutter web app under test, defaults **off**); only the first was
  passed. Added `--web-run-headless` (commit `18767cb`) and re-dispatched.
  It hung at the exact same point, for the exact same duration (killed by
  the 45-minute job timeout at "Waiting for connection from debug service
  on Chrome... 21.2s") — this flag was not the actual cause, or was not
  the only one.
- The real cause: the command used `-d chrome`, which runs the app via
  Chrome's own CDP connection — a different code path from the
  WebDriver-managed Chrome that `flutter drive`'s driver script
  (`test_driver/integration_test.dart`) actually waits to connect through.
  The two were never talking to the same browser instance, so the driver
  waited forever. Switched to `-d web-server`, Flutter's own documented
  device for this combination (commit `5847da6`).
- That switch turned the 45-minute hang into an immediate, explicit
  failure instead: "Unable to start a WebDriver session for web testing.
  Make sure you have the correct WebDriver server (e.g. chromedriver)
  running at 4444." — `-d web-server` needs a WebDriver server already
  *listening* on `--driver-port` (4444 by default); having `chromedriver`
  merely on `PATH` (which was enough to make the earlier, wrong `-d
  chrome` path silently do nothing) does not start one. Fixed by starting
  `chromedriver --port=4444` as a background process and polling
  `http://localhost:4444/status` until it accepts connections, before
  running `flutter drive` (commit `b791cc3`).
- That got a real WebDriver session request to fire, which then failed
  immediately with `SessionNotCreatedException (500): session not created:
  This version of ChromeDriver only supports Chrome version 154. Current
  browser version is 153.0.8010.52.` — `chromedriver@stable` installs the
  newest ChromeDriver release, which had moved ahead of the Chrome version
  actually preinstalled on the `ubuntu-latest` runner image. Fixed by
  reading the installed Chrome's exact version (`google-chrome --version`)
  and installing that same version's ChromeDriver build instead of
  `@stable` (a bare major version like `chromedriver@153` is not itself a
  resolvable build via `@puppeteer/browsers` and 403s; the full
  `major.minor.build.patch` version is).
- With a matching driver, the app finally launched for real (a Dart VM
  Service came up, the WASM module loaded) — and then the very first FRB
  call panicked: `RuntimeError: unreachable`, unwinding from
  `flutter_rust_bridge`'s `WorkerPool::default()` during
  `frb_generated::THREAD_POOL` init. Cause: the WASM build uses
  `-Ctarget-feature=atomics` (needed for FRB's threaded worker pool),
  which requires `SharedArrayBuffer`, which browsers only expose on a
  cross-origin-isolated page (`Cross-Origin-Opener-Policy` /
  `Cross-Origin-Embedder-Policy` headers) — `flutter drive`'s dev server
  doesn't send those by default (`flutter build web --wasm` turns them on
  automatically for the `skwasm` renderer, but the dev server used by
  `flutter drive` needs the flag passed explicitly). Added
  `--cross-origin-isolation` and re-dispatched — it panicked identically,
  proving this wasn't the (or wasn't the whole) cause.
- Traced the actual cause by reading `flutter_rust_bridge` 2.13.0's own
  vendored source
  (`third_party::wasm_bindgen::worker_pool::WorkerPool`): its worker pool
  locates its own script URL via `script_path()`, which deliberately
  throws a JS `Error` and regex-matches a path out of its stack trace — a
  hack borrowed from the `wasm_thread` crate — then `.expect()`-panics if
  the regex doesn't match. `flutter drive` defaults to **debug** mode,
  which recompiles and serves the app from source through its own
  DDC-style dev server, ignoring the release build from the previous step
  entirely; that debug-mode JS has a different stack-trace shape than the
  release build the regex was written against, so the match fails. This
  is a documented `flutter_rust_bridge` constraint: web threading needs
  release or profile mode, not debug. Switched from the default debug
  mode to `--release`.
- The failure report then showed *no* exception text whatsoever, even
  with `--verbose`: `Failure Details:` followed immediately by
  `Failure in method: ...` and `end of failure 1`, nothing in between —
  which was wrongly read at the time as evidence the panic above was
  fixed and a *different*, real test failure had appeared. It was not:
  the blank report was hiding the exact same panic the whole time, and
  every subsequent lead chasing "what's the new failure" was chasing a
  failure that didn't exist as a separate thing:
  - Suspected `FlutterError`/`TestFailure` verbose formatting being gated
    behind `!kReleaseMode`; switched to `--profile`. Still blank, and (it
    turned out) still the same panic.
  - Suspected `print()` inside the test would surface in CI output
    regardless of the driver's own reporting; it never appeared. Real
    cause, confirmed: the `-d web-server` device has no browser console
    access at all (`flutter drive`'s own log says so explicitly —
    "requires the Dart Debug Chrome extension for debugging", which this
    headless CI setup doesn't have).
  - What finally worked: routing the caught exception through
    `IntegrationTestWidgetsFlutterBinding.instance.reportData` (a
    separate channel, unaffected by both of the above), with the driver
    set to `writeResponseOnFailure: true` so it gets written to
    `build/integration_response_data.json` regardless of outcome, printed
    by a new always-run CI step
    (`test_driver/integration_test.dart`, `integration_test/ledger_test.dart`).
    This surfaced the real exception on the very next run — under
    `--release` — and it was `RuntimeError: unreachable` /
    `WorkerPool::default()`: **the exact same panic as at the very start
    of this investigation, on every build mode tried (debug, profile,
    release) alike.** Nothing in this whole chain of CI/build-mode fixes
    had actually resolved it; the reporting bug simply hid it well enough
    to look like progress.

### Web: root cause found, not fixed — a real flutter_rust_bridge limitation

With the real exception finally visible, this is a known, upstream,
maintainer-acknowledged `flutter_rust_bridge` limitation, not a CI
configuration problem:
[fzyzcjy/flutter_rust_bridge#2914](https://github.com/fzyzcjy/flutter_rust_bridge/issues/2914)
(closed as "not planned"). `flutter_rust_bridge`'s web threading spawns a
pool of Web Workers and hands each one the WASM module's linear memory via
`postMessage` so Rust calls can run off the main thread; browsers cannot
clone a `WebAssembly.Memory` object through `postMessage` for this kind of
setup, so `WorkerPool::default()` panics on the very first Rust call this
app makes (`crateApiLedgerInitApp`), regardless of build mode.

The one known workaround, confirmed by the upstream issue: set
`default_dart_async: false` in `flutter_rust_bridge.yaml` and regenerate.
First pass: this does eliminate the panic, but it changes the generated
Dart bridge API from `Future<T>`-returning calls to plain, synchronous
`T`-returning calls everywhere — not a web-only switch. Doing this
immediately broke `flutter analyze` with 22 issues across
`ledger_controller.dart` alone (every `await someRustCall()` site), which
is the app's entire data layer; fixing it properly means auditing and
rewriting every Rust-bridge call site across the app, then re-verifying
iOS and Android (both already green on real hardware) weren't regressed.
That's a real, substantial, cross-cutting refactor — not a safe or
proportionate fix to push through under CI pressure — so it was reverted
rather than committed, the first time this was tried.

**Second attempt, taken on deliberately with real CI verification of all
three platforms**: the refactor was completed properly this time (`flutter
analyze` clean, `flutter test` 54/54, `cargo test --workspace` 84/84,
`flutter_rust_bridge_codegen build-web` and `flutter build web --wasm`
both compiling) and dispatched to real CI on all three platforms. The
results were decisive, and worse than doing nothing:

- **Android**: passed clean.
- **iOS**: the integration test step hung for the entire 45-minute job
  timeout and was killed (`conclusion: cancelled`,
  [run 36481665195](https://github.com/arsalmurad/cash-app/actions/runs/36481665195)) —
  a real regression from the sync-dispatch change, not flakiness.
- **Web**: the `WorkerPool` panic was genuinely gone and the app ran real
  test logic for the first time
  ([run 36481649775](https://github.com/arsalmurad/cash-app/actions/runs/36481649775),
  reproduced identically on a clean re-run,
  [run 36484976444](https://github.com/arsalmurad/cash-app/actions/runs/36484976444)) —
  but the very first `recordTransaction` call silently no-op'd:
  `LedgerController.record()` reported success (`errorMessage=null`,
  `isLoading=false`), yet the controller's own `overview` (read directly
  off the widget tree in
  [a follow-up diagnostic run](https://github.com/arsalmurad/cash-app/actions/runs/36486301616),
  bypassing `find.text` entirely) still showed zero transactions and a
  `USD 0.00` balance. The synchronous call path doesn't actually work
  through wasm-bindgen's web transport in this build — a silent failure,
  which is worse than the original loud panic.

Reverted in full back to async dispatch. See `docs/DECISIONS.md`'s
"2026-09-28 — `default_dart_async: false` tried and reverted" entry for
the complete evidence.

**Current state**: `phase1-web.yml`'s Rust→WASM build, `flutter build web
--wasm`, ChromeDriver setup, and app launch all work end to end on real
CI; the one thing that does not work is running an actual Rust bridge
call on web through this test, for the documented upstream reason above.
Two independent attempts at the one known workaround both made things
worse rather than better. Android and iOS are unaffected (their bridge
calls don't go through `WorkerPool` at all) and remain fully green.

## Remaining work

Ledger events now persist locally and survive a restart, each device keeps a
stable actor ID, categories (with icons, and titles that auto-assign on
repeat) are built, multiple accounts plus transfers between them are built,
search/filter is built, budgets and goals are built, CSV import/export is
built, recurring transactions with upcoming occurrences are built, and a
biometric lock is built — every one of these confirmed on real iOS hardware
(most recently run 36274318774, whose commit tree covers everything through
the biometric lock; see each section above for the specific run that
verified it). Still open before Phase 1's exit test can be called complete:

- Android runtime verification is done: `phase1-android.yml` passed end
  to end on a real KVM-accelerated emulator (see the "Android and web CI
  infrastructure" section above,
  [run 36455584025](https://github.com/arsalmurad/cash-app/actions/runs/36455584025)).
  Web runtime verification hit a genuine, documented upstream
  `flutter_rust_bridge` limitation (see "Web: root cause found, not
  fixed" above) rather than a CI configuration problem: the web build,
  WASM compilation, and app launch all work, but the first Rust bridge
  call panics inside `flutter_rust_bridge`'s Web Worker thread pool
  (browsers can't clone a `WebAssembly.Memory` object via `postMessage`),
  regardless of build mode. The one known fix (switching every Rust-bridge
  call from async to sync dispatch) was attempted in full and verified on
  real CI on all three platforms: it broke iOS (a 45-minute hang, real
  regression) and didn't even fix web (the call silently no-ops instead of
  panicking, worse than before) — see "Web: root cause found, not fixed"
  above for the full evidence — so it was reverted. Android and iOS are
  both fully verified on real hardware/emulator; web is not, and there is
  currently no known fix that doesn't regress another platform.
- The web `EventStore`'s append is read-decode-concatenate-reencode-write
  over the whole log (see `event_store_web.dart`), which is O(log size) per
  write; fine at this milestone's scale, worth revisiting (e.g. IndexedDB
  with one record per frame) if local history grows large.
- Categories can be renamed and re-iconed from the new "Manage categories"
  screen (see the "Category rename" section above), but not deleted — the
  Rust core has no delete operation for categories, only upsert.
- Account currency is fixed at creation (no display-currency conversion
  toggle yet); the net balance card sums accounts' reporting-currency
  equivalents but never shows the same amount converted between two
  currencies side by side.
- The biometric lock has no "require lock after N minutes" grace period —
  it re-locks on every single background/resume cycle, which may be
  stricter than some users want; also untested against a device with no
  biometrics enrolled but a passcode set (device-credential fallback).
- Budgets, goals, and recurring rules can now be edited from the UI (see
  "Budget, goal, and recurring-rule rename" above), but not deleted — like
  categories, the Rust core has no delete operation, only upsert. Goals
  still have no UI to set a category or deadline, and recurring rules
  still have no UI to set a category (editing preserves an existing value
  it can't show, but can't set one on a rule/goal that never had it).
- Recurring rules have no "skip this occurrence" action; the only way past
  a due occurrence is to record it (or edit the rule's start date).
- CSV export/import uses the clipboard rather than a native file
  picker/file-save integration (see `docs/DECISIONS.md`); import also only
  recognizes expense/income rows, not transfers.
- Snapshot/compaction (`cash_core::Snapshot`) exists and is tested at the
  core level but is not yet wired into the persisted log or the bridge; the
  log currently replays from event zero on every load.

Household sharing and all server/cloud features remain outside Phase 1.
