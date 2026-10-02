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
listed above, and no failures in the narrowly scoped label/target guidelines.
Contrast ratios, UI-component contrast, keyboard-only focus order/escape,
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

## Next priorities

1. Verify subsequent layout repairs in the updated browser and mobile app,
   keeping exact source/runtime evidence separate from widget checks.
2. Continue functional and accessibility review of account, entry, budget,
   goal, recurring, search/filter and CSV flows; widget presence alone is not
   the Cashew quality bar. Existing detailed tests remain in Phase 1 progress.
3. Complete final-source platform acceptance and record unsupported lock and
   backup limitations. Do not add cloud sync, bank aggregation, billing or
   telemetry to imitate the reference.
