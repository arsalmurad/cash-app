import 'dart:convert';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/data/rust/frb_generated.dart';
import 'package:private_ledger/data/storage/blob_store.dart';
import 'package:private_ledger/features/household/household_controller.dart';
import 'package:private_ledger/features/household/relay_client.dart';

class _Store implements BlobStore {
  Uint8List? value;
  bool fail = false;
  @override
  Future<Uint8List?> read() async => value;
  @override
  Future<void> write(Uint8List bytes) async {
    if (fail) throw const FileSystemException('uncertain save');
    value = Uint8List.fromList(bytes);
  }

  @override
  Future<void> delete() async => value = null;
}

void main() {
  final library = Platform.environment['RUST_LIB_PATH'];
  group('controller-owned public roster access', () {
    setUpAll(
      () => RustLib.init(externalLibrary: ExternalLibrary.open(library!)),
    );

    test(
      'immutable public keys survive restore without changing saved bytes',
      () async {
        final store = _Store();
        final config = _Store();
        final relay = MemoryRelayClient();
        HouseholdController controller() => HouseholdController(
          stateStore: store,
          configStore: config,
          relayFactory: (_) => relay,
        );
        final first = controller();
        await first.initialize();
        await expectLater(
          first.relayRosterKeys(),
          throwsA(isA<FormatException>()),
        );
        expect(await first.setRelayUrl('https://relay.example'), isTrue);
        expect(await first.createHousehold(), isTrue);
        final saved = Uint8List.fromList(store.value!);
        final keys = await first.relayRosterKeys();
        expect(keys, hasLength(1));
        final proof = jsonDecode(
          await first.relayRequestSigner(
            'GET',
            Uri.parse(
              'https://relay.example/g/${first.overview!.groupId}/policy',
            ),
            Uint8List(0),
          ),
        ) as Map<String, dynamic>;
        expect(keys.single, proof['publicKey']);
        expect(() => keys.clear(), throwsUnsupportedError);
        expect(store.value, saved);
        first.dispose();
        await expectLater(
          first.relayRosterKeys(),
          throwsA(isA<FormatException>()),
        );
        final restored = controller();
        addTearDown(restored.dispose);
        await restored.initialize();
        expect(await restored.relayRosterKeys(), keys);
        expect(store.value, saved);
      },
    );

    test('lock or disposal during the native query discards public projection', () async {
      for (final close in [false, true]) {
        final store = _Store();
        final controller = HouseholdController(
          stateStore: store,
          configStore: _Store(),
          relayFactory: (_) => MemoryRelayClient(),
        );
        await controller.initialize();
        expect(await controller.setRelayUrl('https://relay.example'), isTrue);
        expect(await controller.createHousehold(), isTrue);
        final saved = Uint8List.fromList(store.value!);
        final pending = controller.relayRosterKeys();
        // Controlled lock transition, not biometric or browser-vault UI proof.
        if (close) {
          controller.dispose();
        } else {
          controller.needsVaultUnlock = true;
        }
        await expectLater(pending, throwsA(isA<FormatException>()));
        await expectLater(
          controller.relayRosterKeys(),
          throwsA(isA<FormatException>()),
        );
        expect(store.value, saved);
        if (!close) controller.dispose();
      }
    });

    test('uncertain persistence abandons roster access rather than publishing new keys', () async {
      final store = _Store();
      final controller = HouseholdController(
        stateStore: store,
        configStore: _Store(),
        relayFactory: (_) => MemoryRelayClient(),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      expect(await controller.setRelayUrl('https://relay.example'), isTrue);
      expect(await controller.prepareJoinRequest(), isNotNull);
      final saved = Uint8List.fromList(store.value!);
      store.fail = true;
      expect(await controller.createHousehold(), isFalse);
      expect(controller.requiresRestart, isTrue);
      await expectLater(
        controller.relayRosterKeys(),
        throwsA(isA<FormatException>()),
      );
      expect(store.value, saved);
    });
  }, skip: library == null ? 'Requires the rebuilt native bridge' : false);
}
