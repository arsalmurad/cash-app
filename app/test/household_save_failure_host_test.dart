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

class _FaultRelay implements RelayClient {
  final inner = MemoryRelayClient();
  String? failure;
  @override
  Future<int> append(String group, int expectedTail, Uint8List blob) async {
    final sequence = await inner.append(group, expectedTail, blob);
    if (failure == 'append-reply') {
      failure = null;
      throw const RelayUnavailable('append reply lost');
    }
    return sequence;
  }

  @override
  Future<List<RelayLogEntry>> readAfter(String group, int after) =>
      inner.readAfter(group, after);
  @override
  Future<void> putMailbox(
    String mailbox,
    String group,
    int joinedAfter,
    Uint8List welcome,
  ) async {
    if (failure == 'mailbox-before') {
      failure = null;
      throw const RelayUnavailable('mailbox unavailable');
    }
    await inner.putMailbox(mailbox, group, joinedAfter, welcome);
    if (failure == 'mailbox-reply') {
      failure = null;
      throw const RelayUnavailable('mailbox reply lost');
    }
  }

  @override
  Future<RelayMailboxItem?> takeMailbox(String mailbox) =>
      inner.takeMailbox(mailbox);

  @override
  Future<RelayMailboxItem?> peekMailbox(String mailbox) async {
    final item = await inner.peekMailbox(mailbox);
    if (failure == 'peek-reply') {
      failure = null;
      throw const RelayUnavailable('welcome reply lost');
    }
    return item;
  }

  @override
  Future<void> acknowledgeMailbox(String mailbox) async {
    await inner.acknowledgeMailbox(mailbox);
    if (failure == 'ack-reply') {
      failure = null;
      throw const RelayUnavailable('acknowledgement reply lost');
    }
  }
}

void main() {
  final libraryPath = Platform.environment['RUST_LIB_PATH'];
  group(
    'household save safety through the real bridge',
    () {
      setUpAll(() async {
        await RustLib.init(externalLibrary: ExternalLibrary.open(libraryPath!));
      });

      for (final failure in [
        'append-reply',
        'mailbox-before',
        'mailbox-reply',
      ]) {
        test('invitation resumes after $failure and restart', () async {
          final relay = _FaultRelay();
          final state = _Store();
          final config = _Store();
          HouseholdController alice() => HouseholdController(
            stateStore: state,
            configStore: config,
            relayFactory: (_) => relay,
          );
          final first = alice();
          await first.initialize();
          await first.setRelayUrl('https://relay.test');
          expect(await first.createHousehold(), isTrue);
          final bob = HouseholdController(
            stateStore: _Store(),
            configStore: _Store(),
            relayFactory: (_) => relay,
          );
          await bob.initialize();
          final request = (await bob.prepareJoinRequest())!;
          relay.failure = failure;
          expect(await first.invite(request), isNull);
          expect(first.hasPendingInvitation, isTrue);
          final restarted = alice();
          await restarted.initialize();
          expect(restarted.hasPendingInvitation, isTrue);
          final code = await restarted.resumeInvitation();
          expect(code, isNotNull);
          expect(restarted.hasPendingInvitation, isFalse);
          expect(restarted.overview!.memberIds.length, 2);
          expect(await bob.acceptInvite(code!), isTrue);
          expect(
            await restarted.addExpense(
              title: 'Recovered invitation',
              amount: '5.00',
            ),
            isTrue,
          );
          expect(await bob.syncNow(), isTrue);
          expect(bob.overview!.balanceLabel, restarted.overview!.balanceLabel);
          final afterDelivery = alice();
          await afterDelivery.initialize();
          expect(afterDelivery.lastInviteCode, code);
          expect(
            await afterDelivery.invite(request),
            code,
            reason: 'same request does not add a duplicate member',
          );
        });
      }

      test(
        'a sealed backup retains pending delivery and its relay address',
        () async {
          final relay = _FaultRelay();
          final original = HouseholdController(
            stateStore: _Store(),
            configStore: _Store(),
            relayFactory: (_) => relay,
          );
          await original.initialize();
          await original.setRelayUrl('https://relay.test');
          await original.createHousehold();
          final bob = HouseholdController(
            stateStore: _Store(),
            configStore: _Store(),
            relayFactory: (_) => relay,
          );
          await bob.initialize();
          final request = (await bob.prepareJoinRequest())!;
          relay.failure = 'mailbox-before';
          expect(await original.invite(request), isNull);
          final backup = (await original.createBackup())!;
          final replacement = HouseholdController(
            stateStore: _Store(),
            configStore: _Store(),
            relayFactory: (_) => relay,
          );
          await replacement.initialize();
          expect(
            await replacement.restoreBackup(backup.phrase, backup.backup),
            isTrue,
          );
          expect(replacement.relayUrl, 'https://relay.test');
          expect(replacement.lastInviteCode, isNotNull);
          expect(await bob.acceptInvite(replacement.lastInviteCode!), isTrue);
        },
      );

      test(
        'removal with a lost acknowledgement resumes after restart',
        () async {
          final relay = _FaultRelay();
          final state = _Store();
          final config = _Store();
          HouseholdController alice() => HouseholdController(
            stateStore: state,
            configStore: config,
            relayFactory: (_) => relay,
          );
          final first = alice();
          await first.initialize();
          await first.setRelayUrl('https://relay.test');
          await first.createHousehold();
          final bob = HouseholdController(
            stateStore: _Store(),
            configStore: _Store(),
            relayFactory: (_) => relay,
          );
          await bob.initialize();
          final code = (await first.invite((await bob.prepareJoinRequest())!))!;
          await bob.acceptInvite(code);
          relay.failure = 'append-reply';
          expect(await first.removeMember(bob.overview!.memberId), isFalse);
          final restart = alice();
          await restart.initialize();
          expect(await restart.syncNow(), isTrue);
          expect(restart.overview!.memberIds.length, 1);
          expect(
            await restart.addExpense(title: 'After removal', amount: '7.00'),
            isTrue,
          );
          await bob.syncNow();
          expect(bob.isMember, isFalse);
          expect(bob.overview!.transactions, isEmpty);
        },
      );

      test(
        'corrupt local state stays locked but a verified backup can recover it',
        () async {
          final relay = _FaultRelay();
          final original = HouseholdController(
            stateStore: _Store(),
            configStore: _Store(),
            relayFactory: (_) => relay,
          );
          await original.initialize();
          await original.setRelayUrl('https://relay.test');
          await original.createHousehold();
          final backup = (await original.createBackup())!;
          final broken = _Store()..value = Uint8List.fromList([1, 2, 3]);
          final replacement = HouseholdController(
            stateStore: broken,
            configStore: _Store(),
            relayFactory: (_) => relay,
          );
          await replacement.initialize();
          expect(await replacement.createHousehold(), isFalse);
          expect(
            await replacement.restoreBackup('wrong phrase', backup.backup),
            isFalse,
          );
          expect(await replacement.createHousehold(), isFalse);
          expect(
            await replacement.restoreBackup(backup.phrase, backup.backup),
            isTrue,
          );
          expect(
            await replacement.addExpense(title: 'Recovered', amount: '1.00'),
            isTrue,
          );
        },
      );

      for (final failure in [
        'peek-reply',
        'ack-reply',
        'join-save',
        'join-save-full',
      ]) {
        test('welcome survives $failure and receiver restart', () async {
          final relay = _FaultRelay();
          final alice = HouseholdController(
            stateStore: _Store(),
            configStore: _Store(),
            relayFactory: (_) => relay,
          );
          await alice.initialize();
          await alice.setRelayUrl('https://relay.test');
          await alice.createHousehold();
          final state = _Store();
          final config = _Store();
          HouseholdController bob() => HouseholdController(
            stateStore: state,
            configStore: config,
            relayFactory: (_) => relay,
          );
          final first = bob();
          await first.initialize();
          final code = (await alice.invite(
            (await first.prepareJoinRequest())!,
          ))!;
          if (failure.startsWith('join-save')) {
            state
              ..fail = true
              ..saveBeforeFailure = failure.endsWith('full');
          } else {
            relay.failure = failure;
          }
          expect(await first.acceptInvite(code), isFalse);
          state.fail = false;
          final restart = bob();
          await restart.initialize();
          if (restart.isMember) {
            expect(await restart.syncNow(), isTrue);
          } else {
            expect(await restart.acceptInvite(code), isTrue);
          }
          expect(restart.isMember, isTrue);
          expect(
            await alice.addExpense(
              title: 'After recovered join',
              amount: '8.00',
            ),
            isTrue,
          );
          expect(await restart.syncNow(), isTrue);
          expect(restart.overview!.balanceLabel, alice.overview!.balanceLabel);
        });
      }

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
