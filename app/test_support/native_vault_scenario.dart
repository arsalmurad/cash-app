import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/data/storage/blob_store.dart';
import 'package:private_ledger/data/storage/secret_blob_store.dart';
import 'package:private_ledger/data/storage/vault_keys_native.dart';

import 'household_scenario.dart';

/// The full real-bridge household scenario, now with sealed app-private files
/// and real OS keys for every simulated device; restart recreates both stores.
Future<void> runProtectedNativeHouseholdScenario() async {
  final namespace =
      'protected-household-${DateTime.now().microsecondsSinceEpoch}';
  final scopes = <String>{};
  try {
    await runHouseholdScenario(
      stateFactory: (scope) {
        scopes.add(scope);
        return SecretBlobStore(
          BlobStore('$namespace-$scope'),
          keys: NativeVaultKeys(key: 'cash-app.test.$namespace.$scope'),
        );
      },
      configFactory: (scope) => BlobStore('$namespace-$scope-config'),
    );
  } finally {
    for (final scope in scopes) {
      await BlobStore('$namespace-$scope').delete();
      await BlobStore('$namespace-$scope-config').delete();
      await const FlutterSecureStorage().delete(
        key: 'cash-app.test.$namespace.$scope',
      );
    }
  }
}

/// Actual OS keychain/keystore and app-private file, not plugin mocks. RustLib
/// must already be initialized. Deletes only this uniquely named test material.
Future<void> runNativeVaultScenario() async {
  final namespace =
      'vault-integration-${DateTime.now().microsecondsSinceEpoch}';
  final keyName = 'cash-app.test.$namespace';
  final blob = BlobStore(namespace);
  final keys = NativeVaultKeys(key: keyName);
  final plaintext = Uint8List.fromList(
    utf8.encode('synthetic-private-household-material'),
  );
  try {
    final vault = SecretBlobStore(blob, keys: keys);
    await vault.write(plaintext);
    final raw = utf8.decode((await blob.read())!, allowMalformed: true);
    expect(raw, isNot(contains('synthetic-private-household-material')));
    expect(raw, isNot(contains((await keys.read())!)));
    keys.lock();
    final restarted = SecretBlobStore(
      blob,
      keys: NativeVaultKeys(key: keyName),
    );
    expect(await restarted.read(), plaintext);
  } finally {
    keys.lock();
    await blob.delete();
    await const FlutterSecureStorage().delete(key: keyName);
  }
}
