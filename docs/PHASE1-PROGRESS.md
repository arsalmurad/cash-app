# Phase 1 progress

Updated 2026-09-26. Phase 1 is in progress; its complete exit test has not passed.

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

The current ledger is in memory and resets when the app restarts. Next: durable
local event storage and persistent actor identity, including restart/recovery
tests and a browser-compatible storage path. Transfers, multi-currency UI,
recurrence, budgets, goals, search, biometric lock, and CSV remain unfinished.
Household sharing and all server/cloud features remain outside Phase 1.
