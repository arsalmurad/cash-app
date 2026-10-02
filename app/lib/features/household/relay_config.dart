import 'dart:convert';
import 'dart:typed_data';

const _family = 'cash-app relay config ';
const _prefix = '${_family}v1\u0000';

/// Validate before constructing a network client, including when loading disk.
String _validated(String address) {
  final uri = Uri.tryParse(address);
  if (uri == null ||
      !(uri.scheme == 'https' || uri.scheme == 'http') ||
      uri.host.isEmpty) {
    throw const FormatException('The saved relay address is invalid.');
  }
  return address;
}

Uint8List encodeRelayConfig(String address) => Uint8List.fromList(
  utf8.encode('$_prefix${jsonEncode({'relay': _validated(address)})}'),
);

String decodeRelayConfig(Uint8List bytes) {
  // Old versions saved one byte per UTF-16 code unit. Decode legacy bytes as
  // originally read, not guessed UTF-8: Latin-1 addresses must remain exact.
  final legacy = String.fromCharCodes(bytes);
  if (!legacy.startsWith(_family)) return _validated(legacy);
  final text = utf8.decode(bytes); // Invalid UTF-8 must fail, never replace it.
  if (!text.startsWith(_prefix)) {
    throw const FormatException(
      'This relay configuration version is unsupported.',
    );
  }
  final value = jsonDecode(text.substring(_prefix.length));
  if (value is! Map<String, dynamic> || value['relay'] is! String) {
    throw const FormatException('The saved relay configuration is damaged.');
  }
  return _validated(value['relay'] as String);
}
