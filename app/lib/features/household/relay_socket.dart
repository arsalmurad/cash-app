import 'dart:async';

/// Platform connection only. The application deliberately exposes no send API.
abstract interface class RelaySocket {
  Future<String> get ready;
  Stream<Object?> get messages;
  void close();
}

typedef RelaySocketFactory = RelaySocket Function(Uri uri, String protocol);
