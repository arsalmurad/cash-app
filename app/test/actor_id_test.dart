import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/data/storage/actor_id.dart';

void main() {
  test('generated actor IDs are 128-bit hex and effectively unique', () {
    final ids = List.generate(100, (_) => generateActorId());

    for (final id in ids) {
      expect(id.length, 32);
      expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(id), isTrue);
    }
    expect(ids.toSet().length, ids.length);
  });
}
