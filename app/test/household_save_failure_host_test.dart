import 'dart:async';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/data/rust/frb_generated.dart';
import 'package:private_ledger/data/storage/blob_store.dart';
import 'package:private_ledger/features/household/household_controller.dart';
import 'package:private_ledger/features/household/relay_client.dart';

class _Store implements BlobStore {
  Uint8List? value;
  bool fail = false;
  bool saveBeforeFailure = false;
  int? failAfter;
  Completer<void>? entered;
  Completer<void>? release;

  @override
  Future<Uint8List?> read() async => value;

  @override
  Future<void> write(Uint8List bytes) async {
    if (failAfter != null) {
      failAfter = failAfter! - 1;
      if (failAfter == 0) fail = true;
    }
    if (fail) {
      entered?.complete();
      await release?.future;
      if (saveBeforeFailure) value = Uint8List.fromList(bytes);
      throw const FileSystemException('simulated uncertain save');
    }
    value = Uint8List.fromList(bytes);
  }

  @override
  Future<void> delete() async => value = null;
}

void main() {
  final libraryPath = Platform.environment['RUST_LIB_PATH'];
  group(
    'household save safety through the real bridge',
    () {
      setUpAll(() async {
        await RustLib.init(externalLibrary: ExternalLibrary.open(libraryPath!));
      });

      for (final saved in [false, true]) {
        test('uncertain save ($saved) stops queued and later writes', () async {
          final state = _Store();
          final config = _Store();
          final relay = MemoryRelayClient();
          HouseholdController controller() => HouseholdController(
            stateStore: state,
            configStore: config,
            relayFactory: (_) => relay,
          );
          final device = controller();
          await device.initialize();
          expect(await device.setRelayUrl('https://relay.test'), isTrue);
          expect(await device.createHousehold(), isTrue);
          state
            ..fail = true
            ..saveBeforeFailure = saved
            ..entered = Completer<void>()
            ..release = Completer<void>();
          final first = device.addExpense(title: 'Uncertain', amount: '1.00');
          await state.entered!.future;
          final queued = device.addExpense(
            title: 'Must not save',
            amount: '2.00',
          );
          state.release!.complete();
          expect(await first, isFalse);
          state.fail = false;
          expect(await queued, isFalse);
          expect(
            await device.addExpense(title: 'Still locked', amount: '3.00'),
            isFalse,
          );
          expect(device.overview!.transactions, isEmpty);
          expect(device.errorMessage, contains('Restart'));
          final restart = controller();
          await restart.initialize();
          expect(restart.overview!.transactions.length, saved ? 1 : 0);
          expect(
            await restart.addExpense(title: 'After restart', amount: '4.00'),
            isTrue,
          );
          expect(restart.overview!.transactions.length, saved ? 2 : 1);
        });
      }
      test(
        'ratchet save failure sends no ciphertext and restart can retry',
        () async {
          final state = _Store();
          final config = _Store();
          final relay = MemoryRelayClient();
          HouseholdController controller() => HouseholdController(
            stateStore: state,
            configStore: config,
            relayFactory: (_) => relay,
          );
          final device = controller();
          await device.initialize();
          await device.setRelayUrl('https://relay.test');
          expect(await device.createHousehold(), isTrue);
          final group = device.overview!.groupId!;
          final before = await relay.readAfter(group, 0);
          state.failAfter =
              2; // local event saved, encrypted sender state fails.
          expect(
            await device.addExpense(title: 'Queued', amount: '1.00'),
            isFalse,
          );
          expect((await relay.readAfter(group, 0)).length, before.length);
          state
            ..fail = false
            ..failAfter = null;
          final restart = controller();
          await restart.initialize();
          expect(restart.overview!.transactions.single.title, 'Queued');
          expect(await restart.syncNow(), isTrue);
          expect((await relay.readAfter(group, 0)).length, before.length + 1);
        },
      );
      test(
        'concurrent writes serialize and invalid input does not lock state',
        () async {
          final state = _Store();
          final config = _Store();
          final relay = MemoryRelayClient();
          final device = HouseholdController(
            stateStore: state,
            configStore: config,
            relayFactory: (_) => relay,
            clockMillis: () => 1000,
          );
          await device.initialize();
          await device.setRelayUrl('https://relay.test');
          expect(await device.createHousehold(), isTrue);
          expect(
            await device.addExpense(title: 'Invalid', amount: 'not money'),
            isFalse,
          );
          final results = await Future.wait([
            for (var i = 0; i < 20; i++)
              device.addExpense(title: 'Expense $i', amount: '1.00'),
          ]);
          expect(results, everyElement(isTrue));
          expect(device.overview!.transactions.length, 20);
          expect(device.overview!.balanceLabel, 'USD -20.00');
          final restart = HouseholdController(
            stateStore: state,
            configStore: config,
            relayFactory: (_) => relay,
            clockMillis: () => 1000,
          );
          await restart.initialize();
          expect(restart.overview!.transactions.length, 20);
          expect(
            await restart.addExpense(
              title: 'Same clock after restart',
              amount: '1.00',
            ),
            isTrue,
          );
          expect(restart.overview!.transactions.length, 21);
        },
      );
    },
    skip: libraryPath == null
        ? 'set RUST_LIB_PATH to the rebuilt native bridge'
        : false,
  );
}
