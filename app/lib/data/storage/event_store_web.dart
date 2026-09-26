import 'dart:convert';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'event_store.dart';

EventStore createEventStore() => WebEventStore();

/// Browser durable storage. A web page has no filesystem, so this backs the
/// event log and actor ID with `window.localStorage` instead of the plain
/// file `event_store_io.dart` uses natively — the explicit reason this store
/// exists as a separate implementation rather than reusing native I/O.
///
/// `localStorage` only holds strings, so the binary event log is
/// base64-encoded under one key. Appending therefore reads, decodes,
/// concatenates, and rewrites the whole log rather than truly appending; that
/// is O(log size) per write and a known limitation to revisit (e.g. IndexedDB
/// with one record per frame) if a user's local history grows large, but is
/// simple and correct for this milestone's scope. One consequence is a
/// different crash model than the native file: `Storage.setItem` commits a
/// whole value atomically in every mainstream browser engine, so a page that
/// dies mid-write leaves the previous value intact rather than a half-written
/// frame — the durable-log codec's truncation recovery mainly protects the
/// native path, but costs nothing to keep here as defense in depth.
class WebEventStore implements EventStore {
  static const _logKey = 'private_ledger.event_log.v1';
  static const _actorIdKey = 'private_ledger.actor_id.v1';

  web.Storage get _storage => web.window.localStorage;

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
  Future<String?> readActorId() async {
    final id = _storage.getItem(_actorIdKey);
    return (id == null || id.isEmpty) ? null : id;
  }

  @override
  Future<void> writeActorId(String actorId) async {
    _storage.setItem(_actorIdKey, actorId);
  }
}
