// Runs the two-device household scenario on the development machine against
// the real Rust library, so the Dart controller is checked without a
// simulator. It only runs when RUST_LIB_PATH points at a built
// `librust_lib_cash_app` (scripts/verify_household_host.sh builds it); on
// device the same scenario runs via integration_test/household_test.dart.
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/data/rust/frb_generated.dart';

import '../test_support/household_scenario.dart';

void main() {
  final libraryPath = Platform.environment['RUST_LIB_PATH'];

  test(
    'two devices share expenses through MLS and a relay (host build)',
    () async {
      await RustLib.init(externalLibrary: ExternalLibrary.open(libraryPath!));
      await runHouseholdScenario();
    },
    skip: libraryPath == null
        ? 'set RUST_LIB_PATH to a built librust_lib_cash_app'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
