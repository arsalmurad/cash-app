import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/features/ledger/csv_import_export.dart';

void main() {
  testWidgets('ExportCsvDialog shows the CSV text', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (context) =>
                    const ExportCsvDialog(csv: 'title,amount\nCoffee,4.50\n'),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Coffee,4.50'), findsOneWidget);
  });

  testWidgets('ImportCsvDialog disables Import until text is entered', (
    tester,
  ) async {
    String? result;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await showDialog<String>(
                  context: context,
                  builder: (context) => const ImportCsvDialog(),
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

    final importButtonFinder = find.widgetWithText(FilledButton, 'Import');
    expect(tester.widget<FilledButton>(importButtonFinder).onPressed, isNull);

    await tester.enterText(
      find.byKey(const Key('importCsvField')),
      'Coffee,4.50,expense,Everyday,',
    );
    await tester.pump();

    expect(
      tester.widget<FilledButton>(importButtonFinder).onPressed,
      isNotNull,
    );

    await tester.tap(importButtonFinder);
    await tester.pumpAndSettle();

    expect(result, 'Coffee,4.50,expense,Everyday,');
  });
}
