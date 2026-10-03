import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// One entry of a group's ordered log.
class RelayLogEntry {
  const RelayLogEntry(this.sequence, this.blob);

  final int sequence;
  final Uint8List blob;
}

/// A welcome waiting for one invitee.
class RelayMailboxItem {
  const RelayMailboxItem({
    required this.group,
    required this.joinedAfter,
    required this.welcome,
  });

  final String group;
  final int joinedAfter;
  final Uint8List welcome;
}

/// An append was refused because the caller's view was stale: catch up from
/// the log and try again.
class RelayConflict implements Exception {
  const RelayConflict(this.tail);

  final int tail;

  @override
  String toString() => 'The relay log moved on (now at entry $tail).';
}

/// The relay could not be reached or answered nonsense. A request may have
/// succeeded before its reply was lost: this does not prove rejection.
class RelayUnavailable implements Exception {
  const RelayUnavailable(this.message);

  final String message;

  @override
  String toString() => 'Relay unavailable: $message';
}

/// A matching-tail append was refused without evicting retained history.
/// Keep pending encrypted work; this is not permission to reset the household.
class RelayCapacityReached extends RelayUnavailable {
  const RelayCapacityReached()
    : super(
        'Household relay storage is full. Keep this household on your device '
        'and contact the relay operator before trying Sync again.',
      );

  @override
  String toString() => message;
}

/// The relay's contract (see `relay/src/worker.js`). It is an ordered log
/// with compare-and-swap on the tail, plus single-use welcome mailboxes;
/// every payload is opaque ciphertext to it.
abstract class RelayClient {
  /// Appends `blob` as entry `expectedTail + 1` only if the tail is exactly
  /// `expectedTail`; throws [RelayConflict] otherwise.
  Future<int> append(String group, int expectedTail, Uint8List blob);

  Future<List<RelayLogEntry>> readAfter(String group, int after);

  Future<void> putMailbox(
    String mailbox,
    String group,
    int joinedAfter,
    Uint8List welcome,
  );

  /// The mailbox's item, once; `null` if empty or already taken.
  Future<RelayMailboxItem?> takeMailbox(String mailbox);

  /// Read without consuming: repeat safely after a lost response.
  Future<RelayMailboxItem?> peekMailbox(String mailbox);

  /// Only after joined keys are durably saved; retries are idempotent.
  Future<void> acknowledgeMailbox(String mailbox);
}

/// Talks to the Cloudflare Worker over HTTP.
class HttpRelayClient implements RelayClient {
  HttpRelayClient(String baseUrl, [http.Client? client])
    : _base = baseUrl.replaceAll(RegExp(r'/+$'), ''),
      _client = client ?? http.Client();

  final String _base;
  final http.Client _client;

  Uri _uri(String path) => Uri.parse('$_base$path');

  Future<http.Response> _send(Future<http.Response> Function() request) async {
    try {
      return await request().timeout(const Duration(seconds: 20));
    } on Exception catch (error) {
      throw RelayUnavailable(error.toString());
    }
  }

  Map<String, dynamic> _object(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } on FormatException {
      // Falls through to the error below.
    }
    throw const RelayUnavailable('the relay sent an unreadable reply');
  }

  Uint8List _bytes(Object? encoded) {
    if (encoded is! String) {
      throw const RelayUnavailable('the relay sent an entry without data');
    }
    try {
      return base64.decode(encoded);
    } on FormatException {
      throw const RelayUnavailable('the relay sent an undecodable entry');
    }
  }

  @override
  Future<int> append(String group, int expectedTail, Uint8List blob) async {
    final response = await _send(
      () => _client.post(
        _uri('/g/$group/append'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'expected_tail': expectedTail,
          'blob': base64.encode(blob),
        }),
      ),
    );
    if (response.statusCode == 409) {
      final tail = _object(response)['tail'];
      if (tail is int) {
        throw RelayConflict(tail);
      }
      throw const RelayUnavailable(
        'the relay refused an append without a tail',
      );
    }
    if (response.statusCode == 507) {
      // Use trusted local copy, never instructions from a remote error body.
      throw const RelayCapacityReached();
    }
    if (response.statusCode != 200) {
      throw RelayUnavailable('append failed (${response.statusCode})');
    }
    final sequence = _object(response)['seq'];
    if (sequence is! int) {
      throw const RelayUnavailable(
        'the relay accepted an append without a seq',
      );
    }
    return sequence;
  }

  @override
  Future<List<RelayLogEntry>> readAfter(String group, int after) async {
    final entries = <RelayLogEntry>[];
    var cursor = after;
    while (true) {
      final response = await _send(
        () => _client.get(_uri('/g/$group?after=$cursor')),
      );
      if (response.statusCode != 200) {
        throw RelayUnavailable('read failed (${response.statusCode})');
      }
      final page = _object(response);
      final rawEntries = page['entries'];
      if (rawEntries is! List) {
        throw const RelayUnavailable('the relay sent no entry list');
      }
      for (final raw in rawEntries) {
        if (raw is! Map || raw['seq'] is! int) {
          throw const RelayUnavailable('the relay sent a malformed entry');
        }
        final sequence = raw['seq'] as int;
        entries.add(RelayLogEntry(sequence, _bytes(raw['blob'])));
        cursor = sequence;
      }
      if (page['more'] != true) {
        return entries;
      }
    }
  }

  @override
  Future<void> putMailbox(
    String mailbox,
    String group,
    int joinedAfter,
    Uint8List welcome,
  ) async {
    final response = await _send(
      () => _client.put(
        _uri('/m/$mailbox'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'group': group,
          'joined_after': joinedAfter,
          'welcome': base64.encode(welcome),
        }),
      ),
    );
    if (response.statusCode != 200) {
      throw RelayUnavailable(
        'could not leave the welcome (${response.statusCode})',
      );
    }
  }

  @override
  Future<RelayMailboxItem?> takeMailbox(String mailbox) async {
    final response = await _send(() => _client.post(_uri('/m/$mailbox/take')));
    return _mailboxReply(response);
  }

  @override
  Future<RelayMailboxItem?> peekMailbox(String mailbox) async =>
      _mailboxReply(await _send(() => _client.get(_uri('/m/$mailbox'))));

  @override
  Future<void> acknowledgeMailbox(String mailbox) async {
    final response = await _send(() => _client.post(_uri('/m/$mailbox/ack')));
    if (response.statusCode != 200 && response.statusCode != 404) {
      throw RelayUnavailable(
        'could not acknowledge the welcome (${response.statusCode})',
      );
    }
  }

  RelayMailboxItem? _mailboxReply(http.Response response) {
    if (response.statusCode == 404) {
      return null;
    }
    if (response.statusCode != 200) {
      throw RelayUnavailable(
        'could not collect the welcome (${response.statusCode})',
      );
    }
    final item = _object(response);
    final group = item['group'];
    final joinedAfter = item['joined_after'];
    if (group is! String || joinedAfter is! int) {
      throw const RelayUnavailable('the relay sent an incomplete welcome');
    }
    return RelayMailboxItem(
      group: group,
      joinedAfter: joinedAfter,
      welcome: _bytes(item['welcome']),
    );
  }
}

/// An in-process relay for tests and demos, obeying the same contract.
class MemoryRelayClient implements RelayClient {
  final Map<String, List<Uint8List>> _groups = {};
  final Map<String, RelayMailboxItem> _mailboxes = {};
  final Set<String> _consumedMailboxes = {};

  @override
  Future<int> append(String group, int expectedTail, Uint8List blob) async {
    final log = _groups.putIfAbsent(group, () => []);
    if (log.length != expectedTail) {
      throw RelayConflict(log.length);
    }
    log.add(Uint8List.fromList(blob));
    return log.length;
  }

  @override
  Future<List<RelayLogEntry>> readAfter(String group, int after) async {
    final log = _groups[group] ?? const <Uint8List>[];
    return [
      for (var index = after; index < log.length; index += 1)
        RelayLogEntry(index + 1, Uint8List.fromList(log[index])),
    ];
  }

  @override
  Future<void> putMailbox(
    String mailbox,
    String group,
    int joinedAfter,
    Uint8List welcome,
  ) async {
    final stored = _mailboxes[mailbox];
    if (stored != null) {
      if (stored.group == group &&
          stored.joinedAfter == joinedAfter &&
          base64.encode(stored.welcome) == base64.encode(welcome)) {
        return;
      }
      throw const RelayUnavailable('mailbox already holds a different invite');
    }
    _mailboxes[mailbox] = RelayMailboxItem(
      group: group,
      joinedAfter: joinedAfter,
      welcome: Uint8List.fromList(welcome),
    );
  }

  @override
  Future<RelayMailboxItem?> takeMailbox(String mailbox) async {
    final item = _mailboxes[mailbox];
    if (item == null || !_consumedMailboxes.add(mailbox)) return null;
    return item;
  }

  @override
  Future<RelayMailboxItem?> peekMailbox(String mailbox) async =>
      _consumedMailboxes.contains(mailbox) ? null : _mailboxes[mailbox];

  @override
  Future<void> acknowledgeMailbox(String mailbox) async {
    if (_mailboxes.containsKey(mailbox)) _consumedMailboxes.add(mailbox);
  }
}
