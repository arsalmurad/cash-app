import 'dart:typed_data';

import 'event_store_io.dart' if (dart.library.js_interop) 'event_store_web.dart';

/// Durable storage for one append-only durable log — the financial ledger's
/// event log, or the categories last-writer-wins log, each identified by
/// [name] so they never collide on disk or in browser storage.
///
/// Native platforms and the browser cannot share one storage mechanism — a
/// page has no filesystem access — so this interface has two
/// implementations selected at compile time: `event_store_io.dart` (a
/// sandboxed file, for iOS/Android/desktop) and `event_store_web.dart`
/// (`window.localStorage`, for Flutter web). Everything above this
/// interface, including the Rust ledger and categories cores, stays
/// platform-agnostic.
abstract class EventStore {
  factory EventStore(String name) => createEventStore(name);

  /// The full persisted log, in append order. Empty for a fresh
  /// installation.
  Future<Uint8List> readLog();

  /// Durably appends one already-validated frame to the log. Must complete
  /// before the caller treats the corresponding mutation as committed: a
  /// crash before this returns is expected to lose only that one write,
  /// never corrupt what was already persisted.
  Future<void> appendFrame(Uint8List frame);
}

/// The device's stable actor ID, shared by every durable log on this
/// install (the ledger and the categories book alike) — there is exactly
/// one identity per device, never one per log.
abstract class DeviceIdentity {
  factory DeviceIdentity() => createDeviceIdentity();

  /// The actor ID persisted on a previous launch, or `null` on first launch.
  Future<String?> readActorId();

  /// Persists the actor ID generated on first launch. Must never change
  /// afterwards: the Rust cores use it to order this device's writes, and a
  /// changed ID would let two different actors claim the same event IDs.
  Future<void> writeActorId(String actorId);
}
