@TestOn('browser')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/data/storage/event_store_web.dart';
import 'package:web/web.dart' as web;

void main() {
  const key = 'private_ledger.recovery-test.v1';
  final storage = web.window.localStorage;

  void clearTestKeys() {
    final keys = [for (var i = 0; i < storage.length; i++) storage.key(i)]
        .whereType<String>()
        .where((item) => item == key || item.startsWith('$key.recovery-'));
    for (final item in keys) {
      storage.removeItem(item);
    }
  }

  setUp(clearTestKeys);
  tearDown(clearTestKeys);

  test(
    'recovery archives original bytes before retaining the valid prefix',
    () async {
      final store = WebEventStore('recovery-test');
      await store.appendFrame(Uint8List.fromList([1, 2, 3, 9, 9]));
      await store.recoverPrefix(3, expectedLength: 5);
      await store.appendFrame(Uint8List.fromList([4, 5]));
      expect(await WebEventStore('recovery-test').readLog(), [1, 2, 3, 4, 5]);
      final backups = [for (var i = 0; i < storage.length; i++) storage.key(i)]
          .whereType<String>()
          .where((item) => item.startsWith('$key.recovery-'))
          .toList();
      expect(backups, hasLength(1));
      expect(base64Decode(storage.getItem(backups.single)!), [1, 2, 3, 9, 9]);
    },
  );

  test(
    'invalid lengths and changed logs leave browser storage untouched',
    () async {
      final store = WebEventStore('recovery-test');
      await store.appendFrame(Uint8List.fromList([1, 2, 3]));
      await expectLater(
        store.recoverPrefix(-1, expectedLength: 3),
        throwsArgumentError,
      );
      await expectLater(
        store.recoverPrefix(4, expectedLength: 3),
        throwsArgumentError,
      );
      await expectLater(
        store.recoverPrefix(1, expectedLength: 2),
        throwsStateError,
      );
      expect(await store.readLog(), [1, 2, 3]);
    },
  );
}
