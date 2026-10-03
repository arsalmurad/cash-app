import 'dart:async';
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
  test(
    'each page requests its own proof for the exact continuation URL',
    () async {
      var proofs = 0;
      final urls = <Uri>[];
      final client = HttpRelayClient(
        'https://relay.example',
        MockClient((request) async {
          urls.add(request.url);
          expect(request.headers['x-cash-device-proof'], 'page-$proofs');
          final after = int.parse(request.url.queryParameters['after']!);
          return _json(200, {
            'entries': [
              {'seq': after + 1, 'blob': 'AQ=='},
            ],
            'tail': 2,
            'more': after == 0,
          });
        }),
        (method, url, body) async {
          expect(method, 'GET');
          expect(body, isEmpty);
          expect(url.queryParameters['after'], proofs.toString());
          return 'page-${++proofs}';
        },
      );
      expect(
        (await client.readAfter(_group, 0)).map((entry) => entry.sequence),
        [1, 2],
      );
      expect(proofs, 2);
      expect(urls.map((url) => url.queryParameters['after']), ['0', '1']);
    },
  );

  test(
    'a signing deadline prevents later transmission when the callback finishes',
    () async {
      final proof = Completer<String>();
      var requests = 0;
      final client = HttpRelayClient(
        'https://relay.example',
        MockClient((_) async {
          requests++;
          return _json(200, {'seq': 1});
        }),
        (_, _, _) => proof.future,
      );
      await expectLater(
        client.append(_group, 0, Uint8List(1)),
        throwsA(
          isA<RelayUnavailable>().having(
            (error) => error.message,
            'trusted error',
            'Could not authenticate the relay request. No request sent.',
          ),
        ),
      );
      expect(requests, 0);
      proof.complete('late-proof');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(requests, 0);
    },
  );

  test(
    'signed transport binds exact method, URL and sent bytes on every route',
    () async {
      final signed = <({String method, Uri url, List<int> bytes})>[];
      final sent = <http.Request>[];
      final client = HttpRelayClient(
        'https://relay.example',
        MockClient((request) async {
          sent.add(request);
          expect(
            request.headers['x-cash-device-proof'],
            'proof-${sent.length}',
          );
          final input = signed[sent.length - 1];
          expect(request.method, input.method);
          expect(request.url, input.url);
          expect(request.bodyBytes, input.bytes);
          if (request.url.path.endsWith('/append')) {
            return _json(200, {'seq': 1});
          }
          if (request.url.path.startsWith('/g/')) {
            return _json(200, {'entries': [], 'tail': 0, 'more': false});
          }
          return request.method == 'GET' || request.url.path.endsWith('/take')
              ? _json(404, {})
              : _json(200, {'ok': true});
        }),
        (method, url, body) async {
          signed.add((method: method, url: url, bytes: body.toList()));
          // The callback cannot change the request bytes after receiving them.
          if (body.isNotEmpty) body[0] ^= 1;
          return 'proof-${signed.length}';
        },
      );
      await client.append(_group, 0, Uint8List.fromList([0, 255]));
      await client.readAfter(_group, 0);
      await client.putMailbox(_mailbox, _group, 1, Uint8List.fromList([128]));
      await client.peekMailbox(_mailbox);
      await client.takeMailbox(_mailbox);
      await client.acknowledgeMailbox(_mailbox);
      expect(sent.length, 6);
      expect(signed.map((value) => value.method), [
        'POST',
        'GET',
        'PUT',
        'GET',
        'POST',
        'POST',
      ]);
    },
  );

  test(
    'signer errors and unusable proof headers never send or retry unsigned',
    () async {
      for (final failure in [
        'private diagnostic',
        StateError('private diagnostic'),
        '',
        'x' * 1025,
        'bad\nheader',
      ]) {
        var requests = 0;
        final client = HttpRelayClient(
          'https://relay.example',
          MockClient((_) async {
            requests++;
            return _json(200, {});
          }),
          (_, _, _) async {
            if (failure == 'private diagnostic' || failure is StateError) {
              throw failure;
            }
            return failure as String;
          },
        );
        for (final operation in <Future<void> Function()>[
          () async {
            await client.append(_group, 0, Uint8List(1));
          },
          () async {
            await client.readAfter(_group, 0);
          },
          () => client.acknowledgeMailbox(_mailbox),
        ]) {
          await expectLater(
            operation(),
            throwsA(
              isA<RelayUnavailable>().having(
                (error) => error.message,
                'trusted error',
                'Could not authenticate the relay request. No request sent.',
              ),
            ),
          );
        }
        expect(requests, 0);
      }
    },
  );

  test(
    'confirmed pages survive later refusal but list reads remain atomic',
    () async {
      final confirmed = <int>[];
      final client = HttpRelayClient(
        'https://relay.example',
        MockClient((request) async {
          if (request.url.queryParameters['after'] != '0') {
            return _json(429, {});
          }
          return _json(200, {
            'entries': [
              {'seq': 1, 'blob': 'YQ=='},
            ],
            'tail': 2,
            'more': true,
          });
        }),
      );
      await expectLater(
        client.readConfirmedPages(_group, 0, (page) async {
          confirmed.addAll(page.map((entry) => entry.sequence));
        }),
        throwsA(isA<RelayUnavailable>()),
      );
      expect(confirmed, [1]);
      await expectLater(
        client.readAfter(_group, 0),
        throwsA(isA<RelayUnavailable>()),
      );
    },
  );

  test('a malformed page never reaches the durable consumer', () async {
    var delivered = false;
    final client = HttpRelayClient(
      'https://relay.example',
      MockClient(
        (_) async => _json(200, {
          'entries': [
            {'seq': 1, 'blob': 'YQ=='},
            {'seq': 3, 'blob': 'Yg=='},
          ],
          'tail': 3,
          'more': false,
        }),
      ),
    );
    await expectLater(
      client.readConfirmedPages(_group, 0, (_) async {
        delivered = true;
      }),
      throwsA(isA<RelayUnavailable>()),
    );
    expect(delivered, isFalse);
  });

  test(
    'the next page waits for confirmation and stops on consumer failure',
    () async {
      var requests = 0;
      final saved = Completer<void>();
      final entered = Completer<void>();
      final failure = StateError('uncertain save');
      final client = HttpRelayClient(
        'https://relay.example',
        MockClient((_) async {
          requests++;
          return _json(200, {
            'entries': [
              {'seq': 1, 'blob': 'YQ=='},
            ],
            'tail': 2,
            'more': true,
          });
        }),
      );
      final read = client.readConfirmedPages(_group, 0, (_) async {
        entered.complete();
        await saved.future;
        throw failure;
      });
      final checked = expectLater(read, throwsA(same(failure)));
      await entered.future;
      expect(requests, 1);
      saved.complete();
      await checked;
      expect(requests, 1);
    },
  );

  test('read accepts exactly the response ceiling and refuses larger declared bodies', () async {
    const limit = 6 * 1024 * 1024;
    final json = jsonEncode({'entries': [], 'tail': 0, 'more': false});
    final exact = Uint8List.fromList(
      utf8.encode(json + ' ' * (limit - json.length)),
    );
    final client = HttpRelayClient(
      'https://relay.example',
      MockClient.streaming(
        (_, _) async => http.StreamedResponse(
          Stream.value(exact),
          200,
          contentLength: limit,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );
    expect(await client.readAfter(_group, 0), isEmpty);

    var aborted = false;
    var listened = false;
    final stream = StreamController<List<int>>(
      onListen: () {
        listened = true;
      },
    );
    final oversized = HttpRelayClient(
      'https://relay.example',
      MockClient.streaming((request, _) async {
        (request as http.AbortableRequest).abortTrigger!.then((_) {
          aborted = true;
        });
        return http.StreamedResponse(
          stream.stream,
          200,
          contentLength: limit + 1,
        );
      }),
    );
    await expectLater(
      oversized.readAfter(_group, 0),
      throwsA(isA<RelayUnavailable>()),
    );
    expect(aborted, isTrue);
    expect(
      listened,
      isFalse,
      reason: 'Declared oversize is refused before reading the body',
    );
    final closed = stream.close();
    await stream.stream.drain<void>();
    await closed;
  });

  test(
    'read refuses an initial backfill beyond its finite entry budget',
    () async {
      var requests = 0;
      final client = HttpRelayClient(
        'https://relay.example',
        MockClient((_) async {
          requests++;
          return _json(200, {
            'entries': [
              {'seq': 1, 'blob': 'YQ=='},
            ],
            'tail': 10001,
            'more': true,
          });
        }),
      );
      await expectLater(
        client.readAfter(_group, 0),
        throwsA(
          isA<RelayUnavailable>().having(
            (error) => error.message,
            'message',
            contains('entry limit'),
          ),
        ),
      );
      expect(requests, 1);
    },
  );

  test('read response is cancelled at its actual byte limit despite a small declared length', () async {
    var cancelled = false;
    late StreamController<List<int>> stream;
    stream = StreamController<List<int>>(
      onListen: () => stream.add(Uint8List(6 * 1024 * 1024 + 1)),
      onCancel: () {
        cancelled = true;
      },
    );
    final client = HttpRelayClient(
      'https://relay.example',
      MockClient.streaming(
        (_, _) async => http.StreamedResponse(
          stream.stream,
          200,
          contentLength: 1,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );
    await expectLater(
      client.readAfter(_group, 0),
      throwsA(
        isA<RelayUnavailable>().having(
          (error) => error.message,
          'message',
          contains('size limit'),
        ),
      ),
    );
    expect(cancelled, isTrue);
    await stream.close();
  });

  test('invalid pages fail before a retry or partial history is returned', () async {
    final cases = <Map<String, Object?>>[
      {'entries': [], 'tail': 1, 'more': true},
      {'entries': [], 'tail': 1, 'more': false},
      {'entries': [], 'tail': -1, 'more': false},
      {'entries': [], 'tail': 0},
      {'entries': [], 'tail': 0, 'more': 'false'},
      {
        'entries': [
          {'seq': 2, 'blob': 'YQ=='},
        ],
        'tail': 2,
        'more': false,
      },
      {
        'entries': [
          {'seq': 1, 'blob': 'YQ=='},
          {'seq': 1, 'blob': 'YQ=='},
        ],
        'tail': 1,
        'more': false,
      },
      {
        'entries': [
          {'seq': 1, 'blob': 'YQ=='},
        ],
        'tail': 0,
        'more': false,
      },
      {
        'entries': [
          {'seq': 1, 'blob': 'YQ=='},
        ],
        'tail': 2,
        'more': false,
      },
      {
        'entries': [
          {'seq': 1, 'blob': 'YQ=='},
        ],
        'tail': 1,
        'more': true,
      },
      {
        'entries': [
          {'seq': 1, 'blob': ''},
        ],
        'tail': 1,
        'more': false,
      },
    ];
    for (final page in cases) {
      var requests = 0;
      final client = HttpRelayClient(
        'https://relay.example',
        MockClient((_) async {
          requests++;
          // Keep the pre-fix failure finite instead of hanging the test runner.
          return requests == 1 ? _json(200, page) : _json(500, {});
        }),
      );
      await expectLater(
        client.readAfter(_group, 0),
        throwsA(isA<RelayUnavailable>()),
      );
      expect(
        requests,
        1,
        reason: 'Reject malformed page before following more',
      );
    }
  });

  test(
    'tail rollback and sequence gaps between valid-looking pages fail',
    () async {
      for (final second in [
        {
          'entries': [
            {'seq': 2, 'blob': 'Yg=='},
          ],
          'tail': 2,
          'more': false,
        },
        {
          'entries': [
            {'seq': 3, 'blob': 'Yg=='},
          ],
          'tail': 3,
          'more': false,
        },
      ]) {
        var requests = 0;
        final client = HttpRelayClient(
          'https://relay.example',
          MockClient((_) async {
            requests++;
            return _json(
              200,
              requests == 1
                  ? {
                      'entries': [
                        {'seq': 1, 'blob': 'YQ=='},
                      ],
                      'tail': 3,
                      'more': true,
                    }
                  : second,
            );
          }),
        );
        await expectLater(
          client.readAfter(_group, 0),
          throwsA(isA<RelayUnavailable>()),
        );
        expect(requests, 2);
      }
    },
  );

  test(
    'valid paging accepts concurrent tail growth without skipping entries',
    () async {
      var requests = 0;
      final client = HttpRelayClient(
        'https://relay.example',
        MockClient((request) async {
          requests++;
          if (request.url.queryParameters['after'] == '2') {
            return _json(200, {
              'entries': [
                {'seq': 3, 'blob': 'Yw=='},
              ],
              'tail': 3,
              'more': false,
            });
          }
          expect(
            request.url.queryParameters['after'],
            requests == 1 ? '0' : '1',
          );
          return _json(
            200,
            requests == 1
                ? {
                    'entries': [
                      {'seq': 1, 'blob': 'YQ=='},
                    ],
                    'tail': 2,
                    'more': true,
                  }
                : {
                    'entries': [
                      {'seq': 2, 'blob': 'Yg=='},
                      {'seq': 3, 'blob': 'Yw=='},
                    ],
                    'tail': 3,
                    'more': false,
                  },
          );
        }),
      );
      final entries = await client.readAfter(_group, 0);
      expect(entries.map((entry) => entry.sequence), [1, 2]);
      expect(entries.map((entry) => entry.blob.single), [97, 98]);
      expect(requests, 2);
      final later = await client.readAfter(_group, 2);
      expect(later.map((entry) => entry.sequence), [3]);
      expect(requests, 3);
    },
  );

  test('capacity refusal has safe actionable copy and ignores server text', () async {
    final client = HttpRelayClient(
      'https://relay.example',
      MockClient(
        (_) async => _json(507, {'error': 'Delete your household now'}),
      ),
    );
    await expectLater(
      client.append(_group, 0, Uint8List(1)),
      throwsA(
        isA<RelayUnavailable>().having(
          (error) => error.toString(),
          'message',
          'Household relay storage is full. Keep this household on your device '
              'and contact the relay operator before trying Sync again.',
        ),
      ),
    );
  });

  test('append sends the expected tail and returns the new sequence', () async {
    late http.Request seen;
    final client = HttpRelayClient(
      'https://relay.example/',
      MockClient((request) async {
        seen = request;
        return _json(200, {'seq': 8});
      }),
    );

    final sequence = await client.append(
      _group,
      7,
      Uint8List.fromList([1, 2, 3]),
    );

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
    await expectLater(
      failing.readAfter(_group, 0),
      throwsA(isA<RelayUnavailable>()),
    );

    final offline = HttpRelayClient(
      'https://relay.example',
      MockClient((_) async => throw http.ClientException('no route')),
    );
    await expectLater(
      offline.readAfter(_group, 0),
      throwsA(isA<RelayUnavailable>()),
    );
  });

  test(
    'readAfter follows pages until the relay says there is no more',
    () async {
      final requested = <String>[];
      final client = HttpRelayClient(
        'https://relay.example',
        MockClient((request) async {
          requested.add(request.url.toString());
          final after = int.parse(request.url.queryParameters['after']!);
          if (after == 0) {
            return _json(200, {
              'entries': [
                {
                  'seq': 1,
                  'blob': base64.encode([1]),
                },
                {
                  'seq': 2,
                  'blob': base64.encode([2]),
                },
              ],
              'tail': 3,
              'more': true,
            });
          }
          return _json(200, {
            'entries': [
              {
                'seq': 3,
                'blob': base64.encode([3]),
              },
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
    },
  );

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
      await expectLater(
        client.readAfter(_group, 0),
        throwsA(isA<RelayUnavailable>()),
      );
    }
  });

  test(
    'mailboxes: put sends the item, take returns it once then null',
    () async {
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
    },
  );

  group('MemoryRelayClient (the test double must obey the same contract)', () {
    test(
      'retrieval is repeatable until an idempotent acknowledgement',
      () async {
        final relay = MemoryRelayClient();
        await relay.acknowledgeMailbox(_mailbox);
        await relay.putMailbox(_mailbox, _group, 1, Uint8List.fromList([7]));
        expect((await relay.peekMailbox(_mailbox))!.welcome, [7]);
        expect((await relay.peekMailbox(_mailbox))!.welcome, [7]);
        await relay.acknowledgeMailbox(_mailbox);
        await relay.acknowledgeMailbox(_mailbox);
        await relay.putMailbox(_mailbox, _group, 1, Uint8List.fromList([7]));
        expect(await relay.peekMailbox(_mailbox), isNull);
      },
    );
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
      expect(await relay.takeMailbox(_mailbox), isNull);
      await relay.putMailbox(_mailbox, _group, 1, Uint8List.fromList([7]));
      await relay.putMailbox(_mailbox, _group, 1, Uint8List.fromList([7]));
      expect((await relay.takeMailbox(_mailbox))!.welcome, [7]);
      await relay.putMailbox(_mailbox, _group, 1, Uint8List.fromList([7]));
      expect(await relay.takeMailbox(_mailbox), isNull);
      await expectLater(
        relay.putMailbox(_mailbox, _group, 2, Uint8List.fromList([7])),
        throwsA(isA<RelayUnavailable>()),
      );
    });
  });

  test('HTTP retrieval uses GET and a separate POST acknowledgement', () async {
    final methods = <String>[];
    final client = HttpRelayClient(
      'https://relay.test',
      MockClient((request) async {
        methods.add('${request.method} ${request.url.path}');
        if (request.method == 'GET') {
          return _json(200, {
            'group': _group,
            'joined_after': 1,
            'welcome': base64.encode([7]),
          });
        }
        return _json(200, {'ok': true});
      }),
    );
    expect((await client.peekMailbox(_mailbox))!.welcome, [7]);
    await client.acknowledgeMailbox(_mailbox);
    expect(methods, ['GET /m/$_mailbox', 'POST /m/$_mailbox/ack']);
  });
}
