import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'relay_client.dart';
import 'relay_socket.dart';
import 'relay_socket_io.dart'
    if (dart.library.js_interop) 'relay_socket_web.dart';

/// One cancellable, authenticated attempt. Hints are advisory: callers must
/// backfill over HTTP on every successful connection and reconnect. No cursor,
/// acknowledgement, financial state or durable storage is updated here.
class RelayNotifications {
  RelayNotifications({
    required Uri requestUri,
    required RelayRequestSigner signer,
    RelaySocketFactory? socketFactory,
    Duration timeout = const Duration(seconds: 10),
  }) {
    ready = _open(
      requestUri,
      signer,
      socketFactory ?? createRelaySocket,
      timeout,
    );
  }

  late final Future<void> ready;
  final _tails = StreamController<int>();
  RelaySocket? _socket;
  StreamSubscription<Object?>? _subscription;
  bool _closed = false;
  int _lastTail = -1;

  Stream<int> get tails => _tails.stream;

  Future<void> _open(
    Uri uri,
    RelayRequestSigner signer,
    RelaySocketFactory factory,
    Duration timeout,
  ) async {
    final elapsed = Stopwatch()..start();
    try {
      if (timeout <= Duration.zero ||
          !['http', 'https'].contains(uri.scheme) ||
          !uri.hasAuthority ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          !RegExp(r'^/g/[0-9a-f]{32}/ws$').hasMatch(uri.path) ||
          (uri.scheme == 'http' &&
              !['127.0.0.1', 'localhost', '::1', '[::1]'].contains(uri.host))) {
        throw const FormatException();
      }
      final proof = await signer('GET', uri, Uint8List(0)).timeout(timeout);
      if (_closed) throw const FormatException();
      if (proof.isEmpty ||
          proof.length > 1024 ||
          !RegExp(r'^[\x20-\x7e]+$').hasMatch(proof)) {
        throw const FormatException();
      }
      final protocol =
          'cash-request.${base64Url.encode(utf8.encode(proof)).replaceAll('=', '')}';
      if (protocol.length > 1024) throw const FormatException();
      final remaining = timeout - elapsed.elapsed;
      if (remaining <= Duration.zero) throw const FormatException();
      final socket = factory(
        uri.replace(scheme: uri.scheme == 'https' ? 'wss' : 'ws'),
        protocol,
      );
      _socket = socket;
      final selected = await socket.ready.timeout(remaining);
      if (_closed || selected != protocol) throw const FormatException();
      _subscription = socket.messages.listen(
        _message,
        onError: (Object _) => close(),
        onDone: close,
      );
    } catch (_) {
      close();
      // Never expose proof contents, URL credentials or platform diagnostics.
      throw const RelayUnavailable('Could not connect to relay notifications.');
    }
  }

  void _message(Object? message) {
    if (_closed) return;
    try {
      if (message is! String || message.length > 64) {
        throw const FormatException();
      }
      // Canonical server format only, bounded before any parsing/allocation.
      if (!RegExp(r'^\{"tail":(0|[1-9][0-9]{0,15})\}$').hasMatch(message)) {
        throw const FormatException();
      }
      final tail = int.parse(message.substring(8, message.length - 1));
      if (tail > 9007199254740991) throw const FormatException();
      if (tail > _lastTail) {
        _lastTail = tail;
        _tails.add(tail);
      }
    } catch (_) {
      close();
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _socket?.close();
    final subscription = _subscription;
    if (subscription != null) unawaited(subscription.cancel());
    unawaited(_tails.close());
  }
}
