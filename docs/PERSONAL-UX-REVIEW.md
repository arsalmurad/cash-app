# Personal UX review

Reviewed 2026-10-03 against the Phase 1 scope, not feature parity with Cashew.
This is an implementation review, not user research or a WCAG certification.

## Reference and evidence

The reference is [Cashew's repository](https://github.com/jameskokoska/Cashew)
and its linked [web app](https://budget-track.web.app/). Inspected the upstream
onboarding source and ran the deployed web app in an owned, fresh headless
Chrome profile. Advanced onboarding and selected Preview Demo → Activate;
the rendered Home showed generated accounts, monthly budget progress and
sample transactions. No sign-in, real financial data or cloud integration was
used. The deployed version was not matched to a repository commit. Other
Cashew flows were not comprehensively exercised, and no source code was copied.

Compared that Home with our actual production `43871c4` Overview screenshot
and the personal runtime scenarios. Local screenshots are ignored diagnostic
artifacts, not portable repository evidence. Repeatable checks are in
`scripts/verify_web_runtime.mjs`, `app/test/adaptive_ledger_screen_test.dart`
and `app/test/populated_adaptive_panes_test.dart`.

## Overall impression and hierarchy

Our Overview puts the net balance first, then accounts and recent activity;
the five labeled destinations keep navigation explicit. Cashew exposes more
budget information immediately on Home. Our dedicated budget and goal panes
are a deliberate smaller prototype scope, not evidence of equivalent polish.
The Add control is prominent; transaction history and changes remain available
without overwriting the immutable ledger.

## Usability findings

| Finding | Priority | Repair and evidence |
| --- | --- | --- |
| Older automatic category replies could override a newer title, including Coffee → Lunch → Coffee | High | Request generations reject superseded replies; two RED/GREEN regressions, all 11 transaction-sheet tests pass at `9a813f2` |
| Populated recurring cards overflowed on a 360-pixel phone with enlarged text and a valid large amount | High | Separate wrapping amount and Record control; six populated-pane cases pass at `43871c4` |
| Account trailing amounts consumed the whole narrow tile | High | Keep the full amount in a bounded subtitle column; extreme-value navigation matrix passes at `ba77ac8` |
| Transfer trailing amounts also consumed the whole narrow tile | High | Exact sent/received labels wrap beneath long account names; six same-currency/USD/JPY cases and adjacent activity tests pass at `0fb8f89` |
| Toolbar padlock looked actionable but did nothing | Moderate | It now opens existing Screen lock settings; action and close tested in all six adaptive cases at `ba77ac8` |
| Recurring icon appeared blank in the production screenshot | Moderate | Ordinary repeat icon substituted at `ba77ac8`; widget icon selection and actual updated production screenshot both pass |
| Balance caption exposed implementation jargon | Minor | “Calculated on this device” replaces the Rust-specific caption at `ba77ac8` |
| Search-clear icon had no accessible label when a query was active | Moderate | Tooltip/label and clear/restoration regression pass in all six ledger-screen tests at `2eeafc4` |
| Last category Edit button was covered by New category even at maximum scroll | Moderate | Add bottom scroll space; six phone/tablet/desktop light/dark 200%-text RED/GREEN cases verify non-overlap, pointer opening and no writes on cancel |

## Consistency and copy

Keep Material 3 cards, labeled navigation, explicit edit/remove menus and
non-erasing financial history. The copy review favors a useful device-level
explanation over implementation names. “Screen lock settings” describes the
padlock's actual destination; it does not imply that clicking it immediately
locks the ledger or encrypts personal data. Lock capability remains dependent
on the platform and must not be promised in an unsupported browser.

These English labels avoid idioms. Enlarged text is exercised, but translated
label expansion, full RTL navigation and localization are not verified.

## Accessibility and verification limits

The host widget matrix covers 360×740, 840×600 and 1280×900, light/dark Material
3, hit-testable navigation/settings and long/extreme populated cards. Navigation
uses both 1.5× and 2× text, with all five destinations passing labeled tap-target
and Android 48×48 target checks; populated budget/goal/recurring/transfer cards
use 1.5× text. Full i64-sized amounts and reporting labels remain present,
without ellipsizing. All 303 native-enabled host app tests passed in 104 s
after the transfer repair; analysis reported no issues in 7.6 s.

Accessibility findings here are three observed layout failures, repaired as
listed above. A later check using the actual production theme, rather than
generic Android ThemeData, reproduced 40-pixel desktop toolbar targets and
44-pixel filter chips. Explicit padded targets and standard visual density
repair these. All 30 affected real-theme/adaptive/activity cases pass (13 s),
including the 12 enlarged-text navigation cases and a limited automated
Overview text-contrast guideline. The older 303-suite result predates this
theme change. Conditional search clearing also has a labeled-action regression.
Explicit contrast ratios, UI-component contrast, keyboard-only focus order/escape,
actual VoiceOver/NVDA announcements and enrolled biometric/passcode behavior
have not been measured. There is no overall WCAG pass claim. A 48-pixel
automated guideline pass is not evidence of successful physical-device use.

Production Chrome passed again at `ba77ac8` with Rust WASM `26f9563`:
`WEB_PERSONAL_LIFECYCLE=1 WEB_HOUSEHOLD=1 WEB_HOUSEHOLD_QUOTA=1 WEB_CSV=1
WEB_CSV_LINE_ENDINGS=LF WEB_OFFLINE_FONTS=1 node scripts/verify_web_runtime.mjs`.
Pinned Flutter's Dart-only release build took 151 s. The actual Chrome
154.0.8037.58/local workerd scenario verifies the new balance caption,
screen-lock settings dialog and no ledger write when it is opened/closed,
alongside personal controls, exact large money, CSV/Unicode/offline fonts,
summary preview/cancel/publication, browser lock/reload, real quota exhaustion,
offline conflict convergence, fresh-key recovery, removal, EUR/JPY frozen FX
and no readable fixture titles in HTTP bodies. The resulting Overview
screenshot visibly contains the recurring repeat icon.

Android personal runtime also passes at `ea3390b` (388.6 s concurrent build,
3.3 s install, 92 s runtime); household runtime passes at `2eeafc4` (85.6 s
build, 3.0 s install, 34 s runtime). Both used the pinned owned API 36 AOSP
ATD/WHPX emulator, which was then stopped. Logical household peers on one
emulator are not two physical networked devices or an enrolled biometric test.
The subsequent transfer-card layout repair is in the production artifact
`ea3390b` (same Rust WASM). Its Dart-only release build took 239.9 s while the
Android build was also active. `WEB_VIEWPORT=360x740` with personal lifecycle,
CSV/LF and offline-font options passed in actual Chrome. CDP asserts
`innerWidth`/`innerHeight`, so this is a real narrow browser viewport rather
than Chrome's minimum headless window width. Entry/reload, controls, exact
large money, corrections/history and recent activity all pass; the screenshot
shows the stacked account card and five bottom destinations. This is not an
Android or iPhone hardware run. A combined desktop rerun at that revision
failed at Recent entry 1 with an empty title; do not count it as a pass.
An input-listener-readiness experiment then passed the personal flow once but
timed out in Runtime.evaluate during the combined run before CSV completed.
The browser driver/reliability investigation remains open; the earlier
`ba77ac8` combined pass is not final-source evidence or proof of no flaky input.
Final-source iOS is also a separate gate, not inferred from older runs.

On production `5a792b0`, the extended personal browser flow subsequently passed
search, clear and expense/all filtering, including unchanged SQLite bytes.
Flutter merges the search editor's contextual accessible label as
`Activity\nSearch title or category`; the driver now matches exact label lines
and checks the real engine input listener before typing. This is not app-state
injection. The same combined run failed later in household quota/reload with a
`Household::decrement_strong_count` panic. Confirmed database bytes were preserved;
the complete combined runtime and final-source mobile gate remain open.

Current production `eb09a27` subsequently passes the complete combined desktop
flow with driver `b07c1c7`, including quota/reload recovery. A narrow rerun then
fails on a DOM-focused Title field without an input listener. Driver `d4561e7`
uses ordinary browser pointer activation rather than DOM-only focus and retains
the listener/Tab guards; current 360×740 personal/CSV/LF/offline-font acceptance
passes, including recent entries, search/clear/filter and unchanged SQLite bytes.
The separate desktop household/quota flow also passes with that driver and
the smaller relay pages (`45d8e0b`). Both actual Android integrations pass on
app source `eb09a27`; the owned emulator was stopped. All 305 native-enabled
host tests pass (157 s). Final iOS, complete accessibility and a universal
browser-reliability claim are not inferred from these scoped passes.

## Next priorities

1. Verify subsequent layout repairs in the updated browser and mobile app,
   keeping exact source/runtime evidence separate from widget checks.
2. Continue functional and accessibility review of account, entry, budget,
   goal, recurring, search/filter and CSV flows; widget presence alone is not
   the Cashew quality bar. Existing detailed tests remain in Phase 1 progress.
3. Complete final-source platform acceptance and record unsupported lock and
   backup limitations. Do not add cloud sync, bank aggregation, billing or
   telemetry to imitate the reference.

## Entry keyboard and enlarged-label review (2026-10-03)

The accessibility-review skill guided a scoped operability/resize-text check;
this is not an overall WCAG pass. Four keyboard-only host cases use the actual
production theme, 360x740/1280x900, light/dark and 200% text. They open the sheet,
enter an expense, traverse Title/Amount in both directions, select account and
category with Enter/arrow keys, then submit once. Escape separately cancels a
populated entry, returns no draft and restores opener focus. Long account and
category names, including both transfer selectors, remain complete and wrap.

Both narrow theme cases initially failed with account/category horizontal
overflow (including a 156-pixel category overflow). Expanded dropdowns and
flexible category labels repaired it. A further long-label check exposed the
old dense selected-field height and a menu-position assertion; non-dense,
variable-height selected/menu rows fixed that too. The existing foreign-rate
test needed ordinary scroll-to-submit once the fields grew; validation remained
enabled. No amounts, FX rules, font preferences or financial IDs changed.

All 40 affected entry/adaptive/category tests pass (21 s) and analysis reports
no issues. One intervening invocation passed its 36 real tests but also named a
nonexistent test file; it is not a green suite result. The final corrected run
uses `flutter test --no-pub test/add_transaction_sheet_test.dart
test/adaptive_ledger_screen_test.dart test/populated_adaptive_panes_test.dart
test/categories_screen_test.dart`. The prior 331 full-suite pass predates this
entry-layout change; no 338 full-suite claim is made.

The cached-tool release web build passes (153.3 s). Chrome 154 / Node 24.19 at
360x740 independently passes `WEB_KEYBOARD_ENTRY=1 WEB_PERSONAL_LIFECYCLE=1
WEB_CSV=1 WEB_CSV_LINE_ENDINGS=LF WEB_OFFLINE_FONTS=1
node scripts/verify_web_runtime.mjs`. This actual production run checks forward/
reverse browser field traversal, Escape and byte-unchanged SQLite cancellation,
plus CSV bytes/Unicode/offline fonts, goals/recurring/removal, exact large money,
corrections/history, recent ordering and search/filter after reload. Browser
opening/initial activation still use pointer input; host opening/submission is
keyboard-only. Local logs: `app/.dart_tool/keyboard-web-build.log` and
`app/.dart_tool/keyboard-web-full-isolated.log`. Browser text is its normal scale;
200% coverage here is host-widget evidence, not browser zoom evidence.

The first browser attempt's reverse traversal failed because the driver omitted
physical Shift down/up; the corrected event sequence passes without weakening
assertions. An intervening combined retry failed earlier at reload with
`skwasm.wasm` malloc memory-access-out-of-bounds and a Runtime.evaluate timeout.
Both an isolated keyboard run and a subsequent serial full personal/CSV run pass
at the unchanged app/build source, but the renderer's intermittent cause remains
undiagnosed; passing retries do not establish its repair. No toolchain upgrade,
renderer substitution or app-state injection was used.

Visible keyboard-focus contrast, non-text contrast, actual VoiceOver/NVDA,
enrolled biometrics, 200% browser zoom, RTL/localization and current-source
mobile/iOS remain unverified by this scoped review.

## Category-list action reachability (2026-10-04)

The accessibility-review skill guided a scoped pointer/resize-text check, not
an overall WCAG pass. Unlike the main ledger panes, Categories had no space
after the final row. With 30 synthetic categories, all six 360x740/840x600/
1280x900, light/dark, 200%-text cases reproduced the final Edit control's
rectangle overlapping the floating New category control even at maximum
scroll. The production category list now has 112 pixels of bottom scroll
space, consistent with the ledger panes; no definitions or ledger events change.

The same cases now assert non-overlap and hit-testability, actually tap the
last Edit control, verify its prefilled name, cancel and assert zero creation/
update calls. All ten category tests pass (6 s); the category, adaptive
navigation and populated-pane run passes **28 tests** (16 s), and affected-file
analysis has no issues (42.5 s). Ignored logs: `category-bottom-controls-red.log`,
`category-bottom-controls-green.log`, `category-bottom-adjacent-tests.log` and
`category-bottom-analysis.log` in `app/.dart_tool`. The padding repair currently
has host-widget evidence; the preceding APKs/browser artifacts are not
relabeled as production verification of this newer UI change. No TalkBack/
VoiceOver or complete accessibility claim follows.

## Category-picker accessible names (2026-10-05)

The accessibility-review and UX-copy skills guided a scoped name/state review.
The twelve icon choices previously exposed no human-readable icon names. Each
now labels its existing icon (for example, Dining icon and Travel icon); stored
keys, category IDs and ledger events are unchanged. The regression first failed
on the empty Shopping cart icon label. Six viewport/theme cases at 200% text
check all twelve controls, selected semantics and Android touch-target guidelines;
another case saves the original `flight` key after ordinary selection.

The first label-enabled invocation still failed because the test disposed its
semantics handle too late. With try/finally disposal, all **36 affected/adjacent
tests pass** (23 s), and targeted analysis reports no issues (3.3 s). Commands:
`flutter --no-version-check test --no-pub test/category_edit_dialog_test.dart
test/categories_screen_test.dart test/adaptive_ledger_screen_test.dart
test/populated_adaptive_panes_test.dart`; analyze the two changed production
files and the new dialog test. Logs under `app/.dart_tool`:
`category-icon-names-red.log`, `category-icon-names-green.log` (failed harness
lifecycle), `category-icon-adjacent-tests.log`, `category-icon-analysis.log`.

The production web build passes (199.1 s): `flutter --no-version-check build
web --wasm --no-web-resources-cdn --no-pub`. It reuses the unchanged 6,394,850-byte
Rust/WASM bridge, SHA-256
`558be010d2207a4cab39f52168ffb3c29e8a7bb6acf6fd57d3dafca4432ff1d3`,
ABI `1237803201`. The Dart WASM artifact is 2,775,304 bytes. Chrome 154 / Node
24.19 at 360x740 independently passes twelve real accessible checkbox names,
checked states, icon selection, and byte-identical SQLite after cancelling
creation and editing. A second broader production run also passes:
`WEB_CATEGORIES=1 WEB_VIEWPORT=360x740 WEB_KEYBOARD_ENTRY=1
WEB_PERSONAL_LIFECYCLE=1 WEB_CSV=1 WEB_CSV_LINE_ENDINGS=LF WEB_OFFLINE_FONTS=1
node scripts/verify_web_runtime.mjs`. This includes persisted expense/reloads,
forward/reverse keyboard traversal, Escape cancellation, CSV bytes and Unicode,
offline fonts, personal lifecycle, exact large money, corrections/history,
recent ordering and search/filter. No app-state injection is used.

Build/runtime logs: `category-accessibility-web-build.log`,
`category-picker-production-web-runtime.log`,
`category-current-personal-web-runtime.log`. This build includes the preceding
category bottom padding, but browser fixtures have five seeded categories;
the thirty-row/200%-text bottom-action claim remains host evidence. The current
Android APKs predate these two category UI repairs. Actual mobile screen readers,
200% browser zoom, final iOS and complete accessibility remain unverified.
