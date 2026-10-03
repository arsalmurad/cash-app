import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Supplies a public proof for these exact bytes. Signing is not registration
/// or server permission. Every attempt, including each page, needs a new proof.
typedef RelayRequestSigner = Future<String> Function(
  String method,
  Uri url,
  Uint8List body,
);

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

/// Delivers only fully validated pages. The consumer must finish saving a
/// page before the next request; failures retain earlier confirmed progress.
abstract interface class PagedRelayClient implements RelayClient {
  Future<void> readConfirmedPages(
    String group,
    int after,
    Future<void> Function(List<RelayLogEntry>) confirmPage,
  );
}

/// Talks to the Cloudflare Worker over HTTP.
class HttpRelayClient implements PagedRelayClient {
  HttpRelayClient(
    String baseUrl, [
    http.Client? client,
    RelayRequestSigner? signer,
  ]) : _base = baseUrl.replaceAll(RegExp(r'/+$'), ''),
       _client = client ?? http.Client(),
       _signer = signer;

  final String _base;
  final http.Client _client;
  final RelayRequestSigner? _signer;

  Future<Map<String, String>> _headers(
    String method,
    Uri uri,
    Uint8List body,
    Duration timeout,
  ) async {
    final signer = _signer;
    if (signer == null) return {};
    try {
      // Do not let a callback mutate the bytes that will reach the network.
      final proof = await signer(
        method,
        uri,
        Uint8List.fromList(body),
      ).timeout(timeout);
      if (proof.isEmpty ||
          proof.length > 1024 ||
          !RegExp(r'^[\x20-\x7e]+$').hasMatch(proof)) {
        throw const FormatException('invalid proof header');
      }
      return {'x-cash-device-proof': proof};
    } catch (_) {
      // FRB can throw a Rust String, not just a Dart Exception. Never disclose
      // callback diagnostics or fall back to an unsigned request.
      throw const RelayUnavailable(
        'Could not authenticate the relay request. No request sent.',
      );
    }
  }

  Uri _uri(String path) => Uri.parse('$_base$path');

  Future<http.Response> _readPage(
    Uri uri,
    Duration timeout, {
    String method = 'GET',
    Uint8List? body,
  }) async {
    const maxBytes = 6 * 1024 * 1024;
    final elapsed = Stopwatch()..start();
    final abort = Completer<void>();
    final timer = Timer(timeout, () {
      if (!abort.isCompleted) abort.complete();
    });
    StreamIterator<List<int>>? iterator;
    try {
      final headers = await _headers(
        method,
        uri,
        body ?? Uint8List(0),
        timeout,
      );
      if (body != null) headers['content-type'] = 'application/json';
      final request = http.AbortableRequest(
        method,
        uri,
        abortTrigger: abort.future,
      );
      request.headers.addAll(headers);
      if (body != null) request.bodyBytes = body;
      final remaining = timeout - elapsed.elapsed;
      if (remaining <= Duration.zero) {
        throw TimeoutException('relay request timed out');
      }
      final response = await _client.send(request).timeout(remaining);
      iterator = StreamIterator(response.stream);
      if ((response.contentLength ?? 0) > maxBytes) {
        throw const RelayUnavailable(
          'the relay response exceeds the size limit',
        );
      }
      final bytes = BytesBuilder(copy: false);
      while (true) {
        final remaining = timeout - elapsed.elapsed;
        if (remaining <= Duration.zero) {
          throw TimeoutException('relay read timed out');
        }
        if (!await iterator.moveNext().timeout(remaining)) break;
        if (iterator.current.length > maxBytes - bytes.length) {
          throw const RelayUnavailable(
            'the relay response exceeds the size limit',
          );
        }
        bytes.add(iterator.current);
      }
      return http.Response.bytes(
        bytes.takeBytes(),
        response.statusCode,
        headers: response.headers,
      );
    } on RelayUnavailable {
      rethrow;
    } on Exception catch (error) {
      throw RelayUnavailable(error.toString());
    } finally {
      timer.cancel();
      if (!abort.isCompleted) abort.complete();
      await iterator?.cancel();
    }
  }

  Future<http.Response> _send(String method, Uri uri, [Uint8List? body]) =>
      _readPage(uri, const Duration(seconds: 20), method: method, body: body);

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
      'POST',
      _uri('/g/$group/append'),
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'expected_tail': expectedTail,
            'blob': base64.encode(blob),
          }),
        ),
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
    await readConfirmedPages(
      group,
      after,
      (page) async => entries.addAll(page),
    );
    return entries;
  }

  @override
  Future<void> readConfirmedPages(
    String group,
    int after,
    Future<void> Function(List<RelayLogEntry>) confirmPage,
  ) async {
    var cursor = after;
    var previousTail = after;
    int? targetTail;
    var retainedBytes = 0;
    final elapsed = Stopwatch()..start();
    while (true) {
      final remaining = const Duration(seconds: 20) - elapsed.elapsed;
      if (remaining <= Duration.zero) {
        throw const RelayUnavailable('relay read timed out');
      }
      final response = await _readPage(
        _uri('/g/$group?after=$cursor'),
        remaining,
      );
      if (response.statusCode != 200) {
        throw RelayUnavailable('read failed (${response.statusCode})');
      }
      final page = _object(response);
      final rawEntries = page['entries'];
      final tail = page['tail'];
      final more = page['more'];
      if (rawEntries is! List ||
          tail is! int ||
          more is! bool ||
          tail < cursor ||
          tail < previousTail) {
        throw const RelayUnavailable('the relay sent an invalid log page');
      }
      targetTail ??= tail;
      if (targetTail - after > 10000) {
        throw const RelayUnavailable(
          'the relay backfill exceeds the entry limit',
        );
      }
      final pageStart = cursor;
      final pageEntries = <RelayLogEntry>[];
      for (final raw in rawEntries) {
        if (raw is! Map || raw['seq'] is! int) {
          throw const RelayUnavailable('the relay sent a malformed entry');
        }
        final sequence = raw['seq'] as int;
        if (sequence != cursor + 1 || sequence > tail) {
          throw const RelayUnavailable('the relay sent a gap or reordered log');
        }
        final blob = _bytes(raw['blob']);
        if (blob.isEmpty || blob.length > 256 * 1024) {
          throw const RelayUnavailable('the relay sent an invalid entry size');
        }
        if (sequence <= targetTail) {
          if (blob.length > 64 * 1024 * 1024 - retainedBytes) {
            throw const RelayUnavailable(
              'the relay backfill exceeds the size limit',
            );
          }
          retainedBytes += blob.length;
          pageEntries.add(RelayLogEntry(sequence, blob));
        }
        cursor = sequence;
      }
      if (more != (cursor < tail) || (more && cursor == pageStart)) {
        throw const RelayUnavailable(
          'the relay sent inconsistent continuation',
        );
      }
      previousTail = tail;
      // Never expose a valid-looking prefix of a malformed page. Await the
      // durable consumer without timing it out: an uncertain save must not
      // keep running after its caller has started another operation.
      if (pageEntries.isNotEmpty) {
        await confirmPage(List.unmodifiable(pageEntries));
      }
      // Complete the first observed prefix, not an endlessly moving tail.
      // Entries appended concurrently are fetched on the next read.
      if (cursor >= targetTail) {
        return;
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
      'PUT',
      _uri('/m/$mailbox'),
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'group': group,
            'joined_after': joinedAfter,
            'welcome': base64.encode(welcome),
          }),
        ),
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
    final response = await _send('POST', _uri('/m/$mailbox/take'));
    return _mailboxReply(response);
  }

  @override
  Future<RelayMailboxItem?> peekMailbox(String mailbox) async =>
      _mailboxReply(await _send('GET', _uri('/m/$mailbox')));

  @override
  Future<void> acknowledgeMailbox(String mailbox) async {
    final response = await _send('POST', _uri('/m/$mailbox/ack'));
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
