import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/data/rust/api/ledger.dart';
import 'package:private_ledger/features/ledger/ledger_screen.dart';

void main() {
  for (final size in [
    const Size(360, 740),
    const Size(840, 600),
    const Size(1280, 900),
  ]) {
    for (final brightness in Brightness.values) {
      testWidgets('full transfer amounts at $size, $brightness, 1.5x text', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        for (final received in [
          'USD 10000000000000000.00',
          'JPY 1000000000000000000',
        ]) {
          final amounts = received == 'USD 10000000000000000.00'
              ? received
              : 'USD 10000000000000000.00 → $received';
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(useMaterial3: true, brightness: brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(1.5)),
                child: child!,
              ),
              home: Scaffold(
                body: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    TransferTile(
                      TransferView(
                        id: 'transfer',
                        title: 'Move savings for a household emergency fund',
                        fromAccountId: 'Everyday spending account',
                        toAccountId: 'Long-term household savings account',
                        sentLabel: 'USD 10000000000000000.00',
                        receivedLabel: received,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.text(amounts), findsOneWidget);
          expect(
            find.text(
              'Everyday spending account → Long-term household savings account',
            ),
            findsOneWidget,
          );
        }
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
