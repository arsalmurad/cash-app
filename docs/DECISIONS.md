# Decisions

## 2026-09-24 — Keep Phase 0 isolated

The OpenMLS experiment will live in `mls_spike/`, as the build brief specifies,
until its platform results are known. Starting the Phase 1 app before the
three-platform question is answered was rejected because the bridge and WASM
compatibility are the architecture gate.

## 2026-09-24 — Record an untested iOS target explicitly

This Windows host can test Android and web after toolchain setup but cannot run
an iOS simulator. Treating a Rust desktop build or an Android run as evidence
for iOS was rejected; the required iOS run needs macOS and Xcode according to
the [Flutter iOS setup guide](https://docs.flutter.dev/get-started/install/macos/mobile-ios).

## 2026-09-24 — Use the current OpenMLS release and RustCrypto provider

The spike pins OpenMLS 0.9.0 with `openmls_rust_crypto` 0.6.0 and enables the
OpenMLS `js` feature for WASM. An older 0.8.x release was rejected because the
spike should test the current API and its current platform behavior; the
[OpenMLS release history](https://github.com/openmls/openmls/blob/main/CHANGELOG.md)
and [WASM compile guard](https://docs.rs/openmls/0.9.0/src/openmls/lib.rs.html#148-149)
support that choice.

## 2026-09-24 — Adapt the OpenMLS quickstart inside the spike

The credential, key-package, Welcome, and commit flow in `mls_spike/rust/src/crypto.rs`
follows the [OpenMLS quickstart](https://docs.rs/openmls/0.9.0/src/openmls/lib.rs.html).
Writing a different handshake sequence from scratch was rejected because it
would add uncertainty to a platform compatibility experiment.

## 2026-09-24 — Enable the browser RNG backend for `getrandom` 0.2

The first WASM compile reached a transitive `getrandom` 0.2.17 dependency and
failed because its `js` feature was absent. The spike enables that feature only
for `wasm32`; relying on OpenMLS's `js` feature alone was rejected because it
did not activate the older `getrandom` dependency's backend. See the
[getrandom 0.2 feature list](https://docs.rs/crate/getrandom/0.2.17/features).

## 2026-09-25 — Keep Phase 1 blocked after the partial finding

Android and web/WASM both passed the complete MLS bridge flow. iOS remains
untested because no macOS/Xcode environment is available. The brief defines a
three-target pass condition, so Phase 1 remains blocked and the result is
reported as a partial finding.

## 2026-09-25 — Use matched release baselines for size deltas

The Android and web size deltas compare the spike with fresh minimal Flutter
projects built by the same Flutter version, in the same release mode, and for
the same target. Comparing debug and release artifacts, or using published size
estimates, was rejected because either would obscure the cost of the Rust and
OpenMLS payload.

## 2026-09-25 — Move Android toolchains and generated builds to D:

The system drive did not have enough room for the Android SDK, NDK, emulator,
Gradle cache, and Cargokit objects. Those generated and external files live on
`D:`. The repository's ignored `mls_spike/build` path is a local junction to the
generated build directory on `D:`; no source path depends on that drive.

## 2026-09-25 — Close the iOS gate on a standard GitHub-hosted runner

Use a manual-only `macos-15` GitHub Actions workflow to run the existing bridge
test in an iOS simulator and measure an unsigned release bundle. Leaving iOS
untested or starting Phase 1 provisionally was rejected because iOS is the
primary commercial platform and the Phase 0 brief makes it an explicit gate.
The workflow has a 45-minute timeout and no push trigger so it cannot consume
the private repository's included runner allowance repeatedly.

## 2026-09-25 — Complete Phase 0 and unblock Phase 1

The complete OpenMLS bridge flow passed at runtime on an iPhone 16 Pro
simulator, an Android 16 emulator, and Chrome with the generated WebAssembly
artifact. Matching release baselines were also measured on all three targets.
This satisfies the build brief's three-platform Phase 0 pass condition, so
Phase 1 may begin. The Swift Package Manager and Rust `atomics` warnings remain
recorded compatibility risks; they do not invalidate the pinned, passing
toolchain.
