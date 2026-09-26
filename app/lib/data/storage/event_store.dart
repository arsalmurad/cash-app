import 'dart:typed_data';

import 'event_store_io.dart' if (dart.library.js_interop) 'event_store_web.dart';

/// Durable storage for one device's personal ledger: the append-only event
/// log plus the stable actor ID that anchors it in the ledger's total order.
///
/// Native platforms and the browser cannot share one storage mechanism — a
/// page has no filesystem access — so this interface has two
/// implementations selected at compile time: `event_store_io.dart` (a
/// sandboxed file, for iOS/Android/desktop) and `event_store_web.dart`
/// (`window.localStorage`, for Flutter web). Everything above this
/// interface, including the Rust ledger core, stays platform-agnostic.
abstract class EventStore {
  factory EventStore() => createEventStore();

  /// The full persisted event log, in append order. Empty for a fresh
  /// installation.
  Future<Uint8List> readLog();

  /// Durably appends one already-validated event frame to the log. Must
  /// complete before the caller treats the corresponding ledger mutation as
  /// committed: a crash before this returns is expected to lose only that
  /// one event, never corrupt what was already persisted.
  Future<void> appendFrame(Uint8List frame);

  /// The actor ID persisted on a previous launch, or `null` on first launch.
  Future<String?> readActorId();

  /// Persists the actor ID generated on first launch. Must never change
  /// afterwards: the Rust ledger uses it to order this device's events, and
  /// a changed ID would let two different actors claim the same event IDs.
  Future<void> writeActorId(String actorId);
}
