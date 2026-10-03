import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:private_ledger/features/household/relay_client.dart';

final group = '01' * 16;
final mailbox = '02' * 16;
final recipient = '03' * 32;
void main() {
  test('scoped Welcome routes sign exact bytes with fresh proofs and explicit acknowledgement', () async {
    final signed = <String>[];
    final paths = <String>[];
    final client = HttpRelayClient(
      'https://relay.test',
      MockClient((request) async {
        paths.add(request.url.path);
        expect(request.body, signed.last);
        expect(
          request.headers['x-cash-device-proof'],
          'proof-${signed.length}',
        );
        if (request.method == 'PUT') {
          expect(jsonDecode(request.body), {
            'recipient': recipient,
            'joined_after': 1,
            'welcome': 'AP+A',
          });
          return http.Response('{"ok":true}', 200);
        }
        if (request.method == 'GET') {
          return http.Response(
            jsonEncode({'group': group, 'joined_after': 1, 'welcome': 'AP+A'}),
            200,
          );
        }
        expect(request.method, 'POST');
        expect(request.body, isEmpty);
        return http.Response('{"ok":true}', 200);
      }),
      (method, uri, body) async {
        signed.add(utf8.decode(body));
        body.fillRange(0, body.length, 0);
        return 'proof-${signed.length}';
      },
      true,
    );
    await client.putRosterWelcome(
      group,
      mailbox,
      recipient,
      1,
      Uint8List.fromList([0, 255, 128]),
    );
    final item = await client.peekRosterWelcome(group, mailbox);
    expect(item!.group, group);
    expect(item.joinedAfter, 1);
    expect(item.welcome, [0, 255, 128]);
    await client.acknowledgeRosterWelcome(group, mailbox);
    expect(paths, [
      '/g/$group/invite/$mailbox',
      '/g/$group/invite/$mailbox',
      '/g/$group/invite/$mailbox/ack',
    ]);
    expect(signed, hasLength(3));
  });

  test('invalid or disabled scoped delivery refuses before proof/network, with no legacy fallback', () async {
    var proofs = 0, requests = 0;
    HttpRelayClient client({bool enabled = true, bool signed = true}) =>
        HttpRelayClient(
          'https://relay.test',
          MockClient((_) async {
            requests++;
            return http.Response('{"ok":true}', 200);
          }),
          signed
              ? (method, uri, body) async {
                  proofs++;
                  return 'proof';
                }
              : null,
          enabled,
        );
    final enabled = client();
    for (final call in [
      () => enabled.putRosterWelcome(
        group,
        mailbox,
        'bad',
        1,
        Uint8List.fromList([1]),
      ),
      () => enabled.putRosterWelcome(
        group,
        'bad',
        recipient,
        1,
        Uint8List.fromList([1]),
      ),
      () => enabled.putRosterWelcome(
        group,
        mailbox,
        recipient,
        0,
        Uint8List.fromList([1]),
      ),
      () => enabled.putRosterWelcome(
        group,
        mailbox,
        recipient,
        9007199254740992,
        Uint8List.fromList([1]),
      ),
      () =>
          enabled.putRosterWelcome(group, mailbox, recipient, 1, Uint8List(0)),
      () => enabled.putRosterWelcome(
        group,
        mailbox,
        recipient,
        1,
        Uint8List(256 * 1024 + 1),
      ),
      () => client(enabled: false).peekRosterWelcome(group, mailbox),
      () => client(signed: false).peekRosterWelcome(group, mailbox),
      () => enabled.peekMailbox(mailbox),
      () => enabled.takeMailbox(mailbox),
      () => enabled.putMailbox(mailbox, group, 1, Uint8List.fromList([1])),
      () => enabled.acknowledgeMailbox(mailbox),
    ]) {
      await expectLater(call(), throwsA(isA<RelayUnavailable>()));
    }
    expect(proofs, 0);
    expect(requests, 0);
  });

  test(
    'malformed, financial and foreign Welcome replies cannot reach MLS',
    () async {
      for (final body in [
        'not json',
        jsonEncode({'group': '04' * 16, 'joined_after': 1, 'welcome': 'AQ=='}),
        jsonEncode({
          'group': group,
          'joined_after': 1,
          'welcome': 'AQ==',
          'amount': 2050,
        }),
        jsonEncode({'group': group, 'joined_after': 0, 'welcome': 'AQ=='}),
        jsonEncode({'group': group, 'joined_after': 1.0, 'welcome': 'AQ=='}),
        jsonEncode({'group': group, 'joined_after': 1, 'welcome': 'AA'}),
        jsonEncode({'group': group, 'joined_after': 1, 'welcome': ''}),
        jsonEncode({
          'group': group,
          'joined_after': 1,
          'welcome': base64.encode(Uint8List(256 * 1024 + 1)),
        }),
      ]) {
        final client = HttpRelayClient(
          'https://relay.test',
          MockClient((_) async => http.Response(body, 200)),
          (method, uri, body) async => 'proof',
          true,
        );
        await expectLater(
          client.peekRosterWelcome(group, mailbox),
          throwsA(isA<RelayUnavailable>()),
        );
      }
    },
  );

  test(
    'delivery failures never accept server instructions as trusted text',
    () async {
      for (final status in [401, 403, 409, 429, 503, 507, 200]) {
        final client = HttpRelayClient(
          'https://relay.test',
          MockClient(
            (_) async => http.Response(
              '{"ok":false,"error":"private diagnostic"}',
              status,
            ),
          ),
          (method, uri, body) async => 'proof',
          true,
        );
        for (final call in [
          () => client.putRosterWelcome(
            group,
            mailbox,
            recipient,
            1,
            Uint8List.fromList([1]),
          ),
          () => client.acknowledgeRosterWelcome(group, mailbox),
        ]) {
          await expectLater(
            call(),
            throwsA(
              isA<RelayUnavailable>().having(
                (error) => error.message,
                'safe copy',
                isNot(contains('private diagnostic')),
              ),
            ),
          );
        }
      }
    },
  );

  test('empty scoped mailbox returns null without consuming it', () async {
    final client = HttpRelayClient(
      'https://relay.test',
      MockClient((_) async => http.Response('{}', 404)),
      (method, uri, body) async => 'proof',
      true,
    );
    expect(await client.peekRosterWelcome(group, mailbox), isNull);
  });
}
