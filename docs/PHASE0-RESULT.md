# Phase 0: OpenMLS through flutter_rust_bridge v2

Started: 2026-09-24. Reported: 2026-09-25. Status: **partial finding;
Phase 0 pass condition not met**.

An iOS simulator workflow is prepared at
`.github/workflows/phase0-ios.yml`. It is manual-only and has not run yet; this
does not change the status above.

OpenMLS works through `flutter_rust_bridge` v2 on Android and Flutter web/WASM
in this spike. The iOS target is untested because the available host is Windows
and no Mac or iOS CI runner is available. The brief requires all three targets,
so Phase 1 remains blocked.

## Tested flow

The bridge exposes these calls:

1. `create_group` creates Alice's OpenMLS group.
2. `add_member` creates Bob's credential and key package, adds Bob, processes
   the Welcome, and proves Bob can decrypt an application message.
3. `remove_member_and_verify` removes Bob, processes the removal commit on
   Bob's client, creates a message in Alice's next epoch, and succeeds only if
   Alice is the sole member, Bob's group is inactive, and Bob's client rejects
   the next-epoch message.

## Host and toolchain

- Host: Windows 10 Pro 22H2, x64.
- Flutter: 3.47.5 stable, framework revision `6a19cca564`; Dart 3.13.4.
- Rustup: 1.29.1; stable Rust 1.98.1.
- WASM toolchain: nightly Rust 1.100.0-nightly (2026-09-23),
  `wasm32-unknown-unknown`, and `wasm-pack` 0.15.0.
- `flutter_rust_bridge` and `flutter_rust_bridge_codegen`: 2.13.0.
- OpenMLS: 0.9.0; `openmls_rust_crypto`: 0.6.0;
  `openmls_basic_credential`: 0.6.0.
- WASM RNG compatibility dependency: `getrandom` 0.2.17 with its `js`
  feature, enabled only for `wasm32`.
- Android: Temurin JDK 17.0.20.1, Android SDK 36, Build Tools 36.0.0,
  NDK 28.2.13676358, Emulator 37.1.11, Android 16/API 36 AOSP ATD x86_64.
- Web runtime: Chrome 152.0.7977.83.

The Cargo lockfile records all transitive crate versions.

## Platform results

| Target | Build | Run operations | Binary size delta | Notes |
| --- | --- | --- | --- | --- |
| iOS device/simulator | Not attempted | Not attempted | Not measured | Requires macOS and Xcode. No Mac or iOS runner is available. |
| Android emulator | **Pass** | **Pass** | `+3,654,629` bytes (`+3.49 MiB`) | Release x86_64 APK: `20,577,009` bytes; matched minimal Flutter APK: `16,922,380` bytes. |
| Flutter web/WASM | **Pass** | **Pass** | `+17,114,954` bytes (`+16.32 MiB`) | Release deployment: `59,800,328` bytes; matched minimal Flutter deployment: `42,685,374` bytes. |

The Android MLS APK contains a 3,647,344-byte uncompressed
`librust_lib_mls_spike.so`. The web deployment contains a 17,023,795-byte
`rust_lib_mls_spike_bg.wasm`; its Flutter `main.dart.wasm` is 1,523,295 bytes,
compared with 1,511,217 bytes in the baseline.

Both baselines were generated with Flutter 3.47.5, the same release mode, and
the same target settings. The Android comparison uses release x86_64 APKs. The
web comparison sums every file in each `build/web` deployment.

## Verification output

### Native Rust

```text
cargo test --manifest-path mls_spike/rust/Cargo.toml --locked
running 1 test
test crypto::tests::removed_member_cannot_decrypt_next_epoch ... ok
```

### Android emulator

Command:

```text
flutter test integration_test/mls_test.dart -d emulator-5554
```

Result:

```text
Built build\app\outputs\flutter-apk\app-debug.apk
Installing build\app\outputs\flutter-apk\app-debug.apk... 7.9s
00:00 +0: removed member cannot decrypt next epoch
00:03 +1: All tests passed!
```

The device reported Android 16, API 36, and x86_64. The debug APK built and
installed before the bridge test ran on the emulator.

### Flutter web/WASM

Commands:

```text
flutter_rust_bridge_codegen build-web
flutter build web --wasm
```

Both commands completed successfully. The release app was served with
`Cross-Origin-Opener-Policy: same-origin` and
`Cross-Origin-Embedder-Policy: require-corp`, then driven in headless Chrome
through WebDriver. The rendered result was:

```text
Before removal decrypt: true
After removal decrypt rejected: true
```

See [the captured browser result](phase0-web-pass.png).

### Static checks

`flutter analyze` completed with no issues after binding generation.

## Workarounds and findings

- Puro 1.5.0 selected Flutter 3.47.5, but its full Git fetch stalled. A shallow
  stable-channel Flutter checkout was used instead.
- Rustup's nightly download stalled. The official compiler archive was resumed
  with curl, checked against the release manifest SHA-256, and placed in the
  Rustup cache before installing the minimal nightly toolchain.
- The first WASM compile failed because transitive `getrandom` 0.2.17 did not
  have a browser backend. A WASM-only direct dependency enables its `js`
  feature. The next Rust-to-WASM and Flutter web builds passed.
- `flutter test --platform chrome` could not attach to the installed browser,
  and Flutter does not support `-d chrome` for integration tests. The compiled
  release app was therefore exercised with matching ChromeDriver/WebDriver.
  This ran the real UI, generated Dart bridge, and Rust WASM artifact.
- The host initially had no Android SDK, JDK, or emulator. They were installed
  on `D:`. Gradle, temporary files, the AVD, and the generated Flutter build
  tree were also placed on `D:` because `C:` had insufficient free space.
- The current Android command-line tools emit a nonfatal warning because one
  Flutter SDK processor understands SDK XML through version 3 while the SDK
  metadata uses version 4. The APK still built, installed, and passed.
- This Windows host cannot perform the required iOS build and runtime test.
  Flutter's [iOS setup guide](https://docs.flutter.dev/get-started/install/macos/mobile-ios)
  requires Xcode on macOS. An untested iOS target cannot be counted as a pass.

## Conclusion

The unverified OpenMLS bridge assumption is proven for Android and web/WASM.
The Phase 0 gate is still incomplete because iOS cannot be tested in the
available environment. Do not start Phase 1 until an iOS run is available or
the architecture decision is explicitly revised in response to this finding.

## References

- [flutter_rust_bridge v2 quickstart](https://cjycode.com/flutter_rust_bridge/quickstart)
- [OpenMLS group creation](https://book.openmls.tech/user_manual/create_group.html)
- [OpenMLS member addition](https://book.openmls.tech/user_manual/add_members.html)
- [OpenMLS member removal](https://book.openmls.tech/user_manual/remove_members.html)
- [OpenMLS source: WASM requires the `js` feature](https://docs.rs/openmls/0.9.0/src/openmls/lib.rs.html#148-149)
