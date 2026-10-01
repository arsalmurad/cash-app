import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../rust/api/storage.dart';
import 'blob_store_io.dart' show IoBlobStore;
import 'event_store_io.dart' show IoDeviceIdentity, IoEventStore;
import 'sqlite_store.dart';

SqlitePlatform createSqlitePlatform() => NativeSqlitePlatform();

class NativeSqlitePlatform implements SqlitePlatform {
  Future<String>? _path;

  Future<String> _databasePath() => _path ??= () async {
    final directory = await getApplicationSupportDirectory();
    await Directory(directory.path).create(recursive: true);
    return '${directory.path}/cash-app.v1.sqlite';
  }();

  @override
  Future<StorageResponse> request(StorageRequest request) async =>
      sqliteFile(path: await _databasePath(), request: request);

  @override
  Future<Uint8List> legacyLog(String name) => IoEventStore(name).readLog();
  @override
  Future<Uint8List?> legacyBlob(String name) => IoBlobStore(name).read();
  @override
  Future<String?> legacyActorId() => IoDeviceIdentity().readActorId();
}
