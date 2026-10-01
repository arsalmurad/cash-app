import 'dart:convert';
import 'dart:typed_data';

import 'invite_codes.dart';

const _magic = 'cash-app household journal v2\u0000';
const _legacyMagic = 'cash-app household journal v1\u0000';

/// One atomic snapshot contains both the Rust keys and delivery intent.
/// Like the Rust export, this contains secrets and needs encrypted storage.
class HouseholdJournal {
  HouseholdJournal({
    required this.state,
    this.relayUrl,
    this.pending,
    this.lastCode,
    this.lastRequest,
    this.pendingAck,
    this.recoveryState,
  });
  final Uint8List state;
  final String? relayUrl;
  final PendingInvitation? pending;
  final String? lastCode;
  final String? lastRequest;
  final String? pendingAck;
  final Uint8List? recoveryState;

  Uint8List encode() => Uint8List.fromList([
    ...utf8.encode(_magic),
    ...utf8.encode(
      jsonEncode({
        'state': base64.encode(state),
        'relay': relayUrl,
        'pending': pending?.toJson(),
        'lastCode': lastCode,
        'lastRequest': lastRequest,
        'pendingAck': pendingAck,
        'recoveryState': recoveryState == null
            ? null
            : base64.encode(recoveryState!),
      }),
    ),
  ]);

  static HouseholdJournal decode(Uint8List bytes) {
    final current = utf8.encode(_magic);
    final legacy = utf8.encode(_legacyMagic);
    bool begins(List<int> marker) =>
        bytes.length >= marker.length &&
        !List.generate(
          marker.length,
          (i) => bytes[i] == marker[i],
        ).contains(false);
    final marker = begins(current) ? current : legacy;
    if (bytes.length < marker.length ||
        List.generate(
          marker.length,
          (i) => bytes[i] == marker[i],
        ).contains(false)) {
      return HouseholdJournal(state: bytes); // Existing raw Rust snapshots.
    }
    try {
      final json = jsonDecode(
        utf8.decode(bytes.sublist(marker.length)),
      ) as Map<String, dynamic>;
      final relay = json['relay'] as String?;
      final pendingAck = json['pendingAck'] as String?;
      if (pendingAck != null &&
          !RegExp(r'^[0-9a-f]{32}$').hasMatch(pendingAck)) {
        throw const FormatException();
      }
      if (relay != null) {
        final uri = Uri.parse(relay);
        if (!['http', 'https'].contains(uri.scheme) || uri.host.isEmpty) {
          throw const FormatException();
        }
      }
      return HouseholdJournal(
        state: base64.decode(json['state'] as String),
        relayUrl: relay,
        pending: json['pending'] == null
            ? null
            : PendingInvitation.fromJson(
                json['pending'] as Map<String, dynamic>,
              ),
        lastCode: json['lastCode'] as String?,
        lastRequest: json['lastRequest'] as String?,
        pendingAck: pendingAck,
        recoveryState: json['recoveryState'] == null
            ? null
            : base64.decode(json['recoveryState'] as String),
      );
    } catch (_) {
      throw const FormatException(
        'The household journal is damaged. Restore a backup.',
      );
    }
  }
}

class PendingInvitation {
  PendingInvitation({
    required this.invite,
    required this.expectedTail,
    required this.commit,
    required this.welcome,
    required this.keyPackage,
    required this.createdMillis,
    this.committed = false,
  });
  final HouseholdInvite invite;
  final int expectedTail;
  final Uint8List commit;
  final Uint8List welcome;
  final Uint8List keyPackage;
  final int createdMillis;
  bool committed;
  String get request => base64.encode(keyPackage);
  String get code => encodeInvite(invite);
  bool get expired =>
      DateTime.now().millisecondsSinceEpoch - createdMillis >=
      const Duration(days: 7).inMilliseconds;

  Map<String, dynamic> toJson() => {
    'code': code,
    'tail': expectedTail,
    'commit': base64.encode(commit),
    'welcome': base64.encode(welcome),
    'request': request,
    'created': createdMillis,
    'committed': committed,
  };

  factory PendingInvitation.fromJson(Map<String, dynamic> json) {
    final tail = json['tail'] as int;
    if (tail < 0) throw const FormatException();
    return PendingInvitation(
      invite: decodeInvite(json['code'] as String),
      expectedTail: tail,
      commit: base64.decode(json['commit'] as String),
      welcome: base64.decode(json['welcome'] as String),
      keyPackage: base64.decode(json['request'] as String),
      createdMillis: json['created'] as int,
      committed: json['committed'] as bool,
    );
  }
}
