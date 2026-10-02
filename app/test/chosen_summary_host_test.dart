import 'dart:convert';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:private_ledger/data/rust/api/ledger.dart';
import 'package:private_ledger/data/rust/frb_generated.dart';
import 'package:private_ledger/data/storage/blob_store.dart';
import 'package:private_ledger/data/storage/event_store.dart';
import 'package:private_ledger/data/storage/secret_blob_store.dart';
import 'package:private_ledger/data/storage/vault_keys.dart';
import 'package:private_ledger/features/household/household_controller.dart';
import 'package:private_ledger/features/household/relay_client.dart';
import 'package:private_ledger/features/ledger/ledger_controller.dart';

class _Paths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

// Real AEAD and SQLite, but a test key holder, not an OS-key-storage claim.
class _Keys implements VaultKeys {
  String? phrase;
  @override
  bool get requiresUnlock => false;
  @override
  Future<String?> read() async => phrase;
  @override
  Future<void> write(String value) async => phrase = value;
  @override
  void lock() {}
}

class _FaultBlob implements BlobStore {
  _FaultBlob(this.inner);
  final BlobStore inner;
  bool fail = false;
  bool after = false;
  @override
  Future<Uint8List?> read() => inner.read();
  @override
  Future<void> delete() => inner.delete();
  @override
  Future<void> write(Uint8List bytes) async {
    if (!fail || after) await inner.write(bytes);
    if (fail) throw StateError('Synthetic uncertain summary save');
  }
}

class _FaultEvents implements EventStore {
  final delegate = EventStore('ledger');
  bool fail = false;
  @override
  Future<Uint8List> readLog() => delegate.readLog();
  @override
  Future<void> recoverPrefix(int validLength, {required int expectedLength}) =>
      delegate.recoverPrefix(validLength, expectedLength: expectedLength);
  @override
  Future<void> appendFrame(Uint8List frame) async {
    if (fail) throw StateError('Synthetic private save failure');
    await delegate.appendFrame(frame);
  }
}

void main() {
  final library = Platform.environment['RUST_LIB_PATH'];
  group(
    'chosen summaries through real native SQLite and MLS',
    () {
      late Directory directory;
      late PathProviderPlatform previous;
      final now = DateTime(2026, 10, 2, 12);
      setUpAll(
        () async =>
            RustLib.init(externalLibrary: ExternalLibrary.open(library!)),
      );
      setUp(() async {
        directory = await Directory.systemTemp.createTemp('cash-summary-test-');
        previous = PathProviderPlatform.instance;
        PathProviderPlatform.instance = _Paths(directory.path);
      });
      tearDown(() async {
        PathProviderPlatform.instance = previous;
        await directory.delete(recursive: true);
      });

      Future<LedgerController> privateLedger({EventStore? store}) async {
        final ledger = LedgerController(ledgerStore: store, now: () => now);
        addTearDown(ledger.dispose);
        await ledger.initialize();
        expect(
          await ledger.createAccount(
            name: 'Secret euro account',
            currencyCode: 'EUR',
          ),
          true,
        );
        final euro = ledger.overview!.accounts.firstWhere(
          (account) => account.currencyCode == 'EUR',
        );
        expect(
          await ledger.record(
            title: 'Secret lunch',
            amount: '80',
            kind: EntryKind.expense,
            accountId: euro.id,
            rate: '1.0875',
          ),
          true,
        );
        return ledger;
      }

      test('preview and cancellation write nothing; exact snapshot survives sealed restart', () async {
        final ledger = await privateLedger();
        final keys = _Keys();
        final relay = MemoryRelayClient();
        HouseholdController household() => HouseholdController(
          stateStore: SecretBlobStore(
            BlobStore('summary-household'),
            keys: keys,
          ),
          configStore: BlobStore('summary-config'),
          relayFactory: (_) => relay,
        );
        final first = household();
        addTearDown(first.dispose);
        await first.initialize();
        expect(await first.setRelayUrl('https://relay.test'), true);
        expect(await first.createHousehold(), true);
        final group = first.overview!.groupId!;
        final personal = await EventStore('ledger').readLog();
        final sealedBefore = await BlobStore('summary-household').read();
        final relayBefore = (await relay.readAfter(group, 0)).length;
        final draft = await ledger.prepareChosenSummary(
          groupId: group,
          start: DateTime(2026, 10, 1),
          endExclusive: DateTime(2026, 10, 3),
          includeIncome: false,
          includeExpenses: true,
        );
        expect((await summaryPreview(draft: draft)).expensesLabel, 'USD 87.00');
        expect(await EventStore('ledger').readLog(), personal);
        expect(await BlobStore('summary-household').read(), sealedBefore);
        expect((await relay.readAfter(group, 0)).length, relayBefore);
        expect(
          await ledger.correctAmount(
            ledger.overview!.transactions.single,
            '85',
          ),
          true,
        );
        final correctedPersonal = await EventStore('ledger').readLog();
        expect(await first.publishSummary(draft), true);
        expect(first.summaries.single.preview.expensesLabel, 'USD 87.00');
        expect(first.summaries.single.preview.incomeLabel, null);
        expect(first.overview!.balanceLabel, 'USD 0.00');
        expect(await EventStore('ledger').readLog(), correctedPersonal);
        final sealed = (await BlobStore('summary-household').read())!;
        final text = utf8.decode(sealed, allowMalformed: true);
        expect(text, isNot(contains('Secret lunch')));
        expect(text, isNot(contains('USD 87.00')));
        expect(text, isNot(contains(keys.phrase!)));
        final restarted = household();
        addTearDown(restarted.dispose);
        await restarted.initialize();
        expect(restarted.summaries, first.summaries);
        expect(restarted.overview!.transactions, isEmpty);
        expect(await first.publishSummary(draft), false);
        expect(first.summaries.length, 1);
      });

      for (final after in [false, true]) {
        test(
          'uncertain sealed summary save, afterCommit=$after, never sends before durable restart',
          () async {
            final ledger = await privateLedger();
            final keys = _Keys();
            final relay = MemoryRelayClient();
            final state = _FaultBlob(
              SecretBlobStore(BlobStore('summary-household'), keys: keys),
            );
            HouseholdController household() => HouseholdController(
              stateStore: state,
              configStore: BlobStore('summary-config'),
              relayFactory: (_) => relay,
            );
            final first = household();
            addTearDown(first.dispose);
            await first.initialize();
            expect(await first.setRelayUrl('https://relay.test'), true);
            expect(await first.createHousehold(), true);
            final group = first.overview!.groupId!;
            final before = (await relay.readAfter(group, 0)).length;
            final draft = await ledger.prepareChosenSummary(
              groupId: group,
              start: DateTime(2026, 10, 1),
              endExclusive: DateTime(2026, 10, 3),
              includeIncome: false,
              includeExpenses: true,
            );
            state
              ..fail = true
              ..after = after;
            expect(await first.publishSummary(draft), false);
            expect(first.summaries, isEmpty);
            expect(await first.publishSummary(draft), false);
            expect((await relay.readAfter(group, 0)).length, before);
            state.fail = false;
            final restarted = household();
            addTearDown(restarted.dispose);
            await restarted.initialize();
            expect(restarted.summaries.length, after ? 1 : 0);
            expect(await restarted.syncNow(), true);
            expect(
              (await relay.readAfter(group, 0)).length,
              before + (after ? 1 : 0),
            );
          },
        );
      }

      test('preview queued behind an unconfirmed private write cannot leak unsaved totals', () async {
        final store = _FaultEvents();
        final ledger = await privateLedger(store: store);
        store.fail = true;
        final correction = ledger.correctAmount(
          ledger.overview!.transactions.single,
          '85',
        );
        final preview = ledger.prepareChosenSummary(
          groupId: 'chosen-group',
          start: DateTime(2026, 10, 1),
          endExclusive: DateTime(2026, 10, 3),
          includeIncome: false,
          includeExpenses: true,
        );
        // Install the error expectation before the queued operation can reject.
        final rejected = expectLater(preview, throwsStateError);
        expect(await correction, false);
        await rejected;
      });
    },
    skip: library == null
        ? 'Set RUST_LIB_PATH to the built native bridge.'
        : false,
  );
}
