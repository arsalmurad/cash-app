import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:private_ledger/data/storage/event_store.dart';
import 'package:private_ledger/features/ledger/ledger_controller.dart';
import 'package:private_ledger/features/ledger/ledger_screen.dart';
import 'package:private_ledger/main.dart' as app;

import '../test_support/personal_jpy_scenario.dart';

/// Pumps until [finder] matches, up to [timeout]. `pumpAndSettle` returns as
/// soon as animations stop, which can be before an asynchronous bridge call
/// (a real Rust call on a real thread) has delivered its result, so an
/// assertion right after a mutation must wait for the result to show up.
Future<void> waitFor(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (finder.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pumpAndSettle();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // `RustLib.init()` (called from `app.main()`) refuses to run twice in one
  // process, and every `testWidgets` block in this file shares one process,
  // so `app.main()` can only be called once across the whole file. That
  // makes the restart check part of this same test rather than a second one:
  // a "restart" is simulated afterwards with a fresh `LedgerController` in a
  // new widget tree, which re-reads storage without touching `RustLib` again.
  testWidgets('an expense survives a simulated app restart', (tester) async {
    await app.main();
    await tester.pumpAndSettle();

    expect(find.text('Private Ledger'), findsOneWidget);
    expect(find.text('USD 0.00'), findsNWidgets(2));

    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    final fields = find.byType(TextFormField);
    expect(fields, findsNWidgets(2));
    await tester.enterText(fields.at(0), 'Groceries');
    await tester.enterText(fields.at(1), '12.34');

    // Exercise the categories bridge (a second opaque Rust type with its own
    // durable log) on real hardware: pick a non-default category from the
    // seeded list.
    await tester.tap(find.byKey(const Key('categoryDropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Food').last);
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Add transaction'));
    await tester.pumpAndSettle();

    await waitFor(tester, find.text('Groceries'));
    expect(find.text('Groceries'), findsOneWidget);
    expect(find.text('Food'), findsOneWidget);
    expect(find.text('USD -12.34'), findsNWidgets(2));
    expect(find.text('−USD 12.34'), findsOneWidget);

    // Simulate an app restart with a fresh `LedgerController` in a new
    // widget tree, rather than calling `app.main()` again (see above). It
    // must re-read the same durable event log and actor ID from disk and
    // show the same state.
    var restartedController = LedgerController();
    await restartedController.initialize();
    await tester.pumpWidget(
      MaterialApp(home: LedgerScreen(controller: restartedController)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Groceries'), findsOneWidget);
    expect(find.text('Food'), findsOneWidget);
    expect(find.text('USD -12.34'), findsNWidgets(2));

    // Record a second transaction against the restarted controller, then
    // simulate a further restart to confirm both survive.
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    final moreFields = find.byType(TextFormField);
    await tester.enterText(moreFields.at(0), 'Rent');
    await tester.enterText(moreFields.at(1), '500.00');
    await tester.tap(find.widgetWithText(FilledButton, 'Add transaction'));
    await tester.pumpAndSettle();
    await waitFor(tester, find.text('USD -512.34'));
    expect(find.text('USD -512.34'), findsNWidgets(2));

    restartedController = LedgerController();
    await restartedController.initialize();
    await tester.pumpWidget(
      MaterialApp(home: LedgerScreen(controller: restartedController)),
    );
    await tester.pumpAndSettle();

    expect(find.text('USD -512.34'), findsNWidgets(2));
    expect(find.text('Rent'), findsOneWidget);
    expect(find.text('Groceries'), findsOneWidget);
    expect(find.text('Food'), findsOneWidget);

    // Exercise a second account and a transfer between accounts (a second
    // financial event kind, folded through the same ledger) on real
    // hardware.
    await tester.tap(find.widgetWithIcon(IconButton, Icons.add_rounded));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Savings');
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();
    await waitFor(tester, find.text('Savings'));
    expect(find.text('Savings'), findsOneWidget);

    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Transfer'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('toAccountDropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Savings').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, '100.00');
    await tester.tap(find.widgetWithText(FilledButton, 'Add transfer'));
    await tester.pumpAndSettle();

    await waitFor(tester, find.text('USD 100.00'));
    // The transfer moves money between accounts without changing the total:
    // the net balance card still reads -512.34, but it's now only Everyday's
    // -612.34 and Savings' +100.00 that sum to it, not any single account.
    expect(find.text('USD -512.34'), findsOneWidget);
    expect(find.text('USD -612.34'), findsOneWidget);
    expect(find.text('USD 100.00'), findsOneWidget);

    restartedController = LedgerController();
    await restartedController.initialize();
    await tester.pumpWidget(
      MaterialApp(home: LedgerScreen(controller: restartedController)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Savings'), findsOneWidget);
    expect(find.text('USD -512.34'), findsOneWidget);
    expect(find.text('USD -612.34'), findsOneWidget);
    expect(find.text('USD 100.00'), findsOneWidget);

    // A foreign-currency account: the entry freezes the typed rate, the
    // account shows its reporting-currency value, and both survive a restart.
    await tester.tap(find.widgetWithIcon(IconButton, Icons.add_rounded));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Euro');
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('EUR').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('accountDropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Euro').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(0), 'Hotel');
    await tester.enterText(find.byType(TextFormField).at(1), '80.00');
    await tester.enterText(find.byKey(const Key('rateField')), '1.0875');
    await tester.ensureVisible(
      find.widgetWithText(FilledButton, 'Add transaction'),
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Add transaction'));
    await tester.pumpAndSettle();

    // 80.00 EUR at 1.0875 = 87.00 USD, added to the -512.34 net balance.
    await waitFor(tester, find.text('EUR -80.00'));
    expect(find.text('EUR -80.00'), findsOneWidget);
    expect(find.text('≈ USD -87.00'), findsOneWidget);
    expect(find.text('USD -599.34'), findsOneWidget);

    restartedController = LedgerController();
    await restartedController.initialize();
    await tester.pumpWidget(
      MaterialApp(home: LedgerScreen(controller: restartedController)),
    );
    await tester.pumpAndSettle();

    expect(find.text('EUR -80.00'), findsOneWidget);
    expect(find.text('≈ USD -87.00'), findsOneWidget);
    expect(find.text('USD -599.34'), findsOneWidget);

    // Create real definitions through the same UI as a user. Their removal
    // must append history, never alter financial transactions.
    await tester.tap(find.text('Budgets'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add budget'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextFormField).at(0),
      'Lifecycle budget',
    );
    await tester.enterText(find.byType(TextFormField).at(1), '10');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await waitFor(tester, find.text('Lifecycle budget'));

    await tester.tap(find.text('Goals'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add goal'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(0), 'Lifecycle goal');
    await tester.enterText(find.byType(TextFormField).at(1), '100');
    await tester.tap(find.byKey(const Key('goalAccountDropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Everyday').last);
    await tester.pumpAndSettle();
    expect(find.text('Target currency: USD'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('goalDeadlineButton')));
    await tester.tap(find.byKey(const Key('goalDeadlineButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await waitFor(tester, find.text('Lifecycle goal'));
    expect(restartedController.goals.single.deadlineMillis, isNotNull);

    await tester.tap(find.text('Recurring'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add recurring'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(0), 'Lifecycle bill');
    await tester.enterText(find.byType(TextFormField).at(1), '1.23');
    await tester.tap(find.byKey(const Key('recurringAccountDropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Euro').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const Key('recurringCategoryDropdown')),
    );
    await tester.tap(find.byKey(const Key('recurringCategoryDropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Food').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await waitFor(tester, find.text('Lifecycle bill'));
    expect(restartedController.upcoming, hasLength(1));
    expect(
      restartedController.upcoming.single.isOverdue,
      isTrue,
      reason: 'New rule should already be due before Record is tapped',
    );
    expect(restartedController.upcoming.single.accountId, 'euro');
    expect(restartedController.upcoming.single.categoryId, 'food');
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Record'))
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.text('Record'));
    await waitFor(tester, find.widgetWithText(FilledButton, 'Use rate'));
    final beforeRateCancel = await EventStore('ledger').readLog();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(
      await EventStore('ledger').readLog(),
      orderedEquals(beforeRateCancel),
    );
    expect(restartedController.overview!.balanceLabel, 'USD -599.34');
    await tester.tap(find.text('Record'));
    await waitFor(tester, find.widgetWithText(FilledButton, 'Use rate'));
    await tester.enterText(find.byType(TextFormField), '1');
    await tester.tap(find.widgetWithText(FilledButton, 'Use rate'));
    await tester.pumpAndSettle();
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (restartedController.overview!.balanceLabel != 'USD -600.57' &&
        DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      restartedController.errorMessage,
      isNull,
      reason: 'Report a real save/validation failure before comparing balances',
    );
    expect(
      restartedController.overview!.balanceLabel,
      'USD -600.57',
      reason:
          'Displayed texts: ${tester.widgetList<Text>(find.byType(Text)).map((text) => text.data).whereType<String>().toList()}',
    );
    expect(
      restartedController.upcoming,
      hasLength(1),
      reason: 'Monthly rules remain manageable beyond the reminder horizon',
    );
    expect(
      restartedController.overview!.transactions
          .firstWhere((transaction) => transaction.title == 'Lifecycle bill')
          .categoryId,
      'food',
    );
    final ledgerBytes = await EventStore('ledger').readLog();
    final csv = restartedController.exportTransactionsCsv();

    for (final (tab, kind, empty) in [
      ('Budgets', 'budget', 'No budgets yet.'),
      ('Goals', 'goal', 'No goals yet.'),
      ('Recurring', 'recurring rule', 'No upcoming bills'),
    ]) {
      await tester.tap(find.text(tab));
      await tester.pumpAndSettle();
      final action = kind == 'recurring rule'
          ? 'Stop recurring rule'
          : 'Remove $kind';
      Future<void> open() async {
        await tester.tap(find.byTooltip('$kind actions'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(action));
        await tester.pumpAndSettle();
      }

      final before = await EventStore(
        kind == 'recurring rule' ? 'recurring' : '${kind}s',
      ).readLog();
      await open();
      await tester.tap(find.text('Keep $kind'));
      await tester.pumpAndSettle();
      expect(
        await EventStore(kind == 'recurring rule' ? 'recurring' : '${kind}s')
            .readLog(),
        orderedEquals(before),
      );
      await open();
      await tester.tap(find.widgetWithText(FilledButton, action));
      await waitFor(tester, find.textContaining(empty));
      expect(find.textContaining(empty), findsOneWidget);
    }
    expect(await EventStore('ledger').readLog(), orderedEquals(ledgerBytes));
    expect(restartedController.exportTransactionsCsv(), csv);
    final finalRestart = LedgerController();
    await finalRestart.initialize();
    expect(finalRestart.errorMessage, isNull);
    expect(finalRestart.budgets, isEmpty);
    expect(finalRestart.goals, isEmpty);
    expect(finalRestart.upcoming, isEmpty);
    expect(finalRestart.exportTransactionsCsv(), csv);
    await tester.pumpWidget(
      MaterialApp(home: LedgerScreen(controller: finalRestart)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Overview'));
    await tester.pumpAndSettle();
    expect(find.text('USD -600.57'), findsOneWidget);
    expect(find.text('EUR -81.23'), findsOneWidget);
    expect(
      find.text('≈ USD -88.23'),
      findsOneWidget,
      reason:
          'The old 80 EUR at 1.0875 and new 1.23 EUR at 1 keep their own rates',
    );
    expect(
      find.text('Lifecycle bill'),
      findsOneWidget,
      reason: 'Stopping a rule does not erase the recorded expense',
    );

    // Valid i64 money must not break derived percentage views or saves.
    await tester.tap(find.text('Goals'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add goal'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Name'),
      'Large saving',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Target amount'),
      '0.01',
    );
    await tester.tap(find.byKey(const Key('goalAccountDropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Everyday').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await waitFor(tester, find.text('Large saving'));
    await tester.tap(find.text('Budgets'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add budget'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Name'),
      'Large budget',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Limit amount'),
      '0.01',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await waitFor(tester, find.text('Large budget'));

    Future<void> largeEntry(String title, {bool income = false}) async {
      await tester.tap(find.text('Overview'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      if (income) {
        await tester.tap(find.text('Income'));
        await tester.pumpAndSettle();
      }
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Title'),
        title,
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Amount'),
        '10000000000000000.00',
      );
      await tester.tap(find.byKey(const Key('accountDropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Everyday').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.widgetWithText(FilledButton, 'Add transaction'),
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Add transaction'));
      await waitFor(tester, find.text(title));
    }

    await largeEntry('Large income', income: true);
    expect(finalRestart.errorMessage, isNull);
    expect(
      finalRestart.overview!.transactions
          .firstWhere((t) => t.title == 'Large income')
          .amountLabel,
      'USD 10000000000000000.00',
    );
    final largeRestart = LedgerController();
    await largeRestart.initialize();
    expect(largeRestart.errorMessage, isNull);
    await tester.pumpWidget(
      MaterialApp(home: LedgerScreen(controller: largeRestart)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Goals'));
    await tester.pumpAndSettle();
    expect(find.text('>1,000,000%'), findsOneWidget);
    await largeEntry('Large expense');
    expect(largeRestart.errorMessage, isNull);
    expect(largeRestart.overview!.balanceLabel, 'USD -600.57');
    expect(
      largeRestart.overview!.transactions
          .firstWhere((t) => t.title == 'Large expense')
          .amountLabel,
      'USD 10000000000000000.00',
    );
    final boundaryRestart = LedgerController();
    await boundaryRestart.initialize();
    expect(boundaryRestart.errorMessage, isNull);
    expect(boundaryRestart.overview!.balanceLabel, 'USD -600.57');
    await tester.pumpWidget(
      MaterialApp(home: LedgerScreen(controller: boundaryRestart)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Budgets'));
    await tester.pumpAndSettle();
    expect(find.text('>1,000,000%'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('Activity'),
      ),
    );
    await tester.pumpAndSettle();
    final hotelActions = find.byTooltip('Transaction actions: Hotel');
    // Place this older entry above the floating Add button, not just inside
    // the scroll viewport where that button can intercept its menu tap.
    await Scrollable.ensureVisible(
      tester.element(hotelActions),
      alignment: 0.25,
    );
    await tester.pumpAndSettle();
    expect(hotelActions.hitTestable(), findsOneWidget);
    await tester.tap(hotelActions);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove transaction'));
    await tester.pumpAndSettle();
    final beforeCancel = await EventStore('ledger').readLog();
    await tester.tap(find.text('Keep transaction'));
    await tester.pumpAndSettle();
    expect(await EventStore('ledger').readLog(), orderedEquals(beforeCancel));
    await tester.tap(hotelActions);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Correct amount'));
    await tester.pumpAndSettle();
    expect(find.text('Currency: EUR'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Amount'), '85.00');
    await tester.tap(find.text('Save correction'));
    await waitFor(tester, find.text('−EUR 85.00'));
    expect(boundaryRestart.overview!.balanceLabel, 'USD -606.01');
    await tester.tap(hotelActions);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Change category'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Food').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save correction'));
    await tester.pumpAndSettle();
    await tester.tap(hotelActions);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove transaction'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Remove transaction'));
    await waitFor(tester, find.text('Removed from balances'));
    expect(boundaryRestart.overview!.balanceLabel, 'USD -513.57');
    final correctionRestart = LedgerController();
    await correctionRestart.initialize();
    expect(correctionRestart.errorMessage, isNull);
    final removed = correctionRestart.overview!.transactions.firstWhere(
      (t) => t.title == 'Hotel',
    );
    expect(removed.voided, isTrue);
    expect(removed.amountLabel, 'EUR 85.00');
    expect(correctionRestart.exportTransactionsCsv(), isNot(contains('Hotel')));
    expect((await correctionRestart.historyFor(removed)).map((e) => e.action), [
      'Recorded',
      'Amount corrected',
      'Category changed',
      'Removed from balances',
    ]);
    await tester.pumpWidget(
      MaterialApp(home: LedgerScreen(controller: correctionRestart)),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('Activity'),
      ),
    );
    await tester.pumpAndSettle();
    await Scrollable.ensureVisible(
      tester.element(hotelActions),
      alignment: 0.25,
    );
    await tester.pumpAndSettle();
    expect(hotelActions.hitTestable(), findsOneWidget);
    await tester.tap(hotelActions);
    await tester.pumpAndSettle();
    await tester.tap(find.text('View history'));
    await tester.pumpAndSettle();
    expect(find.text('Transaction history'), findsOneWidget);
    expect(find.text('Reporting: USD 92.44'), findsOneWidget);
    expect(find.text('Removed from balances'), findsWidgets);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await runPersonalJpyScenario(tester);
  });
}
