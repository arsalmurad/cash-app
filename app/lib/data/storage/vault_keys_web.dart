import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'vault_keys.dart';

VaultKeys createVaultKeys() => BrowserVaultKeys();

/// Never writes a key to cookies, localStorage, sessionStorage or IndexedDB.
/// One tab holds the household identity, preventing sender-ratchet reuse by
/// two simultaneously unlocked copies of the same persisted MLS state.
class BrowserVaultKeys implements VaultKeys {
  static String? _phrase;
  static Completer<JSAny?>? _release;
  @override
  bool get requiresUnlock => true;
  @override
  Future<String?> read() async => _phrase;

  @override
  Future<void> write(String phrase) async {
    if (_release == null) {
      final acquired = Completer<bool>();
      try {
        final promise = web.window.navigator.locks.request(
          'cash-app.household.vault.v1',
          web.LockOptions(ifAvailable: true),
          ((web.Lock? lock) {
            if (lock == null) {
              acquired.complete(false);
              return Future<JSAny?>.value(null).toJS;
            }
            _release = Completer<JSAny?>();
            acquired.complete(true);
            return _release!.future.toJS;
          }).toJS,
        );
        unawaited(
          promise.toDart.then<void>(
            (_) {},
            onError: (Object _, StackTrace _) {
              if (!acquired.isCompleted) acquired.complete(false);
            },
          ),
        );
      } catch (_) {
        throw StateError(
          'This browser needs HTTPS/localhost and Web Locks to safely open a household.',
        );
      }
      if (!await acquired.future) throw const VaultBusy();
    }
    _phrase = phrase;
  }

  @override
  void lock() {
    _phrase = null;
    _release?.complete(null);
    _release = null;
  }
}
