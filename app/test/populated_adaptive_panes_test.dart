import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/data/rust/api/budgets.dart';
import 'package:private_ledger/data/rust/api/goals.dart';
import 'package:private_ledger/data/rust/api/recurring.dart';
import 'package:private_ledger/features/ledger/budgets_pane.dart';
import 'package:private_ledger/features/ledger/goals_pane.dart';
import 'package:private_ledger/features/ledger/recurring_pane.dart';

void main() {
  for (final size in [
    const Size(360, 740),
    const Size(840, 600),
    const Size(1280, 900),
  ]) {
    for (final brightness in Brightness.values) {
      testWidgets('populated controls at $size, $brightness, 1.5x text', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        var edits = 0;
        var records = 0;
        final panes = <String, Widget>{
          'budget actions': BudgetsPane(
            budgets: [
              BudgetView(
                id: 'food',
                name: 'Household food and everyday supplies',
                periodLabel: 'Last 365 days',
                limitLabel: 'USD 10000000000000000.00',
                spentLabel: 'USD 123.45',
                percentUsed: PlatformInt64Util.from(0),
              ),
            ],
            categories: const [],
            onEdit: (_) => edits++,
            onRemove: (_) {},
          ),
          'goal actions': GoalsPane(
            goals: [
              GoalView(
                id: 'savings',
                name: 'Savings for a family holiday',
                isSave: true,
                targetLabel: 'USD 10000000000000000.00',
                progressLabel: 'USD 123.45',
                percentComplete: PlatformInt64Util.from(0),
              ),
            ],
            onEdit: (_) => edits++,
            onRemove: (_) {},
          ),
          'recurring rule actions': RecurringPane(
            upcoming: [
              UpcomingView(
                recurringId: 'bill',
                title: 'Annual household insurance payment',
                isExpense: true,
                amountLabel: 'USD 10000000000000000.00',
                accountId: 'daily',
                frequency: RecurringFrequency.yearly,
                occurrenceMillis: PlatformInt64Util.from(0),
                isOverdue: true,
              ),
            ],
            onEdit: (_) => edits++,
            onStop: (_) {},
            onRecord: (_) async {
              records++;
            },
          ),
        };
        for (final entry in panes.entries) {
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(useMaterial3: true, brightness: brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(1.5)),
                child: child!,
              ),
              home: Scaffold(body: entry.value),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            tester.takeException(),
            isNull,
            reason: '${entry.key} must fit populated content',
          );
          final menu = find.byTooltip(entry.key);
          expect(menu.hitTestable(), findsOneWidget);
          await tester.tap(menu);
          await tester.pumpAndSettle();
          await tester.tap(
            find.text(switch (entry.key) {
              'budget actions' => 'Edit budget',
              'goal actions' => 'Edit goal',
              _ => 'Edit recurring rule',
            }),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          if (entry.key == 'recurring rule actions') {
            expect(find.text('Record').hitTestable(), findsOneWidget);
            await tester.tap(find.text('Record'));
            await tester.pumpAndSettle();
          }
        }
        expect(edits, 3);
        expect(records, 1);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
