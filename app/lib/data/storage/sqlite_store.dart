import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show PlatformInt64Util;

import '../rust/api/storage.dart';
import 'blob_store.dart';
import 'event_store.dart';
import 'sqlite_store_io.dart'
    if (dart.library.js_interop) 'sqlite_store_web.dart';

/// Platform code transports paths/bytes; SQL, transactions and revisions live
/// in Rust. Web requests hold a cross-tab lock through the durable byte save.
abstract class SqlitePlatform {
  factory SqlitePlatform() => createSqlitePlatform();
  Future<StorageResponse> request(StorageRequest request);
  Future<Uint8List> legacyLog(String name);
  Future<Uint8List?> legacyBlob(String name);
  Future<String?> legacyActorId();
}

StorageRequest storageRequest(
  String name,
  StorageOperation operation, {
  int revision = 0,
  Uint8List? value,
  int expectedLength = 0,
  int validLength = 0,
}) => StorageRequest(
  name: name,
  operation: operation,
  expectedRevision: PlatformInt64Util.from(revision),
  value: value,
  expectedLength: BigInt.from(expectedLength),
  validLength: BigInt.from(validLength),
);

class SqliteEventStore implements EventStore {
  SqliteEventStore(this.name, {SqlitePlatform? platform})
    : _platform = platform ?? SqlitePlatform();

  final String name;
  final SqlitePlatform _platform;
  int? _revision;

  @override
  Future<Uint8List> readLog() async {
    final result = await _platform.request(
      storageRequest(
        name,
        StorageOperation.openLog,
        value: await _platform.legacyLog(name),
      ),
    );
    _revision = result.revision.toInt();
    return result.value ?? Uint8List(0);
  }

  @override
  Future<void> appendFrame(Uint8List frame) async {
    if (_revision == null) await readLog();
    final result = await _platform.request(
      storageRequest(
        name,
        StorageOperation.appendFrame,
        revision: _revision!,
        value: frame,
      ),
    );
    _revision = result.revision.toInt();
  }

  @override
  Future<void> recoverPrefix(
    int validLength, {
    required int expectedLength,
  }) async {
    if (validLength < 0 || validLength > expectedLength) {
      throw ArgumentError.value(validLength, 'validLength');
    }
    if (_revision == null) await readLog();
    final result = await _platform.request(
      storageRequest(
        name,
        StorageOperation.recoverPrefix,
        revision: _revision!,
        expectedLength: expectedLength,
        validLength: validLength,
      ),
    );
    _revision = result.revision.toInt();
  }
}

class SqliteBlobStore implements BlobStore {
  SqliteBlobStore(this.name, {SqlitePlatform? platform})
    : _platform = platform ?? SqlitePlatform();

  final String name;
  final SqlitePlatform _platform;
  int? _revision;
  String get _key => 'blob.$name';

  @override
  Future<Uint8List?> read() async {
    final result = await _platform.request(
      storageRequest(_key, StorageOperation.readDocument),
    );
    _revision = result.revision.toInt();
    // Do not copy a legacy plaintext journal into SQLite. SecretBlobStore
    // validates it and seals the migrated state before the first write.
    if (_revision == 0) return _platform.legacyBlob(name);
    return result.value;
  }

  Future<void> _save(Uint8List? value) async {
    if (_revision == null) await read();
    final result = await _platform.request(
      storageRequest(
        _key,
        StorageOperation.writeDocument,
        revision: _revision!,
        value: value,
      ),
    );
    _revision = result.revision.toInt();
  }

  @override
  Future<void> write(Uint8List value) => _save(value);
  @override
  Future<void> delete() => _save(null);
}

class SqliteDeviceIdentity implements DeviceIdentity {
  SqliteDeviceIdentity({SqlitePlatform? platform})
    : _platform = platform ?? SqlitePlatform();

  final SqlitePlatform _platform;
  static const _key = 'identity.actor.v1';
  int? _revision;
  String? _actor;

  @override
  Future<String?> readActorId() async {
    final result = await _platform.request(
      storageRequest(_key, StorageOperation.readDocument),
    );
    _revision = result.revision.toInt();
    if (_revision != 0) {
      if (result.value == null) {
        throw StateError('The saved ledger identity is missing');
      }
      _actor = utf8.decode(result.value!).trim();
      if (_actor!.isEmpty) {
        throw StateError('The saved ledger identity is empty');
      }
    } else {
      _actor = await _platform.legacyActorId();
      if (_actor != null) await writeActorId(_actor!);
    }
    return _actor;
  }

  @override
  Future<void> writeActorId(String actorId) async {
    if (_revision == null) await readActorId();
    if (_revision != 0) {
      if (_actor != actorId) {
        throw StateError('The ledger identity cannot change');
      }
      return;
    }
    if (actorId.trim().isEmpty) throw ArgumentError.value(actorId, 'actorId');
    final result = await _platform.request(
      storageRequest(
        _key,
        StorageOperation.writeDocument,
        value: Uint8List.fromList(utf8.encode(actorId)),
      ),
    );
    _revision = result.revision.toInt();
    _actor = actorId;
  }
}
