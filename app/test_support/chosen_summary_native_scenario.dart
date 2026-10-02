import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/data/rust/api/ledger.dart';
import 'package:private_ledger/data/storage/blob_store.dart';
import 'package:private_ledger/data/storage/event_store.dart';
import 'package:private_ledger/data/storage/secret_blob_store.dart';
import 'package:private_ledger/data/storage/vault_keys_native.dart';
import 'package:private_ledger/features/household/household_controller.dart';
import 'package:private_ledger/features/household/household_screen.dart';
import 'package:private_ledger/features/household/relay_client.dart';
import 'package:private_ledger/features/ledger/ledger_controller.dart';

/// Actual native UI, SQLite, OS wrapping keys and MLS. The two peers are logical
/// identities on one test device, not two physical phones or an HTTP relay.
Future<void> runChosenSummaryNativeScenario(WidgetTester tester) async {
  final namespace = 'chosen-summary-${DateTime.now().microsecondsSinceEpoch}';
  final relay = MemoryRelayClient();
  final controllers = <HouseholdController>[];
  final ledger = LedgerController(
    ledgerStore: EventStore('$namespace-private'),
    categoryStore: EventStore('$namespace-categories'),
    budgetStore: EventStore('$namespace-budgets'),
    goalStore: EventStore('$namespace-goals'),
    recurringStore: EventStore('$namespace-recurring'),
  );
  HouseholdController household(String scope) {
    final next = HouseholdController(
      stateStore: SecretBlobStore(
        BlobStore('$namespace-$scope'),
        keys: NativeVaultKeys(key: 'cash-app.test.$namespace.$scope'),
      ),
      configStore: BlobStore('$namespace-$scope-config'),
      relayFactory: (_) => relay,
    );
    controllers.add(next);
    return next;
  }

  Future<void> waitFor(Finder finder) async {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (finder.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(finder, findsWidgets);
    await tester.pumpAndSettle();
  }

  Future<void> preview() async {
    await tester.ensureVisible(find.text('Choose private totals to share'));
    await tester.tap(find.text('Choose private totals to share'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
          .every((tile) => tile.value == false),
      true,
    );
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Preview totals'),
          )
          .onPressed,
      null,
    );
    await tester.ensureVisible(find.text('Expense total'));
    await tester.tap(find.text('Expense total'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Preview totals'));
    await waitFor(find.text('Review shared snapshot'));
    expect(find.text('USD 12.34'), findsOneWidget);
  }

  try {
    await ledger.initialize();
    expect(ledger.errorMessage, null);
    expect(
      await ledger.record(
        title: 'Private native summary source',
        amount: '12.34',
        kind: EntryKind.expense,
        accountId: ledger.overview!.accounts.first.id,
      ),
      true,
    );
    final alice = household('alice');
    await alice.initialize();
    expect(await alice.setRelayUrl('https://relay.test'), true);
    expect(await alice.createHousehold(), true);
    final privateFrames = await EventStore('$namespace-private').readLog();
    final group = alice.overview!.groupId!;
    await tester.pumpWidget(
      MaterialApp(
        home: HouseholdScreen(
          controller: alice,
          privateLedger: ledger,
          syncInterval: const Duration(minutes: 10),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Wait behind the screen's initial auto-sync before measuring cancellation.
    expect(await alice.syncNow(), true);
    await tester.pumpAndSettle();
    final sealedBefore = await BlobStore('$namespace-alice').read();
    final before = (await relay.readAfter(group, 0)).length;
    await preview();
    await tester.tap(find.text('Keep private'));
    await tester.pumpAndSettle();
    expect(alice.summaries, isEmpty);
    expect(await EventStore('$namespace-private').readLog(), privateFrames);
    expect(await BlobStore('$namespace-alice').read(), sealedBefore);
    expect((await relay.readAfter(group, 0)).length, before);
    await preview();
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Share these totals'),
          )
          .onPressed,
      null,
    );
    final compatibility = find.text(
      'Everyone in this household has updated to the summary-capable app.',
    );
    await tester.ensureVisible(compatibility);
    await tester.tap(compatibility);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Share these totals'));
    await waitFor(find.text('Expense total: USD 12.34'));
    expect(alice.overview!.balanceLabel, 'USD 0.00');
    expect(alice.overview!.transactions, isEmpty);
    expect(alice.summaries.single.preview.incomeLabel, null);
    expect(await EventStore('$namespace-private').readLog(), privateFrames);
    final sealed = (await BlobStore('$namespace-alice').read())!;
    expect(latin1.decode(sealed), contains('cash-app sealed vault v1'));
    expect(
      latin1.decode(sealed),
      isNot(contains('Private native summary source')),
    );
    final phrase = await NativeVaultKeys(key: 'cash-app.test.$namespace.alice')
        .read();
    expect(phrase, isNotNull);
    expect(latin1.decode(sealed), isNot(contains(phrase!)));

    expect(
      await ledger.correctAmount(ledger.overview!.transactions.single, '20'),
      true,
    );
    final restarted = household('alice');
    await restarted.initialize();
    expect(restarted.summaries.single.preview.expensesLabel, 'USD 12.34');
    expect(restarted.overview!.balanceLabel, 'USD 0.00');
    final bob = household('bob');
    await bob.initialize();
    final request = (await bob.prepareJoinRequest())!;
    final invite = (await restarted.invite(request))!;
    expect(await bob.acceptInvite(invite), true);
    expect(await restarted.syncNow(), true);
    expect(await bob.syncNow(), true);
    expect(bob.summaries, restarted.summaries);
    expect(bob.summaries.single.preview.expensesLabel, 'USD 12.34');
    expect(bob.overview!.transactions, isEmpty);
    expect(bob.overview!.balanceLabel, 'USD 0.00');
    expect(tester.takeException(), null);
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    for (final controller in controllers) {
      controller.dispose();
    }
    ledger.dispose();
    for (final scope in ['alice', 'bob']) {
      await BlobStore('$namespace-$scope').delete();
      await BlobStore('$namespace-$scope-config').delete();
      await const FlutterSecureStorage().delete(
        key: 'cash-app.test.$namespace.$scope',
      );
    }
  }
}
