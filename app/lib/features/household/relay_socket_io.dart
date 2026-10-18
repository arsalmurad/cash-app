import 'dart:async';
import 'dart:io';

import 'relay_socket.dart';

RelaySocket createRelaySocket(Uri uri, String protocol) =>
    _NativeSocket(uri, protocol);

class _NativeSocket implements RelaySocket {
  _NativeSocket(Uri uri, String protocol) {
    ready = _connect(uri, protocol);
  }

  // Drop early hints: every open must backfill over HTTP. Never build a
  // pre-listener queue while the signed handshake is being checked.
  final _messages = StreamController<Object?>.broadcast(sync: true);
  final _client = HttpClient();
  WebSocket? _socket;
  StreamSubscription<Object?>? _subscription;
  bool _closed = false;
  @override
  late final Future<String> ready;
  @override
  Stream<Object?> get messages => _messages.stream;

  Future<String> _connect(Uri uri, String protocol) async {
    try {
      final socket = await WebSocket.connect(
        uri.toString(),
        protocols: [protocol],
        compression: CompressionOptions.compressionOff,
        customClient: _client,
      );
      if (_closed) {
        unawaited(socket.close());
        throw StateError('Connection cancelled');
      }
      _socket = socket;
      _subscription = socket.listen(
        (message) {
          if (!_closed) _messages.add(message);
        },
        onError: (Object error) {
          if (!_closed) _messages.addError(error);
          close();
        },
        onDone: close,
      );
      return socket.protocol ?? '';
    } catch (_) {
      close();
      rethrow;
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    // WebSocket.connect has no cancellation API. Owning its HTTP client lets
    // timeout/lock/dispose abort a pending upgrade rather than orphaning it.
    _client.close(force: true);
    final subscription = _subscription;
    if (subscription != null) unawaited(subscription.cancel());
    final socket = _socket;
    if (socket != null) unawaited(socket.close());
    scheduleMicrotask(() => unawaited(_messages.close()));
  }
}
