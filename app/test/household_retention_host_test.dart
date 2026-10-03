import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/data/rust/api/shared.dart';
import 'package:private_ledger/data/rust/frb_generated.dart';
import 'package:private_ledger/data/storage/blob_store.dart';
import 'package:private_ledger/features/household/household_controller.dart';
import 'package:private_ledger/features/household/household_journal.dart';
import 'package:private_ledger/features/household/relay_client.dart';

class _Store implements BlobStore {
  Uint8List? value;
  int reads = 0;
  int writes = 0;
  int? failWrite;
  bool saveBeforeFailure = false;
  bool failRead = false;
  Uint8List? staleRead;

  @override
  Future<Uint8List?> read() async {
    reads++;
    if (failRead) throw const FileSystemException('synthetic read failure');
    if (staleRead != null) return Uint8List.fromList(staleRead!);
    return value == null ? null : Uint8List.fromList(value!);
  }

  @override
  Future<void> write(Uint8List bytes) async {
    writes++;
    if (writes == failWrite) {
      if (saveBeforeFailure) value = Uint8List.fromList(bytes);
      throw const FileSystemException('synthetic uncertain save');
    }
    value = Uint8List.fromList(bytes);
  }

  @override
  Future<void> delete() async => value = null;
}

class _LostReplyRelay extends MemoryRelayClient {
  int appends = 0;
  int? loseAt;

  @override
  Future<int> append(String group, int expectedTail, Uint8List blob) async {
    final sequence = await super.append(group, expectedTail, blob);
    appends++;
    if (appends == loseAt) {
      throw const RelayUnavailable('synthetic lost receipt reply');
    }
    return sequence;
  }
}

Future<bool> _needsReceipt(_Store store) async {
  final restored = await householdRestore(
    saved: HouseholdJournal.decode(store.value!).state,
  );
  try {
    return await householdNeedsSavedStateReceipt(household: restored);
  } finally {
    restored.dispose();
  }
}

void main() {
  final library = Platform.environment['RUST_LIB_PATH'];
  group('saved receipt coordination through the native bridge', () {
    setUpAll(() async {
      await RustLib.init(externalLibrary: ExternalLibrary.open(library!));
    });

    test(
      'confirmed saves acknowledge once and restart without a loop',
      () async {
        final relay = MemoryRelayClient();
        final store = _Store();
        final config = _Store();
        HouseholdController controller() => HouseholdController(
          stateStore: store,
          configStore: config,
          relayFactory: (_) => relay,
        );
        final first = controller();
        await first.initialize();
        await first.setRelayUrl('https://relay.test');
        expect(await first.createHousehold(), isTrue);
        expect(await _needsReceipt(store), isFalse);
        final group = first.overview!.groupId!;
        final before = await relay.readAfter(group, 0);
        final reads = store.reads;
        expect(await first.syncNow(), isTrue);
        expect(
          store.reads,
          reads,
          reason: 'Control-only sync needs no new ACK',
        );
        first.dispose();
        final restarted = controller();
        addTearDown(restarted.dispose);
        await restarted.initialize();
        expect(await restarted.syncNow(), isTrue);
        expect((await relay.readAfter(group, 0)).length, before.length);
        final restartReads = store.reads;
        expect(
          await restarted.addExpense(title: 'Shared only', amount: '1.00'),
          isTrue,
        );
        expect(store.reads, greaterThan(restartReads));
        expect(await _needsReceipt(store), isFalse);
        expect(restarted.overview!.balanceLabel, 'USD -1.00');
      },
    );

    for (final afterSave in [false, true]) {
      for (final boundary in [3, 4, 5]) {
        test('save failure at boundary $boundary blocks ACK (saved=$afterSave)', () async {
          final relay = MemoryRelayClient();
          final store = _Store();
          final controller = HouseholdController(
            stateStore: store,
            configStore: _Store(),
            relayFactory: (_) => relay,
          );
          addTearDown(controller.dispose);
          await controller.initialize();
          await controller.setRelayUrl('https://relay.test');
          expect(await controller.createHousehold(), isTrue);
          final group = controller.overview!.groupId!;
          final before = (await relay.readAfter(group, 0)).length;
          store.failWrite = store.writes + boundary;
          store.saveBeforeFailure = afterSave;
          expect(
            await controller.addExpense(
              title: 'Confirmed shared expense',
              amount: '2.00',
            ),
            isFalse,
          );
          expect(controller.requiresRestart, isTrue);
          expect(
            (await relay.readAfter(group, 0)).length,
            before + 1,
            reason:
                'The expense was saved/sent, but no ACK may reach the relay',
          );
          expect(await controller.syncNow(), isFalse);
          expect((await relay.readAfter(group, 0)).length, before + 1);
          final restarted = HouseholdController(
            stateStore: store,
            configStore: _Store(),
            relayFactory: (_) => relay,
          );
          addTearDown(restarted.dispose);
          await restarted.initialize();
          expect(await restarted.syncNow(), isTrue);
          expect(await _needsReceipt(store), isFalse);
          final completed = before + (boundary == 3 && !afterSave ? 3 : 2);
          expect(
            (await relay.readAfter(group, 0)).length,
            completed,
            reason:
                'An unconfirmed financial append may retry its immutable event',
          );
          expect(restarted.overview!.transactions.length, 1);
          expect(await restarted.syncNow(), isTrue);
          expect((await relay.readAfter(group, 0)).length, completed);
        });
      }
    }

    test('read-back failure cannot issue an ACK', () async {
      final relay = MemoryRelayClient();
      final store = _Store();
      final controller = HouseholdController(
        stateStore: store,
        configStore: _Store(),
        relayFactory: (_) => relay,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.setRelayUrl('https://relay.test');
      expect(await controller.createHousehold(), isTrue);
      final group = controller.overview!.groupId!;
      final before = (await relay.readAfter(group, 0)).length;
      store.failRead = true;
      expect(
        await controller.addExpense(title: 'Shared only', amount: '3.00'),
        isFalse,
      );
      expect(controller.requiresRestart, isTrue);
      expect((await relay.readAfter(group, 0)).length, before + 1);
    });

    test(
      'a stale confirmed read-back cannot acknowledge newer live history',
      () async {
        final relay = MemoryRelayClient();
        final store = _Store();
        final controller = HouseholdController(
          stateStore: store,
          configStore: _Store(),
          relayFactory: (_) => relay,
        );
        addTearDown(controller.dispose);
        await controller.initialize();
        await controller.setRelayUrl('https://relay.test');
        expect(await controller.createHousehold(), isTrue);
        final group = controller.overview!.groupId!;
        final before = (await relay.readAfter(group, 0)).length;
        store.staleRead = Uint8List.fromList(store.value!);
        expect(
          await controller.addExpense(
            title: 'New shared history',
            amount: '4.00',
          ),
          isFalse,
        );
        expect(controller.requiresRestart, isTrue);
        expect((await relay.readAfter(group, 0)).length, before + 1);
      },
    );

    test(
      'lost receipt reply retries idempotently without an ongoing loop',
      () async {
        final relay = _LostReplyRelay();
        final store = _Store();
        final config = _Store();
        HouseholdController controller() => HouseholdController(
          stateStore: store,
          configStore: config,
          relayFactory: (_) => relay,
        );
        final first = controller();
        addTearDown(first.dispose);
        await first.initialize();
        await first.setRelayUrl('https://relay.test');
        expect(await first.createHousehold(), isTrue);
        final group = first.overview!.groupId!;
        final before = (await relay.readAfter(group, 0)).length;
        relay.loseAt = relay.appends + 2; // Financial frame, then receipt.
        expect(
          await first.addExpense(title: 'Shared only', amount: '5.00'),
          isFalse,
        );
        expect(first.requiresRestart, isFalse);
        expect((await relay.readAfter(group, 0)).length, before + 2);
        final restarted = controller();
        addTearDown(restarted.dispose);
        await restarted.initialize();
        expect(await restarted.syncNow(), isTrue);
        expect(await _needsReceipt(store), isFalse);
        expect(restarted.overview!.transactions.single.title, 'Shared only');
        expect(
          (await relay.readAfter(group, 0)).length,
          before + 3,
          reason: 'A lost append reply retries the same signed receipt',
        );
        expect(await restarted.syncNow(), isTrue);
        expect((await relay.readAfter(group, 0)).length, before + 3);
      },
    );
  }, skip: library == null ? 'Requires the built native Rust library' : false);
}
