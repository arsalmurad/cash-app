import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/features/household/household_journal.dart';
import 'package:private_ledger/features/household/invite_codes.dart';

void main() {
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
    );
    final journal = HouseholdJournal(
      state: Uint8List.fromList([1]),
      relayUrl: 'https://relay.test',
      pending: pending,
      lastCode: 'previous',
      lastRequest: 'request',
      pendingAck: 'fedcba9876543210fedcba9876543210',
      recoveryState: Uint8List.fromList([5, 6]),
    );
    final restored = HouseholdJournal.decode(journal.encode());
    expect(restored.encode(), journal.encode());
    expect(restored.pending!.committed, isTrue);
    expect(restored.pending!.expired, isFalse);
    expect(restored.pending!.code, pending.code);
    expect(restored.recoveryState, [5, 6]);
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
