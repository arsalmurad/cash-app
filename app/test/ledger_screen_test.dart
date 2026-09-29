import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/data/rust/api/categories.dart';
import 'package:private_ledger/data/rust/api/ledger.dart';
import 'package:private_ledger/features/ledger/ledger_screen.dart';

void main() {
  testWidgets(
    'overview presents Rust ledger values and an actionable empty state',
    (tester) async {
      var addCount = 0;
      var addAccountCount = 0;
      const overview = LedgerOverview(
        balanceLabel: 'USD 0.00',
        accounts: [
          AccountView(
            id: 'everyday',
            name: 'Everyday',
            currencyCode: 'USD',
            balanceLabel: 'USD 0.00',
          ),
        ],
        transactions: [],
        transfers: [],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: OverviewPane(
              overview: overview,
              categories: const [],
              onAdd: () => addCount += 1,
              onAddAccount: () => addAccountCount += 1,
            ),
          ),
        ),
      );

      expect(find.text('USD 0.00'), findsNWidgets(2));
      expect(find.text('Everyday'), findsOneWidget);
      expect(find.text('No transactions yet'), findsOneWidget);

      await tester.tap(find.text('Add first transaction'));
      expect(addCount, 1);
    },
  );

  testWidgets('transaction tile shows its category name and icon', (
    tester,
  ) async {
    const transaction = TransactionView(
      id: 'one',
      accountId: 'everyday',
      title: 'Groceries',
      amountLabel: 'USD 12.34',
      isExpense: true,
      categoryId: 'food',
    );
    const categories = [
      CategoryView(id: 'food', name: 'Food', iconKey: 'restaurant'),
    ];

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: TransactionTile(transaction, categories: categories),
        ),
      ),
    );

    expect(find.text('Groceries'), findsOneWidget);
    expect(find.text('Food'), findsOneWidget);
    expect(find.text('−USD 12.34'), findsOneWidget);
    expect(find.byIcon(Icons.restaurant_outlined), findsOneWidget);
  });

  testWidgets('an uncategorized transaction falls back to a direction icon', (
    tester,
  ) async {
    const transaction = TransactionView(
      id: 'two',
      accountId: 'everyday',
      title: 'Mystery',
      amountLabel: 'USD 5.00',
      isExpense: false,
      categoryId: null,
    );

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: TransactionTile(transaction))),
    );

    expect(find.text('Uncategorized'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_downward_rounded), findsOneWidget);
  });

  testWidgets('typing in the activity search box narrows the shown entries', (
    tester,
  ) async {
    const transactions = [
      TransactionView(
        id: 'one',
        accountId: 'everyday',
        title: 'Groceries',
        amountLabel: 'USD 12.34',
        isExpense: true,
        categoryId: null,
      ),
      TransactionView(
        id: 'two',
        accountId: 'everyday',
        title: 'Paycheck',
        amountLabel: 'USD 2000.00',
        isExpense: false,
        categoryId: null,
      ),
    ];
    const accounts = [
      AccountView(
        id: 'everyday',
        name: 'Everyday',
        currencyCode: 'USD',
        balanceLabel: 'USD 1987.66',
      ),
    ];

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ActivityPane(
            transactions: transactions,
            transfers: [],
            categories: [],
            accounts: accounts,
          ),
        ),
      ),
    );

    expect(find.text('Groceries'), findsOneWidget);
    expect(find.text('Paycheck'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'pay');
    await tester.pump();

    expect(find.text('Groceries'), findsNothing);
    expect(find.text('Paycheck'), findsOneWidget);
  });

  testWidgets('choosing the Income chip filters to income only', (
    tester,
  ) async {
    const transactions = [
      TransactionView(
        id: 'one',
        accountId: 'everyday',
        title: 'Groceries',
        amountLabel: 'USD 12.34',
        isExpense: true,
        categoryId: null,
      ),
      TransactionView(
        id: 'two',
        accountId: 'everyday',
        title: 'Paycheck',
        amountLabel: 'USD 2000.00',
        isExpense: false,
        categoryId: null,
      ),
    ];
    const accounts = [
      AccountView(
        id: 'everyday',
        name: 'Everyday',
        currencyCode: 'USD',
        balanceLabel: 'USD 1987.66',
      ),
    ];

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ActivityPane(
            transactions: transactions,
            transfers: [],
            categories: [],
            accounts: accounts,
          ),
        ),
      ),
    );

    await tester.tap(find.widgetWithText(ChoiceChip, 'Income'));
    await tester.pump();

    expect(find.text('Groceries'), findsNothing);
    expect(find.text('Paycheck'), findsOneWidget);
  });
}
