import 'dart:async';
import 'dart:math';

import 'relay_notifications.dart';

/// One foreground identity/relay session. The only pending work is one dirty
/// bit, one sync and one timer. Hints never carry a cursor, ACK or saved state.
class NotificationSession {
  NotificationSession({
    required this.connect,
    required this.sync,
    this.coalesceDelay = const Duration(milliseconds: 250),
    this.retryDelay = const Duration(seconds: 2),
    this.maxRetryDelay = const Duration(minutes: 1),
  }) {
    unawaited(_open());
  }

  final RelayNotificationConnection Function() connect;
  final Future<bool> Function() sync;
  final Duration coalesceDelay;
  final Duration retryDelay;
  final Duration maxRetryDelay;
  RelayNotificationConnection? _connection;
  StreamSubscription<int>? _subscription;
  Timer? _retry;
  Timer? _pending;
  bool _closed = false;
  bool _dirty = false;
  bool _syncing = false;
  int _failures = 0;
  int _generation = 0;
  Stopwatch? _uptime;

  Future<void> _open() async {
    if (_closed) return;
    final generation = ++_generation;
    try {
      final connection = connect();
      _connection = connection;
      _subscription = connection.tails.listen(
        (_) => _requestSync(generation),
        onError: (Object _) => _disconnect(generation),
        onDone: () => _disconnect(generation),
      );
      await connection.ready;
      if (_closed || generation != _generation) return;
      _uptime = Stopwatch()..start();
      // No hint is required. Open/reconnect always runs authenticated HTTP.
      _requestSync(generation);
    } catch (_) {
      _disconnect(generation);
    }
  }

  void _requestSync(int generation) {
    if (_closed || generation != _generation) return;
    _dirty = true;
    if (!_syncing && _pending == null) {
      _pending = Timer(coalesceDelay, () {
        _pending = null;
        unawaited(_sync(generation));
      });
    }
  }

  Future<void> _sync(int generation) async {
    if (_closed || generation != _generation || !_dirty) return;
    _dirty = false;
    _syncing = true;
    var succeeded = false;
    try {
      succeeded = await sync();
    } catch (_) {
      // Network/lock failures must not escape an advisory background task.
    } finally {
      _syncing = false;
      if (!_closed && _dirty && generation != _generation) {
        _requestSync(_generation);
      }
    }
    if (_closed || generation != _generation) return;
    if (!succeeded && _connection != null) {
      _disconnect(generation, backfill: false);
    } else if (_dirty) {
      _requestSync(generation);
    }
  }

  void _disconnect(int generation, {bool backfill = true}) {
    if (_closed || generation != _generation) return;
    final wasOpen = _uptime != null;
    ++_generation; // Ignore done/error/ready from this abandoned connection.
    _pending?.cancel();
    _pending = null;
    _dirty = false;
    _connection?.close();
    _connection = null;
    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) unawaited(subscription.cancel());
    if ((_uptime?.elapsed ?? Duration.zero) >= const Duration(minutes: 1)) {
      _failures = 0;
    }
    _uptime = null;
    final delay = Duration(
      milliseconds: min(
        maxRetryDelay.inMilliseconds,
        retryDelay.inMilliseconds * (1 << min(_failures++, 8)),
      ),
    );
    _retry = Timer(delay, () {
      _retry = null;
      // A replacement can connect while an old HTTP sync saves; _syncing
      // holds its single dirty bit until that operation finishes.
      unawaited(_open());
    });
    // Revocation may close a current member before its removal hint. Use the
    // ordinary HTTP path to learn that commit (including retired catch-up).
    if (wasOpen && backfill) _requestSync(_generation);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    ++_generation;
    _retry?.cancel();
    _pending?.cancel();
    _connection?.close();
    final subscription = _subscription;
    if (subscription != null) unawaited(subscription.cancel());
  }
}
