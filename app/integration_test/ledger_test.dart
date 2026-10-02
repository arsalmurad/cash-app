import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:private_ledger/data/storage/event_store.dart';
import 'package:private_ledger/features/ledger/ledger_controller.dart';
import 'package:private_ledger/features/ledger/ledger_screen.dart';
import 'package:private_ledger/main.dart' as app;

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
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await waitFor(tester, find.text('Lifecycle goal'));

    await tester.tap(find.text('Recurring'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add recurring'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(0), 'Lifecycle bill');
    await tester.enterText(find.byType(TextFormField).at(1), '1.23');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await waitFor(tester, find.text('Lifecycle bill'));
    await tester.tap(find.text('Record'));
    await tester.pumpAndSettle();
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (restartedController.overview!.balanceLabel != 'USD -600.57' &&
        DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(restartedController.overview!.balanceLabel, 'USD -600.57');
    expect(
      restartedController.upcoming,
      hasLength(1),
      reason: 'Monthly rules remain manageable beyond the reminder horizon',
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
    expect(find.text('USD -600.57'), findsOneWidget);
    expect(
      find.text('Lifecycle bill'),
      findsOneWidget,
      reason: 'Stopping a rule does not erase the recorded expense',
    );
  });
}
