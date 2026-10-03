import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:private_ledger/features/household/relay_client.dart';
import 'package:private_ledger/features/household/relay_policy.dart';

const origin = 'https://relay.example';
const group = '0123456789abcdef0123456789abcdef';
final a = '01' * 32;
final b = '02' * 32;
final c = '03' * 32;
Map<String, Object?> policy() => {
  'version': 2,
  'epoch': 0,
  'scope': {'origin': origin, 'kind': 'g', 'id': group},
  'devices': [
    {
      'key': a,
      'operations': ['append', 'membership', 'read'],
    },
    {
      'key': b,
      'operations': ['read'],
    },
  ],
};
RelayAuthorizationPolicy parse(Object? value) =>
    RelayAuthorizationPolicy.fromJson(value, origin: origin, group: group);

void main() {
  test(
    'roster transport refuses unsafe addresses before proof or network',
    () async {
      var requests = 0;
      var proofs = 0;
      for (final base in [
        'http://relay.example',
        'https://user@relay.example',
        'https://relay.example/base',
        'https://relay.example#fragment',
      ]) {
        final client = HttpRelayClient(
          base,
          MockClient((request) async {
            requests++;
            return http.Response('{}', 200);
          }),
          (method, uri, body) async {
            proofs++;
            return 'proof';
          },
          true,
        );
        await expectLater(
          client.readPolicy(group),
          throwsA(isA<RelayUnavailable>()),
        );
      }
      final notEnabled = HttpRelayClient(
        origin,
        MockClient((request) async {
          requests++;
          return http.Response('{}', 200);
        }),
        (method, uri, body) async {
          proofs++;
          return 'proof';
        },
      );
      await expectLater(
        notEnabled.readPolicy(group),
        throwsA(isA<RelayUnavailable>()),
      );
      expect(requests, 0);
      expect(proofs, 0);
    },
  );

  test(
    'membership conflict and failure replies never falsely confirm',
    () async {
      for (final status in [401, 403, 409, 429, 503, 507, 200]) {
        final client = HttpRelayClient(
          origin,
          MockClient(
            (request) async => http.Response(
              jsonEncode({'error': 'private remote diagnostic', 'seq': 99}),
              status,
            ),
          ),
          (method, uri, body) async => 'public-proof',
          true,
        );
        await expectLater(
          client.appendMembership(
            group,
            0,
            Uint8List.fromList([1]),
            parse(policy()).nextForRosterKeys([a]),
          ),
          throwsA(
            isA<RelayUnavailable>().having(
              (error) => error.message,
              'trusted message',
              isNot(contains('private remote diagnostic')),
            ),
          ),
        );
      }
      final conflict = HttpRelayClient(
        origin,
        MockClient((request) async => http.Response('{"tail":12}', 409)),
        (method, uri, body) async => 'proof',
        true,
      );
      await expectLater(
        conflict.appendMembership(
          group,
          0,
          Uint8List.fromList([1]),
          parse(policy()).nextForRosterKeys([a]),
        ),
        throwsA(isA<RelayConflict>().having((error) => error.tail, 'tail', 12)),
      );
    },
  );

  test(
    'policy replies reject extra fields, bad scope and malformed JSON',
    () async {
      for (final body in [
        'not json',
        jsonEncode({'policy': policy(), 'amount': 100}),
        jsonEncode({
          'policy': {
            ...policy(),
            'scope': {
              'origin': 'https://other.example',
              'kind': 'g',
              'id': group,
            },
          },
        }),
      ]) {
        final client = HttpRelayClient(
          origin,
          MockClient((request) async => http.Response(body, 200)),
          (method, uri, bytes) async => 'proof',
          true,
        );
        await expectLater(
          client.readPolicy(group),
          throwsA(isA<RelayUnavailable>()),
        );
      }
    },
  );
  test('public policy is exact, immutable and preserves existing grants', () {
    final raw = policy();
    final value = parse(raw);
    expect(value.toJson(), raw);
    final next = value.nextForRosterKeys([c, b, a]);
    expect(next.epoch, 1);
    expect(next.devices.map((device) => device.key), [a, b, c]);
    expect(next.devices[1].operations, ['read']);
    expect(next.devices[2].operations, ['append', 'membership', 'read']);
    expect(() => value.devices.clear(), throwsUnsupportedError);
    expect(
      () => value.devices.first.operations.clear(),
      throwsUnsupportedError,
    );
    (raw['devices'] as List).clear();
    expect(value.devices, hasLength(2));
    final serialized = value.toJson();
    (serialized['devices'] as List).clear();
    expect(value.devices, hasLength(2));
    for (final keys in [
      <String>[],
      [a, a],
      ['bad'],
      List.generate(65, (index) => index.toRadixString(16).padLeft(64, '0')),
      [b],
    ]) {
      expect(() => value.nextForRosterKeys(keys), throwsFormatException);
    }
  });

  test('malformed, foreign or financial policy fields are refused', () {
    for (final raw in [
      null,
      {},
      {...policy(), 'amount': 2050},
      {...policy(), 'version': 2.0},
      {...policy(), 'epoch': -1},
      {...policy(), 'epoch': 9007199254740992},
      {
        ...policy(),
        'scope': {'origin': 'https://other.example', 'kind': 'g', 'id': group},
      },
      {
        ...policy(),
        'scope': {'origin': origin, 'kind': 'm', 'id': group},
      },
      {
        ...policy(),
        'devices': [
          {
            'key': a,
            'operations': ['read', 'append'],
          },
        ],
      },
      {
        ...policy(),
        'devices': [
          {
            'key': a,
            'operations': ['append', 'membership', 'read'],
            'name': 'private',
          },
        ],
      },
      {
        ...policy(),
        'devices': [
          {
            'key': a,
            'operations': ['read'],
          },
        ],
      },
    ]) {
      expect(() => parse(raw), throwsFormatException);
    }
    expect(
      () =>
          parse({...policy(), 'epoch': 9007199254740991})
              .nextForRosterKeys([a]),
      throwsFormatException,
    );
  });

  test('membership transport signs exact bytes and confirms only the expected slot', () async {
    final sent = <http.Request>[];
    final signed = <String>[];
    final client = HttpRelayClient(
      origin,
      MockClient((request) async {
        sent.add(request);
        expect(
          request.headers['x-cash-device-proof'],
          'proof-${signed.length}',
        );
        if (request.method == 'GET') {
          return http.Response(jsonEncode({'policy': policy()}), 200);
        }
        expect(request.url.path, '/g/$group/membership');
        expect(request.body, signed.last);
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body.keys.toSet(), {'expected_tail', 'blob', 'policy'});
        expect(body['blob'], 'AP+A');
        expect(body['policy']['epoch'], 1);
        return http.Response('{"seq":1}', 200);
      }),
      (method, uri, body) async {
        signed.add(utf8.decode(body));
        body.fillRange(
          0,
          body.length,
          0,
        ); // Defensive signer copy cannot alter wire.
        return 'proof-${signed.length}';
      },
      true,
    );
    final current = await client.readPolicy(group);
    expect(
      await client.appendMembership(
        group,
        0,
        Uint8List.fromList([0, 255, 128]),
        current.nextForRosterKeys([a, c]),
      ),
      1,
    );
    expect(sent, hasLength(2));
    expect(signed.first, '');
  });

  test(
    'unsigned or non-opted-in clients cannot start roster requests',
    () async {
      var requests = 0;
      for (final enabled in [false, true]) {
        final client = HttpRelayClient(
          origin,
          MockClient((request) async {
            requests++;
            return http.Response('{}', 200);
          }),
          null,
          enabled,
        );
        await expectLater(
          client.readPolicy(group),
          throwsA(isA<RelayUnavailable>()),
        );
        await expectLater(
          client.appendMembership(
            group,
            0,
            Uint8List.fromList([1]),
            parse(policy()).nextForRosterKeys([a]),
          ),
          throwsA(isA<RelayUnavailable>()),
        );
      }
      expect(requests, 0);
    },
  );
}
