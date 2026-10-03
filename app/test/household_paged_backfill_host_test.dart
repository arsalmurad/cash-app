import 'dart:convert';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:private_ledger/data/rust/frb_generated.dart';
import 'package:private_ledger/data/storage/blob_store.dart';
import 'package:private_ledger/features/household/household_controller.dart';
import 'package:private_ledger/features/household/relay_client.dart';

class _Store implements BlobStore {
  Uint8List? value;
  bool failWrite = false;
  bool saveBeforeFailure = false;

  @override
  Future<Uint8List?> read() async =>
      value == null ? null : Uint8List.fromList(value!);
  @override
  Future<void> write(Uint8List bytes) async {
    if (!failWrite || saveBeforeFailure) value = Uint8List.fromList(bytes);
    if (failWrite) {
      throw const FileSystemException('synthetic page save failure');
    }
  }

  @override
  Future<void> delete() async => value = null;
}

class _HttpPages {
  _HttpPages(this.relay, this.start);
  final MemoryRelayClient relay;
  final int start;
  bool refuseNextPage = true;
  final reads = <int>[];
  int appends = 0;

  HttpRelayClient client(String url) => HttpRelayClient(
    url,
    MockClient((request) async {
      final parts = request.url.pathSegments;
      final group = parts[1];
      if (request.method == 'GET') {
        final after = int.parse(request.url.queryParameters['after']!);
        reads.add(after);
        if (refuseNextPage && after >= start + 16) {
          return http.Response('{"error":"synthetic request budget"}', 429);
        }
        final all = await relay.readAfter(group, 0);
        final page = all
            .where((entry) => entry.sequence > after)
            .take(16)
            .toList();
        final cursor = page.isEmpty ? after : page.last.sequence;
        return http.Response(
          jsonEncode({
            'tail': all.length,
            'more': cursor < all.length,
            'entries': [
              for (final entry in page)
                {'seq': entry.sequence, 'blob': base64.encode(entry.blob)},
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.method == 'POST' && parts.last == 'append') {
        appends++;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        try {
          final seq = await relay.append(
            group,
            body['expected_tail'] as int,
            base64.decode(body['blob'] as String),
          );
          return http.Response(jsonEncode({'seq': seq}), 200);
        } on RelayConflict catch (error) {
          return http.Response(jsonEncode({'tail': error.tail}), 409);
        }
      }
      return http.Response('{}', 404);
    }),
  );
}

void main() {
  final library = Platform.environment['RUST_LIB_PATH'];
  group('durable paged HTTP backfill through the native bridge', () {
    setUpAll(
      () async => RustLib.init(externalLibrary: ExternalLibrary.open(library!)),
    );

    Future<
      ({
        MemoryRelayClient relay,
        _Store store,
        _Store config,
        String group,
        int start,
      })
    >
    prepare() async {
      final relay = MemoryRelayClient();
      final store = _Store();
      final config = _Store();
      final alice = HouseholdController(
        stateStore: _Store(),
        configStore: _Store(),
        relayFactory: (_) => relay,
      );
      addTearDown(alice.dispose);
      final bob = HouseholdController(
        stateStore: store,
        configStore: config,
        relayFactory: (_) => relay,
      );
      try {
        await alice.initialize();
        await bob.initialize();
        await alice.setRelayUrl('https://relay.test');
        await bob.setRelayUrl('https://relay.test');
        expect(await alice.createHousehold(), isTrue);
        final request = await bob.prepareJoinRequest();
        final invitation = await alice.invite(request!);
        expect(await bob.acceptInvite(invitation!), isTrue);
        final group = bob.overview!.groupId!;
        final start = bob.overview!.cursor.toInt();
        for (var index = 0; index < 18; index++) {
          expect(
            await alice.addExpense(
              title: 'Backfill expense $index',
              amount: '1.00',
            ),
            isTrue,
          );
        }
        expect((await relay.readAfter(group, start)).length, greaterThan(16));
        return (
          relay: relay,
          store: store,
          config: config,
          group: group,
          start: start,
        );
      } finally {
        bob.dispose();
      }
    }

    test('quota interruption keeps the first confirmed page and resumes after restart', () async {
      final fixture = await prepare();
      final pages = _HttpPages(fixture.relay, fixture.start);
      HouseholdController controller() => HouseholdController(
        stateStore: fixture.store,
        configStore: fixture.config,
        relayFactory: pages.client,
      );
      final first = controller();
      await first.initialize();
      expect(await first.syncNow(), isFalse);
      expect(first.requiresRestart, isFalse);
      expect(first.overview!.cursor.toInt(), fixture.start + 16);
      expect(first.overview!.transactions.length, inInclusiveRange(1, 17));
      expect(
        pages.appends,
        0,
        reason: 'An interrupted catch-up cannot emit a retention receipt',
      );
      first.dispose();

      final restarted = controller();
      addTearDown(restarted.dispose);
      await restarted.initialize();
      expect(restarted.overview!.cursor.toInt(), fixture.start + 16);
      pages.refuseNextPage =
          false; // Models a later allowance, not changing server time.
      pages.reads.clear();
      expect(await restarted.syncNow(), isTrue);
      expect(pages.reads.first, fixture.start + 16);
      expect(restarted.overview!.transactions.length, 18);
      expect(restarted.overview!.balanceLabel, 'USD -18.00');
      final tail = (await fixture.relay.readAfter(fixture.group, 0)).length;
      expect(await restarted.syncNow(), isTrue);
      expect((await fixture.relay.readAfter(fixture.group, 0)).length, tail);
    });

    for (final afterSave in [false, true]) {
      test(
        'uncertain first page save stops networking (saved=$afterSave)',
        () async {
          final fixture = await prepare();
          final pages = _HttpPages(fixture.relay, fixture.start)
            ..refuseNextPage = false;
          final first = HouseholdController(
            stateStore: fixture.store,
            configStore: fixture.config,
            relayFactory: pages.client,
          );
          await first.initialize();
          fixture.store
            ..failWrite = true
            ..saveBeforeFailure = afterSave;
          expect(await first.syncNow(), isFalse);
          expect(first.requiresRestart, isTrue);
          expect(pages.reads, [fixture.start]);
          expect(pages.appends, 0);
          expect(await first.syncNow(), isFalse);
          expect(pages.reads, [fixture.start]);
          first.dispose();
          fixture.store.failWrite = false;
          final restarted = HouseholdController(
            stateStore: fixture.store,
            configStore: fixture.config,
            relayFactory: pages.client,
          );
          addTearDown(restarted.dispose);
          await restarted.initialize();
          expect(
            restarted.overview!.cursor.toInt(),
            fixture.start + (afterSave ? 16 : 0),
          );
          expect(await restarted.syncNow(), isTrue);
          expect(restarted.overview!.transactions.length, 18);
          expect(restarted.overview!.balanceLabel, 'USD -18.00');
        },
      );
    }
  }, skip: library == null ? 'Requires the built native Rust library' : false);
}
