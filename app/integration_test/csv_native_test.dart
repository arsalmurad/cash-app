import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:private_ledger/features/ledger/csv_import_export.dart';
import 'package:private_ledger/features/ledger/ledger_controller.dart';
import 'package:private_ledger/features/ledger/ledger_screen.dart';
import 'package:private_ledger/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const csv =
      'title,amount,kind,account,category\n"Native CSV, چائے 🍵",1.23,expense,Everyday,\n';

  testWidgets(
    'explicit CSV copy round-trips through the actual native clipboard',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: ExportCsvDialog(csv: csv)),
        ),
      );
      await tester.tap(find.text('Copy'));
      await _waitFor(
        tester,
        find.text('CSV copied. Paste it only somewhere you trust.'),
      );
      final copied = await Clipboard.getData(Clipboard.kTextPlain);
      expect(copied?.text, csv);
      // Remove only the synthetic bytes this test explicitly wrote.
      await Clipboard.setData(const ClipboardData(text: ''));
    },
  );

  // A separate owned device driver selects the synthetic fixture in Android's
  // real document UI and presses its Save button. No picker/channel mocks.
  if (const bool.fromEnvironment('RUN_DOCUMENT_PICKER_JOURNEY')) {
    testWidgets(
      'real Android file selection is reviewed before import and export reaches the provider',
      (tester) async {
        await app.main();
        await _waitFor(tester, find.text('USD 0.00'));
        final ledger = tester
            .widget<LedgerScreen>(find.byType(LedgerScreen))
            .controller;
        await tester.tap(find.byTooltip('Import or export'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Import CSV'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Choose CSV'));
        // The driver completes the system picker while Flutter is inactive.
        for (var attempt = 0; attempt < 900; attempt++) {
          await tester.pump(const Duration(milliseconds: 100));
          final field = tester.widget<TextField>(
            find.byKey(const Key('importCsvField')),
          );
          if (field.controller!.text == csv) break;
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
        }
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('importCsvField')))
              .controller!
              .text,
          csv,
        );
        expect(ledger.overview!.balanceLabel, 'USD 0.00');
        expect(ledger.overview!.transactions, isEmpty);
        debugPrint(
          'Verified Android CSV: file selection did not mutate the ledger.',
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Import'));
        await _waitFor(tester, find.text('USD -1.23'));
        final restarted = LedgerController();
        await restarted.initialize();
        expect(restarted.overview!.balanceLabel, 'USD -1.23');
        expect(
          restarted.overview!.transactions.single.title,
          'Native CSV, چائے 🍵',
        );
        restarted.dispose();
        debugPrint(
          'Verified Android CSV: imported Unicode transaction survived SQLite restart.',
        );
        await tester.tap(find.byTooltip('Import or export'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Export CSV'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Save CSV'));
        await _waitFor(
          tester,
          find.text('CSV saved. Keep it somewhere you trust.'),
          attempts: 900,
        );
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );
  }

  // The cached AOSP ATD image has no OPEN_DOCUMENT/CREATE_DOCUMENT activity.
  // This deliberately verifies graceful real-plugin failure there, not a
  // successful file-picker journey. Normal device runs leave it disabled.
  if (const bool.fromEnvironment('EXPECT_MISSING_DOCUMENT_PICKER')) {
    testWidgets(
      'missing Android document provider preserves pasted CSV and permits retry',
      (tester) async {
        await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: ImportCsvDialog())),
        );
        await tester.enterText(find.byKey(const Key('importCsvField')), csv);
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        for (var retry = 0; retry < 2; retry++) {
          await tester.tap(find.text('Choose CSV'));
          await _waitFor(
            tester,
            find.text(
              'Could not open the CSV. Choose another file or paste its text.',
            ),
          );
          expect(
            tester
                .widget<TextField>(find.byKey(const Key('importCsvField')))
                .controller!
                .text,
            csv,
          );
          expect(
            tester
                .widget<FilledButton>(
                  find.widgetWithText(FilledButton, 'Import'),
                )
                .onPressed,
            isNotNull,
          );
        }
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(body: ExportCsvDialog(csv: csv)),
          ),
        );
        await tester.tap(find.text('Save CSV'));
        await _waitFor(
          tester,
          find.text(
            'Could not save the CSV. Try another location or copy it instead.',
          ),
        );
        expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, 'Copy'))
              .onPressed,
          isNotNull,
        );
      },
    );
  }
}

Future<void> _waitFor(
  WidgetTester tester,
  Finder finder, {
  int attempts = 100,
}) async {
  for (var attempt = 0; attempt < attempts; attempt++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
  }
  expect(finder, findsOneWidget);
}
