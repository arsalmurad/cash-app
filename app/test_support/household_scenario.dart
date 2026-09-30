import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/data/rust/api/shared.dart'
    show recoveryGeneratePhrase;
import 'package:private_ledger/data/storage/blob_store.dart';
import 'package:private_ledger/features/household/household_controller.dart';
import 'package:private_ledger/features/household/relay_client.dart';

/// Keeps "saved" state in memory so a simulated restart can reload it.
class _MemoryBlobStore implements BlobStore {
  Uint8List? value;

  @override
  Future<Uint8List?> read() async => value;

  @override
  Future<void> write(Uint8List newValue) async => value = newValue;

  @override
  Future<void> delete() async => value = null;
}

/// A relay that can be cut off for one device, to make it write "offline".
class _SwitchableRelay implements RelayClient {
  _SwitchableRelay(this._inner);

  final RelayClient _inner;
  bool online = true;

  T _guard<T>(T Function() call) {
    if (!online) {
      throw const RelayUnavailable('offline');
    }
    return call();
  }

  @override
  Future<int> append(String group, int expectedTail, Uint8List blob) =>
      _guard(() => _inner.append(group, expectedTail, blob));

  @override
  Future<List<RelayLogEntry>> readAfter(String group, int after) =>
      _guard(() => _inner.readAfter(group, after));

  @override
  Future<void> putMailbox(
    String mailbox,
    String group,
    int joinedAfter,
    Uint8List welcome,
  ) => _guard(() => _inner.putMailbox(mailbox, group, joinedAfter, welcome));

  @override
  Future<RelayMailboxItem?> takeMailbox(String mailbox) =>
      _guard(() => _inner.takeMailbox(mailbox));
}

class _Device {
  _Device(this.name, this.relay)
    : state = _MemoryBlobStore(),
      config = _MemoryBlobStore() {
    controller = _controller();
  }

  final String name;
  final _SwitchableRelay relay;
  final _MemoryBlobStore state;
  final _MemoryBlobStore config;
  late HouseholdController controller;
  int _clock = 1000;

  HouseholdController _controller() => HouseholdController(
    stateStore: state,
    configStore: config,
    relayFactory: (_) => relay,
    clockMillis: () => _clock += 1,
    newMemberId: () => name,
  );

  /// The app is killed and relaunched from nothing but its saved state.
  Future<void> restart() async {
    controller = _controller();
    await controller.initialize();
  }
}

/// The whole two-device household scenario. `RustLib` must already be
/// initialised (it refuses to initialise twice in one process).
Future<void> runHouseholdScenario() async {
  final relayStore = MemoryRelayClient();
  final alice = _Device(
    'aaaa0000aaaa0000aaaa0000aaaa0000',
    _SwitchableRelay(relayStore),
  );
  final bob = _Device(
    'bbbb1111bbbb1111bbbb1111bbbb1111',
    _SwitchableRelay(relayStore),
  );
  await alice.controller.initialize();
  await bob.controller.initialize();

  // Found, invite, and join through the same text codes people paste.
  expect(await alice.controller.setRelayUrl('https://relay.test'), isTrue);
  expect(await alice.controller.createHousehold(), isTrue);
  final request = await bob.controller.prepareJoinRequest();
  expect(request, startsWith('cashkp1:'));
  final invite = await alice.controller.invite(request!);
  expect(invite, startsWith('cashinv1:'));
  expect(await bob.controller.acceptInvite(invite!), isTrue);
  expect(bob.controller.isMember, isTrue);
  expect(bob.controller.relayUrl, 'https://relay.test');
  // An invite works exactly once.
  expect(await bob.controller.acceptInvite(invite), isFalse);

  // A shared expense crosses the relay as ciphertext and folds the same.
  expect(
    await alice.controller.addExpense(title: 'Dinner', amount: '40.00'),
    isTrue,
  );
  expect(await bob.controller.syncNow(), isTrue);
  var overview = bob.controller.overview!;
  expect(overview.balanceLabel, 'USD -40.00');
  expect(overview.transactions.single.title, 'Dinner');
  expect(overview.memberIds.length, 2);
  final dinner = overview.transactions.single.id;

  // Bob edits while offline; Alice edits the same expense meanwhile.
  bob.relay.online = false;
  expect(await bob.controller.adjustAmount(dinner, '42.00'), isFalse);
  expect(bob.controller.overview!.pendingCount.toInt(), 1);
  expect(await alice.controller.adjustAmount(dinner, '45.00'), isTrue);
  bob.relay.online = true;
  expect(await bob.controller.syncNow(), isTrue);
  expect(await alice.controller.syncNow(), isTrue);

  // Both edits stay visible as a conflict, and both devices agree.
  for (final device in [alice, bob]) {
    final view = device.controller.overview!;
    expect(view.conflicts.length, 1, reason: device.name);
    expect(view.transactions.single.conflicted, isTrue);
    expect(view.pendingCount.toInt(), 0);
  }
  expect(
    alice.controller.overview!.balanceLabel,
    bob.controller.overview!.balanceLabel,
  );

  // Bob's app is killed and relaunched; nothing is lost.
  final before = bob.controller.overview!.balanceLabel;
  await bob.restart();
  expect(bob.controller.isMember, isTrue);
  expect(bob.controller.overview!.balanceLabel, before);
  expect(
    await alice.controller.addExpense(title: 'Coffee', amount: '4.50'),
    isTrue,
  );
  expect(await bob.controller.syncNow(), isTrue);
  expect(bob.controller.overview!.transactions.length, 2);

  // Safety numbers agree, so neither side was handed a substituted key.
  final fromAlice = await alice.controller.safetyNumberWith(bob.name);
  final fromBob = await bob.controller.safetyNumberWith(alice.name);
  expect(fromAlice, isNotNull);
  expect(fromAlice, fromBob);

  // A lost phone: Bob's state, sealed under a written-down phrase, restores
  // on a replacement device; a wrong phrase restores nothing.
  final backup = await bob.controller.createBackup();
  expect(backup, isNotNull);
  expect(backup!.phrase.split(' ').length, 24);
  expect(backup.backup, startsWith('cashbk1:'));
  final replacement = _Device(bob.name, bob.relay);
  await replacement.controller.initialize();
  expect(
    await replacement.controller.restoreBackup(
      await recoveryGeneratePhrase(),
      backup.backup,
    ),
    isFalse,
  );
  expect(replacement.controller.isMember, isFalse);
  expect(
    await replacement.controller.restoreBackup(backup.phrase, backup.backup),
    isTrue,
  );
  expect(replacement.controller.isMember, isTrue);
  expect(
    replacement.controller.overview!.balanceLabel,
    bob.controller.overview!.balanceLabel,
  );

  // Removing Bob locks him out of everything written afterwards.
  expect(await alice.controller.removeMember(bob.name), isTrue);
  expect(await bob.controller.syncNow(), isTrue);
  expect(bob.controller.isMember, isFalse);
  final bobSees = bob.controller.overview!.transactions.length;
  expect(
    await alice.controller.addExpense(title: 'Private', amount: '9.99'),
    isTrue,
  );
  expect(await bob.controller.syncNow(), isTrue);
  expect(bob.controller.overview!.transactions.length, bobSees);
  expect(alice.controller.overview!.transactions.length, 3);
}
