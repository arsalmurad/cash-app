import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:private_ledger/data/rust/api/budgets.dart';
import 'package:private_ledger/data/rust/api/goals.dart';
import 'package:private_ledger/data/rust/api/ledger.dart';
import 'package:private_ledger/data/rust/api/recurring.dart';
import 'package:private_ledger/data/rust/frb_generated.dart';
import 'package:private_ledger/features/ledger/ledger_controller.dart';

class _Paths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Paths(this.path);
  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}

Future<void> _writePlans(LedgerController controller, String label) async {
  expect(
    await controller.addOrUpdateBudget(
      name: '$label budget',
      limitAmount: '100.00',
      period: BudgetPeriodKind.monthly,
    ),
    isTrue,
  );
  expect(
    await controller.addOrUpdateGoal(
      name: '$label goal',
      kind: GoalKind.save,
      targetAmount: '200.00',
      linkedAccountId: 'everyday',
    ),
    isTrue,
  );
  expect(
    await controller.addOrUpdateRecurring(
      title: '$label recurring',
      kind: RecurringKind.expense,
      amount: '1.00',
      accountId: 'everyday',
      frequency: RecurringFrequency.monthly,
      startMillis: PlatformInt64Util.from(
        DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch,
      ),
    ),
    isTrue,
  );
}

void main() {
  final libraryPath = Platform.environment['RUST_LIB_PATH'];
  test(
    'new entries survive restart after recovery from a torn frame',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'ledger-recovery-',
      );
      final previousPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths(directory.path);
      addTearDown(() async {
        PathProviderPlatform.instance = previousPaths;
        await directory.delete(recursive: true);
      });
      await RustLib.init(externalLibrary: ExternalLibrary.open(libraryPath!));

      final original = LedgerController();
      addTearDown(original.dispose);
      await original.initialize();
      expect(original.errorMessage, isNull);
      expect(
        await original.record(
          accountId: 'everyday',
          title: 'Before crash',
          amount: '12.34',
          kind: EntryKind.expense,
        ),
        isTrue,
      );

      await _writePlans(original, 'Before crash');
      // Simulate a process dying partway through each log's next frame.
      final logs = directory
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.log'))
          .toList();
      expect(logs.length, 5); // all five durable logs
      for (final file in logs) {
        await file.writeAsBytes(
          Uint8List.fromList([1, 0, 0]),
          mode: FileMode.append,
          flush: true,
        );
      }

      final recovered = LedgerController();
      addTearDown(recovered.dispose);
      await recovered.initialize();
      expect(recovered.errorMessage, isNull);
      expect(recovered.truncatedBytes, 3);
      expect(
        await recovered.record(
          accountId: 'everyday',
          title: 'After crash',
          amount: '5.00',
          kind: EntryKind.expense,
        ),
        isTrue,
      );
      expect(
        await recovered.addCategory(
          name: 'Recovered category',
          iconKey: 'home',
        ),
        isNotNull,
      );
      await _writePlans(recovered, 'After crash');

      final restarted = LedgerController();
      addTearDown(restarted.dispose);
      await restarted.initialize();
      expect(restarted.errorMessage, isNull);
      expect(restarted.truncatedBytes, 0);
      expect(restarted.overview!.balanceLabel, 'USD -17.34');
      expect(
        restarted.overview!.transactions.map((entry) => entry.title),
        containsAll(['Before crash', 'After crash']),
      );
      expect(
        restarted.categories.map((category) => category.name),
        contains('Recovered category'),
      );
      expect(
        restarted.budgets.map((item) => item.name),
        containsAll(['Before crash budget', 'After crash budget']),
      );
      expect(
        restarted.goals.map((item) => item.name),
        containsAll(['Before crash goal', 'After crash goal']),
      );
      expect(
        restarted.upcoming.map((item) => item.title),
        containsAll(['Before crash recurring', 'After crash recurring']),
      );
      expect(
        directory.listSync().whereType<File>().where(
          (file) => file.path.contains('.recovery-'),
        ),
        hasLength(5),
      );
    },
    skip: libraryPath == null
        ? 'set RUST_LIB_PATH to the built Rust library'
        : false,
  );
}
