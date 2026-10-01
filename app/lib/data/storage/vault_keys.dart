import 'vault_keys_native.dart'
    if (dart.library.js_interop) 'vault_keys_web.dart';

abstract class VaultKeys {
  factory VaultKeys() => createVaultKeys();
  bool get requiresUnlock;
  Future<String?> read();
  Future<void> write(String phrase);
  void lock();
}

class VaultLocked implements Exception {
  const VaultLocked({required this.hasCiphertext});
  final bool hasCiphertext;
  @override
  String toString() => 'Unlock the household on this browser first.';
}

class VaultCannotOpen implements Exception {
  const VaultCannotOpen();
  @override
  String toString() =>
      'The saved household could not be opened. Check the unlock phrase or restore an encrypted backup.';
}

class VaultBusy implements Exception {
  const VaultBusy();
  @override
  String toString() =>
      'The household is open in another tab. Lock or close that tab, then try again.';
}
