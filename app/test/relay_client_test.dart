import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:private_ledger/features/household/relay_client.dart';

const _group = '0123456789abcdef0123456789abcdef';
const _mailbox = 'fedcba9876543210fedcba9876543210';

http.Response _json(int status, Object body) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  test('append sends the expected tail and returns the new sequence', () async {
    late http.Request seen;
    final client = HttpRelayClient(
      'https://relay.example/',
      MockClient((request) async {
        seen = request;
        return _json(200, {'seq': 8});
      }),
    );

    final sequence = await client.append(_group, 7, Uint8List.fromList([1, 2, 3]));

    expect(sequence, 8);
    expect(seen.method, 'POST');
    expect(seen.url.toString(), 'https://relay.example/g/$_group/append');
    expect(jsonDecode(seen.body), {
      'expected_tail': 7,
      'blob': base64.encode([1, 2, 3]),
    });
  });

  test('a stale append is a RelayConflict carrying the current tail', () async {
    final client = HttpRelayClient(
      'https://relay.example',
      MockClient((_) async => _json(409, {'tail': 12})),
    );
    await expectLater(
      client.append(_group, 7, Uint8List(1)),
      throwsA(isA<RelayConflict>().having((e) => e.tail, 'tail', 12)),
    );
  });

  test('server errors and network failures are RelayUnavailable', () async {
    final failing = HttpRelayClient(
      'https://relay.example',
      MockClient((_) async => _json(500, {'error': 'boom'})),
    );
    await expectLater(
      failing.append(_group, 0, Uint8List(1)),
      throwsA(isA<RelayUnavailable>()),
    );
    await expectLater(failing.readAfter(_group, 0), throwsA(isA<RelayUnavailable>()));

    final offline = HttpRelayClient(
      'https://relay.example',
      MockClient((_) async => throw http.ClientException('no route')),
    );
    await expectLater(offline.readAfter(_group, 0), throwsA(isA<RelayUnavailable>()));
  });

  test('readAfter follows pages until the relay says there is no more', () async {
    final requested = <String>[];
    final client = HttpRelayClient(
      'https://relay.example',
      MockClient((request) async {
        requested.add(request.url.toString());
        final after = int.parse(request.url.queryParameters['after']!);
        if (after == 0) {
          return _json(200, {
            'entries': [
              {'seq': 1, 'blob': base64.encode([1])},
              {'seq': 2, 'blob': base64.encode([2])},
            ],
            'tail': 3,
            'more': true,
          });
        }
        return _json(200, {
          'entries': [
            {'seq': 3, 'blob': base64.encode([3])},
          ],
          'tail': 3,
          'more': false,
        });
      }),
    );

    final entries = await client.readAfter(_group, 0);

    expect(entries.map((e) => e.sequence), [1, 2, 3]);
    expect(entries.map((e) => e.blob.first), [1, 2, 3]);
    expect(requested, [
      'https://relay.example/g/$_group?after=0',
      'https://relay.example/g/$_group?after=2',
    ]);
  });

  test('a malformed reply is RelayUnavailable, not a crash', () async {
    for (final body in [
      <String, Object?>{'entries': 'nope', 'more': false},
      {
        'entries': [
          {'seq': 'x', 'blob': 'AA=='},
        ],
        'more': false,
      },
      {
        'entries': [
          {'seq': 1, 'blob': '***'},
        ],
        'more': false,
      },
    ]) {
      final client = HttpRelayClient(
        'https://relay.example',
        MockClient((_) async => _json(200, body)),
      );
      await expectLater(client.readAfter(_group, 0), throwsA(isA<RelayUnavailable>()));
    }
  });

  test('mailboxes: put sends the item, take returns it once then null', () async {
    final puts = <Map<String, dynamic>>[];
    var taken = false;
    final client = HttpRelayClient(
      'https://relay.example',
      MockClient((request) async {
        if (request.method == 'PUT') {
          puts.add(jsonDecode(request.body) as Map<String, dynamic>);
          return _json(200, {'ok': true});
        }
        if (taken) {
          return _json(404, {'error': 'empty mailbox'});
        }
        taken = true;
        return _json(200, {
          'group': _group,
          'joined_after': 4,
          'welcome': base64.encode([9, 9]),
        });
      }),
    );

    await client.putMailbox(_mailbox, _group, 4, Uint8List.fromList([9, 9]));
    expect(puts.single, {
      'group': _group,
      'joined_after': 4,
      'welcome': base64.encode([9, 9]),
    });

    final item = await client.takeMailbox(_mailbox);
    expect(item!.group, _group);
    expect(item.joinedAfter, 4);
    expect(item.welcome, [9, 9]);
    expect(await client.takeMailbox(_mailbox), isNull);
  });

  group('MemoryRelayClient (the test double must obey the same contract)', () {
    test('is an ordered compare-and-swap log', () async {
      final relay = MemoryRelayClient();
      expect(await relay.append(_group, 0, Uint8List.fromList([1])), 1);
      expect(await relay.append(_group, 1, Uint8List.fromList([2])), 2);
      await expectLater(
        relay.append(_group, 1, Uint8List.fromList([3])),
        throwsA(isA<RelayConflict>().having((e) => e.tail, 'tail', 2)),
      );
      final after = await relay.readAfter(_group, 1);
      expect(after.map((e) => e.sequence), [2]);
      expect(await relay.readAfter('other', 0), isEmpty);
    });

    test('hands a mailbox item out exactly once', () async {
      final relay = MemoryRelayClient();
      await relay.putMailbox(_mailbox, _group, 1, Uint8List.fromList([7]));
      expect((await relay.takeMailbox(_mailbox))!.welcome, [7]);
      expect(await relay.takeMailbox(_mailbox), isNull);
    });
  });
}
