import 'dart:convert';
import 'dart:typed_data';

import 'relay_config.dart';

/// Text codes for the two out-of-band steps of joining a household.
///
/// Joining is a short two-way exchange because MLS needs the invitee's key
/// package before the inviter can add them, and the key package must not
/// travel through the relay (it names the member, and sending it out of band
/// is what makes comparing safety numbers meaningful):
///
///  1. The invitee shows a *join request* (their key package).
///  2. The inviter pastes it, adds them, and shows an *invite* (relay
///     address, group, and the mailbox holding the encrypted welcome).
///  3. The invitee pastes the invite.
///
/// Both are plain text so they work over any messenger or as a QR payload.
const _joinPrefix = 'cashkp1:';
const _invitePrefix = 'cashinv1:';
const _backupPrefix = 'cashbk1:';

/// What an inviter hands the invitee after adding them.
class HouseholdInvite {
  const HouseholdInvite({
    required this.relayUrl,
    required this.group,
    required this.mailbox,
    this.authenticated = false,
  });

  final String relayUrl;
  final String group;
  final String mailbox;
  final bool authenticated;
}

String _clean(String code) => code.replaceAll(RegExp(r'\s+'), '');

String _encode(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

Uint8List _decode(String text) {
  try {
    return base64Url.decode(base64Url.normalize(text));
  } on FormatException {
    throw const FormatException('That code is damaged or incomplete.');
  }
}

String encodeJoinRequest(Uint8List keyPackage) =>
    '$_joinPrefix${_encode(keyPackage)}';

/// Parses a join request, forgiving whitespace and line wrapping.
Uint8List decodeJoinRequest(String code) {
  final cleaned = _clean(code);
  if (!cleaned.startsWith(_joinPrefix)) {
    throw const FormatException('That is not a join request code.');
  }
  final body = cleaned.substring(_joinPrefix.length);
  if (body.isEmpty) {
    throw const FormatException('That join request code is empty.');
  }
  return _decode(body);
}

String encodeInvite(HouseholdInvite invite) {
  final json = jsonEncode({
    'relay': invite.relayUrl,
    'group': invite.group,
    'mailbox': invite.mailbox,
    if (invite.authenticated) 'authenticated': true,
  });
  return '$_invitePrefix${_encode(utf8.encode(json))}';
}

final _hexId = RegExp(r'^[0-9a-f]{32}$');

/// Parses an invite and checks every field before the app acts on it: a
/// pasted code must not be able to point the app at a non-http address or
/// smuggle path characters into a relay request.
HouseholdInvite decodeInvite(String code) {
  final cleaned = _clean(code);
  if (!cleaned.startsWith(_invitePrefix)) {
    throw const FormatException('That is not an invite code.');
  }
  final body = cleaned.substring(_invitePrefix.length);
  if (body.isEmpty) {
    throw const FormatException('That invite code is empty.');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(_decode(body)));
  } on FormatException {
    throw const FormatException('That invite code is damaged.');
  }
  if (decoded is! Map ||
      decoded['relay'] is! String ||
      decoded['group'] is! String ||
      decoded['mailbox'] is! String) {
    throw const FormatException('That invite code is incomplete.');
  }
  final relay = decoded['relay'] as String;
  final group = decoded['group'] as String;
  final mailbox = decoded['mailbox'] as String;
  final authenticated = decoded.containsKey('authenticated')
      ? decoded['authenticated']
      : false;
  if (authenticated is! bool) {
    throw const FormatException('That invite has an invalid relay protocol.');
  }
  final uri = Uri.tryParse(relay);
  if (uri == null ||
      !(uri.scheme == 'https' || uri.scheme == 'http') ||
      uri.host.isEmpty) {
    throw const FormatException('That invite points at an invalid relay.');
  }
  if (!_hexId.hasMatch(group) || !_hexId.hasMatch(mailbox)) {
    throw const FormatException('That invite has an invalid identifier.');
  }
  RelaySettings(relay, authenticated: authenticated);
  return HouseholdInvite(
    relayUrl: relay,
    group: group,
    mailbox: mailbox,
    authenticated: authenticated,
  );
}

/// A sealed device backup as text, for pasting into a note or file. It is
/// ciphertext under the recovery phrase, so it is safe to store anywhere;
/// it is useless without the 24 words.
String encodeBackup(Uint8List sealed) => '$_backupPrefix${_encode(sealed)}';

Uint8List decodeBackup(String code) {
  final cleaned = _clean(code);
  if (!cleaned.startsWith(_backupPrefix)) {
    throw const FormatException('That is not a backup code.');
  }
  final body = cleaned.substring(_backupPrefix.length);
  if (body.isEmpty) {
    throw const FormatException('That backup code is empty.');
  }
  return _decode(body);
}
