import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:private_ledger/data/storage/blob_store.dart';
import 'package:private_ledger/data/storage/secret_blob_store.dart';
import 'package:private_ledger/data/storage/vault_keys_native.dart';

import 'household_scenario.dart';
import 'household_failure_scenario.dart';

typedef _Scenario = Future<void> Function({
  BlobStore Function(String scope)? stateFactory,
  BlobStore Function(String scope)? configFactory,
});

/// The full real-bridge household scenario with sealed SQLite documents
/// and real OS keys for every simulated device; restart recreates both stores.
Future<void> runProtectedNativeHouseholdScenario() =>
    _runProtectedScenario(runHouseholdScenario);

Future<void> runProtectedNativeHouseholdFailureScenario() =>
    _runProtectedScenario(runHouseholdFailureScenario);

Future<void> _runProtectedScenario(_Scenario scenario) async {
  final namespace =
      'protected-household-${DateTime.now().microsecondsSinceEpoch}';
  final scopes = <String>{};
  try {
    await scenario(
      stateFactory: (scope) {
        scopes.add(scope);
        return SecretBlobStore(
          BlobStore('$namespace-$scope'),
          keys: NativeVaultKeys(key: 'cash-app.test.$namespace.$scope'),
        );
      },
      configFactory: (scope) => BlobStore('$namespace-$scope-config'),
    );
    final directory = await getApplicationSupportDirectory();
    final physical = latin1.decode(
      await File('${directory.path}/cash-app.v1.sqlite').readAsBytes(),
    );
    for (final title in [
      'Queued ratchet',
      'After interrupted invite',
      'After recovered removal',
      'After receiver recovery',
    ]) {
      expect(
        physical,
        isNot(contains(title)),
        reason: 'Failure recovery journals stay sealed in physical SQLite',
      );
    }
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
    final directory = await getApplicationSupportDirectory();
    final database = await File('${directory.path}/cash-app.v1.sqlite')
        .readAsBytes();
    final physical = latin1.decode(database);
    expect(physical, startsWith('SQLite format 3\u0000'));
    expect(physical, contains('cash-app sealed vault v1\u0000'));
    expect(physical, isNot(contains('synthetic-private-household-material')));
    expect(physical, isNot(contains((await keys.read())!)));
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
