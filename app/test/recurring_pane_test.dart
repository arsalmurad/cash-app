import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/data/rust/api/ledger.dart';
import 'package:private_ledger/data/rust/api/recurring.dart';
import 'package:private_ledger/features/ledger/recurring_pane.dart';

void main() {
  testWidgets('empty state prompts to add a recurring rule', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RecurringPane(upcoming: const [], onRecord: (_) async {}),
        ),
      ),
    );

    expect(find.textContaining('No upcoming bills'), findsOneWidget);
  });

  testWidgets('an upcoming occurrence shows its title and amount, and records on tap', (
    tester,
  ) async {
    UpcomingView? recorded;
    final occurrence = UpcomingView(
      recurringId: 'rent',
      title: 'Rent',
      isExpense: true,
      amountLabel: 'USD 1500.00',
      accountId: 'checking',
      categoryId: null,
      frequency: RecurringFrequency.monthly,
      occurrenceMillis: PlatformInt64Util.from(
        DateTime(2026, 3, 1).millisecondsSinceEpoch,
      ),
      isOverdue: true,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RecurringPane(
            upcoming: [occurrence],
            onRecord: (view) async => recorded = view,
          ),
        ),
      ),
    );

    expect(find.text('Rent'), findsOneWidget);
    expect(find.text('USD 1500.00'), findsOneWidget);
    expect(find.textContaining('Due 2026-03-01'), findsOneWidget);

    await tester.tap(find.text('Record'));
    await tester.pumpAndSettle();

    expect(recorded, occurrence);
  });

  testWidgets('NewRecurringDialog returns a RecurringDraft', (tester) async {
    RecurringDraft? result;
    const accounts = [
      AccountView(
        id: 'checking',
        name: 'Checking',
        currencyCode: 'USD',
        balanceLabel: 'USD 0.00',
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await showDialog<RecurringDraft>(
                  context: context,
                  builder: (context) =>
                      const NewRecurringDialog(accounts: accounts),
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

    await tester.enterText(find.byType(TextFormField).first, 'Rent');
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Amount'),
      '1500',
    );

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.title, 'Rent');
    expect(result!.kind, RecurringKind.expense);
    expect(result!.amount, '1500');
    expect(result!.accountId, 'checking');
    expect(result!.frequency, RecurringFrequency.monthly);
  });
}
