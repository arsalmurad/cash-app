import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'relay_socket.dart';

RelaySocket createRelaySocket(Uri uri, String protocol) =>
    _BrowserSocket(uri, protocol);

class _BrowserSocket implements RelaySocket {
  _BrowserSocket(Uri uri, String protocol)
    : _socket = web.WebSocket(uri.toString(), protocol.toJS) {
    _socket.onopen = ((web.Event event) {
      if (!_closed && !_ready.isCompleted) _ready.complete(_socket.protocol);
    }).toJS;
    _socket.onmessage = ((web.MessageEvent event) {
      if (!_closed) {
        final data = event.data;
        // Binary frames are never notification hints.
        _messages.add(data.isA<JSString>() ? (data as JSString).toDart : null);
      }
    }).toJS;
    _socket.onerror = ((web.Event event) => close()).toJS;
    _socket.onclose = ((web.Event event) => close()).toJS;
  }

  final web.WebSocket _socket;
  final _ready = Completer<String>();
  final _messages = StreamController<Object?>();
  bool _closed = false;
  @override
  Future<String> get ready => _ready.future;
  @override
  Stream<Object?> get messages => _messages.stream;

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    if (!_ready.isCompleted)
      _ready.completeError(StateError('Connection closed'));
    _socket.onopen = null;
    _socket.onmessage = null;
    _socket.onerror = null;
    _socket.onclose = null;
    _socket.close();
    unawaited(_messages.close());
  }
}
