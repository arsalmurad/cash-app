import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:private_ledger/features/ledger/ledger_controller.dart';
import 'package:private_ledger/features/ledger/ledger_screen.dart';
import 'package:private_ledger/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('records an expense through the Rust ledger', (tester) async {
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
    expect(find.text('\u2212USD 12.34'), findsOneWidget);
  });

  testWidgets('a transaction survives a simulated app restart', (
    tester,
  ) async {
    // Continues from the previous test's on-device state (the Groceries
    // expense above): this device's event log and actor ID are real files
    // that persist for the life of the app install, not reset between
    // `testWidgets` blocks.
    await app.main();
    await tester.pumpAndSettle();
    expect(find.text('USD -12.34'), findsNWidgets(2));

    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'Rent');
    await tester.enterText(fields.at(1), '500.00');
    await tester.tap(find.widgetWithText(FilledButton, 'Add transaction'));
    await tester.pumpAndSettle();
    expect(find.text('USD -512.34'), findsNWidgets(2));

    // Simulate an app restart with a fresh `LedgerController` rather than
    // calling `app.main()` again: a real restart is a new process, but
    // `flutter_rust_bridge` refuses to initialize twice in one process, and
    // the behavior actually under test — a new controller re-reading the
    // durable event log and actor ID from disk — doesn't depend on re-running
    // `RustLib.init()` anyway.
    final restartedController = LedgerController();
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
