import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/data/rust/api/ledger.dart';
import 'package:private_ledger/features/household/chosen_summary_dialog.dart';

void main() {
  testWidgets(
    'narrow enlarged-text preview can be kept private without publishing',
    (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var published = 0;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.5)),
            child: child!,
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showDialog<bool>(
                  context: context,
                  builder: (_) => ChosenSummaryDialog(
                    now: DateTime(2026, 10, 2),
                    prepare: (range, income, expenses) async => SummaryPreview(
                      groupId: '0123456789abcdef0123456789abcdef',
                      currencyCode: 'USD',
                      startMillis: PlatformInt64Util.from(
                        range.start.millisecondsSinceEpoch,
                      ),
                      endMillisExclusive: PlatformInt64Util.from(
                        DateTime(2026, 10, 3).millisecondsSinceEpoch,
                      ),
                      incomeLabel: 'USD 92233720368547758.07',
                      expensesLabel: null,
                    ),
                    publish: () async {
                      published++;
                      return true;
                    },
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Income total'));
      await tester.tap(find.text('Income total'));
      await tester.pump();
      await tester.tap(find.text('Preview totals'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('USD 92233720368547758.07'));
      expect(find.text('USD 92233720368547758.07'), findsOneWidget);
      expect(tester.takeException(), null);
      await tester.tap(find.text('Keep private'));
      await tester.pumpAndSettle();
      expect(find.byType(ChosenSummaryDialog), findsNothing);
      expect(published, 0);
      expect(tester.takeException(), null);
    },
  );
  testWidgets(
    'nothing selected, exact preview, explicit compatibility confirmation',
    (tester) async {
      var prepared = 0;
      var published = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChosenSummaryDialog(
              now: DateTime(2026, 10, 2),
              prepare: (range, income, expenses) async {
                prepared++;
                expect(income, false);
                expect(expenses, true);
                expect(range.start, DateTime(2026, 10, 1));
                expect(range.end, DateTime(2026, 10, 2));
                return SummaryPreview(
                  groupId: 'chosen-household',
                  currencyCode: 'USD',
                  startMillis: PlatformInt64Util.from(
                    range.start.millisecondsSinceEpoch,
                  ),
                  endMillisExclusive: PlatformInt64Util.from(
                    DateTime(2026, 10, 3).millisecondsSinceEpoch,
                  ),
                  incomeLabel: null,
                  expensesLabel: 'USD 87.00',
                );
              },
              publish: () async {
                published++;
                return true;
              },
            ),
          ),
        ),
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Preview totals'),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
            .every((tile) => tile.value == false),
        true,
      );
      await tester.tap(find.text('Expense total'));
      await tester.pump();
      await tester.tap(find.text('Preview totals'));
      await tester.pumpAndSettle();
      expect(prepared, 1);
      expect(published, 0);
      expect(find.text('USD 87.00'), findsOneWidget);
      expect(find.text('chosen-household'), findsOneWidget);
      expect(
        find.textContaining('cannot take this snapshot back'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Share these totals'),
            )
            .onPressed,
        isNull,
      );
      await tester.ensureVisible(find.byType(CheckboxListTile));
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      await tester.ensureVisible(find.text('Share these totals'));
      await tester.tap(find.text('Share these totals'));
      await tester.pumpAndSettle();
      expect(published, 1);
    },
  );
}
