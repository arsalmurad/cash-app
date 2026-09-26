import 'package:web/web.dart' as web;

import 'lock_preference.dart';

LockPreferenceStore createLockPreferenceStore() => WebLockPreferenceStore();

/// Always reads back `false`: the biometric lock itself is unsupported on
/// web (see `biometric_lock_gate.dart`), so there is nothing meaningful to
/// turn on here, but the interface still needs an implementation to satisfy
/// the conditional import.
class WebLockPreferenceStore implements LockPreferenceStore {
  static const _key = 'private_ledger.lock_enabled.v1';

  web.Storage get _storage => web.window.localStorage;

  @override
  Future<bool> readEnabled() async => _storage.getItem(_key) == 'true';

  @override
  Future<void> writeEnabled(bool enabled) async {
    _storage.setItem(_key, enabled ? 'true' : 'false');
  }
}
