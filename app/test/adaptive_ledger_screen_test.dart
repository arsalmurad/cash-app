import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/data/rust/api/ledger.dart';
import 'package:private_ledger/features/ledger/budgets_pane.dart';
import 'package:private_ledger/features/ledger/goals_pane.dart';
import 'package:private_ledger/features/ledger/ledger_controller.dart';
import 'package:private_ledger/features/ledger/ledger_screen.dart';
import 'package:private_ledger/features/ledger/recurring_pane.dart';

void main() {
  for (final size in [
    const Size(360, 740),
    const Size(840, 600),
    const Size(1280, 900),
  ]) {
    for (final brightness in Brightness.values) {
      testWidgets('all ledger destinations at $size, $brightness, 1.5x text', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final controller = LedgerController()
          ..isLoading = false
          ..overview = const LedgerOverview(
            balanceLabel: 'USD 1987.66',
            accounts: [
              AccountView(
                id: 'daily',
                name: 'Everyday',
                currencyCode: 'USD',
                balanceLabel: 'USD 1987.66',
              ),
            ],
            transactions: [
              TransactionView(
                id: 'groceries',
                accountId: 'daily',
                title: 'Groceries',
                amountLabel: 'USD 12.34',
                voided: false,
                isExpense: true,
              ),
            ],
            transfers: [],
          );
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(useMaterial3: true, brightness: brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(1.5)),
              child: child!,
            ),
            home: LedgerScreen(controller: controller),
          ),
        );
        await tester.pumpAndSettle();
        final wide = size.width >= 840;
        expect(
          find.byType(NavigationRail),
          wide ? findsOneWidget : findsNothing,
        );
        expect(
          find.byType(NavigationBar),
          wide ? findsNothing : findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        final destinations = <String, Type>{
          'Activity': ActivityPane,
          'Budgets': BudgetsPane,
          'Goals': GoalsPane,
          'Recurring': RecurringPane,
          'Overview': OverviewPane,
        };
        for (final destination in destinations.entries) {
          final target = find.descendant(
            of: find.byType(wide ? NavigationRail : NavigationBar),
            matching: find.text(destination.key),
          );
          expect(target.hitTestable(), findsOneWidget);
          await tester.tap(target);
          await tester.pumpAndSettle();
          expect(find.byType(destination.value), findsOneWidget);
          expect(
            tester.takeException(),
            isNull,
            reason: '${destination.key} must fit without render overflow',
          );
        }
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
