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
    final store = IoEventStore();
    expect(await store.readLog(), isEmpty);
    expect(await store.readActorId(), isNull);
  });

  test('appended frames accumulate in order and survive a new instance', () async {
    final store = IoEventStore();
    await store.appendFrame(Uint8List.fromList([1, 2, 3]));
    await store.appendFrame(Uint8List.fromList([4, 5]));

    // A fresh `IoEventStore` (simulating an app restart) must see exactly
    // what was durably appended, in order.
    final restarted = IoEventStore();
    expect(await restarted.readLog(), Uint8List.fromList([1, 2, 3, 4, 5]));
  });

  test('the actor ID persists across a simulated restart', () async {
    final store = IoEventStore();
    await store.writeActorId('device-abc123');

    final restarted = IoEventStore();
    expect(await restarted.readActorId(), 'device-abc123');
  });
}
