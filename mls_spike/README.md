# OpenMLS bridge spike

This isolated Flutter project tests OpenMLS 0.9.0 through
`flutter_rust_bridge` 2.13.0. It creates an MLS group, adds Bob, verifies Bob
can decrypt a message, removes Bob, and verifies Bob cannot process a message
from the next epoch.

The full result, platform matrix, workarounds, and size measurements are in
[`docs/PHASE0-RESULT.md`](../docs/PHASE0-RESULT.md).

## Generate bindings

```sh
flutter_rust_bridge_codegen generate
```

## Native Rust test

```sh
cargo test --manifest-path rust/Cargo.toml --locked
```

## Web

```sh
flutter_rust_bridge_codegen build-web
flutter build web --wasm
```

Serve `build/web` with these response headers before testing the app:

```text
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

## Android integration test

With an emulator or device running:

```sh
flutter test integration_test/mls_test.dart -d <device-id>
```

## Current gate

Android and web/WASM pass. iOS has not been tested because no Mac/Xcode runner
is available, so the Phase 0 pass condition is not met.
