import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:private_ledger/features/ledger/ledger_controller.dart';
import 'package:private_ledger/features/ledger/ledger_screen.dart';
import 'package:private_ledger/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // `RustLib.init()` (called from `app.main()`) refuses to run twice in one
  // process, and every `testWidgets` block in this file shares one process,
  // so `app.main()` can only be called once across the whole file. That
  // makes the restart check part of this same test rather than a second one:
  // a "restart" is simulated afterwards with a fresh `LedgerController` in a
  // new widget tree, which re-reads storage without touching `RustLib` again.
  testWidgets('an expense survives a simulated app restart', (tester) async {
    // A real, reproducible failure here reports through `flutter drive` with
    // no exception text at all in debug, profile, or release mode, and
    // `print()` doesn't surface either since `-d web-server` has no browser
    // console access — so attach it to `reportData` instead, which the
    // driver (configured with `writeResponseOnFailure: true`) writes to
    // build/integration_response_data.json regardless of outcome.
    try {
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

    // `LedgerController.record()` swallows a failed bridge call into
    // `errorMessage` and just shows a SnackBar rather than throwing, so a
    // bare "Groceries not found" assertion below gives no clue whether the
    // save actually failed, or succeeded but the controller's own state
    // (read straight off the widget tree, bypassing the UI entirely) still
    // doesn't have it. Surface both in the failure reason.
    final snackBarText = tester
        .widgetList<SnackBar>(find.byType(SnackBar))
        .map((bar) => (bar.content as Text?)?.data)
        .join('; ');
    final liveController = tester
        .widget<LedgerScreen>(find.byType(LedgerScreen))
        .controller;
    final overview = liveController.overview;
    final overviewDump =
        'isLoading=${liveController.isLoading} '
        'errorMessage=${liveController.errorMessage} '
        'balanceLabel=${overview?.balanceLabel} '
        'accountCount=${overview?.accounts.length} '
        'transactionTitles=${overview?.transactions.map((t) => t.title).toList()}';
    expect(
      find.text('Groceries'),
      findsOneWidget,
      reason:
          '${snackBarText.isEmpty ? "no SnackBar shown" : "SnackBar shown: $snackBarText"}; '
          'controller state: $overviewDump',
    );
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
    } catch (e, st) {
      // ignore: avoid_print
      print('TEST EXCEPTION: $e\nSTACK:\n$st');
      IntegrationTestWidgetsFlutterBinding.instance.reportData = {
        'exception': e.toString(),
        'stackTrace': st.toString(),
      };
      rethrow;
    }
  });
}
