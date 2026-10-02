import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:private_ledger/data/rust/api/ledger.dart';
import 'package:private_ledger/data/rust/frb_generated.dart';
import 'package:private_ledger/data/storage/event_store.dart';
import 'package:private_ledger/features/ledger/ledger_controller.dart';

class _Paths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

class _FaultStore implements EventStore {
  _FaultStore(this.afterCommit);
  final bool afterCommit;
  final delegate = EventStore('ledger');
  bool fail = false;
  @override
  Future<Uint8List> readLog() => delegate.readLog();
  @override
  Future<void> recoverPrefix(int validLength, {required int expectedLength}) =>
      delegate.recoverPrefix(validLength, expectedLength: expectedLength);
  @override
  Future<void> appendFrame(Uint8List frame) async {
    if (!fail || afterCommit) await delegate.appendFrame(frame);
    if (fail) throw StateError('Synthetic correction save failure');
  }
}

void main() {
  final library = Platform.environment['RUST_LIB_PATH'];
  group(
    'real SQLite transaction corrections',
    () {
      late Directory directory;
      late PathProviderPlatform previous;
      setUpAll(
        () async =>
            RustLib.init(externalLibrary: ExternalLibrary.open(library!)),
      );
      setUp(() async {
        directory = await Directory.systemTemp.createTemp(
          'cash-correction-test-',
        );
        previous = PathProviderPlatform.instance;
        PathProviderPlatform.instance = _Paths(directory.path);
      });
      tearDown(() async {
        PathProviderPlatform.instance = previous;
        await directory.delete(recursive: true);
      });
      test('correction/category/removal survive cold reload with original frames intact', () async {
        final controller = LedgerController();
        addTearDown(controller.dispose);
        await controller.initialize();
        expect(
          await controller.createAccount(name: 'Euro', currencyCode: 'EUR'),
          isTrue,
        );
        final euro = controller.overview!.accounts.firstWhere(
          (a) => a.currencyCode == 'EUR',
        );
        final food = controller.categories.first.id;
        expect(
          await controller.record(
            title: 'Lunch',
            amount: '80.00',
            kind: EntryKind.expense,
            accountId: euro.id,
            categoryId: food,
            rate: '1.0875',
          ),
          isTrue,
        );
        final original = controller.overview!.transactions.single;
        final prefix = await EventStore('ledger').readLog();
        expect(await controller.correctAmount(original, '85.00'), isTrue);
        expect(controller.overview!.balanceLabel, 'USD -92.44');
        expect(await controller.correctAmount(original, '90.00'), isFalse);
        final changed = controller.overview!.transactions.single;
        expect(
          await controller.changeTransactionCategory(changed, null),
          isTrue,
        );
        expect(await controller.suggestCategoryFor('lunch'), isNull);
        expect(
          await controller.removeTransaction(changed),
          isFalse,
          reason: 'Stale category must be rejected',
        );
        expect(
          await controller.removeTransaction(
            controller.overview!.transactions.single,
          ),
          isTrue,
        );
        expect(controller.overview!.balanceLabel, 'USD 0.00');
        expect(
          controller.exportTransactionsCsv(),
          'title,amount,kind,account,category\n',
        );
        final bytes = await EventStore('ledger').readLog();
        expect(bytes.take(prefix.length), orderedEquals(prefix));
        final restarted = LedgerController();
        addTearDown(restarted.dispose);
        await restarted.initialize();
        expect(restarted.errorMessage, isNull);
        expect(restarted.overview!.transactions.single.voided, isTrue);
        expect(
          (await restarted.historyFor(restarted.overview!.transactions.single))
              .map((e) => e.action),
          [
            'Recorded',
            'Amount corrected',
            'Category changed',
            'Removed from balances',
          ],
        );
        expect(
          restarted.exportTransactionsCsv(),
          controller.exportTransactionsCsv(),
        );
      });
      for (final action in ['amount', 'category', 'remove']) {
        for (final after in [false, true]) {
          test(
            '$action failure ${after ? "after" : "before"} commit requires restart',
            () async {
              final store = _FaultStore(after);
              final controller = LedgerController(ledgerStore: store);
              addTearDown(controller.dispose);
              await controller.initialize();
              final category = controller.categories.first.id;
              expect(
                await controller.record(
                  title: 'Coffee',
                  amount: '10',
                  kind: EntryKind.expense,
                  accountId: controller.overview!.accounts.first.id,
                  categoryId: category,
                ),
                isTrue,
              );
              final transaction = controller.overview!.transactions.single;
              store.fail = true;
              final saved = switch (action) {
                'amount' => await controller.correctAmount(transaction, '12'),
                'category' => await controller.changeTransactionCategory(
                  transaction,
                  null,
                ),
                _ => await controller.removeTransaction(transaction),
              };
              expect(saved, isFalse);
              expect(
                controller.overview!.transactions.single.amountLabel,
                'USD 10.00',
              );
              expect(
                controller.overview!.transactions.single.categoryId,
                category,
              );
              expect(controller.overview!.transactions.single.voided, isFalse);
              expect(
                await controller.correctAmount(transaction, '15'),
                isFalse,
              );
              expect(await controller.removeTransaction(transaction), isFalse);
              final restarted = LedgerController();
              addTearDown(restarted.dispose);
              await restarted.initialize();
              expect(restarted.errorMessage, isNull);
              final recovered = restarted.overview!.transactions.single;
              expect(
                recovered.amountLabel,
                after && action == 'amount' ? 'USD 12.00' : 'USD 10.00',
              );
              expect(
                recovered.categoryId,
                after && action == 'category' ? null : category,
              );
              expect(recovered.voided, after && action == 'remove');
              expect(
                (await restarted.historyFor(recovered)).length,
                after ? 2 : 1,
              );
            },
          );
        }
      }
    },
    skip: library == null
        ? 'Set RUST_LIB_PATH to the built native bridge.'
        : false,
  );
}
