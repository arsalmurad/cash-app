# Codex Cloud handoff

Updated 2026-10-18 during the Linux continuation. This file replaces reliance on the
long local conversation; it does not declare the product finished.

## Active continuation after 81bb306

Source checkpoints `c93f238` and `aad0f8f` fix a restart-required household
screen hidden by its old overview, and exact shared amounts exhausting a narrow
tile's trailing width. The restart screen now takes priority over cached
household/unlock panes and hides mutation controls. Exact amounts wrap in the
text column without dropping digits. The six enlarged-text amount/action cases
and adjacent household tests pass **50 tests**, with focused analysis clean.
The adaptive fixture first needed real scrolling before it reproduced the actual
phone `ListTile` width assertion; tablet/desktop pass after scrolling.

A separate local clone under `/tmp/cash-app-clean-release-wE6l7a/repo` has built
both checkpoints with pinned offline packages, SDKs and validated Rust caches;
tracked source remains clean. No pre-existing app release output was copied in.
Rust WASM remains SHA-256
`af90b53d8e05975e24dcd7a03a6188260550f4f3528c7e382068d8643de5c74e`;
the `aad0f8f` Dart WASM is
`1637e67c4adabd9a5e6848f5be9849ee6fadc9083f0aa7aebb2ab46771adb805`.
Builds are not runtime acceptance. The prior c93 release is retained separately
as `app/build/web-c93f238`; the new driver accepts `WEB_BUILD_DIR` for artifact
verification without overlaying application sources.

Current-source production browser faults and a serial full host suite are
running; do not call them passed from this interim checkpoint. Logs:
`/tmp/notification-browser-final-wide.log`, `/tmp/cash-final-host-acceptance.log`.
The browser acceptance draft exercises actual minimized/hidden windows,
offline network emulation, bounded reconnect, incoming-save quota, no premature
receipt, restart/re-enable/backfill and i64-range amounts. Earlier iterations
passed background/offline and failed incorrect fixture assumptions: tiny edits
can fit allocated SQLite pages; earlier confirmed control prefixes need not
roll back when a later frame fails; restart resets notifications to off. Keep
those partial runs separate from complete acceptance.

One broad c93 host invocation passed 477/478 and hit the existing 15s HTTP
fixture startup deadline during heavy release compilation. Its isolated file
subsequently passed both real HTTP/storage-audit cases (36s), with no timeout or
assertion changes. A new serial full run is needed for a final suite claim.

The resumed shell sandbox currently fails before command startup with a bwrap
bad-file-descriptor error. Individually reviewed scoped `require_escalated`
commands run successfully; no automatic approval rejection occurred. Do not
disable networking restrictions or broaden project scope to work around it.
Automatic restart after a session/usage limit reset is unavailable; checkpoint
and use the resume prompt when the session is continued.

## Start here

- Repository: <https://github.com/arsalmurad/cash-app>.
- Resume branch: `codex/notification-lifecycle-20261018`; implementation checkpoint
  `7aaae2d`, relay close fix `50c3e02`, descended from the requested handoff
  `b867ad2`. Later commits record acceptance-driver/evidence updates. Read
  `git log` and preserve task work.
- Latest accepted runtime/test-driver checkpoint: `18ab351`, pushed to that
  branch. Later documentation-only commits do not require rebuilding artifacts.
- Last reviewed baseline: `cfee91ae7819cf8a87fc0904155ebbeca49c8d41` on `main`
  and `codex/browser-summary-lifecycle`, independently checked on 2026-10-18.
- Original preserved draft client: commit `12f7a36`. Linux continuation commits
  implement and verify its bounded transport and controller integration.
- Read `AGENTS.md`, `docs/PHASE0-RESULT.md`, `docs/COMPLETION.md`, then only the
  relevant build-brief phase and task-specific evidence. `RTK.md` is absent;
  do not spend time searching the owner's computer for it.
- `docs/CLOUD-RESUME-PROMPT.md` is the reusable task prompt. Use a new cloud
  work branch; do not silently merge the draft client into `main`.

The full source, lockfiles, generated Dart bridge, repeatable tests and evidence
summaries are in Git. Windows caches/SDKs, compiled native/WASM/APK artifacts,
test logs, emulator state, real ledgers, recovery phrases and OS/browser keys
are intentionally not transferred. Rebuild appropriate artifacts on Linux;
do not upload private data to make tests pass. A fresh task does not implicitly
inherit the entire conversation or local machine. Use this handoff and Git.

## Product and non-negotiable invariants

Build a polished local-first budgeting app for iPhone, Android and web, then
privacy-preserving selected household sharing. Each person owns a private
ledger; no shared login. Share only deliberately selected expenses/analytics.
The relay must never receive readable financial data. Preserve `AGENTS.md`'s
i64 minor units, rational frozen FX/deterministic rounding, immutable/idempotent
events, HLC total order, per-actor causal frontier, canonical byte-identical
folds and visible conflicts. No broad rewrite or toolchain upgrade is needed.

Phase 0 passed runtime on all three platforms; extensive personal/shared-core
and scoped native/web/Android evidence exists. `docs/COMPLETION.md` is the
completion checklist, not a statement that every remaining gate passed.

## Notification continuation

Five previously local-only files were preserved as a separate draft commit:

- `app/lib/features/household/relay_notifications.dart`
- `app/lib/features/household/relay_socket.dart`
- `app/lib/features/household/relay_socket_io.dart`
- `app/lib/features/household/relay_socket_web.dart`
- `app/test/relay_notifications_test.dart`

They now have a bounded receive-only transport and are wired into the serialized
controller HTTP path through an explicit **Live updates while open** menu option.
Open/reconnect backfills without needing a hint; hints coalesce and never advance
state/ACK/retention consent. Foreground, lock, session-generation, uncertain-save,
removal, disposal and native-handle lifetime checks have scoped tests. Read
[the implementation and evidence](NOTIFICATION-LIFECYCLE.md) before continuing.
The original interrupted Windows draft run is not counted as a pass. The
64-character parser bound remains after platform frame reception.

### Server contract already verified at the baseline

`docs/RELAY-NOTIFICATIONS.md` records the actual workerd tests, failures and
limits. `LOCAL_AUTH_SOCKETS=true` is explicit loopback-only opt-in alongside
existing authenticated membership. GET `/g/{32-lowercase-hex-group}/ws` requires
current `read` permission. Sign the HTTP(S) origin/exact GET path/empty body
with a fresh short-lived device proof; transport uses WS(S). Browser carrier is
one `cash-request.` + unpadded base64url(proof JSON) subprotocol; server selects
the exact token. It sends only `{"tail":n}`. No application messages, financial
events or ACKs are sent over the socket.

Current roster/read-grant revocation closes removed listeners; native
hibernation API/serialized attachments and connection/quota/replay bounds have
local runtime evidence. Actual hosted eviction/revival/billing is unverified.
Recorded baseline: 16-file relay suite 91 tests, 88 pass + three optional Rust
fixture skips; separate Rust interop run 21 pass, zero skips. These are previous
Windows-source-specific results, not a fresh Linux or final-app-platform pass.

### Next safe work

1. Expand current-source production WASM notification lifecycle acceptance. The driver
   supports `WEB_HOUSEHOLD_NOTIFICATIONS=1 WEB_HOUSEHOLD=1 WEB_HOUSEHOLD_AUTH=1`.
   Check the Linux continuation status below before rebuilding. Browser transport
   and native controller passes do not prove broader production app lifecycle behavior.
2. Expand final-platform background/offline/lock, quota/recovery and removal
   acceptance, preserving saved-before-ACK and single-owner browser identity
   leases. OS-protected native saves/biometric enrollment need actual platforms.
3. Continue safe remaining gates in `docs/COMPLETION.md`: lifecycle/recovery
   faults; complete personal/adaptive/accessibility review; final-source runtime
   and clean-checkout release verification; concise final handoff. No new brand,
   telemetry, bank sync, paid service or app-store publication is implied.

## Linux cloud preparation

Use the platform's Linux environment. Check installed tools, free disk and
caches before downloading. The bootstrap and version preflight now pass on the
Linux host, including repeat execution with a read-only home. It installs host SDKs and locked
packages, not Android emulators, WASM compilers or iOS tools.

Install-script / legacy setup-script command, from the repository root:

```bash
bash scripts/codex_cloud_setup.sh
```

Select the resume branch before setup. If the UI has no branch picker, tell its
setup agent to fetch and check out `origin/codex/cloud-handoff-20261018` in its
fresh clean workspace before reading/running these files. Do not reset or
overwrite an existing task's work to change branches. Setup at default `main`
will not contain these handoff files.

Requires Linux x86_64, git, curl, tar/xz, unzip, sha256sum, rustup, a C compiler
and pkg-config. Ask environment setup to provide missing prerequisites; do not
silently upgrade repository dependencies. Node downloads are checked against
the vendor SHA-256 list and Flutter checkout against the exact known revision.
The helper never deletes a cache, modifies global default Rust or deploys.

In every new shell, including the task phase:

```bash
source scripts/codex_cloud_env.sh
```

The helper now activates workspace-installed Rust when needed and sets writable
Flutter/analyzer state and package caches without changing HOME or global Rust
defaults. Explicit cache bindings win. The temporary onboarding activation
wrapper is no longer required. Keep generated caches ignored.

Pins: Flutter 3.47.5, revision
`6a19cca56475dbfba1478ee68d7bd0c2ef891da1`, Dart 3.13.4; Rust 1.98.1;
Node 24.19.0; Miniflare 4.20260730.0; FRB 2.13.0. Do not copy Windows's temporary
`stable` alias workaround to Linux: use named Rust 1.98.1 here. Lockfiles are
tracked for all three package managers. Never replace them to force setup green.

Small first checks (the real socket test needs owned-loopback binding):

```bash
source scripts/codex_cloud_env.sh
cd app
flutter --no-version-check analyze --no-pub lib/features/household/relay_notifications.dart lib/features/household/relay_socket.dart lib/features/household/relay_socket_io.dart lib/features/household/relay_socket_web.dart test/relay_notifications_test.dart
flutter --no-version-check test --no-pub --timeout 20s test/relay_notifications_test.dart
```

For affected controller/native-host tests, build the actual Linux bridge once:

```bash
source scripts/codex_cloud_env.sh
cargo build --manifest-path rust/Cargo.toml -p rust_lib_cash_app --locked
cd app
RUST_LIB_PATH="$PWD/../rust/target/debug/librust_lib_cash_app.so" flutter --no-version-check test --no-pub test/household_host_test.dart
```

Select further tests by change. Host tests without `RUST_LIB_PATH` may skip;
skips are not native passes. For relay changes, start with the focused file in
`relay/test`; the tracked `relay/package.json` contains the complete suite and
`npm run test:request-proof-rust` actual interoperability runner. Limit concurrent
workerds/build jobs on small VMs. Preserve useful caches; do not build every
platform for each change.

WASM is separate and expensive: `.github/workflows/phase1-web.yml` pins
`nightly-2026-09-24` (compiler identifies its build as 2026-09-23), rust-src,
wasm target, wasm-pack 0.15.0, wasm-bindgen-cli 0.2.129 and FRB codegen 2.13.0.
Use its commands and exact target flags only when needed. Generated Dart bridge
and Rust binary must match ABI `1237803201` until an intentional API/codegen
change. A Flutter web build alone is not Rust-WASM runtime verification.
Android needs the pinned SDK/JDK/NDK and an actual supported runtime; Linux
builds do not replace phone/emulator results. Linux does not provide Xcode;
final iOS requires an authorized macOS runner.

## Access, costs and owner-only gates

- Connect GitHub for **this repository only**, with normal branch/PR write
  permission. No broad personal access token, repo-admin or billing rights.
- Prefer default/Approve-for-me repository editing. If permissions are shown,
  do not select unrestricted/full access just to avoid prompts. Internet access
  and repository write permission are different controls.
- Saved environment draft now has restricted networking to the required GitHub,
  Flutter/pub, Rust/crates, Node/npm and Debian download hosts. The previous
  saved configuration was unrestricted; the draft readback confirms restricted
  mode with 16 explicit hosts and no wildcard. Draft saving does not apply that
  policy to this running instance. Review/save the settings and publish through
  the product to activate the prepared configuration; fresh-task restoration has
  not been tested. Add a denied destination only after inspecting the failure.
  Permit the owned-loopback servers needed for tests. A pure GET/HEAD
  restriction can break git push or local HTTP sync POSTs; do not equate network
  restrictions with intended application authorization.
- No production secrets needed initially. Never supply ledger keys, recovery
  phrases, Cloudflare deploy keys, Apple credentials or payment information.
- Keep environment private/Only me. This does **not** change GitHub visibility.
  Authenticated API on 2026-10-18 reports the repo **public**; we made no change.
- Prior safety review refused GitHub Actions dispatch without owner-verified
  **$0 Actions spending cap**. It remains unverified; do not dispatch workflows,
  open a PR that auto-triggers checks, or deploy/purchase anything before that
  gate is satisfied. Branch pushes alone do not trigger the current workflows
  (they use workflow_dispatch and/or pull_request). Preserve these guards.
- Public relay remains closed (503). Trusted public registration, account-wide
  abuse/cost bounds, free-host authorization and hosted runtime proof are open.
  Full-access permissions are not spending or deployment authority. Codex usage
  itself is subject to the owner's plan; no promise of unlimited/free compute.

Use feature branches and save progress in commits. After cost authorization,
open a reviewed PR and run affected acceptance checks before merging. If a task
ends due to limits, update this handoff with exact HEAD/tests/next step; do not
start over or label unchecked gates complete. Do not run the local and cloud
agents concurrently against the same branches.

## Official Cloud setup references (checked 2026-10-18)

The current UI supports Work in > Cloud, repository selection, setup review and
Publish, followed by Start a new task. The older UI has setup/maintenance script
fields; use the same bootstrap there and source the env file in each task shell.
Cloud setup/saved state is not a replacement for committed source.

- [Cloud quickstart](https://learn.chatgpt.com/docs/cloud)
- [Current environments, setup, networking and limitations](https://learn.chatgpt.com/docs/environments/cloud-environments)
- [Legacy setup-script environment](https://learn.chatgpt.com/docs/environments/cloud-environment)
- [Legacy agent internet access](https://learn.chatgpt.com/docs/cloud/internet-access)

## Original Windows handoff verification

Independently checked on Windows 2026-10-18 using the existing pinned cache:

- `cd app; flutter --no-version-check test --no-pub --timeout 20s
  test/relay_notifications_test.dart`: **19 pass, exit 0**, including an actual
  native loopback WebSocket/hint and no application frames. Test execution
  reported about four seconds; SDK/compiler startup was substantially slower.
  This is a transport-only host test, not the real authenticated Rust/workerd
  client, a browser run, controller integration or mobile acceptance.
- Targeted `flutter analyze --no-pub` stayed at `Analyzing 5 items...` without
  a result. Its exact owned idle process was checked and terminated to bound
  handoff work. **Analyzer incomplete, not passed**; rerun on Linux. The user's
  editor language server was left untouched.
- Pinned `dart format` completed on all five files (three formatted). Formatting
  changed no behavior after the test run. `git diff --check` passed.
- Git Bash syntax checks for both setup helpers, setup `--help`, environment
  variable isolation/version exports, and explicit Windows refusal (exit 2)
  passed. The initial Git Bash check lacked `/usr/bin` and failed to find
  `dirname`/`uname`; rerunning with its proper utility PATH passed. The Linux
  bootstrap/download/package-install path **has not been executed here**. Let
  the actual cloud setup test it before publishing; report a missing pinned
  release/download rather than silently substituting versions.

No broad app suite, native Rust rebuild, WASM/mobile build, Actions job or public
deployment was run for that original Windows handoff. Keep those results separate from the
already-reviewed `cfee91a` relay evidence.

## Linux continuation status

At `7aaae2d`, notification transport, controller/UI lifecycle, default-off menu,
bounded reconnect/coalescing, queued-work bounds and deferred native read-borrow
retirement are implemented in focused commits. The pinned Linux native bridge
is retained at `rust/target/debug/librust_lib_cash_app.so` (ABI unchanged).
Full host validation at this implementation checkpoint passed **477 tests,
exit 0, no skips** (5m 06s while pinned WASM tools compiled). Focused native HTTP/churn plus menu checks
passed 29 cases, and the final handle-lifetime file passed all four cases.
The enhanced native HTTP scenario also passes with both peers subscribed and
their actual HTTP traffic draining to silence (one case, 20 s).
Full analysis passes. Six actual Chromium transport cases and three browser
storage/identity-lease cases pass. See `NOTIFICATION-LIFECYCLE.md` for scope.

Production WASM prerequisites and release builds now pass using the exact CI pins:
nightly `nightly-2026-09-24` is installed and reports `6eeff9a52`; rust-src and
the wasm target are present. Optional build tools install into the existing
workspace Cargo home, using a shared cache `/workspace/.cache/cash-cargo-tools`.
LLVM 19.1.7 was extracted locally from hash-checked packages selected from the
host's signed Debian snapshot indexes; no system packages were changed. Its
Clang/archive tools are under `/workspace/toolchains/llvm/usr/lib/llvm-19/bin`.
`wasm-pack 0.15.0`, `wasm-bindgen 0.2.129` and FRB codegen 2.13.0 are installed.
`bash scripts/build_web_bridge.sh --check` verifies pins, components, target and
an actual Clang WASM compilation without installing anything. The helper selects
the local Clang/archive tools, uses locked Cargo resolution and confines FRB's
`RUST_LOG=info` workaround to its child process. The host's module-filter logging
syntax otherwise makes FRB 2.13 panic. Writable `WASM_PACK_CACHE` avoids the
read-only home; existing explicit cache bindings win.

```bash
source scripts/codex_cloud_env.sh
bash scripts/build_web_bridge.sh
cd app
flutter --no-version-check build web --wasm --no-web-resources-cdn --no-pub
```

The initial Rust release bridge compiled in 8m 15s; the locked repeat reused the
cache (Rust 1.22s, wasm-pack 3.39s). The Flutter release build passed in 165.1s.
The generated and packaged `rust_lib_cash_app_bg.wasm` match SHA-256
`af90b53d8e05975e24dcd7a03a6188260550f4f3528c7e382068d8643de5c74e`
(6.2 MiB), with ABI `1237803201` unchanged. Atomics compatibility warnings remain
visible. Builds alone are not production browser acceptance.

The rebuilt production app now passes the complete authenticated household
browser journey with `WEB_HOUSEHOLD=1 WEB_HOUSEHOLD_AUTH=1
WEB_HOUSEHOLD_NOTIFICATIONS=1 CHROME_BINARY=/usr/bin/chromium
CHROME_NO_SANDBOX=1 node scripts/verify_web_runtime.mjs` (exit 0). Actual signed
101 handshake, hint-before-HTTP and rendered balance within ten seconds,
receive-only frames and browser vault lock/reopen pass. The existing sealed
reload, offline conflict, explicit pruning/lease/recovery and EUR/JPY/privacy
checks also pass in that journey. Details and earlier driver failures are in
`NOTIFICATION-LIFECYCLE.md`; the local log is
`/tmp/notification-production-runtime-full.log`. Mobile, hosted behavior and
wider lifecycle/fault gates remain open.

The expanded complete repeat at relay fix `50c3e02` also passes opt-out/re-enable,
default-off reload and live current-member revocation with automatic rendered
removal/no reconnect (`/tmp/notification-production-lifecycle-pointer.log`,
exit 0). It exposed and fixed a real empty-status close-handshake defect, with
an actual TCP RED/GREEN regression. Post-fix manifest suite: **88 pass, four
optional skips, zero failures, exit 0** (92 tests, 128.36s). The dedicated Rust
proof/socket runner passes **22 without skips** and consent runner **one without
skips**. The actual native HTTP lifecycle case passes again in 22s. Do not run
the relay tests with a wildcard: the separate fixture-only consent test requires
its Rust generator. That mistaken invocation failed once; the correct suite and
both generators subsequently pass. See `NOTIFICATION-LIFECYCLE.md` for scope.

Reusable installation/start instructions have been saved in the environment
draft, using `source scripts/codex_cloud_env.sh` directly and the pinned helpers.
Only this repository is configured, no production secrets are needed, and live
servers must restart in each task. Saving is not publication or restore proof.

The next safe UX gate also has new scoped evidence: the rebuilt production app
passes a thirty-category bottom pointer/edit/cancel/reload journey and a separate
keyboard Tab/Shift+Tab/Escape cancellation run at actual Chromium **200% page
zoom**, 360x740 CSS, DPR 2 and pinch scale 1. Driver flag: `WEB_BROWSER_ZOOM=2`.
No app source changes or rebuild were needed. `PERSONAL-UX-REVIEW.md` records
commands, initial failed preflight/missed animation click and remaining limits.

The 200% keyboard run and default 100% smoke both exit 0, including the driver's
final viewport/zoom check after reload. Setup and WASM preflights pass again;
all three project lockfiles are byte-unchanged from `b867ad2`. Current source is
checkpointed on the feature branch, with no main merge/PR/Actions/deployment.
The environment draft pins the exact current checkout and has tested install
and start instructions, 16 restricted hosts and no secret requirements.

Resume with `source scripts/codex_cloud_env.sh`, `git status`, and this handoff.
Do not restart notification implementation or rebuild unchanged cached bridges.
Next safe gaps are production-browser background/offline notifications while
enabled and save/quota faults, the remaining personal functional/contrast/focus
and screen-reader review, and a clean-checkout release check. Actual updated
Android/iOS/native enlarged-text/vault/biometric acceptance needs supported
platform tools/runtimes (this machine has no adb/emulator/KVM or Xcode). Hosted
runtime, deployment and Actions remain blocked by the documented owner spending
authorization, not a reason to expose a public relay or use another route.

Do not repeat old native/mobile results as current release acceptance. No PR,
Actions dispatch, deployment, purchase or visibility change has been made.
