import 'dart:convert';
import 'dart:typed_data';

import 'invite_codes.dart';
import 'relay_policy.dart';
import 'relay_config.dart';

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
    this.membership,
    this.pendingAckRoster = false,
    this.authenticatedRelay,
  });
  final Uint8List state;
  final String? relayUrl;
  final PendingInvitation? pending;
  final String? lastCode;
  final String? lastRequest;
  final String? pendingAck;
  final Uint8List? recoveryState;
  final PendingRelayMembership? membership;
  final bool pendingAckRoster;
  final bool? authenticatedRelay;

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
        'ackRoster': pendingAckRoster,
        if (authenticatedRelay != null)
          'relayAuthenticated': authenticatedRelay,
        'membership': membership?.toJson(),
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
      final ackRoster = json['ackRoster'] ?? false;
      final authenticated = json['relayAuthenticated'];
      if (json.containsKey('relayAuthenticated') && authenticated is! bool) {
        throw const FormatException();
      }
      if (ackRoster is! bool || (ackRoster && pendingAck == null)) {
        throw const FormatException();
      }
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
      final membership = json['membership'] == null
          ? null
          : PendingRelayMembership.fromJson(json['membership']);
      if (membership != null && relay != membership.policy.origin) {
        throw const FormatException();
      }
      final pending = json['pending'] == null
          ? null
          : PendingInvitation.fromJson(json['pending'] as Map<String, dynamic>);
      if (authenticated == false &&
          (membership != null || ackRoster || pending?.recipient != null)) {
        throw const FormatException();
      }
      if (authenticated == true) {
        if (relay == null) throw const FormatException();
        RelaySettings(relay, authenticated: true);
      }
      return HouseholdJournal(
        state: base64.decode(json['state'] as String),
        relayUrl: relay,
        pending: pending,
        lastCode: json['lastCode'] as String?,
        lastRequest: json['lastRequest'] as String?,
        pendingAck: pendingAck,
        pendingAckRoster: ackRoster,
        authenticatedRelay: authenticated as bool?,
        membership: membership,
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

/// The exact atomic relay transition retained with the pending private MLS
/// state. No response loss permits recomputing its policy or replacing bytes.
class PendingRelayMembership {
  PendingRelayMembership({
    required this.expectedTail,
    required Uint8List commit,
    required this.policy,
  }) : _commit = Uint8List.fromList(commit) {
    if (expectedTail < 0 ||
        expectedTail >= RelayAuthorizationPolicy.maximumInteger ||
        commit.isEmpty ||
        commit.length > 256 * 1024 ||
        policy.epoch == 0) {
      throw const FormatException('Invalid pending relay membership.');
    }
  }
  final int expectedTail;
  final Uint8List _commit;
  final RelayAuthorizationPolicy policy;
  Uint8List get commit => Uint8List.fromList(_commit);
  Map<String, Object?> toJson() => {
    'version': 1,
    'tail': expectedTail,
    'commit': base64.encode(_commit),
    'policy': policy.toJson(),
  };
  factory PendingRelayMembership.fromJson(Object? value) {
    if (value is! Map ||
        value.length != 4 ||
        !value.keys.every({'version', 'tail', 'commit', 'policy'}.contains) ||
        value['version'] is! int ||
        value['version'] != 1 ||
        value['tail'] is! int ||
        value['commit'] is! String) {
      throw const FormatException('Invalid pending relay membership.');
    }
    final rawPolicy = value['policy'];
    if (rawPolicy is! Map || rawPolicy['scope'] is! Map) {
      throw const FormatException('Invalid pending relay membership.');
    }
    final scope = rawPolicy['scope'] as Map;
    if (scope['origin'] is! String || scope['id'] is! String) {
      throw const FormatException('Invalid pending relay membership.');
    }
    return PendingRelayMembership(
      expectedTail: value['tail'] as int,
      commit: base64.decode(value['commit'] as String),
      policy: RelayAuthorizationPolicy.fromJson(
        rawPolicy,
        origin: scope['origin'] as String,
        group: scope['id'] as String,
      ),
    );
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
    this.recipient,
  }) {
    if (recipient != null &&
        (recipient!.length != 64 ||
            !RegExp(r'^[0-9a-f]{64}$').hasMatch(recipient!))) {
      throw const FormatException('Invalid invitation recipient.');
    }
  }
  final HouseholdInvite invite;
  final int expectedTail;
  final Uint8List commit;
  final Uint8List welcome;
  final Uint8List keyPackage;
  final int createdMillis;
  bool committed;
  final String? recipient;
  String get request => base64.encode(keyPackage);
  String get code => encodeInvite(
    HouseholdInvite(
      relayUrl: invite.relayUrl,
      group: invite.group,
      mailbox: invite.mailbox,
      authenticated: recipient != null || invite.authenticated,
    ),
  );
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
    'recipient': recipient,
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
      recipient: json['recipient'] as String?,
    );
  }
}
