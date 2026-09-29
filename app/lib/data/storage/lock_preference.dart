import 'lock_preference_io.dart' if (dart.library.js_interop) 'lock_preference_web.dart';

/// Whether the user has turned on the biometric lock, persisted so the
/// choice survives a restart. Separate from [EventStore]/[DeviceIdentity]
/// (`event_store.dart`) since it holds a UI preference, not ledger data —
/// nothing here is folded by the Rust core or needs to be durable in the
/// same crash-safety sense as an event log.
abstract class LockPreferenceStore {
  factory LockPreferenceStore() => createLockPreferenceStore();

  /// `false` (locked screen off) until the user turns it on; there is no
  /// ambiguous "unset" state to distinguish from "off".
  Future<bool> readEnabled();

  Future<void> writeEnabled(bool enabled);
}
