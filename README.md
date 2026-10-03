# Private Ledger

A private prototype of a local-first personal budget and encrypted household
expense app for iPhone, Android and web. Each person owns a separate ledger;
creating shared expenses does not upload their private accounts or transactions.
Money and frozen exchange rates are computed with Rust integers/rational rates,
not floating point. Household membership and removal use OpenMLS.

## Status and limits

This is not a finished or publicly deployed product. See
[the completion tracker](docs/COMPLETION.md) for outstanding gates and
[Phase 2 evidence](docs/PHASE2-PROGRESS.md) for exactly which revisions/platforms
were run. A successful build is not runtime verification.

- Personal features include accounts, multi-currency transactions/transfers,
  categories, budgets, goals, recurring occurrences, search and CSV files.
- Shared features include explicit shared accounts/expenses, frozen FX,
  visible conflicts, invitations, safety numbers, recovery and member removal.
- Working household journals are encrypted. Personal SQLite is **not** encrypted
  by this app. Screen lock is a UI gate, not database encryption.
- Browser storage currently uses a whole SQLite image in localStorage; it has
  quota and main-thread costs. Browser household unlock phrases stay in RAM.
- The relay is **closed by default**. The local test server explicitly enables
  loopback-only development. This is not production authentication. Do not
  expose it publicly or deploy until the authentication/abuse gate is complete.
- Recovery needs the saved phrase **and** its matching encrypted backup. There
  is no server reset. A stale backup rejoins with fresh keys after retirement of
  the old device; it must not resume an old sender ratchet.
- Sharing cannot make an already disclosed expense secret again. The relay also
  sees metadata such as IDs, timing, counts and network addresses.

## Repository map

`app/` is Flutter UI and local adapters; `rust/core/` is deterministic money and
event folding; `rust/crypto/` is MLS/recovery; `rust/sync/` is authenticated shared
history; `rust/storage/` is SQLite; `rust/api/` is the bridge; `relay/` is the
ciphertext worker; `scripts/` holds acceptance drivers.

Before development, read [AGENTS.md](AGENTS.md),
[the pinned toolchains](docs/PHASE0-RESULT.md) and the relevant phase of
[the build brief](expense-app-build-brief.md). Reuse installed tools/caches.
The Flutter SDK and build outputs are intentionally not committed. Cloud CI
configuration in `.github/workflows/` pins the required environments.

## Local verification

With the pinned Rust, Flutter and Node available:

```text
cargo test --manifest-path rust/Cargo.toml --workspace --locked
cargo build --manifest-path rust/Cargo.toml -p rust_lib_cash_app --locked
```

In `app/`, run `flutter pub get` when the dependency lock has changed. Set
`RUST_LIB_PATH` to the built native library before `flutter test --no-pub test`
so host bridge tests run instead of being skipped. On the recorded Windows
checkout the library is `rust/target/debug/rust_lib_cash_app.dll`; use an
absolute path. Then run `flutter analyze --no-pub`.

For the local worker, run `npm ci` once in `relay/`, then `npm test` and
`npm run dev`. The latter binds only `127.0.0.1:8787`. Enter that relay address
in local browser clients. The native acceptance scenario uses a fixture relay;
native HTTP networking setup is a separate check, not a deployed-relay claim.
Do not place financial data or
credentials in test fixtures.

For production WASM, follow the existing pinned web workflow to build the Rust
bridge first, then `flutter build web --wasm --no-web-resources-cdn --no-pub`.
On Windows, `scripts\build_web_bridge.cmd -CheckOnly` verifies the existing
FRB 2.13.0, wasm-pack 0.15.0, pinned nightly commit and NDK 28.2 Clang/llvm-ar
before doing any compilation. `scripts\build_web_bridge.cmd` then builds the
release bridge with the recorded atomics/bulk-memory flags, reusing caches.
It honours explicit `CC_wasm32_unknown_unknown`/`AR_wasm32_unknown_unknown`
paths; otherwise it checks `ANDROID_SDK_ROOT`, `ANDROID_HOME`, then the recorded
`D:\Android\Sdk`. Preflight installs nothing and refuses missing or changed
versions. The actual release command retains wasm-pack's normal binding-tool
and cache behaviour; its `Installing wasm-bindgen` message alone does not prove
whether a tool was newly downloaded.
The local `nightly` alias must match commit `6eeff9a52`; use
`-WasmToolchain nightly-2026-09-24` for the equivalent CI-named toolchain if
already installed. The atomics compatibility warning remains unresolved.
`scripts\test_web_bridge_helper.ps1` checks fail-fast and unchanged-artifact
behaviour without rebuilding. These are build/setup checks, not browser runtime
acceptance or permission to launch cloud CI.
From the repository root, `WEB_HOUSEHOLD=1 node scripts/verify_web_runtime.mjs`
drives the rendered release UI against a fresh local workerd relay. Set
`WEB_CSV=1` for actual file import/download checks.
With `WEB_HOUSEHOLD=1`, `WEB_HOUSEHOLD_QUOTA=1` exhausts actual Chrome storage
using an unrelated key in the owned test profile. It checks unchanged confirmed
SQLite bytes, no relay append, blocked later writes and restart/unlock recovery.
`WEB_PERSONAL_LIFECYCLE=1` checks budget/goal removal and stopping a monthly
rule through the rendered UI, cancellation without writes and durable restart
without erasing its recorded expense. Set it alongside the other checks.
`WEB_KEYBOARD_ENTRY=1` checks Tab/Shift+Tab and Escape in a populated personal
entry and requires the stored SQLite bytes to stay unchanged on cancellation.
Opening and initial field activation still use pointer input in this browser
driver; separate host tests exercise keyboard-only opening and submission.
On PowerShell set these
environment variables with `$env:NAME='value'` before invoking Node.

The Android CSV driver requires the explicitly named disposable
`CashAppCsvApi36` emulator, a full API 36 document-provider image, and
`ANDROID_RESET_CSV_TEST_APP=1`; it clears only that emulator's synthetic app
data. It refuses physical devices and unexpected fixture output. Normal users
should not run reset acceptance drivers on their own financial installation.

## Continuing elsewhere

Use the private GitHub `main` source, not local ignored binaries or caches.
Read the completion tracker and relevant acceptance evidence first. Implement
one concern per commit, write money-path regressions before changes, and run
the smallest relevant tests before broader checks. Keep private data private,
retain signed history until pruning is safe, and never substitute a claim of
completion for the unverified deployment or final-platform gates.

Do not launch cloud jobs until the account owner confirms they cannot incur
charges. App-store publication, billing, telemetry and repository visibility
changes are not authorized by this prototype brief.
