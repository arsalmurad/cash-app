import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/data/rust/api/categories.dart';
import 'package:private_ledger/data/rust/api/ledger.dart';
import 'package:private_ledger/features/ledger/add_transaction_sheet.dart';

const _categories = [
  CategoryView(id: 'food', name: 'Food', iconKey: 'restaurant'),
  CategoryView(id: 'transport', name: 'Transport', iconKey: 'directions_car'),
];

const _euroAccount = AccountView(
  id: 'euro',
  name: 'Euro',
  currencyCode: 'EUR',
  balanceLabel: 'EUR 0.00',
);

const _accounts = [
  AccountView(
    id: 'everyday',
    name: 'Everyday',
    currencyCode: 'USD',
    balanceLabel: 'USD 0.00',
  ),
  AccountView(
    id: 'savings',
    name: 'Savings',
    currencyCode: 'USD',
    balanceLabel: 'USD 0.00',
  ),
];

/// Opens the sheet in an on-screen modal so tests can interact with it while
/// it stays open (the returned Future from `showModalBottomSheet` only
/// resolves once it's dismissed, which these tests don't need).
Future<void> _openSheet(
  WidgetTester tester, {
  required Future<String?> Function(String) onSuggestCategory,
  Future<CategoryView?> Function(String, String)? onAddCategory,
  List<AccountView> accounts = _accounts,
  ValueChanged<EntryDraft?>? onResult,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              final result = await showModalBottomSheet<EntryDraft>(
                context: context,
                isScrollControlled: true,
                builder: (context) => AddTransactionSheet(
                  accounts: accounts,
                  reportingCurrencyCode: 'USD',
                  categories: _categories,
                  onSuggestCategory: onSuggestCategory,
                  onAddCategory: onAddCategory ?? (_, _) async => null,
                ),
              );
              onResult?.call(result);
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'typing a title auto-selects its previous category after a pause',
    (tester) async {
      await _openSheet(
        tester,
        onSuggestCategory: (title) async =>
            title == 'Coffee' ? 'transport' : null,
      );

      await tester.enterText(find.byType(TextFormField).first, 'Coffee');
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('Transport'), findsOneWidget);
    },
  );

  testWidgets('manually choosing a category stops later auto-suggestion', (
    tester,
  ) async {
    await _openSheet(
      tester,
      onSuggestCategory: (title) async =>
          title == 'Coffee' ? 'transport' : null,
    );

    await tester.tap(find.byKey(const Key('categoryDropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Food').last);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).first, 'Coffee');
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Food'), findsOneWidget);
    expect(find.text('Transport'), findsNothing);
  });

  testWidgets('creating a new category selects it immediately', (tester) async {
    await _openSheet(
      tester,
      onSuggestCategory: (_) async => null,
      onAddCategory: (name, iconKey) async =>
          CategoryView(id: 'rent', name: name, iconKey: iconKey),
    );

    await tester.tap(find.byKey(const Key('categoryDropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New category'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      'Rent',
    );
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    expect(find.text('Rent'), findsOneWidget);
  });

  testWidgets('submitting returns the selected category and amount', (
    tester,
  ) async {
    TransactionDraft? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showModalBottomSheet<TransactionDraft>(
                  context: context,
                  isScrollControlled: true,
                  builder: (context) => AddTransactionSheet(
                    accounts: _accounts,
                    reportingCurrencyCode: 'USD',
                    categories: _categories,
                    onSuggestCategory: (_) async => null,
                    onAddCategory: (_, _) async => null,
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

    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'Bus fare');
    await tester.enterText(fields.at(1), '3.50');
    await tester.tap(find.widgetWithText(FilledButton, 'Add transaction'));
    await tester.pumpAndSettle();

    expect(result?.title, 'Bus fare');
    expect(result?.amount, '3.50');
    expect(result?.kind, EntryKind.expense);
    expect(result?.accountId, 'everyday');
    expect(result?.categoryId, 'food');
  });

  testWidgets(
    'switching to transfer mode returns a TransferDraft between two accounts',
    (tester) async {
      EntryDraft? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await showModalBottomSheet<EntryDraft>(
                    context: context,
                    isScrollControlled: true,
                    builder: (context) => AddTransactionSheet(
                      accounts: _accounts,
                      reportingCurrencyCode: 'USD',
                      categories: _categories,
                      onSuggestCategory: (_) async => null,
                      onAddCategory: (_, _) async => null,
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

      await tester.tap(find.text('Transfer'));
      await tester.pumpAndSettle();

      // Defaults to the first two distinct accounts; switch "To account" to
      // confirm the dropdown is wired up, then fill in the amount.
      await tester.tap(find.byKey(const Key('toAccountDropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Savings').last);
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextFormField).first, '25.00');
      await tester.tap(find.widgetWithText(FilledButton, 'Add transfer'));
      await tester.pumpAndSettle();

      final transfer = result;
      expect(transfer, isA<TransferDraft>());
      transfer as TransferDraft;
      expect(transfer.fromAccountId, 'everyday');
      expect(transfer.toAccountId, 'savings');
      expect(transfer.sentAmount, '25.00');
      expect(transfer.receivedAmount, isNull);
      expect(transfer.title, 'Transfer');
    },
  );

  testWidgets('the sheet scrolls instead of overflowing on a short screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 320);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await _openSheet(tester, onSuggestCategory: (_) async => null);

    // A RenderFlex overflow would surface as a test exception here.
    expect(tester.takeException(), isNull);

    await tester.scrollUntilVisible(
      find.widgetWithText(FilledButton, 'Add transaction'),
      100,
      scrollable: find.byType(Scrollable).last,
    );
    expect(
      find.widgetWithText(FilledButton, 'Add transaction'),
      findsOneWidget,
    );
  });

  group('foreign-currency entries', () {
    final accounts = [..._accounts, _euroAccount];

    testWidgets('an account in the reporting currency asks for no rate', (
      tester,
    ) async {
      await _openSheet(
        tester,
        accounts: accounts,
        onSuggestCategory: (_) async => null,
      );
      expect(find.byKey(const Key('rateField')), findsNothing);
    });

    testWidgets('a foreign-currency expense requires and returns a rate', (
      tester,
    ) async {
      EntryDraft? result;
      await _openSheet(
        tester,
        accounts: accounts,
        onSuggestCategory: (_) async => null,
        onResult: (draft) => result = draft,
      );

      await tester.tap(find.byKey(const Key('accountDropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Euro').last);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('rateField')), findsOneWidget);

      await tester.enterText(find.byType(TextFormField).at(0), 'Hotel');
      await tester.enterText(find.byType(TextFormField).at(1), '80.00');
      await tester.tap(find.widgetWithText(FilledButton, 'Add transaction'));
      await tester.pumpAndSettle();
      expect(result, isNull, reason: 'a missing rate must block submission');
      expect(find.text('Enter the exchange rate'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('rateField')), '1.0875');
      await tester.tap(find.widgetWithText(FilledButton, 'Add transaction'));
      await tester.pumpAndSettle();

      final draft = result as TransactionDraft;
      expect(draft.accountId, 'euro');
      expect(draft.rate, '1.0875');
    });

    testWidgets('a transfer only asks for a rate on its foreign leg', (
      tester,
    ) async {
      EntryDraft? result;
      await _openSheet(
        tester,
        accounts: accounts,
        onSuggestCategory: (_) async => null,
        onResult: (draft) => result = draft,
      );
      await tester.tap(find.text('Transfer'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sentRateField')), findsNothing);
      expect(find.byKey(const Key('receivedRateField')), findsNothing);

      await tester.tap(find.byKey(const Key('toAccountDropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Euro').last);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('sentRateField')), findsNothing);
      expect(find.byKey(const Key('receivedRateField')), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Amount sent'),
        '110.00',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Amount received'),
        '100.00',
      );
      await tester.enterText(
        find.byKey(const Key('receivedRateField')),
        '1.10',
      );
      await tester.ensureVisible(
        find.widgetWithText(FilledButton, 'Add transfer'),
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Add transfer'));
      await tester.pumpAndSettle();

      final draft = result as TransferDraft;
      expect(draft.sentRate, isNull);
      expect(draft.receivedRate, '1.10');
    });
  });
}
