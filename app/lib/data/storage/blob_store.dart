import 'dart:typed_data';

import 'blob_store_io.dart' if (dart.library.js_interop) 'blob_store_web.dart';

/// Durable storage for one named value that is replaced as a whole, unlike
/// [EventStore]'s append-only logs: a household's saved state, which changes
/// with every message and must always be read back complete or not at all.
///
/// This primitive does not encrypt values. Secret state must be wrapped in
/// [SecretBlobStore] before using a native file or browser localStorage.
abstract class BlobStore {
  factory BlobStore(String name) => createBlobStore(name);

  /// The stored value, or `null` if nothing has been written.
  Future<Uint8List?> read();

  /// Replaces the stored value atomically: a crash mid-write leaves the
  /// previous value, never a torn one.
  Future<void> write(Uint8List value);

  Future<void> delete();
}
