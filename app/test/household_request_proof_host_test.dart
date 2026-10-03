import 'dart:io';
import 'dart:convert';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:private_ledger/data/rust/api/shared.dart';
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
  group('public request proofs through the native bridge', () {
    setUpAll(
      () async => RustLib.init(externalLibrary: ExternalLibrary.open(library!)),
    );

    test('controller provider uses protected identity, exact URI and public JSON only', () async {
      final store = _Store();
      final config = _Store();
      HouseholdController controller() => HouseholdController(
        stateStore: store,
        configStore: config,
        clockMillis: () => 1790000000000,
      );
      final first = controller();
      await first.initialize();
      expect(await first.prepareJoinRequest(), isNotNull);
      final saved = Uint8List.fromList(store.value!);
      final provider = first.relayRequestSigner;
      final uri = Uri.parse(
        'https://relay.example/g/0123456789abcdef0123456789abcdef?after=12',
      );
      final proof = jsonDecode(
        await provider('GET', uri, Uint8List(0)),
      ) as Map<String, dynamic>;
      expect(proof.keys.toSet(), {
        'publicKey',
        'nonce',
        'expires',
        'signature',
      });
      expect(proof['publicKey'], matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(proof['nonce'], matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(proof['signature'], matches(RegExp(r'^[0-9a-f]{128}$')));
      expect(proof['expires'], 1790000050000);
      final verifier = File('../relay/src/request-proof.js').absolute.uri
          .toString();
      final verified = await Process.run('node', [
        '--input-type=module',
        '-e',
        '''
        import { verifyRequestProof } from ${jsonEncode(verifier)};
        const proof = JSON.parse(process.argv[1]);
        const url = process.argv[2];
        const bytes = new Uint8Array();
        const valid = await verifyRequestProof(new Request(url), bytes, proof, proof.publicKey, 1790000000000);
        const tampered = await verifyRequestProof(new Request(url.replace('after=12', 'after=13')), bytes, proof, proof.publicKey, 1790000000000);
        if (!valid || tampered) process.exit(1);
      ''',
        jsonEncode(proof),
        uri.toString(),
      ]);
      expect(
        verified.exitCode,
        0,
        reason:
            'Actual relay verifier must accept the controller proof and reject changed query: ${verified.stderr}',
      );
      expect(store.value, saved);
      final again = jsonDecode(
        await provider('GET', uri, Uint8List(0)),
      ) as Map<String, dynamic>;
      final transport = HttpRelayClient(
        'https://relay.example',
        MockClient((request) async {
          final accepted = await Process.run('node', [
            '--input-type=module',
            '-e',
            '''
          import { verifyRequestProof } from ${jsonEncode(verifier)};
          const proof = JSON.parse(process.argv[1]);
          const url = process.argv[2];
          const bytes = Buffer.from(process.argv[3], 'base64');
          const key = process.argv[4];
          const valid = await verifyRequestProof(new Request(url, {method:'POST', body:bytes}), bytes, proof, key, 1790000000000);
          const changed = Uint8Array.from(bytes); changed[0] ^= 1;
          const tampered = await verifyRequestProof(new Request(url, {method:'POST', body:changed}), changed, proof, key, 1790000000000);
          if (!valid || tampered) process.exit(1);
        ''',
            request.headers['x-cash-device-proof']!,
            request.url.toString(),
            base64.encode(request.bodyBytes),
            proof['publicKey'] as String,
          ]);
          expect(
            accepted.exitCode,
            0,
            reason:
                'Native controller to HTTP proof must bind the sent body: ${accepted.stderr}',
          );
          return http.Response('{"seq":1}', 200);
        }),
        provider,
      );
      expect(
        await transport.append(
          '0123456789abcdef0123456789abcdef',
          0,
          Uint8List.fromList([0, 255, 128]),
        ),
        1,
      );
      expect(store.value, saved);
      expect(again['nonce'], isNot(proof['nonce']));
      first.dispose();
      await expectLater(
        provider('GET', uri, Uint8List(0)),
        throwsA(isA<FormatException>()),
      );
      final restored = controller();
      addTearDown(restored.dispose);
      await restored.initialize();
      final restarted = jsonDecode(
        await restored.relayRequestSigner('GET', uri, Uint8List(0)),
      ) as Map<String, dynamic>;
      expect(restarted['publicKey'], proof['publicKey']);
      expect(restarted['nonce'], isNot(proof['nonce']));
      expect(store.value, saved);
      for (final invalid in [
        'https://user@relay.example/g/a',
        'https://relay.example/g/a#fragment',
        'http://relay.example/g/a',
      ]) {
        await expectLater(
          restored.relayRequestSigner('GET', Uri.parse(invalid), Uint8List(0)),
          throwsA(anything),
        );
        expect(store.value, saved);
      }
    });

    test(
      'abandoned controller identity cannot sign after uncertain persistence',
      () async {
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
        final provider = controller.relayRequestSigner;
        final saved = Uint8List.fromList(store.value!);
        store.fail = true;
        expect(await controller.createHousehold(), isFalse);
        expect(controller.requiresRestart, isTrue);
        await expectLater(
          provider('GET', Uri.parse('https://relay.example/g/a'), Uint8List(0)),
          throwsA(isA<FormatException>()),
        );
        expect(store.value, saved);
      },
    );

    test(
      'lock state or disposal while signing discards the pending proof',
      () async {
        for (final close in [false, true]) {
          final controller = HouseholdController(
            stateStore: _Store(),
            configStore: _Store(),
          );
          await controller.initialize();
          expect(await controller.prepareJoinRequest(), isNotNull);
          final provider = controller.relayRequestSigner;
          final pending = provider(
            'GET',
            Uri.parse('https://relay.example/g/a'),
            Uint8List(0),
          );
          if (close) {
            controller.dispose();
          } else {
            // Controlled lock-state transition while the read-only Rust future
            // is pending, not a claim of native biometric/vault UI acceptance.
            controller.needsVaultUnlock = true;
          }
          await expectLater(pending, throwsA(isA<FormatException>()));
          await expectLater(
            provider(
              'GET',
              Uri.parse('https://relay.example/g/a'),
              Uint8List(0),
            ),
            throwsA(isA<FormatException>()),
          );
          if (!close) controller.dispose();
        }
      },
    );

    Future<HouseholdRequestProof> sign(
      Household device, {
      int expiry = 1790000030000,
    }) => householdSignRelayRequest(
      household: device,
      origin: 'https://relay.example',
      method: 'POST',
      path: '/g/0123456789abcdef0123456789abcdef/append',
      body: Uint8List.fromList([0, 255, 1, 128]),
      expires: PlatformInt64Util.from(expiry),
    );

    test(
      'fresh public proof preserves archive and identity after restart',
      () async {
        final device = await householdNew(
          memberId: 'opaque-device',
          reportingCurrencyCode: 'USD',
        );
        addTearDown(device.dispose);
        final saved = await householdExport(household: device);
        final first = await sign(device);
        final second = await sign(device);
        expect(first.publicKey.length, 32);
        expect(first.nonce.length, 32);
        expect(first.signature.length, 64);
        expect(first.expires.toInt(), 1790000030000);
        expect(second.publicKey, first.publicKey);
        expect(second.nonce, isNot(first.nonce));
        expect(await householdExport(household: device), saved);
        final restored = await householdRestore(saved: saved);
        addTearDown(restored.dispose);
        final restarted = await sign(restored);
        expect(restarted.publicKey, first.publicKey);
        expect(restarted.nonce, isNot(first.nonce));
        expect(await householdExport(household: restored), saved);
      },
    );

    test(
      'invalid expiry is refused without changing the saved archive',
      () async {
        final device = await householdNew(
          memberId: 'opaque-device',
          reportingCurrencyCode: 'USD',
        );
        addTearDown(device.dispose);
        final saved = await householdExport(household: device);
        for (final expiry in [-1, 9007199254740992]) {
          await expectLater(
            sign(device, expiry: expiry),
            throwsA(
              expiry < 0
                  ? 'Invalid request expiry.'
                  : 'invalid or noncanonical relay request fields',
            ),
          );
          expect(await householdExport(household: device), saved);
        }
      },
    );
  }, skip: library == null ? 'Requires the built native Rust library' : false);
}
