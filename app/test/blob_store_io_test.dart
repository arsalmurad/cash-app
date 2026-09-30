import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:private_ledger/data/storage/blob_store_io.dart';

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
    sandbox = await Directory.systemTemp.createTemp('blob_store_io_test');
    PathProviderPlatform.instance = _FakePathProviderPlatform(sandbox.path);
  });

  tearDown(() async {
    if (await sandbox.exists()) {
      await sandbox.delete(recursive: true);
    }
  });

  test('a fresh store reads null', () async {
    expect(await IoBlobStore('household').read(), isNull);
  });

  test('a write replaces the previous value and survives a new instance', () async {
    final store = IoBlobStore('household');
    await store.write(Uint8List.fromList([1, 2, 3]));
    await store.write(Uint8List.fromList([4, 5]));
    expect(await IoBlobStore('household').read(), [4, 5]);
  });

  test('names are isolated from each other', () async {
    await IoBlobStore('one').write(Uint8List.fromList([1]));
    await IoBlobStore('two').write(Uint8List.fromList([2]));
    expect(await IoBlobStore('one').read(), [1]);
    expect(await IoBlobStore('two').read(), [2]);
  });

  test('an empty value is stored as empty, not as missing', () async {
    final store = IoBlobStore('household');
    await store.write(Uint8List(0));
    expect(await store.read(), isEmpty);
    expect(await store.read(), isNotNull);
  });

  test('delete removes the value and leaves no temporary file behind', () async {
    final store = IoBlobStore('household');
    await store.write(Uint8List.fromList([1]));
    await store.delete();
    expect(await store.read(), isNull);
    await store.delete(); // deleting nothing is fine
    expect(sandbox.listSync().whereType<File>(), isEmpty);
  });

  test('a write leaves only the final file, never the temporary one', () async {
    await IoBlobStore('household').write(Uint8List.fromList([1]));
    final names = sandbox.listSync().map((e) => e.path.split('/').last).toList();
    expect(names, hasLength(1));
    expect(names.single, isNot(endsWith('.tmp')));
  });
}
