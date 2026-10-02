import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/data/storage/blob_store.dart';
import 'package:private_ledger/features/household/household_controller.dart';
import 'package:private_ledger/features/household/relay_client.dart';

class _MemoryStore implements BlobStore {
  Uint8List? value;
  @override
  Future<Uint8List?> read() async => value;
  @override
  Future<void> write(Uint8List bytes) async =>
      value = Uint8List.fromList(bytes);
  @override
  Future<void> delete() async => value = null;
}

/// Exceptions surround the real delegate; afterCommit really writes the sealed
/// native SQLite document before withholding the success acknowledgement.
class _FaultStore implements BlobStore {
  _FaultStore(this.inner);
  final BlobStore inner;
  bool fail = false;
  bool afterCommit = false;
  int? failAfter;
  Completer<void>? entered;
  Completer<void>? release;
  @override
  Future<Uint8List?> read() => inner.read();
  @override
  Future<void> write(Uint8List bytes) async {
    if (failAfter != null) {
      failAfter = failAfter! - 1;
      if (failAfter == 0) fail = true;
    }
    if (fail) {
      if (entered != null && !entered!.isCompleted) entered!.complete();
      await release?.future;
      if (afterCommit) await inner.write(bytes);
      throw StateError('Synthetic unconfirmed household save');
    }
    await inner.write(bytes);
  }

  @override
  Future<void> delete() => inner.delete();
}

class _FaultRelay implements RelayClient {
  final inner = MemoryRelayClient();
  String? failure;
  @override
  Future<int> append(String group, int tail, Uint8List blob) async {
    final sequence = await inner.append(group, tail, blob);
    if (failure == 'append-reply') {
      failure = null;
      throw const RelayUnavailable('Synthetic lost append reply');
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
  ) => inner.putMailbox(mailbox, group, joinedAfter, welcome);
  @override
  Future<RelayMailboxItem?> takeMailbox(String mailbox) =>
      inner.takeMailbox(mailbox);
  @override
  Future<RelayMailboxItem?> peekMailbox(String mailbox) =>
      inner.peekMailbox(mailbox);
  @override
  Future<void> acknowledgeMailbox(String mailbox) async {
    await inner.acknowledgeMailbox(mailbox);
    if (failure == 'ack-reply') {
      failure = null;
      throw const RelayUnavailable('Synthetic lost mailbox acknowledgement');
    }
  }
}

/// The same recovery assertions run against memory on the host and actual
/// sealed SQLite + OS keys in native integration. This is controlled exception
/// injection and two logical peers, not a power-loss or physical-network test.
Future<void> runHouseholdFailureScenario({
  BlobStore Function(String scope)? stateFactory,
  BlobStore Function(String scope)? configFactory,
}) async {
  final memory = <String, _MemoryStore>{};
  final controllers = <HouseholdController>[];
  BlobStore state(String scope) =>
      stateFactory?.call(scope) ?? memory.putIfAbsent(scope, _MemoryStore.new);
  BlobStore config(String scope) =>
      configFactory?.call(scope) ??
      memory.putIfAbsent('$scope-config', _MemoryStore.new);
  HouseholdController device(
    String scope,
    RelayClient relay, {
    _FaultStore? fault,
  }) {
    final controller = HouseholdController(
      stateStore: fault ?? state(scope),
      configStore: config(scope),
      relayFactory: (_) => relay,
    );
    controllers.add(controller);
    return controller;
  }

  Future<void> owner(HouseholdController controller) async {
    await controller.initialize();
    expect(controller.errorMessage, isNull);
    expect(await controller.setRelayUrl('https://relay.test'), isTrue);
    expect(await controller.createHousehold(), isTrue);
  }

  try {
    for (final saved in [false, true]) {
      final scope = 'uncertain-$saved';
      final relay = _FaultRelay();
      final fault = _FaultStore(state(scope));
      final first = device(scope, relay, fault: fault);
      await owner(first);
      final group = first.overview!.groupId!;
      final before = await relay.readAfter(group, 0);
      fault
        ..fail = true
        ..afterCommit = saved
        ..entered = Completer<void>()
        ..release = Completer<void>();
      final uncertain = first.addExpense(title: 'Unconfirmed', amount: '1');
      await fault.entered!.future;
      final queued = first.addExpense(title: 'Must not save', amount: '2');
      fault.release!.complete();
      expect(await uncertain, isFalse);
      expect(await queued, isFalse);
      expect(
        await first.addExpense(title: 'Still stopped', amount: '3'),
        isFalse,
      );
      expect(first.overview!.transactions, isEmpty);
      expect(
        (await relay.readAfter(group, 0)).length,
        before.length,
        reason: 'Unconfirmed local saves cannot publish ciphertext',
      );
      final restarted = device(scope, relay);
      await restarted.initialize();
      expect(restarted.errorMessage, isNull);
      expect(restarted.overview!.transactions.length, saved ? 1 : 0);
      expect(await restarted.syncNow(), isTrue);
      expect(
        (await relay.readAfter(group, 0)).length,
        before.length + (saved ? 1 : 0),
      );
      expect(
        await restarted.addExpense(title: 'After restart', amount: '4'),
        isTrue,
      );
      expect(restarted.overview!.transactions.length, saved ? 2 : 1);
    }

    for (final saved in [false, true]) {
      final scope = 'ratchet-$saved';
      final relay = _FaultRelay();
      final fault = _FaultStore(state(scope));
      final first = device(scope, relay, fault: fault);
      await owner(first);
      final group = first.overview!.groupId!;
      final before = await relay.readAfter(group, 0);
      fault
        ..failAfter = 2
        ..afterCommit = saved;
      expect(
        await first.addExpense(title: 'Queued ratchet', amount: '1'),
        isFalse,
      );
      expect((await relay.readAfter(group, 0)).length, before.length);
      final restarted = device(scope, relay);
      await restarted.initialize();
      expect(restarted.errorMessage, isNull);
      expect(restarted.overview!.transactions.single.title, 'Queued ratchet');
      expect(await restarted.syncNow(), isTrue);
      expect((await relay.readAfter(group, 0)).length, before.length + 1);
      expect(await restarted.syncNow(), isTrue);
      expect(
        (await relay.readAfter(group, 0)).length,
        before.length + 1,
        reason: 'Retry must publish the retained event exactly once',
      );
    }

    {
      final relay = _FaultRelay();
      final alice = device('lost-commit-owner', relay);
      await owner(alice);
      final bob = device('lost-commit-joiner', relay);
      await bob.initialize();
      final request = (await bob.prepareJoinRequest())!;
      relay.failure = 'append-reply';
      expect(await alice.invite(request), isNull);
      expect(alice.hasPendingInvitation, isTrue);
      final restarted = device('lost-commit-owner', relay);
      await restarted.initialize();
      expect(restarted.hasPendingInvitation, isTrue);
      final code = await restarted.resumeInvitation();
      expect(code, isNotNull);
      expect(restarted.overview!.memberIds, hasLength(2));
      expect(await bob.acceptInvite(code!), isTrue);
      expect(
        await restarted.addExpense(
          title: 'After interrupted invite',
          amount: '5',
        ),
        isTrue,
      );
      expect(await bob.syncNow(), isTrue);
      expect(bob.overview!.balanceLabel, 'USD -5.00');
      final afterDelivery = device('lost-commit-owner', relay);
      await afterDelivery.initialize();
      expect(await afterDelivery.invite(request), code);
      expect(afterDelivery.overview!.memberIds, hasLength(2));
      final removedId = bob.overview!.memberId;
      relay.failure = 'append-reply';
      expect(await afterDelivery.removeMember(removedId), isFalse);
      final afterRemoval = device('lost-commit-owner', relay);
      await afterRemoval.initialize();
      expect(await afterRemoval.syncNow(), isTrue);
      expect(afterRemoval.overview!.memberIds, hasLength(1));
      expect(
        await afterRemoval.addExpense(
          title: 'After recovered removal',
          amount: '7',
        ),
        isTrue,
      );
      expect(await bob.syncNow(), isTrue);
      expect(bob.isMember, isFalse);
      expect(bob.overview!.transactions, hasLength(1));
      expect(
        bob.overview!.balanceLabel,
        'USD -5.00',
        reason: 'Removed peer cannot read the next-epoch expense',
      );
    }

    for (final failure in ['join-before', 'join-after', 'ack-reply']) {
      final relay = _FaultRelay();
      final alice = device('$failure-owner', relay);
      await owner(alice);
      final scope = '$failure-joiner';
      final fault = _FaultStore(state(scope));
      final first = device(scope, relay, fault: fault);
      await first.initialize();
      final code = (await alice.invite((await first.prepareJoinRequest())!))!;
      if (failure == 'ack-reply') {
        relay.failure = failure;
      } else {
        fault
          ..fail = true
          ..afterCommit = failure == 'join-after';
      }
      expect(await first.acceptInvite(code), isFalse);
      final restarted = device(scope, relay);
      await restarted.initialize();
      expect(restarted.errorMessage, isNull);
      if (restarted.isMember) {
        expect(await restarted.syncNow(), isTrue);
      } else {
        expect(await restarted.acceptInvite(code), isTrue);
      }
      expect(restarted.isMember, isTrue);
      expect(
        await alice.addExpense(title: 'After receiver recovery', amount: '8'),
        isTrue,
      );
      expect(await restarted.syncNow(), isTrue);
      expect(restarted.overview!.balanceLabel, 'USD -8.00');
      expect(restarted.overview!.transactions, hasLength(1));
    }
  } finally {
    for (final controller in controllers) {
      controller.dispose();
    }
  }
}
