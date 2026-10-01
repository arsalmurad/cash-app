import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../rust/api/storage.dart';
import 'blob_store_web.dart' show WebBlobStore;
import 'event_store_web.dart' show WebDeviceIdentity, WebEventStore;
import 'sqlite_store.dart';

SqlitePlatform createSqlitePlatform() => BrowserSqlitePlatform();

/// SQLite runs only on this page's main WASM thread. Its image is copied to
/// origin-local storage under an exclusive Web Lock, not a C/JS worker VFS.
/// Whole-image saves remain O(database size); no durability claim for OPFS.
class BrowserSqlitePlatform implements SqlitePlatform {
  static const databaseKey = 'private_ledger.sqlite.v1';

  @override
  Future<StorageResponse> request(StorageRequest request) async {
    final result = Completer<StorageResponse>();
    // The lock callback may fail before its JS promise settles. Observe errors
    // immediately; awaiting this same future below still forwards them normally.
    final completion = result.future;
    completion.ignore();
    await web.window.navigator.locks
        .request(
          'cash-app.sqlite.v1',
          ((web.Lock lock) {
            try {
              final stored = web.window.localStorage.getItem(databaseKey);
              final bytes = stored == null
                  ? Uint8List(0)
                  : base64Decode(stored);
              // Synchronous on purpose: sqlite-wasm-rs has no thread-safe mode.
              // No other tab can read/replace the image until this save completes.
              final response = sqliteSerialized(
                database: bytes,
                request: request,
              );
              web.window.localStorage.setItem(
                databaseKey,
                base64Encode(response.database),
              );
              result.complete(response);
            } catch (error, stack) {
              result.completeError(error, stack);
            }
            return Future<JSAny?>.value(null).toJS;
          }).toJS,
        )
        .toDart;
    return completion;
  }

  @override
  Future<Uint8List> legacyLog(String name) => WebEventStore(name).readLog();
  @override
  Future<Uint8List?> legacyBlob(String name) => WebBlobStore(name).read();
  @override
  Future<String?> legacyActorId() => WebDeviceIdentity().readActorId();
}
