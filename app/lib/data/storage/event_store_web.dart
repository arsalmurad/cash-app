import 'dart:convert';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'event_store.dart';

EventStore createEventStore(String name) => WebEventStore(name);

DeviceIdentity createDeviceIdentity() => WebDeviceIdentity();

/// Browser durable log storage. A web page has no filesystem, so this backs
/// each named log with `window.localStorage` instead of the plain file
/// `event_store_io.dart` uses natively — the explicit reason this store
/// exists as a separate implementation rather than reusing native I/O.
///
/// `localStorage` only holds strings, so the binary log is base64-encoded
/// under one key per log name. Appending therefore reads, decodes,
/// concatenates, and rewrites the whole log rather than truly appending;
/// that is O(log size) per write and a known limitation to revisit (e.g.
/// IndexedDB with one record per frame) if a user's local history grows
/// large, but is simple and correct for this milestone's scope. One
/// consequence is a different crash model than the native file:
/// `Storage.setItem` commits a whole value atomically in every mainstream
/// browser engine, so a page that dies mid-write leaves the previous value
/// intact rather than a half-written frame — the durable-log codecs' own
/// truncation recovery mainly protects the native path, but costs nothing to
/// keep here as defense in depth.
class WebEventStore implements EventStore {
  WebEventStore(this.name);

  final String name;

  web.Storage get _storage => web.window.localStorage;

  String get _logKey => 'private_ledger.$name.v1';

  @override
  Future<Uint8List> readLog() async {
    final encoded = _storage.getItem(_logKey);
    if (encoded == null || encoded.isEmpty) {
      return Uint8List(0);
    }
    return base64Decode(encoded);
  }

  @override
  Future<void> appendFrame(Uint8List frame) async {
    final existing = await readLog();
    final combined = Uint8List(existing.length + frame.length)
      ..setRange(0, existing.length, existing)
      ..setRange(existing.length, existing.length + frame.length, frame);
    _storage.setItem(_logKey, base64Encode(combined));
  }

  @override
  Future<void> recoverPrefix(
    int validLength, {
    required int expectedLength,
  }) async {
    if (validLength < 0 || validLength > expectedLength) {
      throw ArgumentError.value(validLength, 'validLength');
    }
    final original = await readLog();
    if (original.length != expectedLength) {
      throw StateError('Log changed during recovery');
    }
    if (validLength == expectedLength) return;
    // Both writes are synchronous. If archiving fails (e.g. quota exceeded),
    // leave the original untouched and fail initialization.
    _storage.setItem(
      '$_logKey.recovery-${DateTime.now().microsecondsSinceEpoch}',
      base64Encode(original),
    );
    _storage.setItem(_logKey, base64Encode(original.sublist(0, validLength)));
  }
}

/// Browser actor ID storage, alongside the event log(s).
class WebDeviceIdentity implements DeviceIdentity {
  static const _actorIdKey = 'private_ledger.actor_id.v1';

  web.Storage get _storage => web.window.localStorage;

  @override
  Future<String?> readActorId() async {
    final id = _storage.getItem(_actorIdKey);
    return (id == null || id.isEmpty) ? null : id;
  }

  @override
  Future<void> writeActorId(String actorId) async {
    _storage.setItem(_actorIdKey, actorId);
  }
}
