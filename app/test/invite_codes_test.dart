import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/features/household/invite_codes.dart';

void main() {
  group('join request', () {
    test('round-trips a key package', () {
      final keyPackage = Uint8List.fromList(List.generate(300, (i) => i % 256));
      final code = encodeJoinRequest(keyPackage);
      expect(code, startsWith('cashkp1:'));
      expect(decodeJoinRequest(code), keyPackage);
    });

    test('forgives whitespace and line wrapping from copy and paste', () {
      final keyPackage = Uint8List.fromList(List.generate(100, (i) => i));
      final code = encodeJoinRequest(keyPackage);
      final wrapped = '  ${code.substring(0, 20)}\n${code.substring(20)}  ';
      expect(decodeJoinRequest(wrapped), keyPackage);
    });

    test('rejects the wrong kind of code, garbage, and empty input', () {
      expect(() => decodeJoinRequest(''), throwsFormatException);
      expect(() => decodeJoinRequest('hello'), throwsFormatException);
      expect(() => decodeJoinRequest('cashkp1:'), throwsFormatException);
      expect(() => decodeJoinRequest('cashkp1:!!!'), throwsFormatException);
      final invite = encodeInvite(
        const HouseholdInvite(
          relayUrl: 'https://relay.example',
          group: 'g',
          mailbox: 'm',
        ),
      );
      expect(() => decodeJoinRequest(invite), throwsFormatException);
    });
  });

  group('invite', () {
    const invite = HouseholdInvite(
      relayUrl: 'https://relay.example.workers.dev',
      group: '0123456789abcdef0123456789abcdef',
      mailbox: 'fedcba9876543210fedcba9876543210',
    );

    test('round-trips, carrying the relay address', () {
      final code = encodeInvite(invite);
      expect(code, startsWith('cashinv1:'));
      final decoded = decodeInvite(code);
      expect(decoded.relayUrl, invite.relayUrl);
      expect(decoded.group, invite.group);
      expect(decoded.mailbox, invite.mailbox);
    });

    test('rejects damaged, incomplete, and wrong-kind codes', () {
      expect(() => decodeInvite('cashinv1:'), throwsFormatException);
      expect(() => decodeInvite('cashinv1:AAAA'), throwsFormatException);
      expect(() => decodeInvite('nonsense'), throwsFormatException);
      expect(
        () => decodeInvite(encodeJoinRequest(Uint8List.fromList([1, 2, 3]))),
        throwsFormatException,
      );
    });

    test('rejects a relay address that is not http(s) or group ids that '
        'are not hex (a pasted invite must not steer the app elsewhere)', () {
      for (final bad in [
        const HouseholdInvite(relayUrl: 'file:///etc', group: 'a', mailbox: 'b'),
        const HouseholdInvite(
          relayUrl: 'https://relay.example',
          group: '../../etc',
          mailbox: 'b',
        ),
        const HouseholdInvite(
          relayUrl: 'https://relay.example',
          group: '0123456789abcdef0123456789abcdef',
          mailbox: 'not hex!',
        ),
      ]) {
        expect(() => decodeInvite(encodeInvite(bad)), throwsFormatException);
      }
    });
  });
}
