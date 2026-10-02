import 'dart:io';
import 'dart:convert';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/data/rust/frb_generated.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:private_ledger/data/storage/blob_store.dart';
import 'package:private_ledger/data/storage/secret_blob_store.dart';
import 'package:private_ledger/data/storage/vault_keys.dart';

import '../test_support/household_failure_scenario.dart';

class _Paths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

// An in-memory key backend, not an OS-key-store claim. Native integration
// supplies NativeVaultKeys instead; both use the actual Rust sealing code.
class _Keys implements VaultKeys {
  String? phrase;
  @override
  bool get requiresUnlock => false;
  @override
  Future<String?> read() async => phrase;
  @override
  Future<void> write(String value) async => phrase = value;
  @override
  void lock() {}
}

void main() {
  final path = Platform.environment['RUST_LIB_PATH'];
  group('portable household failures', () {
    setUpAll(
      () async => RustLib.init(externalLibrary: ExternalLibrary.open(path!)),
    );
    test(
      'portable household failure scenario through actual native bridge',
      () async {
        await runHouseholdFailureScenario();
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
    test('failure recovery retains sealed actual SQLite documents', () async {
      final directory = await Directory.systemTemp.createTemp(
        'cash-household-failures-',
      );
      final previous = PathProviderPlatform.instance;
      final keys = <String, _Keys>{};
      PathProviderPlatform.instance = _Paths(directory.path);
      try {
        await runHouseholdFailureScenario(
          stateFactory: (scope) => SecretBlobStore(
            BlobStore(scope),
            keys: keys.putIfAbsent(scope, _Keys.new),
          ),
          configFactory: (scope) => BlobStore('$scope-config'),
        );
        final physical = latin1.decode(
          await File('${directory.path}/cash-app.v1.sqlite').readAsBytes(),
        );
        expect(physical, startsWith('SQLite format 3\u0000'));
        for (final title in [
          'Queued ratchet',
          'After interrupted invite',
          'After recovered removal',
          'After receiver recovery',
        ]) {
          expect(physical, isNot(contains(title)));
        }
        for (final key in keys.values) {
          expect(key.phrase, isNotNull);
          expect(physical, isNot(contains(key.phrase!)));
        }
      } finally {
        PathProviderPlatform.instance = previous;
        await directory.delete(recursive: true);
      }
    }, timeout: const Timeout(Duration(minutes: 5)));
  }, skip: path == null ? 'Set RUST_LIB_PATH for actual bridge tests' : false);
}
