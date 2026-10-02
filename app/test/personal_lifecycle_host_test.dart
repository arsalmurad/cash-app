import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:private_ledger/data/rust/api/budgets.dart';
import 'package:private_ledger/data/rust/api/goals.dart';
import 'package:private_ledger/data/rust/api/recurring.dart';
import 'package:private_ledger/data/rust/frb_generated.dart';
import 'package:private_ledger/data/storage/event_store.dart';
import 'package:private_ledger/features/ledger/ledger_controller.dart';

class _Paths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

class _FailingStore implements EventStore {
  _FailingStore(this.delegate, this.afterCommit);
  final EventStore delegate;
  final bool afterCommit;
  bool fail = false;
  @override
  Future<Uint8List> readLog() => delegate.readLog();
  @override
  Future<void> recoverPrefix(int validLength, {required int expectedLength}) =>
      delegate.recoverPrefix(validLength, expectedLength: expectedLength);
  @override
  Future<void> appendFrame(Uint8List frame) async {
    if (!fail || afterCommit) await delegate.appendFrame(frame);
    if (fail) throw StateError('Synthetic ambiguous save');
  }
}

Future<void> _seed(LedgerController controller) async {
  await controller.initialize();
  expect(
    await controller.addOrUpdateBudget(
      name: 'Food',
      limitAmount: '10',
      period: BudgetPeriodKind.monthly,
    ),
    isTrue,
  );
  expect(
    await controller.addOrUpdateGoal(
      name: 'Holiday',
      kind: GoalKind.save,
      targetAmount: '100',
      linkedAccountId: controller.overview!.accounts.first.id,
    ),
    isTrue,
  );
  expect(
    await controller.addOrUpdateRecurring(
      title: 'Rent',
      kind: RecurringKind.expense,
      amount: '1.23',
      accountId: controller.overview!.accounts.first.id,
      frequency: RecurringFrequency.daily,
      startMillis: PlatformInt64Util.from(
        DateTime.now().millisecondsSinceEpoch,
      ),
    ),
    isTrue,
  );
}

void main() {
  final libraryPath = Platform.environment['RUST_LIB_PATH'];
  group(
    'real persisted personal lifecycle',
    () {
      late Directory directory;
      late PathProviderPlatform previousPaths;
      setUpAll(() async {
        await RustLib.init(externalLibrary: ExternalLibrary.open(libraryPath!));
      });
      setUp(() async {
        directory = await Directory.systemTemp.createTemp(
          'cash-lifecycle-test-',
        );
        previousPaths = PathProviderPlatform.instance;
        PathProviderPlatform.instance = _Paths(directory.path);
      });
      tearDown(() async {
        PathProviderPlatform.instance = previousPaths;
        await directory.delete(recursive: true);
      });

      test('removal persists but never erases recorded transactions', () async {
        final controller = LedgerController();
        addTearDown(controller.dispose);
        await _seed(controller);
        final occurrence = controller.upcoming.single;
        expect(await controller.recordUpcoming(occurrence), isTrue);
        final csv = controller.exportTransactionsCsv();
        final balance = controller.overview!.balanceLabel;
        final ledgerBytes = await EventStore('ledger').readLog();
        expect(await controller.removeBudget('missing'), isFalse);
        expect(await controller.removeGoal('missing'), isFalse);
        expect(await controller.stopRecurring('missing'), isFalse);
        expect(
          await controller.removeBudget(controller.budgets.single.id),
          isTrue,
        );
        expect(await controller.removeGoal(controller.goals.single.id), isTrue);
        expect(await controller.stopRecurring(occurrence.recurringId), isTrue);
        expect(
          await controller.recordUpcoming(occurrence),
          isFalse,
          reason: 'A stale reminder cannot record a stopped rule',
        );
        expect(
          await EventStore('ledger').readLog(),
          orderedEquals(ledgerBytes),
        );
        expect(controller.exportTransactionsCsv(), csv);
        expect(controller.overview!.balanceLabel, balance);
        final restarted = LedgerController();
        addTearDown(restarted.dispose);
        await restarted.initialize();
        expect(restarted.errorMessage, isNull);
        expect(restarted.budgets, isEmpty);
        expect(restarted.goals, isEmpty);
        expect(restarted.upcoming, isEmpty);
        expect(restarted.exportTransactionsCsv(), csv);
      });

      test('a monthly rule remains manageable after its next date leaves the upcoming window', () async {
        final controller = LedgerController();
        addTearDown(controller.dispose);
        await _seed(controller);
        expect(
          await controller.addOrUpdateRecurring(
            recurringId: controller.upcoming.single.recurringId,
            title: 'Rent',
            kind: RecurringKind.expense,
            amount: '1.23',
            accountId: controller.overview!.accounts.first.id,
            frequency: RecurringFrequency.monthly,
            startMillis: PlatformInt64Util.from(
              DateTime.now().millisecondsSinceEpoch,
            ),
          ),
          isTrue,
        );
        final current = controller.upcoming.single;
        expect(await controller.recordUpcoming(current), isTrue);
        expect(controller.upcoming, hasLength(1));
        expect(
          controller.upcoming.single.occurrenceMillis.toInt(),
          greaterThan(
            DateTime.now().add(const Duration(days: 14)).millisecondsSinceEpoch,
          ),
        );
        expect(await controller.recordUpcoming(current), isFalse);
        final beforeFutureAttempt = await EventStore('ledger').readLog();
        expect(
          await controller.recordUpcoming(controller.upcoming.single),
          isFalse,
          reason:
              'Future rules are manageable but cannot repeatedly post early',
        );
        expect(
          await EventStore('ledger').readLog(),
          orderedEquals(beforeFutureAttempt),
        );
        expect(await controller.stopRecurring(current.recurringId), isTrue);
        expect(controller.upcoming, isEmpty);
      });

      test('stale reminder cannot post the old kind after an expense becomes income', () async {
        final controller = LedgerController();
        addTearDown(controller.dispose);
        await _seed(controller);
        final old = controller.upcoming.single;
        final before = await EventStore('ledger').readLog();
        expect(
          await controller.addOrUpdateRecurring(
            recurringId: old.recurringId,
            title: old.title,
            kind: RecurringKind.income,
            amount: '1.23',
            accountId: old.accountId,
            frequency: RecurringFrequency.daily,
            startMillis: old.occurrenceMillis,
          ),
          isTrue,
        );
        expect(await controller.recordUpcoming(old), isFalse);
        expect(await EventStore('ledger').readLog(), orderedEquals(before));
        expect(
          await controller.recordUpcoming(controller.upcoming.single),
          isTrue,
        );
        expect(controller.overview!.balanceLabel, 'USD 1.23');
      });

      for (final name in ['budgets', 'goals', 'recurring']) {
        for (final afterCommit in [false, true]) {
          test(
            '$name ambiguous save afterCommit=$afterCommit freezes writes',
            () async {
              final store = _FailingStore(EventStore(name), afterCommit);
              final controller = LedgerController(
                budgetStore: name == 'budgets' ? store : null,
                goalStore: name == 'goals' ? store : null,
                recurringStore: name == 'recurring' ? store : null,
              );
              addTearDown(controller.dispose);
              await _seed(controller);
              store.fail = true;
              final saved = switch (name) {
                'budgets' => await controller.removeBudget(
                  controller.budgets.single.id,
                ),
                'goals' => await controller.removeGoal(
                  controller.goals.single.id,
                ),
                _ => await controller.stopRecurring(
                  controller.upcoming.single.recurringId,
                ),
              };
              expect(saved, isFalse);
              expect(controller.errorMessage, contains('Restart'));
              expect(controller.budgets, hasLength(1));
              expect(controller.goals, hasLength(1));
              expect(controller.upcoming, hasLength(1));
              expect(
                await controller.removeBudget(controller.budgets.single.id),
                isFalse,
              );
              final restarted = LedgerController();
              addTearDown(restarted.dispose);
              await restarted.initialize();
              expect(restarted.errorMessage, isNull);
              final remaining = switch (name) {
                'budgets' => restarted.budgets.length,
                'goals' => restarted.goals.length,
                _ => restarted.upcoming.length,
              };
              expect(remaining, afterCommit ? 0 : 1);
            },
          );
        }
      }
    },
    skip: libraryPath == null
        ? 'Set RUST_LIB_PATH for actual bridge tests'
        : false,
  );
}
