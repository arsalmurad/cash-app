import 'dart:async';
import 'dart:io';

import 'relay_socket.dart';

RelaySocket createRelaySocket(Uri uri, String protocol) =>
    _NativeSocket(uri, protocol);

class _NativeSocket implements RelaySocket {
  _NativeSocket(Uri uri, String protocol) {
    ready = _connect(uri, protocol);
  }

  final _messages = StreamController<Object?>();
  WebSocket? _socket;
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
      );
      if (_closed) {
        unawaited(socket.close());
        throw StateError('Connection cancelled');
      }
      _socket = socket;
      socket.listen(
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
    final socket = _socket;
    if (socket != null) unawaited(socket.close());
    unawaited(_messages.close());
  }
}
