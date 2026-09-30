import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/features/household/household_dialogs.dart';

Future<T?> _open<T>(
  WidgetTester tester,
  Widget dialog,
  void Function(T?) onResult,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async => onResult(
              await showDialog<T>(context: context, builder: (_) => dialog),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return null;
}

void main() {
  testWidgets('JoinDialog shows the request to hand over, then joins', (
    tester,
  ) async {
    bool? joined;
    String? pasted;
    await _open<bool>(
      tester,
      JoinDialog(
        prepareRequest: () async => 'cashkp1:REQUEST',
        join: (invite) async {
          pasted = invite;
          return true;
        },
      ),
      (result) => joined = result,
    );

    expect(find.text('cashkp1:REQUEST'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('inviteField')),
      'cashinv1:ABC',
    );
    await tester.tap(find.byKey(const Key('joinSubmit')));
    await tester.pumpAndSettle();

    expect(pasted, 'cashinv1:ABC');
    expect(joined, isTrue);
  });

  testWidgets('JoinDialog stays open when joining fails, and when empty', (
    tester,
  ) async {
    var attempts = 0;
    await _open<bool>(
      tester,
      JoinDialog(
        prepareRequest: () async => 'cashkp1:REQUEST',
        join: (_) async {
          attempts += 1;
          return false;
        },
      ),
      (_) {},
    );

    await tester.tap(find.byKey(const Key('joinSubmit')));
    await tester.pumpAndSettle();
    expect(attempts, 0, reason: 'nothing pasted yet');
    expect(find.text('Paste the invite you received'), findsWidgets);

    await tester.enterText(
      find.byKey(const Key('inviteField')),
      'cashinv1:ABC',
    );
    await tester.tap(find.byKey(const Key('joinSubmit')));
    await tester.pumpAndSettle();
    expect(attempts, 1);
    expect(find.byKey(const Key('inviteField')), findsOneWidget);
  });

  testWidgets('JoinDialog explains when the request cannot be made', (
    tester,
  ) async {
    await _open<bool>(
      tester,
      JoinDialog(prepareRequest: () async => null, join: (_) async => true),
      (_) {},
    );
    expect(
      find.textContaining("Couldn't create a join request"),
      findsOneWidget,
    );
  });

  testWidgets('InviteDialog turns a pasted request into an invite to copy', (
    tester,
  ) async {
    String? seen;
    await _open<void>(
      tester,
      InviteDialog(
        createInvite: (request) async {
          seen = request;
          return 'cashinv1:INVITE';
        },
      ),
      (_) {},
    );

    await tester.enterText(
      find.byKey(const Key('requestField')),
      'cashkp1:REQ',
    );
    await tester.tap(find.byKey(const Key('inviteSubmit')));
    await tester.pumpAndSettle();

    expect(seen, 'cashkp1:REQ');
    expect(find.text('cashinv1:INVITE'), findsOneWidget);
    expect(find.textContaining('once'), findsWidgets);
  });

  testWidgets('InviteDialog shows nothing to copy when inviting fails', (
    tester,
  ) async {
    await _open<void>(
      tester,
      InviteDialog(createInvite: (_) async => null),
      (_) {},
    );
    await tester.enterText(
      find.byKey(const Key('requestField')),
      'cashkp1:REQ',
    );
    await tester.tap(find.byKey(const Key('inviteSubmit')));
    await tester.pumpAndSettle();
    expect(find.textContaining('cashinv1:'), findsNothing);
    expect(find.byKey(const Key('requestField')), findsOneWidget);
  });

  testWidgets('SafetyNumberDialog shows the number for comparison', (
    tester,
  ) async {
    await _open<void>(
      tester,
      const SafetyNumberDialog(
        memberLabel: 'Member bbbb11',
        number: '12345 67890 11111 22222 33333 44444',
      ),
      (_) {},
    );
    expect(find.text('12345 67890 11111 22222 33333 44444'), findsOneWidget);
    expect(find.textContaining('Member bbbb11'), findsWidgets);
  });

  testWidgets('ExpenseDialog returns a trimmed title and an amount', (
    tester,
  ) async {
    ({String title, String amount})? result;
    await _open<({String title, String amount})>(
      tester,
      const ExpenseDialog(),
      (value) => result = value,
    );

    // Empty fields are refused.
    await tester.tap(find.byKey(const Key('expenseSubmit')));
    await tester.pumpAndSettle();
    expect(find.text('Enter a title'), findsOneWidget);
    expect(find.text('Enter an amount'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('expenseTitle')), '  Dinner ');
    await tester.enterText(find.byKey(const Key('expenseAmount')), '40.00');
    await tester.tap(find.byKey(const Key('expenseSubmit')));
    await tester.pumpAndSettle();
    expect(result, (title: 'Dinner', amount: '40.00'));
  });

  testWidgets('AmountDialog prefills and returns the new amount', (
    tester,
  ) async {
    String? result;
    await _open<String>(
      tester,
      const AmountDialog(title: 'Change amount', initial: '40.00'),
      (value) => result = value,
    );
    expect(find.text('40.00'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('amountField')), '42.50');
    await tester.tap(find.byKey(const Key('amountSubmit')));
    await tester.pumpAndSettle();
    expect(result, '42.50');
  });

  testWidgets('BackupDialog shows all 24 words and the backup code', (
    tester,
  ) async {
    final phrase = List.generate(
      24,
      (i) => 'word${String.fromCharCode(97 + i)}',
    ).join(' ');
    await _open<void>(
      tester,
      BackupDialog(phrase: phrase, backup: 'cashbk1:SEALED'),
      (_) {},
    );
    expect(find.text(phrase), findsOneWidget);
    expect(find.text('cashbk1:SEALED'), findsOneWidget);
    expect(find.textContaining('Write these 24 words'), findsOneWidget);
  });

  testWidgets('RestoreDialog sends the phrase and backup, closing on success', (
    tester,
  ) async {
    String? phrase;
    String? backup;
    bool? restored;
    await _open<bool>(
      tester,
      RestoreDialog(
        restore: (p, b) async {
          phrase = p;
          backup = b;
          return true;
        },
      ),
      (value) => restored = value,
    );
    await tester.enterText(
      find.byKey(const Key('phraseField')),
      'one two three',
    );
    await tester.enterText(
      find.byKey(const Key('backupField')),
      'cashbk1:SEALED',
    );
    await tester.tap(find.byKey(const Key('restoreSubmit')));
    await tester.pumpAndSettle();
    expect(phrase, 'one two three');
    expect(backup, 'cashbk1:SEALED');
    expect(restored, isTrue);
  });
}
