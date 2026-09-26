import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/data/rust/api/ledger.dart';
import 'package:private_ledger/features/ledger/ledger_screen.dart';

void main() {
  testWidgets(
    'overview presents Rust ledger values and an actionable empty state',
    (tester) async {
      var addCount = 0;
      const overview = LedgerOverview(
        balanceLabel: 'USD 0.00',
        accounts: [
          AccountView(
            id: 'everyday',
            name: 'Everyday',
            balanceLabel: 'USD 0.00',
          ),
        ],
        transactions: [],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: OverviewPane(overview: overview, onAdd: () => addCount += 1),
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

  testWidgets('transaction tile distinguishes an expense', (tester) async {
    const transaction = TransactionView(
      id: 'one',
      title: 'Groceries',
      amountLabel: 'USD 12.34',
      isExpense: true,
      categoryId: 'Food',
    );

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: TransactionTile(transaction))),
    );

    expect(find.text('Groceries'), findsOneWidget);
    expect(find.text('Food'), findsOneWidget);
    expect(find.text('−USD 12.34'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_upward_rounded), findsOneWidget);
  });
}
