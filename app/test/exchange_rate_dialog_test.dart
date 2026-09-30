import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/features/ledger/exchange_rate_dialog.dart';

void main() {
  Future<void> open(WidgetTester tester, ValueChanged<String?> onResult) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                onResult(
                  await showDialog<String>(
                    context: context,
                    builder: (context) => const ExchangeRateDialog(
                      sourceCurrencyCode: 'EUR',
                      reportingCurrencyCode: 'USD',
                    ),
                  ),
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
  }

  testWidgets('names both currencies and returns the typed rate', (
    tester,
  ) async {
    String? result;
    await open(tester, (value) => result = value);

    expect(find.textContaining('USD per 1 EUR'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField), ' 1.0875 ');
    await tester.tap(find.text('Use rate'));
    await tester.pumpAndSettle();

    expect(result, '1.0875');
  });

  testWidgets('an empty rate is rejected and the dialog stays open', (
    tester,
  ) async {
    String? result = 'untouched';
    await open(tester, (value) => result = value);

    await tester.tap(find.text('Use rate'));
    await tester.pumpAndSettle();

    expect(find.text('Enter the exchange rate'), findsOneWidget);
    expect(result, 'untouched');
  });

  testWidgets('cancelling returns null', (tester) async {
    String? result = 'untouched';
    await open(tester, (value) => result = value);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(result, isNull);
  });
}
