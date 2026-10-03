import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/data/rust/api/shared.dart';
import 'package:private_ledger/data/rust/frb_generated.dart';

String _hex(Uint8List bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

void main() {
  final library = Platform.environment['RUST_LIB_PATH'];
  test(
    'native bridge returns exact public staged roster without archive writes',
    () async {
      await RustLib.init(externalLibrary: ExternalLibrary.open(library!));
      final alice = await householdNew(
        memberId: 'private-alice',
        reportingCurrencyCode: 'USD',
      );
      final bob = await householdNew(
        memberId: 'private-bob',
        reportingCurrencyCode: 'USD',
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      final initial = await householdExport(household: alice);
      await expectLater(
        householdRelayRosterKeys(household: alice),
        throwsA('no active household for relay permissions'),
      );
      expect(await householdExport(household: alice), initial);
      final group = await householdFound(household: alice);
      final own = (await householdRelayRosterKeys(household: alice))
          .map(_hex)
          .toList();
      expect(own, hasLength(1));
      final invitation = await householdBeginInvite(
        household: alice,
        keyPackage: await householdKeyPackage(household: bob),
      );
      final saved = await householdExport(household: alice);
      final keys = await householdRelayRosterKeys(household: alice);
      final expected = keys.map(_hex).toList();
      expect(keys, hasLength(2));
      expect(keys.every((key) => key.length == 32), isTrue);
      expect(expected, orderedEquals([...expected]..sort()));
      expect(expected.toSet(), hasLength(2));
      expect(expected, contains(own.single));
      expect((await householdOverview(household: alice)).memberIds, [
        'private-alice',
      ]);
      expect(await householdExport(household: alice), saved);
      keys.first[0] ^= 1;
      expect(
        (await householdRelayRosterKeys(household: alice)).map(_hex),
        expected,
      );
      expect(await householdExport(household: alice), saved);
      final restored = await householdRestore(saved: saved);
      addTearDown(restored.dispose);
      expect(
        (await householdRelayRosterKeys(household: restored)).map(_hex),
        expected,
      );
      expect(await householdExport(household: restored), saved);
      await householdCommitRejected(household: restored);
      expect(
        (await householdRelayRosterKeys(household: restored)).map(_hex),
        own,
      );
      await householdCommitAccepted(
        household: alice,
        sequence: PlatformInt64Util.from(1),
      );
      await householdJoin(
        household: bob,
        groupId: group,
        welcome: invitation.welcome,
        joinedAfter: PlatformInt64Util.from(1),
      );
      expect(
        (await householdRelayRosterKeys(household: bob)).map(_hex),
        expected,
      );
      await householdBeginRemoval(household: alice, memberId: 'private-bob');
      final removed = await householdExport(household: alice);
      expect((await householdRelayRosterKeys(household: alice)).map(_hex), own);
      expect(await householdExport(household: alice), removed);
    },
    skip: library == null ? 'Requires the rebuilt native bridge' : false,
  );
}
