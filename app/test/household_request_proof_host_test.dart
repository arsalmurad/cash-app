import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/data/rust/api/shared.dart';
import 'package:private_ledger/data/rust/frb_generated.dart';

void main() {
  final library = Platform.environment['RUST_LIB_PATH'];
  group('public request proofs through the native bridge', () {
    setUpAll(
      () async => RustLib.init(externalLibrary: ExternalLibrary.open(library!)),
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
