import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/features/household/retention_codes.dart';

void main() {
  test(
    'request and approval codes preserve bounded binary bytes and wrapping',
    () {
      final bytes = Uint8List.fromList(List.generate(1024, (i) => i % 256));
      final request = encodeRetentionRequest(bytes),
          approval = encodeRetentionConsent(bytes);
      expect(decodeRetentionRequest(' \n$request\n '), bytes);
      expect(decodeRetentionConsent(approval), bytes);
      expect(() => decodeRetentionRequest(approval), throwsFormatException);
      expect(() => decodeRetentionConsent(request), throwsFormatException);
    },
  );
  test(
    'empty, oversized, malformed and unrelated clipboard text is refused',
    () {
      for (final bytes in [Uint8List(0), Uint8List(1025)]) {
        expect(() => encodeRetentionRequest(bytes), throwsFormatException);
        expect(() => encodeRetentionConsent(bytes), throwsFormatException);
      }
      for (final code in [
        'cashretreq1:',
        'cashretreq1:!',
        'cashretreq1:A',
        'cashinv1:AQ',
        'cashretreq1:${'A' * 5000}',
      ]) {
        expect(() => decodeRetentionRequest(code), throwsFormatException);
      }
    },
  );
}
