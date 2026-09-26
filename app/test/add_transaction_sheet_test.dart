import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/data/rust/api/categories.dart';
import 'package:private_ledger/data/rust/api/ledger.dart';
import 'package:private_ledger/features/ledger/add_transaction_sheet.dart';

const _categories = [
  CategoryView(id: 'food', name: 'Food', iconKey: 'restaurant'),
  CategoryView(id: 'transport', name: 'Transport', iconKey: 'directions_car'),
];

/// Opens the sheet in an on-screen modal so tests can interact with it while
/// it stays open (the returned Future from `showModalBottomSheet` only
/// resolves once it's dismissed, which these tests don't need).
Future<void> _openSheet(
  WidgetTester tester, {
  required Future<String?> Function(String) onSuggestCategory,
  Future<CategoryView?> Function(String, String)? onAddCategory,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () {
              showModalBottomSheet<TransactionDraft>(
                context: context,
                isScrollControlled: true,
                builder: (context) => AddTransactionSheet(
                  categories: _categories,
                  onSuggestCategory: onSuggestCategory,
                  onAddCategory: onAddCategory ?? (_, _) async => null,
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
}

void main() {
  testWidgets('typing a title auto-selects its previous category after a pause', (
    tester,
  ) async {
    await _openSheet(
      tester,
      onSuggestCategory: (title) async =>
          title == 'Coffee' ? 'transport' : null,
    );

    await tester.enterText(find.byType(TextFormField).first, 'Coffee');
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Transport'), findsOneWidget);
  });

  testWidgets('manually choosing a category stops later auto-suggestion', (
    tester,
  ) async {
    await _openSheet(
      tester,
      onSuggestCategory: (title) async =>
          title == 'Coffee' ? 'transport' : null,
    );

    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Food').last);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).first, 'Coffee');
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Food'), findsOneWidget);
    expect(find.text('Transport'), findsNothing);
  });

  testWidgets('creating a new category selects it immediately', (
    tester,
  ) async {
    await _openSheet(
      tester,
      onSuggestCategory: (_) async => null,
      onAddCategory: (name, iconKey) async =>
          CategoryView(id: 'rent', name: name, iconKey: iconKey),
    );

    await tester.tap(find.byType(DropdownButtonFormField<String>));
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
    expect(result?.categoryId, 'food');
  });
}
