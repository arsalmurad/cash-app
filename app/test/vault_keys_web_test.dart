@TestOn('browser')
library;

import 'dart:js_interop';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/data/storage/vault_keys_web.dart';
import 'package:web/web.dart' as web;

void main() {
  test(
    'root is RAM-only and a second tab cannot acquire the identity lease',
    () async {
      final keys = BrowserVaultKeys();
      final iframe = web.HTMLIFrameElement()..src = 'about:blank';
      web.document.body!.append(iframe);
      try {
        const phrase = 'synthetic-vault-phrase-not-for-production';
        await keys.write(phrase);
        expect(await keys.read(), phrase);
        for (final storage in [
          web.window.localStorage,
          web.window.sessionStorage,
        ]) {
          for (var i = 0; i < storage.length; i++) {
            expect(storage.getItem(storage.key(i)!), isNot(contains(phrase)));
          }
        }
        expect(web.document.cookie, isNot(contains(phrase)));
        Future<bool> available() async {
          final result = await iframe.contentWindow!.navigator.locks
              .request(
                'cash-app.household.vault.v1',
                web.LockOptions(ifAvailable: true),
                ((web.Lock? lock) => Future<JSAny?>.value(
                  (lock != null).toJS,
                ).toJS).toJS,
              )
              .toDart;
          return (result as JSBoolean).toDart;
        }

        expect(await available(), isFalse);
        keys.lock();
        expect(await keys.read(), isNull);
        expect(await available(), isTrue);
      } finally {
        keys.lock();
        iframe.remove();
      }
    },
  );
}
