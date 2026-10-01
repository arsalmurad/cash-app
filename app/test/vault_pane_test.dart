import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/features/household/vault_pane.dart';

void main() {
  testWidgets('setup requires private phrase confirmation before adoption', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    String? adopted;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VaultPane(
            hasCiphertext: false,
            generatePhrase: () async => 'a generated synthetic phrase',
            unlock: (value) async {
              adopted = value;
              return true;
            },
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('vaultUnlock')), findsNothing);
    await tester.tap(find.text('Create unlock phrase'));
    await tester.pumpAndSettle();
    expect(
      find.bySemanticsLabel('a generated synthetic phrase'),
      findsOneWidget,
    );
    expect(adopted, isNull);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('vaultUnlock')))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('vaultUnlock')));
    await tester.tap(find.byKey(const Key('vaultUnlock')));
    await tester.pumpAndSettle();
    expect(adopted, 'a generated synthetic phrase');
    semantics.dispose();
  });

  testWidgets('unlock obscures input and exposes independent backup recovery', (
    tester,
  ) async {
    String? adopted;
    bool recovered = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VaultPane(
            hasCiphertext: true,
            error: 'The saved household could not be opened.',
            generatePhrase: () async => null,
            unlock: (value) async {
              adopted = value;
              return false;
            },
            recover: () {
              recovered = true;
            },
          ),
        ),
      ),
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('vaultPhrase')))
          .obscureText,
      isTrue,
    );
    expect(find.byKey(const Key('vaultError')), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('vaultPhrase')),
      '  synthetic phrase  ',
    );
    await tester.tap(find.byKey(const Key('vaultUnlock')));
    await tester.pumpAndSettle();
    expect(adopted, 'synthetic phrase');
    await tester.tap(find.text('Restore an encrypted backup'));
    expect(recovered, isTrue);
  });
}
