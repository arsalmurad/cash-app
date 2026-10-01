import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/features/ledger/csv_files.dart';

void main() {
  test(
    'file decoding preserves Unicode across chunk boundaries and strips BOM',
    () async {
      final bytes = utf8.encode('\uFEFFtitle,amount\nچائے 🍵,4.50\n');
      final result = await decodeCsvStream(
        Stream.fromIterable([
          bytes.sublist(0, 2),
          bytes.sublist(2, 19),
          bytes.sublist(19),
        ]),
      );
      expect(result, 'title,amount\nچائے 🍵,4.50\n');
    },
  );
  test('oversized streams are stopped rather than truncated', () async {
    await expectLater(
      decodeCsvStream(
        Stream.fromIterable([
          [1, 2],
          [3, 4],
        ]),
        maxBytes: 3,
      ),
      throwsFormatException,
    );
  });
  test('invalid UTF-8 is reported without replacement characters', () async {
    await expectLater(
      decodeCsvStream(Stream.value([255])),
      throwsFormatException,
    );
  });
}
