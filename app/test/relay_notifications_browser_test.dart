@TestOn('browser')
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:private_ledger/features/household/relay_client.dart';
import 'package:private_ledger/features/household/relay_notifications.dart';

// Start relay/test/notification-client-fixture.mjs on owned loopback and set
// --dart-define=NOTIFICATION_TEST_ORIGIN=http://127.0.0.1:8799.
void main() {
  const origin = String.fromEnvironment('NOTIFICATION_TEST_ORIGIN');
  RelayNotifications open(String digit) => RelayNotifications(
    requestUri: Uri.parse('$origin/g/${digit * 32}/ws'),
    signer: (_, _, _) async => '{}',
  );
  test(
    'real browser receives canonical text with no outgoing application frames',
    () async {
      final connection = open('0');
      addTearDown(connection.close);
      final hint = connection.tails.first;
      await connection.ready;
      expect(await hint.timeout(const Duration(seconds: 5)), 7);
      final stats = await http.get(Uri.parse(origin));
      expect((jsonDecode(stats.body) as Map)['frames'], 0);
    },
    skip: origin.isEmpty
        ? 'Requires owned loopback notification fixture'
        : false,
  );

  test(
    'real browser rejects an unselected protocol',
    () async {
      final connection = open('1');
      addTearDown(connection.close);
      await expectLater(connection.ready, throwsA(isA<RelayUnavailable>()));
    },
    skip: origin.isEmpty
        ? 'Requires owned loopback notification fixture'
        : false,
  );

  for (final digit in ['2', '3']) {
    test(
      'real browser closes on binary or noncanonical frame ($digit)',
      () async {
        final connection = open(digit);
        addTearDown(connection.close);
        final hints = connection.tails.toList();
        await connection.ready;
        expect(await hints.timeout(const Duration(seconds: 5)), isEmpty);
      },
      skip: origin.isEmpty
          ? 'Requires owned loopback notification fixture'
          : false,
    );
  }
  test(
    'browser close before open has no late ready or hints',
    () async {
      final connection = open('0');
      final hints = connection.tails.toList();
      connection.close();
      await expectLater(connection.ready, throwsA(isA<RelayUnavailable>()));
      expect(await hints, isEmpty);
    },
    skip: origin.isEmpty
        ? 'Requires owned loopback notification fixture'
        : false,
  );
  test(
    'browser cancels an actual pending upgrade',
    () async {
      final connection = open('4');
      final hints = connection.tails.toList();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      connection.close();
      await expectLater(connection.ready, throwsA(isA<RelayUnavailable>()));
      expect(await hints, isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 600));
    },
    skip: origin.isEmpty
        ? 'Requires owned loopback notification fixture'
        : false,
  );
}
