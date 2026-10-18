import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/features/household/notification_session.dart';
import 'package:private_ledger/features/household/relay_notifications.dart';

class _Connection implements RelayNotificationConnection {
  final opening = Completer<void>();
  final events = StreamController<int>(sync: true);
  int closes = 0;
  @override
  Future<void> get ready => opening.future;
  @override
  Stream<int> get tails => events.stream;
  @override
  void close() => closes++;
}

void main() {
  const batch = Duration(milliseconds: 250);
  testWidgets('open backfills without hints; a storm queues one follow-up', (
    tester,
  ) async {
    final connection = _Connection();
    final firstSync = Completer<bool>();
    var calls = 0;
    final session = NotificationSession(
      connect: () => connection,
      sync: () {
        calls++;
        return calls == 1 ? firstSync.future : Future.value(true);
      },
    );
    addTearDown(session.close);
    connection.opening.complete();
    await tester.pump();
    await tester.pump(batch);
    expect(calls, 1, reason: 'No hint is needed to backfill');
    for (var i = 0; i < 10000; i++) {
      connection.events.add(i);
    }
    await tester.pump(const Duration(seconds: 5));
    expect(calls, 1, reason: 'Do not overlap HTTP syncs');
    firstSync.complete(true);
    await tester.pump();
    await tester.pump(batch);
    expect(calls, 2);
    await tester.pump(const Duration(seconds: 5));
    expect(calls, 2, reason: 'A tail is not a target cursor or an ACK');
  });

  testWidgets('close cancels queued sync and retry, including late ready', (
    tester,
  ) async {
    final connection = _Connection();
    var connects = 0, calls = 0;
    final session = NotificationSession(
      connect: () {
        connects++;
        return connection;
      },
      sync: () async {
        calls++;
        return true;
      },
    );
    session.close();
    connection.opening.complete();
    await tester.pump(const Duration(minutes: 10));
    expect(connects, 1);
    expect(calls, 0);
    expect(connection.closes, 1);
  });

  testWidgets('refusals back off and reconnect backfills with no hint', (
    tester,
  ) async {
    final connections = <_Connection>[];
    var calls = 0;
    final session = NotificationSession(
      connect: () {
        final c = _Connection();
        connections.add(c);
        return c;
      },
      sync: () async {
        calls++;
        return true;
      },
    );
    addTearDown(session.close);
    connections.last.opening.completeError(StateError('denied'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(connections, hasLength(1));
    await tester.pump(const Duration(seconds: 1));
    expect(connections, hasLength(2));
    connections.last.opening.completeError(StateError('offline'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(connections, hasLength(2));
    await tester.pump(const Duration(seconds: 1));
    connections.last.opening.complete();
    await tester.pump();
    await tester.pump(batch);
    expect(calls, 1);
  });

  testWidgets('replacement backfill waits for an old in-flight save', (
    tester,
  ) async {
    final connections = <_Connection>[];
    final saving = Completer<bool>();
    var calls = 0;
    final session = NotificationSession(
      connect: () {
        final c = _Connection();
        connections.add(c);
        return c;
      },
      sync: () {
        calls++;
        return calls == 1 ? saving.future : Future.value(true);
      },
    );
    addTearDown(session.close);
    connections.first.opening.complete();
    await tester.pump();
    await tester.pump(batch);
    unawaited(connections.first.events.close());
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    connections.last.opening.complete();
    await tester.pump();
    await tester.pump(batch);
    expect(calls, 1);
    saving.complete(true);
    await tester.pump();
    await tester.pump(batch);
    expect(calls, 2);
  });

  testWidgets('failed HTTP backfill closes and retries, without a sync loop', (
    tester,
  ) async {
    final connections = <_Connection>[];
    var calls = 0;
    final session = NotificationSession(
      connect: () {
        final c = _Connection();
        connections.add(c);
        return c;
      },
      sync: () async {
        calls++;
        return false;
      },
    );
    connections.first.opening.complete();
    await tester.pump();
    await tester.pump(batch);
    expect(connections.first.closes, 1);
    expect(calls, 1);
    session.close();
    await tester.pump(const Duration(minutes: 5));
    expect(connections, hasLength(1));
  });
}
