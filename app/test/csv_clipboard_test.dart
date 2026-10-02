import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/features/ledger/csv_import_export.dart';

void main() {
  const csv = 'title,amount\nچائے 🍵,1.23\n';
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('clipboard failure is visible and a retry copies exact CSV', (
    tester,
  ) async {
    var fail = true;
    final copied = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            if (fail) throw PlatformException(code: 'denied');
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        });
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: ExportCsvDialog(csv: csv)),
      ),
    );
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      find.text('Could not copy the CSV. Try again or save it as a file.'),
      findsOneWidget,
    );
    expect(copied, isEmpty);
    fail = false;
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(copied, [csv]);
    expect(
      find.text('CSV copied. Paste it only somewhere you trust.'),
      findsOneWidget,
    );
    final status = tester.widget<Semantics>(
      find
          .ancestor(
            of: find.text('CSV copied. Paste it only somewhere you trust.'),
            matching: find.byType(Semantics),
          )
          .first,
    );
    expect(status.properties.liveRegion, isTrue);
  });

  testWidgets(
    'pending copy prevents duplicates and safely completes after dismissal',
    (tester) async {
      final pending = Completer<void>();
      var calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              calls++;
              await pending.future;
            }
            return null;
          });
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: ExportCsvDialog(csv: csv)),
        ),
      );
      await tester.tap(find.text('Copy'));
      await tester.pump();
      expect(calls, 1);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Copying…'))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save CSV'))
            .onPressed,
        isNull,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      pending.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(calls, 1);
    },
  );
}
