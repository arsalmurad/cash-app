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
    await tester.tap(find.widgetWithText(FilledButton, 'Add transaction'));
    await tester.pumpAndSettle();

    expect(find.text('Groceries'), findsOneWidget);
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
  });
}
