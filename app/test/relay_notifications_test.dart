import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/features/household/relay_client.dart';
import 'package:private_ledger/features/household/relay_notifications.dart';
import 'package:private_ledger/features/household/relay_socket.dart';

const group = '0123456789abcdef0123456789abcdef';
final uri = Uri.parse('https://relay.example/g/$group/ws');

class FakeSocket implements RelaySocket {
  FakeSocket(String? protocol) {
    if (protocol != null) connection.complete(protocol);
  }
  final connection = Completer<String>();
  final events = StreamController<Object?>();
  int closes = 0;
  @override
  Future<String> get ready => connection.future;
  @override
  Stream<Object?> get messages => events.stream;
  @override
  void close() {
    closes++;
  }
}

Future<String> signer(String method, Uri url, Uint8List body) async => '{}';
Future<void> flush() => Future<void>.delayed(Duration.zero);

void main() {
  test(
    'signs exact HTTP URL, connects once with only canonical public proof',
    () async {
      late FakeSocket socket;
      final notifications = RelayNotifications(
        requestUri: uri,
        signer: (method, url, body) async {
          expect(method, 'GET');
          expect(url, uri);
          expect(body, isEmpty);
          return '{"nonce":"public-proof"}';
        },
        socketFactory: (url, protocol) {
          expect(url.toString(), 'wss://relay.example/g/$group/ws');
          expect(protocol.startsWith('cash-request.'), isTrue);
          expect(protocol.contains('='), isFalse);
          expect(
            utf8.decode(
              base64Url.decode(base64Url.normalize(protocol.substring(13))),
            ),
            '{"nonce":"public-proof"}',
          );
          return socket = FakeSocket(protocol);
        },
      );
      final tails = <int>[];
      final subscription = notifications.tails.listen(tails.add);
      await notifications.ready;
      for (final tail in [0, 1, 1, 0, 9007199254740991]) {
        socket.events.add('{"tail":$tail}');
      }
      await flush();
      expect(tails, [0, 1, 9007199254740991]);
      notifications.close();
      notifications.close();
      expect(socket.closes, 1);
      await subscription.cancel();
      await socket.events.close();
    },
  );

  for (final address in [
    'http://foreign.example/g/$group/ws',
    'https://user:pass@relay.example/g/$group/ws',
    'https://relay.example/g/$group/ws?proof=secret',
    'https://relay.example/g/$group/ws#fragment',
    'https://relay.example/g/$group/history',
    'wss://relay.example/g/$group/ws',
  ]) {
    test(
      'invalid notification address sends and signs nothing: $address',
      () async {
        final notifications = RelayNotifications(
          requestUri: Uri.parse(address),
          signer: (_, _, _) => throw StateError('must not sign'),
          socketFactory: (_, _) => throw StateError('must not connect'),
        );
        await expectLater(
          notifications.ready,
          throwsA(isA<RelayUnavailable>()),
        );
      },
    );
  }

  test('closing during signing suppresses later transmission', () async {
    final proof = Completer<String>();
    var connects = 0;
    final notifications = RelayNotifications(
      requestUri: uri,
      signer: (_, _, _) => proof.future,
      socketFactory: (_, protocol) {
        connects++;
        return FakeSocket(protocol);
      },
    );
    notifications.close();
    proof.complete('{}');
    await expectLater(notifications.ready, throwsA(isA<RelayUnavailable>()));
    expect(connects, 0);
  });

  test('signing timeout never sends a late proof', () async {
    final proof = Completer<String>();
    var connects = 0;
    final notifications = RelayNotifications(
      requestUri: uri,
      signer: (_, _, _) => proof.future,
      timeout: const Duration(milliseconds: 10),
      socketFactory: (_, protocol) {
        connects++;
        return FakeSocket(protocol);
      },
    );
    await expectLater(notifications.ready, throwsA(isA<RelayUnavailable>()));
    proof.complete('{}');
    await flush();
    expect(connects, 0);
  });

  test('close cancels a handshake without waiting for its deadline', () async {
    final socket = FakeSocket(null);
    final notifications = RelayNotifications(
      requestUri: uri,
      signer: signer,
      socketFactory: (_, _) => socket,
    );
    await flush();
    notifications.close();
    await expectLater(notifications.ready, throwsA(isA<RelayUnavailable>()));
    socket.connection.complete('late');
    await flush();
    expect(socket.closes, 1);
  });

  test('paused hint consumer closes instead of buffering frames', () async {
    late FakeSocket socket;
    final notifications = RelayNotifications(
      requestUri: uri,
      signer: signer,
      socketFactory: (_, protocol) => socket = FakeSocket(protocol),
    );
    final subscription = notifications.tails.listen((_) {});
    await notifications.ready;
    subscription.pause();
    await flush();
    expect(socket.closes, 1);
    subscription.resume();
    await subscription.cancel();
    await socket.events.close();
  });

  test('native timeout aborts an actual stalled HTTP upgrade', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final request = Completer<void>();
    final disconnected = Completer<void>();
    Socket? peer;
    final listening = server.listen((socket) {
      peer = socket;
      socket.listen(
        (_) {
          if (!request.isCompleted) request.complete();
        },
        onDone: () {
          if (!disconnected.isCompleted) disconnected.complete();
        },
      );
    });
    final notifications = RelayNotifications(
      requestUri: Uri.parse('http://127.0.0.1:${server.port}/g/$group/ws'),
      signer: signer,
      timeout: const Duration(milliseconds: 200),
    );
    final failed = expectLater(
      notifications.ready,
      throwsA(isA<RelayUnavailable>()),
    );
    try {
      await request.future.timeout(const Duration(seconds: 2));
      await failed;
      await disconnected.future.timeout(const Duration(seconds: 2));
    } finally {
      notifications.close();
      peer?.destroy();
      await listening.cancel();
      await server.close();
    }
  });

  test('wrong negotiated protocol closes without reading hints', () async {
    final socket = FakeSocket('wrong');
    final notifications = RelayNotifications(
      requestUri: uri,
      signer: signer,
      socketFactory: (_, _) => socket,
    );
    await expectLater(notifications.ready, throwsA(isA<RelayUnavailable>()));
    expect(socket.closes, 1);
    unawaited(socket.events.close());
  });

  for (final invalid in <Object?>[
    '{"tail":1,"amount":123}',
    '{"tail":-1}',
    '{"tail":1.0}',
    '{"tail":9007199254740992}',
    '{"tail":01}',
    'x' * 65,
    Uint8List.fromList([1]),
    null,
  ]) {
    test(
      'non-canonical or financial frame closes, emits no tail: $invalid',
      () async {
        late FakeSocket socket;
        final notifications = RelayNotifications(
          requestUri: uri,
          signer: signer,
          socketFactory: (_, protocol) => socket = FakeSocket(protocol),
        );
        final tails = <int>[];
        notifications.tails.listen(tails.add);
        await notifications.ready;
        socket.events.add(invalid);
        await flush();
        expect(tails, isEmpty);
        expect(socket.closes, 1);
        await socket.events.close();
      },
    );
  }

  test('native actual loopback WebSocket receives hint; sends no application frames', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = Completer<WebSocket>();
    final received = <Object?>[];
    final serverSubscription = server.listen((request) async {
      expect(request.uri.path, '/g/$group/ws');
      expect(request.uri.hasQuery, isFalse);
      expect(request.headers.value('x-cash-device-proof'), isNull);
      final offered = request.headers.value('sec-websocket-protocol')!;
      expect(offered, 'cash-request.e30');
      final socket = await WebSocketTransformer.upgrade(
        request,
        protocolSelector: (_) => offered,
      );
      socket.listen(received.add);
      accepted.complete(socket);
      socket.add('{"tail":7}');
    });
    final notifications = RelayNotifications(
      requestUri: Uri.parse('http://127.0.0.1:${server.port}/g/$group/ws'),
      signer: signer,
    );
    final hint = notifications.tails.first;
    try {
      await notifications.ready;
      expect(await hint.timeout(const Duration(seconds: 5)), 7);
      expect(received, isEmpty);
    } finally {
      notifications.close();
      if (accepted.isCompleted) await (await accepted.future).close();
      await serverSubscription.cancel();
      await server.close(force: true);
    }
  });
}
