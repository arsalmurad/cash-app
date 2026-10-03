import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/data/rust/api/categories.dart';
import 'package:private_ledger/data/rust/api/ledger.dart';
import 'package:private_ledger/features/ledger/add_transaction_sheet.dart';
import 'package:private_ledger/theme.dart';

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
  List<CategoryView> categories = _categories,
  ValueChanged<EntryDraft?>? onResult,
  bool keyboardOnly = false,
  Brightness brightness = Brightness.light,
  double textScale = 1,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ledgerTheme(brightness),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
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
                  categories: categories,
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
  if (keyboardOnly) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  } else {
    await tester.tap(find.text('open'));
  }
  await tester.pumpAndSettle();
}

bool _focusedInside(Finder finder) {
  final target = finder.evaluate().single;
  var inside = FocusManager.instance.primaryFocus?.context == target;
  FocusManager.instance.primaryFocus?.context?.visitAncestorElements((element) {
    if (element == target) inside = true;
    return !inside;
  });
  return inside;
}

Future<void> _key(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

void main() {
  for (final size in [const Size(360, 740), const Size(1280, 900)]) {
    for (final brightness in Brightness.values) {
      testWidgets('keyboard expense at $size / $brightness / 200% text', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        EntryDraft? result;
        var returns = 0;
        await _openSheet(
          tester,
          keyboardOnly: true,
          brightness: brightness,
          textScale: 2,
          onSuggestCategory: (_) async => null,
          onResult: (draft) {
            returns++;
            result = draft;
          },
        );
        expect(_focusedInside(find.byType(TextFormField).first), isTrue);
        tester.testTextInput.enterText('Keyboard coffee');
        await _key(tester, LogicalKeyboardKey.tab);
        expect(_focusedInside(find.byType(TextFormField).at(1)), isTrue);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await _key(tester, LogicalKeyboardKey.tab);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        expect(_focusedInside(find.byType(TextFormField).first), isTrue);
        await _key(tester, LogicalKeyboardKey.tab);
        tester.testTextInput.enterText('4.50');
        await _key(tester, LogicalKeyboardKey.tab);
        expect(
          _focusedInside(find.byKey(const Key('accountDropdown'))),
          isTrue,
        );
        await _key(tester, LogicalKeyboardKey.enter);
        await _key(tester, LogicalKeyboardKey.arrowDown);
        await _key(tester, LogicalKeyboardKey.enter);
        await _key(tester, LogicalKeyboardKey.tab);
        expect(
          _focusedInside(find.byKey(const Key('categoryDropdown'))),
          isTrue,
        );
        await _key(tester, LogicalKeyboardKey.enter);
        await _key(tester, LogicalKeyboardKey.arrowDown);
        await _key(tester, LogicalKeyboardKey.enter);
        await _key(tester, LogicalKeyboardKey.tab);
        expect(
          _focusedInside(find.widgetWithText(FilledButton, 'Add transaction')),
          isTrue,
        );
        await _key(tester, LogicalKeyboardKey.enter);
        expect(returns, 1);
        final draft = result as TransactionDraft;
        expect(draft.title, 'Keyboard coffee');
        expect(draft.amount, '4.50');
        expect(draft.accountId, 'savings');
        expect(draft.categoryId, 'transport');
        expect(draft.kind, EntryKind.expense);
        expect(find.byType(AddTransactionSheet), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('Escape cancels a populated personal entry without submitting', (
    tester,
  ) async {
    EntryDraft? result;
    var returns = 0;
    await _openSheet(
      tester,
      keyboardOnly: true,
      onSuggestCategory: (_) async => null,
      onResult: (draft) {
        returns++;
        result = draft;
      },
    );
    tester.testTextInput.enterText('Keep private');
    await _key(tester, LogicalKeyboardKey.escape);
    expect(returns, 1);
    expect(result, isNull);
    expect(find.byType(AddTransactionSheet), findsNothing);
    expect(_focusedInside(find.widgetWithText(TextButton, 'open')), isTrue);
  });

  testWidgets('long account and category labels wrap at 200% phone text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const accountName =
        'Everyday personal account with a complete descriptive name';
    const categoryName =
        'Food and household groceries with a complete descriptive name';
    await _openSheet(
      tester,
      keyboardOnly: true,
      textScale: 2,
      accounts: const [
        AccountView(
          id: 'everyday',
          name: accountName,
          currencyCode: 'USD',
          balanceLabel: 'USD 0.00',
        ),
      ],
      categories: const [
        CategoryView(id: 'food', name: categoryName, iconKey: 'restaurant'),
      ],
      onSuggestCategory: (_) async => null,
    );
    await _key(tester, LogicalKeyboardKey.tab);
    await _key(tester, LogicalKeyboardKey.tab);
    await _key(tester, LogicalKeyboardKey.enter);
    expect(find.text(accountName), findsWidgets);
    await _key(tester, LogicalKeyboardKey.escape);
    await _key(tester, LogicalKeyboardKey.tab);
    await _key(tester, LogicalKeyboardKey.enter);
    expect(find.text(categoryName), findsWidgets);
    await _key(tester, LogicalKeyboardKey.escape);
    await _key(tester, LogicalKeyboardKey.escape);
    expect(tester.takeException(), isNull);
  });

  testWidgets('returning to a title still ignores its superseded suggestion', (
    tester,
  ) async {
    final replies = <Completer<String?>>[];
    await _openSheet(
      tester,
      onSuggestCategory: (title) {
        if (title.isEmpty) return Future<String?>.value(null);
        final reply = Completer<String?>();
        replies.add(reply);
        return reply.future;
      },
    );
    for (final title in ['Coffee', 'Lunch', 'Coffee']) {
      await tester.enterText(find.byType(TextFormField).first, title);
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(replies, hasLength(3));
    replies[2].complete('food');
    await tester.pump();
    replies[0].complete('transport');
    replies[1].complete('transport');
    await tester.pumpAndSettle();
    expect(find.text('Food'), findsOneWidget);
    expect(find.text('Transport'), findsNothing);
  });
  testWidgets('long transfer account selectors wrap at 200% phone text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const from = 'Everyday personal account with a complete descriptive name';
    const to = 'Euro savings account with a complete descriptive name';
    await _openSheet(
      tester,
      textScale: 2,
      accounts: const [
        AccountView(
          id: 'everyday',
          name: from,
          currencyCode: 'USD',
          balanceLabel: 'USD 0.00',
        ),
        AccountView(
          id: 'euro',
          name: to,
          currencyCode: 'EUR',
          balanceLabel: 'EUR 0.00',
        ),
      ],
      onSuggestCategory: (_) async => null,
    );
    await tester.ensureVisible(find.text('Transfer'));
    await tester.tap(find.text('Transfer'));
    await tester.pumpAndSettle();
    for (final selector in ['fromAccountDropdown', 'toAccountDropdown']) {
      await tester.ensureVisible(find.byKey(Key(selector)));
      await tester.tap(find.byKey(Key(selector)));
      await tester.pumpAndSettle();
      expect(find.text(from), findsWidgets);
      expect(find.text(to), findsWidgets);
      await _key(tester, LogicalKeyboardKey.escape);
    }
    expect(tester.takeException(), isNull);
    await _key(tester, LogicalKeyboardKey.escape);
  });
  testWidgets('an older title suggestion cannot replace the current category', (
    tester,
  ) async {
    final first = Completer<String?>();
    final second = Completer<String?>();
    await _openSheet(
      tester,
      onSuggestCategory: (title) =>
          title == 'Coffee' ? first.future : second.future,
    );
    await tester.enterText(find.byType(TextFormField).first, 'Coffee');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.enterText(find.byType(TextFormField).first, 'Lunch');
    await tester.pump(const Duration(milliseconds: 500));
    second.complete('food');
    await tester.pump();
    first.complete('transport');
    await tester.pumpAndSettle();
    expect(find.text('Food'), findsOneWidget);
    expect(find.text('Transport'), findsNothing);
  });
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
      await tester.ensureVisible(
        find.widgetWithText(FilledButton, 'Add transaction'),
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Add transaction'));
      await tester.pumpAndSettle();
      expect(result, isNull, reason: 'a missing rate must block submission');
      expect(find.text('Enter the exchange rate'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('rateField')), '1.0875');
      await tester.ensureVisible(
        find.widgetWithText(FilledButton, 'Add transaction'),
      );
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
