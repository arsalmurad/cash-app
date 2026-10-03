import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/data/rust/api/ledger.dart';
import 'package:private_ledger/data/storage/event_store.dart';
import 'package:private_ledger/features/ledger/ledger_controller.dart';
import 'package:private_ledger/features/ledger/ledger_screen.dart';
import 'package:private_ledger/theme.dart';

/// Real UI entry, Rust rational conversion and default SQLite restart. Callers
/// initialize the bridge once; no ledger event or balance is injected.
Future<void> runPersonalJpyScenario(WidgetTester tester) async {
  final controller = LedgerController();
  addTearDown(controller.dispose);
  await tester.runAsync(controller.initialize);
  debugPrint('JPY fixture: real ledger initialized');
  expect(controller.errorMessage, isNull);
  await tester.pumpWidget(
    MaterialApp(
      theme: ledgerTheme(Brightness.light),
      home: LedgerScreen(controller: controller),
    ),
  );
  await tester.pumpAndSettle();
  debugPrint('JPY fixture: account entry UI ready');
  await tester.tap(find.widgetWithIcon(IconButton, Icons.add_rounded));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField).first, 'Zero Yen');
  await tester.tap(find.byType(DropdownButtonFormField<String>));
  await tester.pumpAndSettle();
  await tester.tap(find.text('JPY').last);
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(FilledButton, 'Create'));
  await _wait(
    tester,
    () => controller.overview!.accounts.any((a) => a.name == 'Zero Yen'),
  );
  debugPrint('JPY fixture: account persisted');

  Future<void> expense(String title, String amount, String rate) async {
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('accountDropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Zero Yen').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(0), title);
    await tester.enterText(find.byType(TextFormField).at(1), amount);
    await tester.enterText(find.byKey(const Key('rateField')), rate);
    await tester.ensureVisible(
      find.widgetWithText(FilledButton, 'Add transaction'),
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Add transaction'));
    await _wait(
      tester,
      () => controller.overview!.transactions.any((t) => t.title == title),
    );
  }

  await expense('Whole yen first rate', '123', '0.0065');
  debugPrint('JPY fixture: first rate persisted');
  var account = controller.overview!.accounts.singleWhere(
    (a) => a.name == 'Zero Yen',
  );
  expect(account.balanceLabel, 'JPY -123');
  expect(account.reportingBalanceLabel, 'USD -0.80');
  await expense('Whole yen later rate', '100', '0.01');
  debugPrint('JPY fixture: second rate persisted');
  account = controller.overview!.accounts.singleWhere(
    (a) => a.name == 'Zero Yen',
  );
  expect(account.balanceLabel, 'JPY -223');
  expect(account.reportingBalanceLabel, 'USD -1.80');
  final first = controller.overview!.transactions.singleWhere(
    (t) => t.title == 'Whole yen first rate',
  );
  expect(first.amountLabel, 'JPY 123');

  final restarted = LedgerController();
  addTearDown(restarted.dispose);
  await tester.runAsync(restarted.initialize);
  final restored = restarted.overview!.accounts.singleWhere(
    (a) => a.name == 'Zero Yen',
  );
  expect(restored.balanceLabel, 'JPY -223');
  expect(restored.reportingBalanceLabel, 'USD -1.80');
  await tester.pumpWidget(
    MaterialApp(
      theme: ledgerTheme(Brightness.light),
      home: LedgerScreen(controller: restarted),
    ),
  );
  await tester.pumpAndSettle();
  await Scrollable.ensureVisible(tester.element(find.text('JPY -223')));
  await tester.pumpAndSettle();
  expect(find.text('JPY -223').hitTestable(), findsOneWidget);
  expect(find.text('≈ USD -1.80'), findsOneWidget);

  final before = await tester.runAsync(() => EventStore('ledger').readLog());
  expect(
    await tester.runAsync(
      () => restarted.record(
        title: 'Fractional yen must not persist',
        amount: '0.5',
        kind: EntryKind.expense,
        accountId: restored.id,
        rate: '0.01',
      ),
    ),
    isFalse,
  );
  expect(
    await tester.runAsync(() => EventStore('ledger').readLog()),
    orderedEquals(before!),
  );
  expect(
    restarted.overview!.accounts
        .singleWhere((a) => a.id == restored.id)
        .balanceLabel,
    'JPY -223',
  );
}

Future<void> _wait(WidgetTester tester, bool Function() complete) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!complete() && DateTime.now().isBefore(deadline)) {
    // Let real SQLite/FFI callbacks run outside the host's fake timer zone.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(complete(), isTrue);
  await tester.pumpAndSettle();
}
