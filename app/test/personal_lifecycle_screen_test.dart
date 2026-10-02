import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/data/rust/api/budgets.dart';
import 'package:private_ledger/data/rust/api/goals.dart';
import 'package:private_ledger/data/rust/api/ledger.dart';
import 'package:private_ledger/data/rust/api/recurring.dart';
import 'package:private_ledger/features/ledger/ledger_controller.dart';
import 'package:private_ledger/features/ledger/ledger_screen.dart';

class _Controller extends LedgerController {
  _Controller() {
    isLoading = false;
    overview = const LedgerOverview(
      balanceLabel: 'USD 0.00',
      accounts: [],
      transactions: [],
      transfers: [],
    );
    budgets = [
      BudgetView(
        id: 'food',
        name: 'Food',
        categoryId: null,
        periodLabel: 'This month',
        limitLabel: 'USD 10.00',
        spentLabel: 'USD 0.00',
        percentUsed: PlatformInt64Util.from(0),
      ),
    ];
    goals = [
      GoalView(
        id: 'holiday',
        name: 'Holiday',
        isSave: false,
        linkedAccountId: null,
        categoryId: null,
        targetLabel: 'USD 100.00',
        progressLabel: 'USD 0.00',
        percentComplete: PlatformInt64Util.from(0),
      ),
    ];
    upcoming = [
      UpcomingView(
        recurringId: 'rent',
        title: 'Rent',
        isExpense: true,
        amountLabel: 'USD 1.23',
        accountId: 'cash',
        categoryId: null,
        frequency: RecurringFrequency.daily,
        occurrenceMillis: PlatformInt64Util.from(0),
        isOverdue: true,
      ),
    ];
  }
  final calls = <String>[];
  Completer<bool>? pending;
  Future<bool> _remove(String id) async {
    calls.add(id);
    final saved = await (pending?.future ?? Future.value(true));
    if (saved) {
      budgets = budgets.where((item) => item.id != id).toList();
      goals = goals.where((item) => item.id != id).toList();
      upcoming = upcoming.where((item) => item.recurringId != id).toList();
      notifyListeners();
    } else {
      errorMessage = 'Save could not be confirmed. Restart before retrying.';
    }
    return saved;
  }

  @override
  Future<bool> removeBudget(String id) => _remove(id);
  @override
  Future<bool> removeGoal(String id) => _remove(id);
  @override
  Future<bool> stopRecurring(String id) => _remove(id);
}

void main() {
  for (final (tab, kind, id) in [
    ('Budgets', 'budget', 'food'),
    ('Goals', 'goal', 'holiday'),
    ('Recurring', 'recurring rule', 'rent'),
  ]) {
    testWidgets(
      '$kind small-phone confirmation keeps or removes only on consent',
      (tester) async {
        tester.view.physicalSize = const Size(360, 740);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final controller = _Controller();
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          MaterialApp(home: LedgerScreen(controller: controller)),
        );
        await tester.tap(find.text(tab));
        await tester.pumpAndSettle();
        final action = kind == 'recurring rule'
            ? 'Stop recurring rule'
            : 'Remove $kind';
        Future<void> open() async {
          await tester.tap(find.byTooltip('$kind actions'));
          await tester.pumpAndSettle();
          await tester.tap(find.text(action));
          await tester.pumpAndSettle();
        }

        await open();
        expect(
          find.textContaining(
            kind == 'recurring rule'
                ? 'Transactions already recorded stay'
                : 'transactions and balances stay unchanged',
          ),
          findsOneWidget,
        );
        await tester.tap(find.text('Keep $kind'));
        await tester.pumpAndSettle();
        expect(controller.calls, isEmpty);
        await open();
        await tester.tap(find.widgetWithText(FilledButton, action));
        await tester.pumpAndSettle();
        expect(controller.calls, [id]);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'pending removal blocks repeat actions and a failed save stays visible',
    (tester) async {
      final controller = _Controller()..pending = Completer<bool>();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(home: LedgerScreen(controller: controller)),
      );
      await tester.tap(find.text('Budgets'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('budget actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove budget'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Remove budget'));
      await tester.pump();
      expect(controller.calls, ['food']);
      expect(
        tester
            .widget<FloatingActionButton>(find.byType(FloatingActionButton))
            .onPressed,
        isNull,
      );
      controller.pending!.complete(false);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Save could not be confirmed'),
        findsOneWidget,
      );
      expect(controller.budgets, hasLength(1));
    },
  );
}
