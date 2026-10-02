import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:private_ledger/data/rust/api/goals.dart';
import 'package:private_ledger/data/rust/api/budgets.dart';
import 'package:private_ledger/data/rust/api/ledger.dart';
import 'package:private_ledger/data/rust/frb_generated.dart';
import 'package:private_ledger/data/storage/event_store.dart';
import 'package:private_ledger/features/ledger/ledger_controller.dart';

class _Paths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

void main() {
  final libraryPath = Platform.environment['RUST_LIB_PATH'];
  group(
    'real savings-goal currency validation',
    () {
      late Directory directory;
      late PathProviderPlatform previousPaths;
      setUpAll(() async {
        await RustLib.init(externalLibrary: ExternalLibrary.open(libraryPath!));
      });
      setUp(() async {
        directory = await Directory.systemTemp.createTemp(
          'cash-goal-currency-',
        );
        previousPaths = PathProviderPlatform.instance;
        PathProviderPlatform.instance = _Paths(directory.path);
      });
      tearDown(() async {
        PathProviderPlatform.instance = previousPaths;
        await directory.delete(recursive: true);
      });

      test(
        'JPY target uses linked-account units through edit and restart',
        () async {
          final controller = LedgerController();
          addTearDown(controller.dispose);
          await controller.initialize();
          expect(
            await controller.createAccount(name: 'Yen', currencyCode: 'JPY'),
            isTrue,
          );
          expect(
            await controller.addOrUpdateGoal(
              name: 'Yen savings',
              kind: GoalKind.save,
              targetAmount: '100',
              linkedAccountId: 'yen',
            ),
            isTrue,
          );
          expect(controller.goals.single.targetLabel, 'JPY 100');
          final id = controller.goals.single.id;
          expect(
            await controller.addOrUpdateGoal(
              goalId: id,
              name: 'Yen savings',
              kind: GoalKind.save,
              targetAmount: '123',
              linkedAccountId: 'yen',
            ),
            isTrue,
          );
          final restarted = LedgerController();
          addTearDown(restarted.dispose);
          await restarted.initialize();
          expect(restarted.errorMessage, isNull);
          expect(restarted.goals.single.targetLabel, 'JPY 123');
        },
      );

      test('fractional JPY and unknown linked accounts cannot persist invalid goals', () async {
        final controller = LedgerController();
        addTearDown(controller.dispose);
        await controller.initialize();
        expect(
          await controller.createAccount(name: 'Yen', currencyCode: 'JPY'),
          isTrue,
        );
        final before = await EventStore('goals').readLog();
        expect(
          await controller.addOrUpdateGoal(
            name: 'Invalid yen',
            kind: GoalKind.save,
            targetAmount: '1.5',
            linkedAccountId: 'yen',
          ),
          isFalse,
        );
        expect(await EventStore('goals').readLog(), orderedEquals(before));
        expect(
          await controller.addOrUpdateGoal(
            name: 'Missing account',
            kind: GoalKind.save,
            targetAmount: '100',
            linkedAccountId: 'missing',
          ),
          isFalse,
        );
        expect(await EventStore('goals').readLog(), orderedEquals(before));
        final restarted = LedgerController();
        addTearDown(restarted.dispose);
        await restarted.initialize();
        expect(restarted.errorMessage, isNull);
        expect(restarted.goals, isEmpty);
      });
      test(
        'missing linked account is rejected before writing a goal',
        () async {
          final controller = LedgerController();
          addTearDown(controller.dispose);
          await controller.initialize();
          final before = await EventStore('goals').readLog();
          expect(
            await controller.addOrUpdateGoal(
              name: 'Missing account',
              kind: GoalKind.save,
              targetAmount: '100',
              linkedAccountId: 'missing',
            ),
            isFalse,
          );
          expect(await EventStore('goals').readLog(), orderedEquals(before));
          final restarted = LedgerController();
          addTearDown(restarted.dispose);
          await restarted.initialize();
          expect(restarted.errorMessage, isNull);
          expect(restarted.goals, isEmpty);
        },
      );
      for (final saving in [true, false]) {
        test(
          'maximum i64 ${saving ? 'saving' : 'budget'} progress persists without failed saves',
          () async {
            const maximum = '92233720368547758.07';
            final controller = LedgerController();
            addTearDown(controller.dispose);
            await controller.initialize();
            final account = controller.overview!.accounts.first.id;
            if (saving) {
              expect(
                await controller.addOrUpdateGoal(
                  name: 'Large',
                  kind: GoalKind.save,
                  targetAmount: maximum,
                  linkedAccountId: account,
                ),
                isTrue,
              );
            } else {
              expect(
                await controller.addOrUpdateBudget(
                  name: 'Large',
                  limitAmount: maximum,
                  period: BudgetPeriodKind.monthly,
                ),
                isTrue,
              );
            }
            expect(
              await controller.record(
                title: 'Maximum',
                amount: maximum,
                kind: saving ? EntryKind.income : EntryKind.expense,
                accountId: account,
              ),
              isTrue,
            );
            expect(controller.errorMessage, isNull);
            if (saving) {
              expect(controller.goals.single.percentComplete.toInt(), 100);
              expect(
                await controller.addOrUpdateGoal(
                  goalId: controller.goals.single.id,
                  name: 'Large',
                  kind: GoalKind.save,
                  targetAmount: '0.01',
                  linkedAccountId: account,
                ),
                isTrue,
              );
            } else {
              expect(controller.budgets.single.percentUsed.toInt(), 100);
              expect(
                await controller.addOrUpdateBudget(
                  budgetId: controller.budgets.single.id,
                  name: 'Large',
                  limitAmount: '0.01',
                  period: BudgetPeriodKind.monthly,
                ),
                isTrue,
              );
            }
            final restarted = LedgerController();
            addTearDown(restarted.dispose);
            await restarted.initialize();
            expect(restarted.errorMessage, isNull);
            expect(
              restarted.overview!.transactions.single.amountLabel,
              'USD $maximum',
            );
            expect(
              saving
                  ? restarted.goals.single.percentComplete.toInt()
                  : restarted.budgets.single.percentUsed.toInt(),
              9223372036854775807,
            );
          },
        );
      }
      test(
        'spending category and deadline survive edits and SQLite restart',
        () async {
          final controller = LedgerController();
          addTearDown(controller.dispose);
          await controller.initialize();
          final category = controller.categories.first.id;
          final account = controller.overview!.accounts.first.id;
          final deadline = PlatformInt64Util.from(
            DateTime(2000).millisecondsSinceEpoch,
          );
          expect(
            await controller.addOrUpdateGoal(
              name: 'Food cap',
              kind: GoalKind.spend,
              targetAmount: '100',
              categoryId: category,
              deadlineMillis: deadline,
            ),
            isTrue,
          );
          final id = controller.goals.single.id;
          expect(
            await controller.record(
              title: 'Counted food',
              amount: '10',
              kind: EntryKind.expense,
              accountId: account,
              categoryId: category,
            ),
            isTrue,
          );
          expect(
            await controller.record(
              title: 'Other expense',
              amount: '5',
              kind: EntryKind.expense,
              accountId: account,
            ),
            isTrue,
          );
          expect(controller.goals.single.progressLabel, 'USD 0.00');
          final restarted = LedgerController();
          addTearDown(restarted.dispose);
          await restarted.initialize();
          expect(restarted.errorMessage, isNull);
          expect(restarted.goals.single.categoryId, category);
          expect(restarted.goals.single.deadlineMillis, deadline);
          final ledgerBefore = await EventStore('ledger').readLog();
          expect(
            await restarted.addOrUpdateGoal(
              goalId: id,
              name: 'Food cap',
              kind: GoalKind.spend,
              targetAmount: '100',
              categoryId: category,
            ),
            isTrue,
          );
          expect(restarted.goals.single.progressLabel, 'USD 10.00');
          expect(
            await restarted.addOrUpdateGoal(
              goalId: id,
              name: 'All spending',
              kind: GoalKind.spend,
              targetAmount: '100',
            ),
            isTrue,
          );
          expect(restarted.goals.single.progressLabel, 'USD 15.00');
          expect(
            await EventStore('ledger').readLog(),
            orderedEquals(ledgerBefore),
          );
          final finalRestart = LedgerController();
          addTearDown(finalRestart.dispose);
          await finalRestart.initialize();
          expect(finalRestart.errorMessage, isNull);
          expect(finalRestart.goals.single.progressLabel, 'USD 15.00');
          expect(finalRestart.goals.single.categoryId, isNull);
          expect(finalRestart.goals.single.deadlineMillis, isNull);
        },
      );
    },
    skip: libraryPath == null
        ? 'Set RUST_LIB_PATH for actual bridge tests'
        : false,
  );
}
