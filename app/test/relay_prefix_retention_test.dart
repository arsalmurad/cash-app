import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:private_ledger/features/household/relay_client.dart';

const group = '0123456789abcdef0123456789abcdef';
void main() {
  test(
    'pruning signs exact consent bytes and validates bounded progress',
    () async {
      final source = Uint8List.fromList([1, 2]);
      final client = HttpRelayClient(
        'https://relay.example',
        MockClient((request) async {
          expect(request.url.path, '/g/$group/prune');
          expect(request.headers['x-cash-device-proof'], 'proof');
          expect(jsonDecode(request.body), {
            'expectedFloor': 0,
            'through': 33,
            'consents': ['0102'],
          });
          return http.Response(
            jsonEncode({'floor': 16, 'tail': 35, 'more': true}),
            200,
          );
        }),
        (method, url, body) async {
          expect(method, 'POST');
          source[0] = 9;
          expect(jsonDecode(utf8.decode(body))['consents'], ['0102']);
          return 'proof';
        },
        true,
      );
      final result = await client.prunePrefix(group, 0, 33, [source]);
      expect(result.floor, 16);
      expect(result.tail, 35);
      expect(result.more, isTrue);
      expect(result.conflict, isFalse);
    },
  );
  test('stale-floor conflict is distinct from permission refusal', () async {
    final client = HttpRelayClient(
      'https://relay.example',
      MockClient(
        (_) async => http.Response(
          jsonEncode({'conflict': true, 'floor': 16, 'tail': 35}),
          409,
        ),
      ),
      (_, _, _) async => 'proof',
      true,
    );
    final result = await client.prunePrefix(group, 0, 33, [Uint8List(1)]);
    expect(result.conflict, isTrue);
    expect(result.floor, 16);
    final refused = HttpRelayClient(
      'https://relay.example',
      MockClient((_) async => http.Response('{"error":"refused"}', 409)),
      (_, _, _) async => 'proof',
      true,
    );
    await expectLater(
      refused.prunePrefix(group, 0, 33, [Uint8List(1)]),
      throwsA(isA<RelayUnavailable>()),
    );
  });
  test('malformed success, oversized jumps and continuation cannot authorize more deletion', () async {
    for (final body in [
      {'floor': 17, 'tail': 35, 'more': true},
      {'floor': 16, 'tail': 35, 'more': false},
      {'floor': 16, 'tail': 15, 'more': true},
      {'floor': 16.5, 'tail': 35, 'more': true},
      {'floor': 16, 'tail': 35, 'more': true, 'extra': 'no'},
    ]) {
      final client = HttpRelayClient(
        'https://relay.example',
        MockClient((_) async => http.Response(jsonEncode(body), 200)),
        (_, _, _) async => 'proof',
        true,
      );
      await expectLater(
        client.prunePrefix(group, 0, 33, [Uint8List(1)]),
        throwsA(isA<RelayUnavailable>()),
      );
    }
  });
  test(
    'no unauthenticated fallback or invalid target is transmitted',
    () async {
      var sent = 0;
      final raw = MockClient((_) async {
        sent++;
        return http.Response('{}', 200);
      });
      final client = HttpRelayClient(
        'https://relay.example',
        raw,
        (_, _, _) async => 'proof',
        true,
      );
      await expectLater(
        HttpRelayClient(
          'https://relay.example',
          raw,
        ).prunePrefix(group, 0, 33, [Uint8List(1)]),
        throwsA(isA<RelayUnavailable>()),
      );
      for (final input in [
        (floor: -1, through: 33),
        (floor: 34, through: 33),
        (floor: 0, through: 0),
        (floor: 0, through: 1000000000000),
      ]) {
        await expectLater(
          client.prunePrefix(group, input.floor, input.through, [Uint8List(1)]),
          throwsA(isA<RelayUnavailable>()),
        );
      }
      await expectLater(
        client.prunePrefix(group, 0, 33, []),
        throwsA(isA<RelayUnavailable>()),
      );
      expect(sent, 0);
    },
  );
}
