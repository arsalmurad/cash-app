import 'dart:convert';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'blob_store.dart';
import 'sqlite_store.dart';

BlobStore createBlobStore(String name) => SqliteBlobStore(name);

/// Browser blob storage in `window.localStorage`, base64-encoded.
/// `Storage.setItem` commits a whole value atomically in every mainstream
/// engine, so a page that dies mid-write keeps the previous value.
class WebBlobStore implements BlobStore {
  WebBlobStore(this.name);

  final String name;

  web.Storage get _storage => web.window.localStorage;

  String get _key => 'private_ledger.blob.$name.v1';

  @override
  Future<Uint8List?> read() async {
    final encoded = _storage.getItem(_key);
    return encoded == null ? null : base64Decode(encoded);
  }

  @override
  Future<void> write(Uint8List value) async {
    _storage.setItem(_key, base64Encode(value));
  }

  @override
  Future<void> delete() async {
    _storage.removeItem(_key);
  }
}
