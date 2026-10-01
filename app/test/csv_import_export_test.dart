import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/features/ledger/csv_import_export.dart';
import 'package:private_ledger/features/ledger/csv_files.dart';

class _Files implements CsvFiles {
  String? picked;
  String? exported;
  Object? error;
  CsvSaveResult outcome = CsvSaveResult.saved;
  @override
  Future<String?> pick() async {
    if (error != null) throw error!;
    return picked;
  }

  @override
  Future<CsvSaveResult> save(String csv) async {
    exported = csv;
    if (error != null) throw error!;
    return outcome;
  }
}

void main() {
  testWidgets('CSV dialogs fit a narrow phone with enlarged text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final dialog in [
      ImportCsvDialog(files: _Files()),
      ExportCsvDialog(csv: 'title,amount\nCoffee,4.50\n', files: _Files()),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.5)),
            child: child!,
          ),
          home: Scaffold(body: dialog),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
    'file selection fills review text and cancellation preserves edits',
    (tester) async {
      final files = _Files()..picked = 'چائے,4.50,expense,Everyday,';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ImportCsvDialog(files: files)),
        ),
      );
      await tester.tap(find.text('Choose CSV'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('importCsvField')))
            .controller!
            .text,
        files.picked,
      );
      files.picked = null;
      await tester.tap(find.text('Choose CSV'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('importCsvField')))
            .controller!
            .text,
        'چائے,4.50,expense,Everyday,',
      );
      files.error = const FormatException('Choose a UTF-8 CSV.');
      await tester.tap(find.text('Choose CSV'));
      await tester.pumpAndSettle();
      expect(find.text('Choose a UTF-8 CSV.'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('importCsvField')))
            .controller!
            .text,
        'چائے,4.50,expense,Everyday,',
      );
    },
  );

  testWidgets('export distinguishes save, cancellation and download request', (
    tester,
  ) async {
    final files = _Files();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ExportCsvDialog(csv: 'title,amount\nچائے,4.50', files: files),
        ),
      ),
    );
    await tester.tap(find.text('Save CSV'));
    await tester.pumpAndSettle();
    expect(files.exported, 'title,amount\nچائے,4.50');
    expect(
      find.text('CSV saved. Keep it somewhere you trust.'),
      findsOneWidget,
    );
    files.outcome = CsvSaveResult.cancelled;
    await tester.tap(find.text('Save CSV'));
    await tester.pumpAndSettle();
    expect(find.text('CSV saved. Keep it somewhere you trust.'), findsNothing);
    files.outcome = CsvSaveResult.downloadRequested;
    await tester.tap(find.text('Save CSV'));
    await tester.pumpAndSettle();
    expect(
      find.text('Download requested. Check your browser’s downloads.'),
      findsOneWidget,
    );
    files.error = StateError('synthetic platform failure');
    await tester.tap(find.text('Save CSV'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not save the CSV.'), findsOneWidget);
  });

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
