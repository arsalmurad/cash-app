import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:private_ledger/data/storage/event_store_io.dart';

class _FakePathProviderPlatform extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProviderPlatform(this.supportPath);

  final String supportPath;

  @override
  Future<String?> getApplicationSupportPath() async => supportPath;
}

void main() {
  late Directory sandbox;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('event_store_io_test');
    PathProviderPlatform.instance = _FakePathProviderPlatform(sandbox.path);
  });

  tearDown(() async {
    if (await sandbox.exists()) {
      await sandbox.delete(recursive: true);
    }
  });

  test('a fresh installation has no persisted log or actor ID', () async {
    final store = IoEventStore('ledger');
    expect(await store.readLog(), isEmpty);
    expect(await IoDeviceIdentity().readActorId(), isNull);
  });

  test(
    'appended frames accumulate in order and survive a new instance',
    () async {
      final store = IoEventStore('ledger');
      await store.appendFrame(Uint8List.fromList([1, 2, 3]));
      await store.appendFrame(Uint8List.fromList([4, 5]));

      // A fresh `IoEventStore` (simulating an app restart) must see exactly
      // what was durably appended, in order.
      final restarted = IoEventStore('ledger');
      expect(await restarted.readLog(), Uint8List.fromList([1, 2, 3, 4, 5]));
    },
  );

  test('logs with different names do not collide', () async {
    final ledgerStore = IoEventStore('ledger');
    final categoryStore = IoEventStore('categories');
    await ledgerStore.appendFrame(Uint8List.fromList([1, 2, 3]));
    await categoryStore.appendFrame(Uint8List.fromList([9, 9]));

    expect(await ledgerStore.readLog(), Uint8List.fromList([1, 2, 3]));
    expect(await categoryStore.readLog(), Uint8List.fromList([9, 9]));
  });

  test('the actor ID persists across a simulated restart', () async {
    await IoDeviceIdentity().writeActorId('device-abc123');

    final restarted = IoDeviceIdentity();
    expect(await restarted.readActorId(), 'device-abc123');
  });

  test(
    'recovery archives the original and keeps new appends readable',
    () async {
      final store = IoEventStore('ledger');
      await store.appendFrame(Uint8List.fromList([1, 2, 3, 9, 9]));
      await store.recoverPrefix(3, expectedLength: 5);
      await store.appendFrame(Uint8List.fromList([4, 5]));
      expect(await IoEventStore('ledger').readLog(), [1, 2, 3, 4, 5]);
      final backups = sandbox
          .listSync()
          .whereType<File>()
          .where((file) => file.path.contains('.recovery-'))
          .toList();
      expect(backups, hasLength(1));
      expect(await backups.single.readAsBytes(), [1, 2, 3, 9, 9]);
    },
  );

  test('recovery never extends a log or discards a changed log', () async {
    final store = IoEventStore('ledger');
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
    expect(sandbox.listSync(), hasLength(1));
  });
}
