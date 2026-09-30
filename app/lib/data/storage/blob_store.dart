import 'dart:typed_data';

import 'blob_store_io.dart' if (dart.library.js_interop) 'blob_store_web.dart';

/// Durable storage for one named value that is replaced as a whole, unlike
/// [EventStore]'s append-only logs: a household's saved state, which changes
/// with every message and must always be read back complete or not at all.
///
/// The value holds private keys. Native platforms keep it in a file private
/// to the app; the browser keeps it in `localStorage`, which any script on
/// the page can read. Both are weaker than the platform keychain, which is a
/// known gap recorded in `docs/PHASE2-PROGRESS.md`.
abstract class BlobStore {
  factory BlobStore(String name) => createBlobStore(name);

  /// The stored value, or `null` if nothing has been written.
  Future<Uint8List?> read();

  /// Replaces the stored value atomically: a crash mid-write leaves the
  /// previous value, never a torn one.
  Future<void> write(Uint8List value);

  Future<void> delete();
}
