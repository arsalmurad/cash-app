# Current Android production release evidence

Verified 2026-10-04. Production app through `1edf8a5`, evidence head `f855f34`,
Rust/Dart bridge ABI `1237803201`; the new tracked production-UI driver does not
change app code. This is scoped x86_64 emulator evidence, not a full-platform
completion claim.

## Artifact and actual runtime

- `app/build/app/outputs/flutter-apk/app-x86_64-release.apk`: **30,652,033 bytes**.
- SHA-256: `957A0C974215CCFCF734DE313D866BABA0C352094FCC50E72741C51327F21A7B`.
- Package `app.privateledger.private_ledger`, version `0.1.0`, ABI-split version
  code `4001`, SDK 36. Actual badging reports **only x86_64**, not debuggable.
- ZIP inventory includes real `lib/x86_64/libapp.so` (Dart AOT),
  `libflutter.so` and `librust_lib_cash_app.so`. Project release signing uses its
  debug key for this private prototype; this is not store signing/publication.
- Windows, Flutter 3.47.5/Dart 3.13.4, Rust stable 1.98.1, JDK 17.0.20.1,
  NDK 28.2.13676358. Named owned `Phase0Api36`, `emulator-5580`, Android 16/API 36.

The exact production APK passes `scripts/verify_android_release_ui.mjs`,
terminal **exit 0**. Ordinary Android accessibility snapshots, observed bounds,
pointer taps/swipes and keyboard input add a unique synthetic 12.34 expense.
The actual balance changes by exactly 1,234 minor units. A real process stop/
cold launch preserves the title and balance; explicit removal confirmation
excludes only that fixture, and a second cold launch preserves the original
balance. The script uses BigInt for money comparisons, verifies APK metadata/
packaged libraries before installing, refuses physical devices/other AVDs,
and never resets app data or reads private files. Immutable fixture histories
remain. No debug/integration-test app target or app-state injection is used.

```text
ANDROID_DEVICE_SERIAL=emulator-5580 node scripts/verify_android_release_ui.mjs
```

Log `app/.dart_tool/consent-android-release-production-ui-uncovered.log`.
Diagnostic APKs, local logs/screenshots and caches remain ignored; the recipe,
driver and evidence are tracked. Packaging alone was not counted as runtime.

## Exact successful build sequence and efficient reproduction

Use the D: Android/JDK/Gradle/temp environment recorded in
[PHASE2-PROGRESS.md](PHASE2-PROGRESS.md), `RUSTUP_TOOLCHAIN=stable`,
`CARGO_NET_OFFLINE=true`, `CI=true`, and the existing pinned Flutter path.
From `app`, the successful sequence was:

```text
flutter --no-version-check pub get --offline --enforce-lockfile
flutter --no-version-check build apk --release --target-platform android-x64
flutter --no-version-check build apk --release --target-platform android-x64 --split-per-abi --no-pub
```

The middle build passed in **312.0 s**, regenerating the release registrant;
its generic APK is **not** the verified artifact. The final split build reused
that native compilation and fresh registrant and passed in **66.7 s**.
For a new debug-to-release mode switch, use the normal pub-enabled release
build **with `--split-per-abi` directly**, rather than reproducing the
intermediate generic APK. That combined recipe is derived from the verified
two steps, not a separate clean-checkout pass. Do not use `--no-pub` on a mode
switch with a stale registrant. The existing Android CI release step already
uses normal pub-enabled regeneration; no CI jobs were dispatched.

## Failures and fixes, kept separate from passes

1. Initial release build failed before testing (13.1 s) on a ReadOnly Gradle
   transform workspace. Actual host attributes confirmed the cause. Only
   directory ReadOnly flags were cleared on **18,939** validated generated
   directories under `D:/cash-app-toolchains/gradle/caches/9.3.1/transforms`;
   reparse targets were rejected. No files/source were changed or deleted.
2. The retry finished native compilation but failed Java packaging after
   **700.1 s**: stale generated registration still referenced `integration_test`
   while release excluded that plugin. Pinned Flutter source confirms that
   `--no-pub` skips platform regeneration and release injection filters dev
   plugins. Normal tool regeneration fixed it; no generated Java hand-edit,
   package upgrade, toolchain upgrade or cache clean was used. App/tracked
   lockfiles stayed unchanged. Cargokit's one reported dependency change was
   only `c:` to `C:` spelling of the same local build-tool path.
3. The generic x86_64-target build passed, but pre-install badging/ZIP checks
   rejected it: JNI supplied ARM libraries even though Dart/Flutter/Rust code
   was only x86_64. It was **not installed or counted as a runtime pass**.
   ABI-split packaging produces the verified correctly filtered artifact.
4. Initial split UI test stopped before entry: Android exposed Title/Amount
   as native `hint` attributes. The driver now reads those observed labels
   and the real `Add transaction` submit label. The next run passed expense/
   process restart but its action tap hit the overlapping floating Add button.
   The corrected driver uses an observed scroll viewport, checks that the
   action is clear of the FAB, and waits through transient empty snapshots.
   The failed run's exact synthetic fixture was reviewed/removed through its
   normal confirmation, restoring USD 0.00 while retaining history; no reset.
   The final whole sequence passes. This is not an overall accessibility audit
   or proof that every background/renderer timing issue is fixed.

Low C: space was separately resolved by relocating **615 generated files,
859 MiB** from `app/build/rust_lib_cash_app/intermediates` to
`D:/cash-app-build/cash-app-rust-plugin-intermediates-20261004`. Exact source/
destination and all children were validated, reparse contents rejected, and
file counts/total bytes checked after the move. The original path is a junction;
all prior junctions/native caches remain. Preserve it on future local builds.
This moved generated build output, not source, app data or financial records.

Logs in `app/.dart_tool`: `consent-android-x64-release-build.log` (cache failure),
`consent-android-x64-release-build-retry.log` (registrant failure),
`consent-android-release-locked-pub.log`,
`consent-android-x64-release-build-regenerated.log` (generic build),
`consent-android-x64-release-build-split.log` (verified artifact),
`consent-android-release-production-ui.log` (badging rejection),
`consent-android-release-production-ui-split.log` (hint failure),
`consent-android-release-production-ui-hints.log` (occluded action failure),
and the final `...-uncovered.log` above.

## Limits and remaining work

No ARM phone runtime/artifact, fresh clean checkout, enrolled physical
biometrics, actual TalkBack, production release household/network consent,
public relay deployment or current-source iOS claim follows from this pass.
Debug-emulator OS-vault/authenticated consent and production web consent have
separate evidence in [PREFIX-CONSENT.md](PREFIX-CONSENT.md). The main manifest's
production network protections were not relaxed to run an HTTP fixture.
No public deployment, cloud job, purchase or repository visibility change.

Vendor source inspected locally at pinned Flutter
`6a19cca56475dbfba1478ee68d7bd0c2ef891da1`:
[mode regeneration](https://github.com/flutter/flutter/blob/6a19cca56475dbfba1478ee68d7bd0c2ef891da1/packages/flutter_tools/lib/src/runner/flutter_command.dart),
[release dev-plugin filtering](https://github.com/flutter/flutter/blob/6a19cca56475dbfba1478ee68d7bd0c2ef891da1/packages/flutter_tools/lib/src/flutter_plugins.dart),
[ABI-split packaging](https://github.com/flutter/flutter/blob/6a19cca56475dbfba1478ee68d7bd0c2ef891da1/packages/flutter_tools/gradle/src/main/kotlin/FlutterPlugin.kt).
