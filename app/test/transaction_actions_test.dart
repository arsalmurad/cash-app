import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show PlatformInt64Util;
import 'package:private_ledger/data/rust/api/categories.dart';
import 'package:private_ledger/data/rust/api/ledger.dart';
import 'package:private_ledger/features/ledger/ledger_screen.dart';
import 'package:private_ledger/features/ledger/transaction_actions.dart';

const transaction = TransactionView(
  id: 'expense',
  accountId: 'cash',
  title: 'Lunch',
  amountLabel: 'EUR 80.00',
  isExpense: true,
  categoryId: 'food',
  voided: false,
);
const categories = [
  CategoryView(id: 'food', name: 'Food', iconKey: 'restaurant'),
];

void main() {
  testWidgets(
    'history fits enlarged phone text and handles an out-of-range date',
    (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.5)),
            child: child!,
          ),
          home: Scaffold(
            body: TransactionHistoryDialog(
              transaction: transaction,
              categories: categories,
              history: [
                TransactionHistoryView(
                  eventId: 'old-event',
                  actorId: 'old-device',
                  physicalMillis: PlatformInt64Util.from(
                    8640000000000001,
                  ),
                  logical: 1,
                  action: 'Amount corrected',
                  amountLabel: 'EUR 85.00',
                  reportingAmountLabel: 'USD 92.44',
                  categoryId: null,
                ),
              ],
            ),
          ),
        ),
      );
      expect(find.text('Transaction history'), findsOneWidget);
      expect(
        find.text('Date outside the supported display range'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'amount correction explains frozen FX and returns only the new amount',
    (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      TransactionCorrectionDraft? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await showDialog<TransactionCorrectionDraft>(
                    context: context,
                    builder: (_) => const TransactionCorrectionDialog(
                      transaction: transaction,
                      action: TransactionAction.amount,
                      categories: categories,
                    ),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('Currency: EUR'), findsOneWidget);
      expect(find.textContaining('original exchange rate'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '85.00');
      await tester.tap(find.text('Save correction'));
      await tester.pumpAndSettle();
      expect(result!.amount, '85.00');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('category can be cleared and removal can be cancelled', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: TransactionCorrectionDialog(
            transaction: transaction,
            action: TransactionAction.category,
            categories: categories,
          ),
        ),
      ),
    );
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Uncategorized').last);
    await tester.pumpAndSettle();
    expect(find.text('Uncategorized'), findsOneWidget);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: TransactionRemovalDialog(transaction: transaction),
        ),
      ),
    );
    expect(
      find.textContaining('original entry and corrections stay'),
      findsOneWidget,
    );
    expect(find.text('Keep transaction'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('removed entries are visibly excluded and offer history only', (
    tester,
  ) async {
    const removed = TransactionView(
      id: 'expense',
      accountId: 'cash',
      title: 'Lunch',
      amountLabel: 'EUR 85.00',
      isExpense: true,
      categoryId: 'food',
      voided: true,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TransactionTile(removed, onAction: (_, _) {})),
      ),
    );
    expect(find.text('Removed from balances'), findsOneWidget);
    await tester.tap(find.byTooltip('Transaction actions: Lunch'));
    await tester.pumpAndSettle();
    expect(find.text('View history'), findsOneWidget);
    expect(find.text('Correct amount'), findsNothing);
    expect(find.text('Remove transaction'), findsNothing);
  });
}
