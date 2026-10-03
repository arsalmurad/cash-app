import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/data/storage/blob_store.dart';
import 'package:private_ledger/features/household/household_controller.dart';
import 'package:private_ledger/features/household/relay_client.dart';
import 'package:private_ledger/features/household/relay_config.dart';

class _Store implements BlobStore {
  Uint8List? value;
  int writes = 0;

  @override
  Future<Uint8List?> read() async => value;
  @override
  Future<void> write(Uint8List bytes) async {
    writes++;
    value = Uint8List.fromList(bytes);
  }

  @override
  Future<void> delete() async => value = null;
}

void main() {
  test(
    'authenticated settings survive restart without constructing requests',
    () async {
      final config = _Store();
      final first = HouseholdController(
        stateStore: _Store(),
        configStore: config,
      );
      await first.initialize();
      expect(
        await first.setRelayUrl('https://relay.test', authenticated: true),
        isTrue,
      );
      expect(first.authenticatedRelay, isTrue);
      expect(decodeRelaySettings(config.value!).authenticated, isTrue);
      first.dispose();
      final restored = HouseholdController(
        stateStore: _Store(),
        configStore: config,
      );
      addTearDown(restored.dispose);
      await restored.initialize();
      expect(restored.authenticatedRelay, isTrue);
      expect(restored.relayUrl, 'https://relay.test');
      expect(config.writes, 1);
    },
  );
  test('authenticated mode refuses unsafe origins and ambiguous saved flags', () {
    for (final address in [
      'http://relay.test',
      'https://user@relay.test',
      'https://relay.test/path',
      'https://relay.test?x=1',
      'https://relay.test#x',
    ]) {
      expect(
        () => encodeRelayConfig(address, authenticated: true),
        throwsFormatException,
      );
    }
    for (final value in ['"true"', '1', 'null']) {
      expect(
        () => decodeRelaySettings(
          Uint8List.fromList(
            utf8.encode(
              'cash-app relay config v2\u0000{"relay":"https://relay.test","authenticated":$value}',
            ),
          ),
        ),
        throwsFormatException,
      );
    }
    expect(
      decodeRelaySettings(
        encodeRelayConfig('http://127.0.0.1:8787', authenticated: true),
      ).authenticated,
      isTrue,
    );
    expect(
      decodeRelaySettings(encodeRelayConfig('https://relay.test'))
          .authenticated,
      isFalse,
    );
  });
  for (final address in [
    'https://relay.test',
    'https://relay.test/چائے/🍵',
    'https://relay.test/café',
  ]) {
    test('relay configuration preserves $address across restart', () async {
      final config = _Store();
      final observed = <String>[];
      HouseholdController device() => HouseholdController(
        stateStore: _Store(),
        configStore: config,
        relayFactory: (url) {
          observed.add(url);
          return MemoryRelayClient();
        },
      );
      final first = device();
      addTearDown(first.dispose);
      await first.initialize();
      expect(await first.setRelayUrl(address), isTrue);
      final restart = device();
      addTearDown(restart.dispose);
      await restart.initialize();
      expect(restart.errorMessage, isNull);
      expect(restart.relayUrl, address);
      expect(observed, [address, address]);
      expect(
        config.writes,
        1,
        reason: 'Reading must not rewrite configuration',
      );
    });
  }

  for (final address in [
    'https://relay.test',
    'https://relay.test/café',
    'https://relay.test/Ã©',
  ]) {
    test('legacy byte configuration remains exact: $address', () {
      final bytes = Uint8List.fromList(address.codeUnits);
      expect(decodeRelayConfig(bytes), address);
      expect(decodeRelayConfig(encodeRelayConfig(address)), address);
    });
  }

  for (final damaged in [
    Uint8List.fromList(utf8.encode('file:///not-a-relay')),
    Uint8List.fromList(utf8.encode('cash-app relay config v2\u0000{}')),
    Uint8List.fromList(
      utf8.encode('cash-app relay config v1\u0000{"relay":3}'),
    ),
    Uint8List.fromList(
      utf8.encode('cash-app relay config v1\u0000{"relay":"file:///no"}'),
    ),
    Uint8List.fromList([
      ...utf8.encode('cash-app relay config v1\u0000'),
      0xff,
    ]),
    Uint8List.fromList(utf8.encode('cash-app relay config v1\u0000{"relay":')),
  ]) {
    test(
      'damaged configuration cannot make requests or overwrite saved bytes: ${damaged.length}',
      () async {
        expect(() => decodeRelayConfig(damaged), throwsFormatException);
        final config = _Store()..value = damaged;
        var clients = 0;
        final controller = HouseholdController(
          stateStore: _Store(),
          configStore: config,
          relayFactory: (_) {
            clients++;
            return MemoryRelayClient();
          },
        );
        addTearDown(controller.dispose);
        await controller.initialize();
        expect(controller.errorMessage, isNotNull);
        expect(clients, 0);
        expect(await controller.setRelayUrl('https://relay.test'), isFalse);
        expect(config.writes, 0);
        expect(config.value, damaged);
      },
    );
  }
}
