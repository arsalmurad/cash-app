import 'dart:convert';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/data/rust/api/shared.dart';
import 'package:private_ledger/data/rust/frb_generated.dart';
import 'package:private_ledger/data/storage/blob_store.dart';
import 'package:private_ledger/data/storage/secret_blob_store.dart';
import 'package:private_ledger/data/storage/vault_keys.dart';
import 'package:private_ledger/features/household/household_controller.dart';
import 'package:private_ledger/features/household/relay_client.dart';

class _Blob implements BlobStore {
  Uint8List? value;
  bool fail = false;
  bool saveBeforeFailure = false;
  int writes = 0;
  @override
  Future<Uint8List?> read() async => value;
  @override
  Future<void> write(Uint8List bytes) async {
    writes++;
    if (!fail || saveBeforeFailure) value = Uint8List.fromList(bytes);
    if (fail) throw StateError('uncertain file save');
  }

  @override
  Future<void> delete() async => value = null;
}

class _Keys implements VaultKeys {
  _Keys({this.requiresUnlock = false, this.phrase});
  @override
  final bool requiresUnlock;
  String? phrase;
  bool fail = false;
  bool discardWrite = false;
  int writes = 0;
  @override
  Future<String?> read() async => phrase;
  @override
  Future<void> write(String value) async {
    writes++;
    if (fail) throw StateError('secure storage unavailable');
    if (!discardWrite) phrase = value;
  }

  @override
  void lock() => phrase = null;
}

void main() {
  final libraryPath = Platform.environment['RUST_LIB_PATH'];
  group('sealed household state through real Rust AEAD', () {
    setUpAll(() async {
      await RustLib.init(externalLibrary: ExternalLibrary.open(libraryPath!));
    });

    test(
      'ciphertext hides payload and root; restart reuses one secure key',
      () async {
        final blob = _Blob();
        final keys = _Keys();
        final plaintext = Uint8List.fromList(
          utf8.encode('private MLS keys and grocery history'),
        );
        await SecretBlobStore(blob, keys: keys).write(plaintext);
        final encoded = utf8.decode(blob.value!, allowMalformed: true);
        expect(encoded, isNot(contains('private MLS keys')));
        expect(encoded, isNot(contains(keys.phrase!)));
        expect(await SecretBlobStore(blob, keys: keys).read(), plaintext);
        await SecretBlobStore(blob, keys: keys).write(plaintext);
        expect(keys.writes, 1);
      },
    );

    test(
      'wrong key, changed bytes, and cross-purpose substitution fail closed',
      () async {
        final blob = _Blob();
        final keys = _Keys();
        await SecretBlobStore(
          blob,
          keys: keys,
        ).write(Uint8List.fromList([1, 2, 3]));
        final original = Uint8List.fromList(blob.value!);
        final wrong = _Keys(phrase: await recoveryGeneratePhrase());
        await expectLater(
          SecretBlobStore(blob, keys: wrong).read(),
          throwsA(isA<VaultCannotOpen>()),
        );
        await expectLater(
          SecretBlobStore(blob, keys: keys, purpose: 'another-ledger').read(),
          throwsA(isA<VaultCannotOpen>()),
        );
        blob.value![blob.value!.length - 1] ^= 1;
        await expectLater(
          SecretBlobStore(blob, keys: keys).read(),
          throwsA(isA<VaultCannotOpen>()),
        );
        expect(original, isNot(blob.value));
      },
    );

    test(
      'missing secure key never replaces the key for existing ciphertext',
      () async {
        final blob = _Blob();
        await SecretBlobStore(
          blob,
          keys: _Keys(),
        ).write(Uint8List.fromList([7]));
        final missing = _Keys();
        await expectLater(
          SecretBlobStore(blob, keys: missing).read(),
          throwsStateError,
        );
        expect(missing.writes, 0);
        expect(blob.writes, 1);
      },
    );

    for (final discard in [false, true]) {
      test(
        'unconfirmed secure key cannot write ciphertext (silent=$discard)',
        () async {
          final blob = _Blob();
          final keys = _Keys()
            ..fail = !discard
            ..discardWrite = discard;
          await expectLater(
            SecretBlobStore(blob, keys: keys).write(Uint8List(1)),
            throwsStateError,
          );
          expect(blob.writes, 0);
        },
      );
    }

    test(
      'concurrent first saves create one root and remain decryptable',
      () async {
        final keys = _Keys();
        final blobs = List.generate(8, (_) => _Blob());
        await Future.wait(
          blobs.map(
            (blob) => SecretBlobStore(
              blob,
              keys: keys,
            ).write(Uint8List.fromList([42])),
          ),
        );
        expect(keys.writes, 1);
        for (final blob in blobs) {
          expect(await SecretBlobStore(blob, keys: keys).read(), [42]);
        }
      },
    );

    for (final saved in [false, true]) {
      test(
        'uncertain replacement recovers a complete authenticated blob (saved=$saved)',
        () async {
          final blob = _Blob();
          final keys = _Keys();
          final vault = SecretBlobStore(blob, keys: keys);
          await vault.write(Uint8List.fromList([1]));
          blob
            ..fail = true
            ..saveBeforeFailure = saved;
          await expectLater(
            vault.write(Uint8List.fromList([2])),
            throwsStateError,
          );
          expect(await SecretBlobStore(blob, keys: keys).read(), [
            saved ? 2 : 1,
          ]);
          expect(keys.writes, 1);
        },
      );
    }

    final relay = MemoryRelayClient();
    HouseholdController controller(_Blob blob, _Keys keys) =>
        HouseholdController(
          stateStore: SecretBlobStore(blob, keys: keys),
          configStore: _Blob(),
          relayFactory: (_) => relay,
        );

    test(
      'valid legacy state is validated and migrated, corrupt state preserved',
      () async {
        final legacy = _Blob();
        final original = HouseholdController(
          stateStore: legacy,
          configStore: _Blob(),
          relayFactory: (_) => relay,
        );
        await original.initialize();
        await original.setRelayUrl('https://relay.test');
        expect(await original.createHousehold(), isTrue);
        final plaintext = Uint8List.fromList(legacy.value!);
        final keys = _Keys();
        final migrated = controller(legacy, keys);
        await migrated.initialize();
        expect(migrated.isMember, isTrue);
        expect(legacy.value, isNot(plaintext));
        expect(await SecretBlobStore(legacy, keys: keys).read(), plaintext);
        final corrupt = _Blob()..value = Uint8List.fromList([0, 1, 2]);
        final invalidKeys = _Keys();
        final invalid = controller(corrupt, invalidKeys);
        await invalid.initialize();
        expect(invalid.errorMessage, isNotNull);
        expect(invalid.requiresRestart, isTrue);
        expect(await invalid.createHousehold(), isFalse);
        expect(corrupt.value, [0, 1, 2]);
        expect(corrupt.writes, 0);
        expect(invalidKeys.writes, 0);
      },
    );

    test(
      'browser locks mutations, retries wrong phrase, and reopens after reload',
      () async {
        final blob = _Blob();
        final keys = _Keys(requiresUnlock: true);
        final first = controller(blob, keys);
        await first.initialize();
        expect(first.needsVaultUnlock, isTrue);
        expect(first.vaultHasCiphertext, isFalse);
        expect(await first.createHousehold(), isFalse);
        final phrase = (await first.generateBrowserUnlockPhrase())!;
        expect(keys.phrase, isNull);
        expect(await first.unlockBrowserVault(phrase), isTrue);
        await first.setRelayUrl('https://relay.test');
        expect(await first.createHousehold(), isTrue);
        expect(await first.lockBrowserVault(), isTrue);
        expect(keys.phrase, isNull);
        expect(first.overview, isNull);
        final original = Uint8List.fromList(blob.value!);
        final reloaded = controller(blob, keys);
        await reloaded.initialize();
        expect(reloaded.vaultHasCiphertext, isTrue);
        expect(
          await reloaded.unlockBrowserVault(await recoveryGeneratePhrase()),
          isFalse,
        );
        expect(keys.phrase, isNull);
        expect(blob.value, original);
        expect(await reloaded.unlockBrowserVault(phrase), isTrue);
        expect(reloaded.isMember, isTrue);
      },
    );

    test(
      'lost browser phrase recovers only with verified independent backup',
      () async {
        final blob = _Blob();
        final keys = _Keys(requiresUnlock: true);
        final first = controller(blob, keys);
        await first.initialize();
        expect(
          await first.unlockBrowserVault(await recoveryGeneratePhrase()),
          isTrue,
        );
        await first.setRelayUrl('https://relay.test');
        expect(await first.createHousehold(), isTrue);
        final backup = (await first.createBackup())!;
        await first.lockBrowserVault();
        final original = Uint8List.fromList(blob.value!);
        final restored = controller(blob, keys);
        await restored.initialize();
        final newPhrase = await recoveryGeneratePhrase();
        expect(
          await restored.restoreBackupWithNewUnlock(
            await recoveryGeneratePhrase(),
            backup.backup,
            newPhrase,
          ),
          isFalse,
        );
        expect(keys.phrase, isNull);
        expect(blob.value, original);
        expect(
          await restored.restoreBackupWithNewUnlock(
            backup.phrase,
            backup.backup,
            newPhrase,
          ),
          isTrue,
        );
        expect(restored.isMember, isFalse);
        expect(restored.needsRecoveryInvite, isTrue);
        expect(restored.recoveryOverview!.isMember, isTrue);
        expect(keys.phrase, newPhrase);
        await restored.lockBrowserVault();
        final fresh = controller(blob, keys);
        await fresh.initialize();
        expect(await fresh.unlockBrowserVault(newPhrase), isTrue);
        expect(fresh.isMember, isFalse);
        expect(fresh.needsRecoveryInvite, isTrue);
      },
    );
  }, skip: libraryPath == null ? 'set RUST_LIB_PATH to the native bridge' : false);
}
