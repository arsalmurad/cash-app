import 'dart:convert';
import 'dart:typed_data';

import '../rust/api/shared.dart';
import 'blob_store.dart';
import 'vault_keys.dart';

const _magic = 'cash-app sealed vault v1\u0000';
final _marker = utf8.encode(_magic);

bool _startsWith(List<int> bytes, List<int> prefix) =>
    bytes.length >= prefix.length &&
    !List.generate(prefix.length, (i) => bytes[i] == prefix[i]).contains(false);

/// The whole atomic journal is sealed with the existing Rust AEAD, while its
/// independent random wrapping key is in OS secure storage or browser RAM.
class SecretBlobStore implements BlobStore {
  SecretBlobStore(this.inner, {VaultKeys? keys, this.purpose = 'household'})
    : keys = keys ?? VaultKeys();
  final BlobStore inner;
  final VaultKeys keys;
  final String purpose;
  static Future<void> _keyQueue = Future<void>.value();
  bool needsMigration = false;
  List<int> get _domain => utf8.encode('cash-app vault payload $purpose\u0000');

  @override
  Future<Uint8List?> read() async {
    final bytes = await inner.read();
    final encrypted = bytes != null && _startsWith(bytes, _marker);
    if (!keys.requiresUnlock && !encrypted) {
      needsMigration = bytes != null;
      return bytes; // No OS key access until a household actually needs it.
    }
    final phrase = await keys.read();
    if (phrase == null && keys.requiresUnlock) {
      throw VaultLocked(hasCiphertext: encrypted);
    }
    if (bytes == null) return null;
    if (!encrypted) {
      needsMigration = true;
      return bytes; // Caller validates legacy state before sealing it.
    }
    if (phrase == null) {
      throw StateError(
        'The device secure key is missing. Restore an encrypted backup.',
      );
    }
    try {
      final plaintext = await recoveryOpen(
        phrase: phrase,
        sealed: Uint8List.fromList(bytes.sublist(_marker.length)),
      );
      if (!_startsWith(plaintext, _domain)) throw const VaultCannotOpen();
      return Uint8List.fromList(plaintext.sublist(_domain.length));
    } catch (_) {
      throw const VaultCannotOpen();
    }
  }

  Future<String> _writeKey() {
    final next = _keyQueue.then((_) async {
      final current = await keys.read();
      if (current != null) return current;
      if (keys.requiresUnlock) throw const VaultLocked(hasCiphertext: false);
      final phrase = await recoveryGeneratePhrase();
      await keys.write(phrase);
      if (await keys.read() != phrase) {
        throw StateError('The secure key save could not be confirmed.');
      }
      return phrase;
    });
    _keyQueue = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  @override
  Future<void> write(Uint8List value) async {
    final phrase = await _writeKey();
    final sealed = await recoverySeal(
      phrase: phrase,
      plaintext: Uint8List.fromList([..._domain, ...value]),
    );
    await inner.write(Uint8List.fromList([..._marker, ...sealed]));
    needsMigration = false;
  }

  @override
  Future<void> delete() => inner.delete();
}
