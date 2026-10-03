import 'dart:convert';
import 'dart:typed_data';

const _family = 'cash-app relay config ';
const _prefix = '${_family}v1\u0000';
const _scopedPrefix = '${_family}v2\u0000';

class RelaySettings {
  RelaySettings(String address, {this.authenticated = false})
    : address = _validated(address) {
    if (authenticated) {
      final uri = Uri.parse(address);
      if (uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          uri.origin != address ||
          (uri.scheme == 'http' &&
              !['127.0.0.1', 'localhost', '::1', '[::1]'].contains(uri.host))) {
        throw const FormatException(
          'Authenticated relays need a canonical HTTPS origin or loopback development address.',
        );
      }
    }
  }
  final String address;
  final bool authenticated;
}

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

Uint8List encodeRelayConfig(String address, {bool authenticated = false}) {
  final settings = RelaySettings(address, authenticated: authenticated);
  return Uint8List.fromList(
    utf8.encode(
      authenticated
          ? '$_scopedPrefix${jsonEncode({'relay': settings.address, 'authenticated': true})}'
          : '$_prefix${jsonEncode({'relay': settings.address})}',
    ),
  );
}

String decodeRelayConfig(Uint8List bytes) => decodeRelaySettings(bytes).address;

RelaySettings decodeRelaySettings(Uint8List bytes) {
  // Old versions saved one byte per UTF-16 code unit. Decode legacy bytes as
  // originally read, not guessed UTF-8: Latin-1 addresses must remain exact.
  final legacy = String.fromCharCodes(bytes);
  if (!legacy.startsWith(_family)) return RelaySettings(legacy);
  final text = utf8.decode(bytes); // Invalid UTF-8 must fail, never replace it.
  final scoped = text.startsWith(_scopedPrefix);
  if (!scoped && !text.startsWith(_prefix)) {
    throw const FormatException(
      'This relay configuration version is unsupported.',
    );
  }
  final value = jsonDecode(
    text.substring(scoped ? _scopedPrefix.length : _prefix.length),
  );
  if (value is! Map<String, dynamic> || value['relay'] is! String) {
    throw const FormatException('The saved relay configuration is damaged.');
  }
  if (scoped && (value.length != 2 || value['authenticated'] is! bool)) {
    throw const FormatException('The saved relay protocol is damaged.');
  }
  return RelaySettings(
    value['relay'] as String,
    authenticated: scoped && value['authenticated'] == true,
  );
}
