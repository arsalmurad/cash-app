import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/data/rust/api/budgets.dart';
import 'package:private_ledger/data/rust/api/categories.dart';
import 'package:private_ledger/features/ledger/budgets_pane.dart';

void main() {
  testWidgets('empty state prompts to add a budget', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: BudgetsPane(budgets: [], categories: [])),
      ),
    );

    expect(find.textContaining('No budgets yet'), findsOneWidget);
  });

  testWidgets('a budget card shows its name, period, spend, and percent', (
    tester,
  ) async {
    final budget = BudgetView(
      id: 'groceries',
      name: 'Groceries',
      categoryId: 'food',
      periodLabel: 'This month',
      limitLabel: 'USD 200.00',
      spentLabel: 'USD 50.00',
      percentUsed: PlatformInt64Util.from(25),
    );
    const categories = [
      CategoryView(id: 'food', name: 'Food', iconKey: 'restaurant'),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BudgetsPane(budgets: [budget], categories: categories),
        ),
      ),
    );

    expect(find.text('Groceries'), findsOneWidget);
    expect(find.text('This month'), findsOneWidget);
    expect(find.text('Food'), findsOneWidget);
    expect(find.text('USD 50.00 of USD 200.00'), findsOneWidget);
    expect(find.text('25%'), findsOneWidget);
  });

  testWidgets('a budget with no category shows "All categories"', (
    tester,
  ) async {
    final budget = BudgetView(
      id: 'everything',
      name: 'Everything',
      categoryId: null,
      periodLabel: 'This week',
      limitLabel: 'USD 100.00',
      spentLabel: 'USD 10.00',
      percentUsed: PlatformInt64Util.from(10),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: BudgetsPane(budgets: [budget], categories: const [])),
      ),
    );

    expect(find.text('All categories'), findsOneWidget);
  });

  testWidgets('NewBudgetDialog returns a BudgetDraft with a custom period', (
    tester,
  ) async {
    BudgetDraft? result;
    const categories = [
      CategoryView(id: 'food', name: 'Food', iconKey: 'restaurant'),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await showDialog<BudgetDraft>(
                  context: context,
                  builder: (context) =>
                      const NewBudgetDialog(categories: categories),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).first, 'Groceries');
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Limit amount'),
      '200',
    );

    await tester.tap(find.byKey(const Key('budgetPeriodDropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Custom (rolling days)').last);
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Days'),
      '14',
    );

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.name, 'Groceries');
    expect(result!.limitAmount, '200');
    expect(result!.period, BudgetPeriodKind.custom);
    expect(result!.customPeriodDays, 14);
  });

  testWidgets('tapping a budget\'s edit icon opens the dialog pre-filled', (
    tester,
  ) async {
    final budget = BudgetView(
      id: 'groceries',
      name: 'Groceries',
      categoryId: 'food',
      periodLabel: 'Last 14 days',
      limitLabel: 'USD 200.00',
      spentLabel: 'USD 50.00',
      percentUsed: PlatformInt64Util.from(25),
    );
    const categories = [
      CategoryView(id: 'food', name: 'Food', iconKey: 'restaurant'),
    ];
    BudgetView? edited;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BudgetsPane(
            budgets: [budget],
            categories: categories,
            onEdit: (b) => edited = b,
          ),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pump();

    expect(edited, budget);
  });

  testWidgets(
    'NewBudgetDialog in edit mode pre-fills name, limit, category, and custom period',
    (tester) async {
      final budget = BudgetView(
        id: 'groceries',
        name: 'Groceries',
        categoryId: 'food',
        periodLabel: 'Last 14 days',
        limitLabel: 'USD 200.00',
        spentLabel: 'USD 50.00',
        percentUsed: PlatformInt64Util.from(25),
      );
      const categories = [
        CategoryView(id: 'food', name: 'Food', iconKey: 'restaurant'),
      ];
      BudgetDraft? result;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  result = await showDialog<BudgetDraft>(
                    context: context,
                    builder: (context) => NewBudgetDialog(
                      categories: categories,
                      existing: budget,
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Edit budget'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'Groceries'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, '200.00'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, '14'), findsOneWidget);

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(result!.categoryId, 'food');
      expect(result!.period, BudgetPeriodKind.custom);
      expect(result!.customPeriodDays, 14);
    },
  );
}
