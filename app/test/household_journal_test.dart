import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/features/household/household_journal.dart';
import 'package:private_ledger/features/household/invite_codes.dart';
import 'package:private_ledger/features/household/relay_policy.dart';

void main() {
  test(
    'authenticated journal mode is strict and cannot downgrade scoped intent',
    () {
      final legacy = HouseholdJournal(state: Uint8List.fromList([1])).encode();
      expect(HouseholdJournal.decode(legacy).authenticatedRelay, isNull);
      final valid = HouseholdJournal(
        state: Uint8List.fromList([1]),
        relayUrl: 'https://relay.test',
        authenticatedRelay: true,
      ).encode();
      expect(HouseholdJournal.decode(valid).authenticatedRelay, isTrue);
      final encoded = utf8.decode(valid);
      for (final value in ['null', '1', '"true"']) {
        expect(
          () => HouseholdJournal.decode(
            Uint8List.fromList(
              utf8.encode(
                encoded.replaceFirst(
                  '"relayAuthenticated":true',
                  '"relayAuthenticated":$value',
                ),
              ),
            ),
          ),
          throwsFormatException,
        );
      }
      for (final relay in [
        null,
        'http://remote.test',
        'https://relay.test/path',
      ]) {
        expect(
          () => HouseholdJournal.decode(
            HouseholdJournal(
              state: Uint8List.fromList([1]),
              relayUrl: relay,
              authenticatedRelay: true,
            ).encode(),
          ),
          throwsFormatException,
        );
      }
      expect(
        () => HouseholdJournal.decode(
          HouseholdJournal(
            state: Uint8List.fromList([1]),
            relayUrl: 'https://relay.test',
            authenticatedRelay: false,
            pendingAckRoster: true,
            pendingAck: 'fedcba9876543210fedcba9876543210',
          ).encode(),
        ),
        throwsFormatException,
      );
    },
  );
  RelayAuthorizationPolicy policy() => RelayAuthorizationPolicy.fromJson(
    {
      'version': 2,
      'epoch': 1,
      'scope': {'origin': 'https://relay.test', 'kind': 'g', 'id': '01' * 16},
      'devices': [
        {
          'key': '02' * 32,
          'operations': ['append', 'membership', 'read'],
        },
      ],
    },
    origin: 'https://relay.test',
    group: '01' * 16,
  );

  test(
    'pending relay transition survives restart with immutable exact bytes',
    () {
      final bytes = Uint8List.fromList([1, 2, 255]);
      final pending = PendingRelayMembership(
        expectedTail: 5,
        commit: bytes,
        policy: policy(),
      );
      bytes[0] = 99;
      pending.commit[1] = 99;
      final journal = HouseholdJournal(
        state: Uint8List.fromList([3]),
        relayUrl: 'https://relay.test',
        membership: pending,
      );
      final restored = HouseholdJournal.decode(journal.encode());
      expect(restored.encode(), journal.encode());
      expect(restored.membership!.commit, [1, 2, 255]);
      expect(restored.membership!.expectedTail, 5);
      expect(restored.membership!.policy.toJson(), policy().toJson());
      expect(
        () => HouseholdJournal.decode(
          HouseholdJournal(
            state: journal.state,
            relayUrl: 'https://foreign.test',
            membership: pending,
          ).encode(),
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'invalid pending membership cannot silently fall back to ordinary append',
    () {
      final valid = PendingRelayMembership(
        expectedTail: 5,
        commit: Uint8List.fromList([1]),
        policy: policy(),
      ).toJson();
      for (final value in [
        null,
        {},
        {...valid, 'amount': 2050},
        {...valid, 'version': 1.0},
        {...valid, 'tail': -1},
        {...valid, 'tail': 9007199254740991},
        {...valid, 'commit': ''},
        {...valid, 'commit': '%%%'},
        {...valid, 'policy': {}},
        {
          ...valid,
          'policy': {...policy().toJson(), 'epoch': 0},
        },
      ]) {
        expect(
          () => PendingRelayMembership.fromJson(value),
          throwsFormatException,
        );
      }
      expect(
        () => PendingRelayMembership(
          expectedTail: 0,
          commit: Uint8List(256 * 1024 + 1),
          policy: policy(),
        ),
        throwsFormatException,
      );
      final encoded = utf8.decode(
        HouseholdJournal(
          state: Uint8List.fromList([3]),
          relayUrl: 'https://relay.test',
        ).encode(),
      );
      expect(
        () => HouseholdJournal.decode(
          Uint8List.fromList(
            utf8.encode(
              encoded.replaceFirst('"membership":null', '"membership":{}'),
            ),
          ),
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'v1 journals migrate and v2 records cannot be mistaken for raw state',
    () {
      final old = Uint8List.fromList(
        utf8.encode(
          'cash-app household journal v1\u0000{"state":"AQID","relay":null}',
        ),
      );
      final migrated = HouseholdJournal.decode(old);
      expect(migrated.state, [1, 2, 3]);
      expect(
        utf8.decode(migrated.encode()),
        startsWith('cash-app household journal v2\u0000'),
      );
    },
  );
  test('legacy Rust state is preserved without inventing relay metadata', () {
    final bytes = Uint8List.fromList([1, 2, 3]);
    final journal = HouseholdJournal.decode(bytes);
    expect(journal.state, bytes);
    expect(journal.pending, isNull);
    expect(journal.relayUrl, isNull);
  });
  test('pending delivery, keys, confirmation and last invite round trip', () {
    final pending = PendingInvitation(
      invite: const HouseholdInvite(
        relayUrl: 'https://relay.test',
        group: '0123456789abcdef0123456789abcdef',
        mailbox: 'fedcba9876543210fedcba9876543210',
      ),
      expectedTail: 5,
      commit: Uint8List.fromList([2]),
      welcome: Uint8List.fromList([3]),
      keyPackage: Uint8List.fromList([4]),
      createdMillis: DateTime.now().millisecondsSinceEpoch,
      committed: true,
      recipient: '02' * 32,
    );
    final journal = HouseholdJournal(
      state: Uint8List.fromList([1]),
      relayUrl: 'https://relay.test',
      pending: pending,
      lastCode: 'previous',
      lastRequest: 'request',
      pendingAck: 'fedcba9876543210fedcba9876543210',
      pendingAckRoster: true,
      recoveryState: Uint8List.fromList([5, 6]),
    );
    final restored = HouseholdJournal.decode(journal.encode());
    expect(restored.encode(), journal.encode());
    expect(restored.pending!.committed, isTrue);
    expect(restored.pending!.expired, isFalse);
    expect(restored.pending!.code, pending.code);
    expect(restored.pending!.recipient, '02' * 32);
    expect(restored.pendingAckRoster, isTrue);
    expect(restored.recoveryState, [5, 6]);
  });
  test('damaged acknowledgement mode and recipient binding fail closed', () {
    final encoded = utf8.decode(
      HouseholdJournal(state: Uint8List.fromList([1])).encode(),
    );
    for (final value in ['true', '"true"', '1']) {
      expect(
        () => HouseholdJournal.decode(
          Uint8List.fromList(
            utf8.encode(
              encoded.replaceFirst('"ackRoster":false', '"ackRoster":$value'),
            ),
          ),
        ),
        throwsFormatException,
      );
    }
    final valid = PendingInvitation(
      invite: const HouseholdInvite(
        relayUrl: 'https://relay.test',
        group: '0123456789abcdef0123456789abcdef',
        mailbox: 'fedcba9876543210fedcba9876543210',
      ),
      expectedTail: 1,
      commit: Uint8List.fromList([1]),
      welcome: Uint8List.fromList([2]),
      keyPackage: Uint8List.fromList([3]),
      createdMillis: 1,
    ).toJson();
    for (final recipient in ['bad', '${'02' * 32}\n', 2]) {
      expect(
        () => PendingInvitation.fromJson({...valid, 'recipient': recipient}),
        throwsA(anything),
      );
    }
    expect(PendingInvitation.fromJson(valid).recipient, isNull);
  });
  test('damaged journal fails closed rather than losing pending intent', () {
    final bytes = Uint8List.fromList(
      utf8.encode('cash-app household journal v1\u0000{"state":"%%%"}'),
    );
    expect(() => HouseholdJournal.decode(bytes), throwsFormatException);
  });
  test('unsafe persisted relay scheme is rejected', () {
    final journal = HouseholdJournal(
      state: Uint8List.fromList([1]),
      relayUrl: 'file:///secret',
    );
    expect(
      () => HouseholdJournal.decode(journal.encode()),
      throwsFormatException,
    );
  });
}
