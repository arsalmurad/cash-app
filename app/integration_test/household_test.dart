import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:private_ledger/data/rust/frb_generated.dart';

import '../test_support/household_scenario.dart';
import '../test_support/native_vault_scenario.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // `RustLib.init()` refuses to run twice in one process, so the whole
  // scenario is one test (see integration_test/ledger_test.dart).
  testWidgets(
    'two devices share expenses through MLS and a relay, through the real bridge',
    (tester) async {
      await RustLib.init();
      await runNativeVaultScenario();
      await runHouseholdScenario();
    },
  );
}
