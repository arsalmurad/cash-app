# Current Android production release evidence

Initial verification 2026-10-04. Production app through `1edf8a5`, evidence head `f855f34`,
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

## ARM64 packaging and explicit final-library alignment (2026-10-04)

The final release splits below supersede the initial x86_64 artifact above.
Flutter UI, generated bridge ABI `1237803201`, lockfiles and pinned tools are
unchanged. `rust/api/build.rs` makes max/common page size explicit only at the
final 64-bit Android `cdylib` link. This is defensive build hardening, **not a
proven pre-existing runtime crash repair**. Other platforms and 32-bit Android
receive no new flags; dependency-wide `RUSTFLAGS` and Cargokit are unchanged.

| Split | Bytes | SHA-256 |
| --- | ---: | --- |
| `app-arm64-v8a-release.apk` | 28,483,149 | `5e5cd35371d60c796d16b67040243e334f548c105ce8c119800584b94339f6ba` |
| `app-x86_64-release.apk` | 30,652,017 | `3207859e31b52e706b426b7620d2040a0c14b7b45090b65e53a3bcb242d0d389` |

Both are in `app/build/app/outputs/flutter-apk`, package version `0.1.0`, split
codes 2001/4001, private-prototype debug-key release signing. Each reports only
its exact ABI and is not debuggable. Every native library's actual ELF64 machine
matches; Dart AOT, Flutter, JNI and Rust code are present. Android's own
`zipalign -v -c -P 16 4` passes. All LOAD alignments are at least 16 KB, with
valid file/address congruence. Rust RELRO ends now align exactly to 16 KB;
ARM Flutter's unchanged RELRO occupies its entire LOAD and passes the verified
whole-segment exception without overlapping another writable region.

Tracked `scripts/verify_android_release_artifact.mjs` inspects/extracts only
safe native ZIP entries into its own disposable directory; it never installs
or runs an artifact. Both invocations terminate **exit 0**, with hashes and
per-library inventories in ignored `android-arm64-final-artifact.log` and
`android-x64-final-artifact.log`. Four Node regression tests reject wrong
machine/class/format, truncated tables, bad LOAD/partial RELRO alignment and
unsafe adjacent writable data, while permitting the whole-LOAD case. Three
standalone Rust tests verify both flags and non-Android/32-bit exclusions.

The final x86_64 split independently passes the unchanged production UI driver
on owned `Phase0Api36` / `emulator-5580`, Android 16/API 36: real unique 12.34
expense, exact 1,234-minor-unit balance change, force-stop/cold launch, explicit
removal confirmation and second cold launch. **Exit 0**, ignored log
`android-aligned-release-production-ui.log`; existing app data preserved.
This emulator was not a 16 KB runtime, and no ARM phone was connected.

### Exact commands, costs and failed checks

ARM Flutter artifacts were cached. Only the missing `aarch64-linux-android`
standard library was added to existing Rust stable **1.98.1**, without a
compiler upgrade. Rustup's transfer stalled; curl retrieved the official
29,448,296-byte archive, resuming after a timeout. Its SHA-256 matched the
installed pinned manifest exactly:
`d7c4949bb77b007bed188c9b15b8267a3222dc9b9c517f05d1899f9e885fb79e`.
Rustup then installed from that verified cache. The archive remains cached.

From `app`, with the existing D: Android/JDK/Gradle/temp environment:

```text
flutter --no-version-check build apk --release --target-platform android-arm64 --split-per-abi
flutter --no-version-check build apk --release --target-platform android-arm64,android-x64 --split-per-abi --no-pub
```

The first new-target build passed in **1,314.1 s**; its historical ARM APK was
28,483,149 bytes, hash `7e1a2811de45b8c91393ada2a061eaa2f2f1ec2559f04d4a4a4a12a874e7e55c`.
The explicit-link-boundary rebuild passed in **310.1 s**, reusing dependencies
with `CARGO_BUILD_JOBS=2`, rather than changing global compiler flags and
rebuilding all dependencies. Logs: `consent-android-arm64-release-build.log`
and `android-64bit-page-alignment-build.log`. The latter's helper dependency
report was again only `c:` → `C:` path spelling, not a version upgrade.

```text
node --test scripts/verify_android_release_artifact.test.mjs
node scripts/verify_android_release_artifact.mjs arm64-v8a
node scripts/verify_android_release_artifact.mjs x86_64
ANDROID_DEVICE_SERIAL=emulator-5580 node scripts/verify_android_release_ui.mjs
rustc +stable --edition 2024 --test rust/api/tests/android_link_flags.rs -o app/.dart_tool/android-link-flags-test.exe
app/.dart_tool/android-link-flags-test.exe
```

Verifier tools can be overridden with `AAPT_BINARY`, `JAR_BINARY` and
`ZIPALIGN_BINARY`; Windows defaults use the installed SDK 36/JDK 17. Use an
allowed temporary directory, or host permission for the designated D: cache.
One D: extraction attempt correctly failed sandbox permissions before reading
ELF files; it is not a packaging failure.

The initial custom checker incorrectly required every RELRO end to align,
flagging both old Rust and ARM Flutter. Independent installed NDK
`llvm-readelf -Wl` showed each RELRO was the **entire** corresponding LOAD.
The [actual Android linker](https://android.googlesource.com/platform/bionic/+/android16-qpr2-release/linker/linker_phdr_16kib_compat.cpp)
explicitly exempts that case; the corrected checker and its negative controls
pass even on the pre-hardening ARM artifact. Do not present those preliminary
false positives as library incompatibility or a repaired crash. Raw diagnostic
log: `android-arm64-before-readelf.log`.

An exploratory Cargokit helper regression reproduced the absent companion
flag; its old test runner could not load the pinned Dart frontend snapshot,
so a direct cached-Dart check was used. The helper edit was rejected in favor
of the final-library-only hook; neither helper nor its temporary test is in
the deliverable. The new Rust/Node tests above are the tracked regression
checks. No generated Java edit, SDK upgrade, public deploy or cloud job.

Vendor references: [Android alignment checks and flags](https://developer.android.com/guide/practices/page-sizes),
[Cargo final-cdylib link directive](https://doc.rust-lang.org/cargo/reference/build-scripts.html#rustc-link-arg-cdylib).
Packaging passes do not prove code's page-size-independent behavior. ARM phone,
16 KB OS, release household/network, clean-checkout and final iOS runtime
remain open. The earlier native/Chrome suites were not rerun for this Android-
only link configuration and are not relabeled as current-source full suites.

### Additional preserved JNI cache

After release verification, low C: headroom was recovered by moving only the
four generated native-plugin JNI files (**265.9 MiB**) from
`app/build/rust_lib_cash_app/jniLibs` to
`D:/cash-app-build/cash-app-rust-plugin-jni-libs-20261004`. Exact paths and
children were validated, reparse children refused, and every relative filename,
length and SHA-256 matched after relocation. The original path is now a junction;
preserve it and all previous cache junctions. No source, app data, financial
records or unrelated generated artifacts were removed. Headroom immediately
after relocation: C: 1.19 GiB, D: 1.96 GiB; recheck before new builds.

### Balanced Flutter cache placement (2026-10-05)

The updated category APK build passes in 359.6 s, but the owned emulator's
disk-space check refuses startup with only 1.37 GiB free on D:. This is an
environment refusal before app execution, not an app failure. The completed
owned Gradle daemon was stopped. Sixteen generated cache directories, 312
files / **1,074.1 MiB**, were relocated from below
`D:/cash-app-build/cash-app-flutter-build-cache-20261004` to the new ignored
`app/.dart_tool/preserved-flutter-cache-20261005` on C:. Every relative filename,
length and SHA-256 matched; each original D: child path is a junction to its
same-name C: directory. The existing outer `app/.dart_tool/flutter_build`
junction and all native build junctions remain intact. Preserve both roots and
these sixteen child junctions; no cache rebuild or ledger deletion was used.

The first cross-drive move transferred its nineteen files but could not remove
the empty read-only source directory. That exact folder was recovered to its
original path with matching hashes; only the confirmed empty temporary folder
was removed. The subsequent validated move clears only the selected generated
directory's read-only attribute and completes with matching hashes. Headroom
immediately afterward: C: 2.75 GiB, D: 2.41 GiB. Recheck before further builds.

## Updated category UI release acceptance (2026-10-05)

App source `4928159` (build checkout `cac75d4`), unchanged consent bridge ABI
`1237803201`, pinned tools above. The cached build succeeds in **359.6 s**:
`flutter --no-version-check build apk --release --target-platform
android-arm64,android-x64 --split-per-abi --no-pub`. The existing SDK XML warning
remains; the Cargokit path-case refresh changes no dependency version.

| Release split | Bytes | SHA-256 |
| --- | ---: | --- |
| `app-arm64-v8a-release.apk` | 28,483,149 | `3a661b3a8af1620cca3b2017b5bb1a21dfac1b6d2a11e33d76ace158299c612e` |
| `app-x86_64-release.apk` | 30,652,017 | `236b642aefa57aa4978bfe18be3c3a6b234ee94216be125bddc6371b51a1bd7d` |

Both `node scripts/verify_android_release_artifact.mjs arm64-v8a` and the
`x86_64` invocation exit 0: exact ABI/machine inventories, nondebuggable/AOT,
16 KB ZIP/LOAD and valid RELRO layouts. Both native Rust library hashes remain
the same as the preceding final-link artifact; Dart AOT hashes change. These
are still debug-key-signed private-prototype artifacts, not store releases.

After the disk-headroom recovery above, actual `Phase0Api36` / `emulator-5580`
Android 36 x86_64 passes (terminal exit 0):
`ANDROID_DEVICE_SERIAL=emulator-5580 ANDROID_CATEGORIES=1
node scripts/verify_android_release_ui.mjs`. Normal production controls create
one random-ID 12.34 expense, verify the exact 1,234-minor-unit balance change,
force-stop/restart persistence, explicitly confirm removal, and restart with
the original balance. No app reset/uninstall occurs; immutable fixture history
remains. UiAutomator then observes all twelve uniquely named, clickable icon
choices with exactly one selected state, taps Travel icon and observes its
selection, cancels a populated creation and existing-category editor, and
restarts with the original exact balance. This is actual native semantics/
pointer evidence, not TalkBack, private SQLite-byte inspection or a long-list
mobile/200%-text proof.

Ignored logs under `app/.dart_tool`: `category-current-android-release-build.log`,
`category-android-arm64-artifact.log`, `category-android-x64-artifact.log`,
`category-current-android-release-ui.log`. The four Node ELF-verifier negative-
control tests also pass. ARM phone, 16 KB OS, release household/TLS runtime,
clean-checkout and final iOS remain open. Earlier full-suite results are not
relabeled as current-source complete acceptance.
