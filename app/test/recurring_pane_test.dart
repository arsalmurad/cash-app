import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/data/rust/api/ledger.dart';
import 'package:private_ledger/data/rust/api/recurring.dart';
import 'package:private_ledger/features/ledger/recurring_pane.dart';

void main() {
  testWidgets('future rules can be managed but cannot be recorded early', (
    tester,
  ) async {
    var stopped = false;
    final future = UpcomingView(
      recurringId: 'future',
      title: 'Future bill',
      isExpense: true,
      amountLabel: 'USD 10.00',
      accountId: 'cash',
      categoryId: null,
      frequency: RecurringFrequency.monthly,
      occurrenceMillis: PlatformInt64Util.from(
        DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch,
      ),
      isOverdue: false,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RecurringPane(
            upcoming: [future],
            onRecord: (_) async {},
            onStop: (_) => stopped = true,
          ),
        ),
      ),
    );
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Record'))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byTooltip('recurring rule actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Stop recurring rule'));
    await tester.pumpAndSettle();
    expect(stopped, isTrue);
  });
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

  testWidgets(
    'an upcoming occurrence shows its title and amount, and records on tap',
    (tester) async {
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
    },
  );

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

  testWidgets('tapping a rule\'s edit icon opens the dialog pre-filled', (
    tester,
  ) async {
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
    UpcomingView? edited;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RecurringPane(
            upcoming: [occurrence],
            onRecord: (_) async {},
            onEdit: (view) => edited = view,
          ),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pump();

    expect(edited, occurrence);
  });

  testWidgets(
    'NewRecurringDialog in edit mode pre-fills title, amount, kind, and frequency',
    (tester) async {
      final occurrence = UpcomingView(
        recurringId: 'rent',
        title: 'Rent',
        isExpense: true,
        amountLabel: 'USD 1500.00',
        accountId: 'checking',
        categoryId: 'housing',
        frequency: RecurringFrequency.monthly,
        occurrenceMillis: PlatformInt64Util.from(
          DateTime(2026, 3, 1).millisecondsSinceEpoch,
        ),
        isOverdue: true,
      );
      const accounts = [
        AccountView(
          id: 'checking',
          name: 'Checking',
          currencyCode: 'USD',
          balanceLabel: 'USD 0.00',
        ),
      ];
      RecurringDraft? result;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  result = await showDialog<RecurringDraft>(
                    context: context,
                    builder: (context) => NewRecurringDialog(
                      accounts: accounts,
                      existing: occurrence,
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

      expect(find.text('Edit recurring rule'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'Rent'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, '1500.00'), findsOneWidget);

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      // No category picker exists in this dialog; the existing category must
      // still be carried through rather than dropped.
      expect(result!.categoryId, 'housing');
    },
  );
}
