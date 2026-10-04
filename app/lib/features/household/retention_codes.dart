import 'dart:convert';
import 'dart:typed_data';

String encodeRetentionRequest(Uint8List bytes) =>
    _encode('cashretreq1:', bytes);
String encodeRetentionConsent(Uint8List bytes) => _encode('cashretok1:', bytes);
Uint8List decodeRetentionRequest(String code) => _decode('cashretreq1:', code);
Uint8List decodeRetentionConsent(String code) => _decode('cashretok1:', code);

String _encode(String prefix, Uint8List bytes) {
  if (bytes.isEmpty || bytes.length > 1024) {
    throw const FormatException('Invalid retention code.');
  }
  return '$prefix${base64Url.encode(bytes).replaceAll('=', '')}';
}

Uint8List _decode(String prefix, String code) {
  if (code.length > 4096) {
    throw const FormatException('Invalid retention code.');
  }
  final text = code.replaceAll(RegExp(r'\s+'), '');
  if (!text.startsWith(prefix)) {
    throw const FormatException('Invalid retention code.');
  }
  final body = text.substring(prefix.length);
  if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(body)) {
    throw const FormatException('Invalid retention code.');
  }
  final bytes = base64Url.decode(base64Url.normalize(body));
  if (bytes.isEmpty || bytes.length > 1024) {
    throw const FormatException('Invalid retention code.');
  }
  return bytes;
}
