// Real native MLS and protected journal, controlled relay failures. This does
// not prove real-worker Welcome/mailbox authorization or public bootstrap.
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/data/rust/frb_generated.dart';
import 'package:private_ledger/data/storage/blob_store.dart';
import 'package:private_ledger/features/household/household_controller.dart';
import 'package:private_ledger/features/household/household_journal.dart';
import 'package:private_ledger/features/household/relay_client.dart';
import 'package:private_ledger/features/household/relay_policy.dart';

class _Store implements BlobStore {
  Uint8List? value;
  bool fail = false;
  @override
  Future<Uint8List?> read() async => value;
  @override
  Future<void> write(Uint8List bytes) async {
    if (fail) throw const FileSystemException('uncertain save');
    value = Uint8List.fromList(bytes);
  }

  @override
  Future<void> delete() async => value = null;
}

class _RosterRelay extends MemoryRelayClient
    implements RosterWelcomeRelayClient {
  _RosterRelay(this.policy, this.store);
  RelayAuthorizationPolicy policy;
  final _Store store;
  String mode = 'success';
  bool failMailbox = false;
  Uint8List? competingEntry;
  final attempts = <PendingRelayMembership>[];
  @override
  bool get rosterEnabled => true;
  @override
  Future<RelayAuthorizationPolicy> readPolicy(String group) async => policy;
  @override
  Future<void> putRosterWelcome(
    String group,
    String mailbox,
    String recipient,
    int joinedAfter,
    Uint8List welcome,
  ) async {
    expect(policy.devices.map((device) => device.key), contains(recipient));
    final saved = HouseholdJournal.decode(store.value!).pending!;
    expect(saved.recipient, recipient);
    expect(saved.committed, isTrue);
    await putMailbox(mailbox, group, joinedAfter, welcome);
  }

  @override
  Future<RelayMailboxItem?> peekRosterWelcome(String group, String mailbox) =>
      peekMailbox(mailbox);
  @override
  Future<void> acknowledgeRosterWelcome(String group, String mailbox) =>
      acknowledgeMailbox(mailbox);
  @override
  Future<void> putMailbox(
    String mailbox,
    String group,
    int joinedAfter,
    Uint8List welcome,
  ) async {
    if (failMailbox) throw const RelayUnavailable('controlled mailbox failure');
    await super.putMailbox(mailbox, group, joinedAfter, welcome);
  }

  @override
  Future<int> appendMembership(
    String group,
    int expectedTail,
    Uint8List blob,
    RelayAuthorizationPolicy nextPolicy,
  ) async {
    final saved = HouseholdJournal.decode(store.value!).membership;
    expect(saved, isNotNull, reason: 'Exact intent must precede network I/O');
    expect(saved!.commit, blob);
    expect(saved.expectedTail, expectedTail);
    expect(saved.policy.toJson(), nextPolicy.toJson());
    attempts.add(saved);
    final competing = competingEntry;
    if (competing != null) {
      competingEntry = null;
      throw RelayConflict(await super.append(group, expectedTail, competing));
    }
    if (mode == 'offline') throw const RelayUnavailable('controlled offline');
    if (mode == 'policy') throw const RelayMembershipConflict();
    if (mode == 'capacity') throw const RelayCapacityReached();
    expect(nextPolicy.epoch, policy.epoch + 1);
    final sequence = await super.append(group, expectedTail, blob);
    policy = nextPolicy;
    if (mode == 'lost') throw const RelayUnavailable('controlled lost reply');
    return sequence;
  }
}

void main() {
  final library = Platform.environment['RUST_LIB_PATH'];
  group('durable native membership policy retries', () {
    setUpAll(
      () => RustLib.init(externalLibrary: ExternalLibrary.open(library!)),
    );
    test('lost invite commit and failed Welcome delivery resume without a second membership change', () async {
      final memory = MemoryRelayClient();
      final store = _Store();
      final config = _Store();
      final alice = HouseholdController(
        stateStore: store,
        configStore: config,
        relayFactory: (_) => memory,
      );
      final bob = HouseholdController(
        stateStore: _Store(),
        configStore: _Store(),
        relayFactory: (_) => memory,
      );
      addTearDown(bob.dispose);
      await alice.initialize();
      await bob.initialize();
      expect(await alice.setRelayUrl('https://relay.test'), isTrue);
      expect(await bob.setRelayUrl('https://relay.test'), isTrue);
      expect(await alice.createHousehold(), isTrue);
      final group = alice.overview!.groupId!;
      final request = (await bob.prepareJoinRequest())!;
      final root = RelayAuthorizationPolicy.fromJson(
        {
          'version': 2,
          'epoch': 0,
          'scope': {'origin': 'https://relay.test', 'kind': 'g', 'id': group},
          'devices': [
            for (final key in await alice.relayRosterKeys())
              {
                'key': key,
                'operations': ['append', 'membership', 'read'],
              },
          ],
        },
        origin: 'https://relay.test',
        group: group,
      );
      final relay = _RosterRelay(root, store);
      for (final entry in await memory.readAfter(group, 0)) {
        await relay.append(group, entry.sequence - 1, entry.blob);
      }
      alice.dispose();
      HouseholdController restore() => HouseholdController(
        stateStore: store,
        configStore: config,
        relayFactory: (_) => relay,
      );
      final first = restore();
      await first.initialize();
      relay.mode = 'lost';
      expect(await first.invite(request), isNull);
      final uncertain = HouseholdJournal.decode(store.value!);
      expect(uncertain.membership, isNotNull);
      expect(uncertain.pending!.committed, isFalse);
      final welcome = uncertain.pending!.welcome;
      first.dispose();
      final second = restore();
      await second.initialize();
      relay.mode = 'success';
      relay.failMailbox = true;
      expect(await second.syncNow(), isFalse);
      final committed = HouseholdJournal.decode(store.value!);
      expect(committed.membership, isNull);
      expect(committed.pending!.committed, isTrue);
      expect(committed.pending!.welcome, welcome);
      expect(relay.attempts, hasLength(1));
      second.dispose();
      final third = restore();
      addTearDown(third.dispose);
      await third.initialize();
      relay.failMailbox = false;
      final invite = await third.resumeInvitation();
      expect(invite, isNotNull);
      expect(HouseholdJournal.decode(store.value!).pending, isNull);
      expect(
        (await relay.peekMailbox(committed.pending!.invite.mailbox))!.welcome,
        welcome,
      );
      expect(relay.attempts, hasLength(1));
      expect(relay.policy.epoch, 1);
    });
    for (final rotation in [false, true]) {
      for (final mode in [
        'offline',
        'lost',
        'policy',
        'capacity',
        'save',
        'missing',
        'foreign',
        'exhausted',
        if (rotation) 'race',
      ]) {
        test(
          '${rotation ? 'rotation' : 'removal'} retains exact transition after $mode and resumes after restart',
          () async {
            final memory = MemoryRelayClient();
            final store = _Store();
            final config = _Store();
            final alice = HouseholdController(
              stateStore: store,
              configStore: config,
              relayFactory: (_) => memory,
            );
            final bob = HouseholdController(
              stateStore: _Store(),
              configStore: _Store(),
              relayFactory: (_) => memory,
            );
            addTearDown(bob.dispose);
            for (final device in [alice, bob]) {
              await device.initialize();
              expect(await device.setRelayUrl('https://relay.test'), isTrue);
            }
            expect(await alice.createHousehold(), isTrue);
            final invitation = await alice.invite(
              (await bob.prepareJoinRequest())!,
            );
            expect(await bob.acceptInvite(invitation!), isTrue);
            expect(await alice.syncNow(), isTrue);
            final group = alice.overview!.groupId!;
            final policy = RelayAuthorizationPolicy.fromJson(
              {
                'version': 2,
                'epoch': 0,
                'scope': {
                  'origin': 'https://relay.test',
                  'kind': 'g',
                  'id': group,
                },
                'devices': [
                  for (final key in await alice.relayRosterKeys())
                    {
                      'key': key,
                      'operations': ['append', 'membership', 'read'],
                    },
                ],
              },
              origin: 'https://relay.test',
              group: group,
            );
            final relay = _RosterRelay(policy, store);
            for (final entry in await memory.readAfter(group, 0)) {
              await relay.append(group, entry.sequence - 1, entry.blob);
            }
            alice.dispose();
            HouseholdController restore() => HouseholdController(
              stateStore: store,
              configStore: config,
              relayFactory: (_) => relay,
            );
            final first = restore();
            await first.initialize();
            final originalKeys = await first.relayRosterKeys();
            final originalMembers = List<String>.of(first.overview!.memberIds);
            relay.mode = mode == 'missing' ? 'offline' : mode;
            final bobId = bob.overview!.memberId;
            Future<bool> change(HouseholdController device) => rotation
                ? device.refreshEncryptionKeys()
                : device.removeMember(bobId);
            if (mode == 'race') {
              final before = first.overview!.cursor.toInt();
              expect(
                await bob.addExpense(
                  title: 'Competing expense',
                  amount: '1.25',
                ),
                isTrue,
              );
              relay.competingEntry = (await memory.readAfter(
                group,
                before,
              )).first.blob;
              expect(await change(first), isFalse);
              expect(first.errorMessage, contains('not confirmed'));
              expect(first.overview!.balanceLabel, 'USD -1.25');
              expect(first.overview!.memberIds, originalMembers);
              expect(relay.policy.epoch, 0);
              expect(HouseholdJournal.decode(store.value!).membership, isNull);
              expect(await change(first), isTrue);
              expect(relay.policy.epoch, 1);
              expect(first.overview!.balanceLabel, 'USD -1.25');
              first.dispose();
              return;
            }
            if (mode == 'foreign' || mode == 'exhausted') {
              final origin = mode == 'foreign'
                  ? 'https://foreign.test'
                  : policy.origin;
              relay.policy = RelayAuthorizationPolicy.fromJson(
                {
                  ...policy.toJson(),
                  'epoch': mode == 'exhausted'
                      ? RelayAuthorizationPolicy.maximumInteger
                      : 0,
                  'scope': {'origin': origin, 'kind': 'g', 'id': group},
                },
                origin: origin,
                group: group,
              );
              final saved = Uint8List.fromList(store.value!);
              expect(await change(first), isFalse);
              expect(relay.attempts, isEmpty);
              expect(store.value, saved);
              expect(first.overview!.memberIds, contains(bobId));
              first.dispose();
              return;
            }
            if (mode == 'save') store.fail = true;
            expect(await change(first), isFalse);
            if (mode == 'save') {
              expect(first.requiresRestart, isTrue);
              expect(relay.attempts, isEmpty);
              expect(HouseholdJournal.decode(store.value!).membership, isNull);
              first.dispose();
              store.fail = false;
              relay.mode = 'success';
              final restarted = restore();
              addTearDown(restarted.dispose);
              await restarted.initialize();
              expect(await change(restarted), isTrue);
              expect(relay.policy.epoch, 1);
              return;
            }
            final pending = HouseholdJournal.decode(store.value!).membership!;
            expect(first.overview!.memberIds, contains(bobId));
            expect(await first.setRelayUrl('https://foreign.test'), isFalse);
            expect(relay.attempts, hasLength(1));
            first.dispose();
            if (mode == 'missing') {
              final journal = HouseholdJournal.decode(store.value!);
              store.value = HouseholdJournal(
                state: journal.state,
                relayUrl: journal.relayUrl,
                pending: journal.pending,
                lastCode: journal.lastCode,
                lastRequest: journal.lastRequest,
                pendingAck: journal.pendingAck,
                recoveryState: journal.recoveryState,
              ).encode();
            }
            final restarted = restore();
            addTearDown(restarted.dispose);
            await restarted.initialize();
            relay.mode = 'success';
            if (mode == 'missing') {
              expect(await restarted.syncNow(), isFalse);
              expect(restarted.errorMessage, contains('saved membership'));
              expect(relay.attempts, hasLength(1));
              expect(
                await relay.readAfter(group, pending.expectedTail),
                isEmpty,
              );
              expect(relay.policy.epoch, 0);
              return;
            }
            expect(await restarted.syncNow(), isTrue);
            if (rotation) {
              expect(restarted.overview!.memberIds, originalMembers);
              expect(await restarted.relayRosterKeys(), originalKeys);
              expect(
                relay.policy.devices.map((device) => device.key),
                originalKeys,
              );
            } else {
              expect(restarted.overview!.memberIds, isNot(contains(bobId)));
            }
            expect(HouseholdJournal.decode(store.value!).membership, isNull);
            if (mode == 'lost') {
              expect(relay.attempts, hasLength(1));
            } else {
              expect(relay.attempts, hasLength(2));
              expect(relay.attempts.last.commit, pending.commit);
              expect(
                relay.attempts.last.policy.toJson(),
                pending.policy.toJson(),
              );
            }
            expect(relay.policy.epoch, 1);
            expect(
              (await relay.readAfter(
                group,
                pending.expectedTail,
              )).where((entry) => entry.sequence == pending.expectedTail + 1),
              hasLength(1),
            );
          },
        );
      }
    }
  }, skip: library == null ? 'Requires the rebuilt native bridge' : false);
}
