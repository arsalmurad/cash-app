import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'vault_keys.dart';

VaultKeys createVaultKeys() => NativeVaultKeys();

/// Only the random wrapping phrase is stored here, never a large MLS snapshot.
/// No reset-on-error: keychain failures must not silently destroy the key.
class NativeVaultKeys implements VaultKeys {
  NativeVaultKeys({
    FlutterSecureStorage? storage,
    this.key = 'cash-app.household.vault.v1',
  }) : _storage =
           storage ??
           const FlutterSecureStorage(
             iOptions: IOSOptions(
               accessibility: KeychainAccessibility.unlocked_this_device,
             ),
             mOptions: MacOsOptions(usesDataProtectionKeychain: false),
             aOptions: AndroidOptions(
               resetOnError: false,
               migrateWithBackup: true,
             ),
           );

  final FlutterSecureStorage _storage;
  final String key;
  String? _cached;
  @override
  bool get requiresUnlock => false;
  @override
  Future<String?> read() async => _cached ??= await _storage.read(key: key);
  @override
  Future<void> write(String phrase) async {
    _cached = null;
    await _storage.write(key: key, value: phrase);
    // Readback catches platform writes that claimed success but saved nothing.
    if (await _storage.read(key: key) != phrase) {
      throw StateError('The device could not confirm its secure key save.');
    }
    _cached = phrase;
  }

  @override
  void lock() => _cached = null;
}
