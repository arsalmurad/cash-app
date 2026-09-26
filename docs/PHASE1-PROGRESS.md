# Phase 1 progress

Updated 2026-09-26. Phase 1 is in progress; its complete exit test has not passed.

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
  after recording a transaction, the test calls `app.main()` a second time
  (rebuilding the widget tree, and with it a fresh `LedgerController`) and
  asserts both transactions and the correct balance are still shown. This
  exercises the full on-device stack (Rust ledger + `IoEventStore` +
  controller), but needs a device/emulator to run — see below.

Not verified this session (no Android emulator, iOS simulator, or browser
available in this container): the Android integration test, the manual
`phase1-ios` GitHub Actions workflow, and the web runtime check
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

Ledger events now persist locally and survive a restart (see above), and each
device keeps a stable actor ID. Still open before Phase 1's exit test can be
called complete:

- Run the Android integration test, the manual `phase1-ios` workflow, and the
  web runtime check against this change (see "Not verified this session").
- The web `EventStore`'s append is read-decode-concatenate-reencode-write
  over the whole log (see `event_store_web.dart`), which is O(log size) per
  write; fine at this milestone's scale, worth revisiting (e.g. IndexedDB
  with one record per frame) if local history grows large.
- Multi-currency UI, transfers, recurring/upcoming transactions, custom
  titles that auto-assign on repeat, budgets, goals, search and filter, CSV
  import/export, and biometric lock remain unbuilt.
- Snapshot/compaction (`cash_core::Snapshot`) exists and is tested at the
  core level but is not yet wired into the persisted log or the bridge; the
  log currently replays from event zero on every load.

Household sharing and all server/cloud features remain outside Phase 1.
