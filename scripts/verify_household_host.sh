#!/usr/bin/env bash
# Runs the Dart household controller against the real Rust library on this
# machine (no simulator): builds the bridge crate as a shared library and
# points test/household_host_test.dart at it.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
(cd "$root/rust" && cargo build -p rust_lib_cash_app)

case "$(uname -s)" in
  Darwin) library="librust_lib_cash_app.dylib" ;;
  MINGW*|MSYS*|CYGWIN*) library="rust_lib_cash_app.dll" ;;
  *) library="librust_lib_cash_app.so" ;;
esac

cd "$root/app"
RUST_LIB_PATH="$root/rust/target/debug/$library" \
  flutter test test/household_host_test.dart
