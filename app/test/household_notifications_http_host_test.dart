// Actual Linux Rust identities, signed sockets, authenticated HTTP and SQLite
// workerd. Synthetic in-memory app journals; not OS vault or mobile acceptance.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:private_ledger/data/rust/frb_generated.dart';
import 'package:private_ledger/data/storage/blob_store.dart';
import 'package:private_ledger/features/household/household_controller.dart';
import 'package:private_ledger/features/household/relay_client.dart';
import 'package:private_ledger/features/household/relay_socket.dart';
import 'package:private_ledger/features/household/relay_socket_io.dart';

class _Store implements BlobStore {
  Uint8List? value;
  bool fail = false;
  Completer<void>? hold;
  Completer<void>? entered;
  @override
  Future<Uint8List?> read() async =>
      value == null ? null : Uint8List.fromList(value!);
  @override
  Future<void> write(Uint8List bytes) async {
    value = Uint8List.fromList(bytes);
    if (hold != null) {
      if (entered?.isCompleted == false) entered!.complete();
      await hold!.future;
    }
    if (fail) throw StateError('Synthetic uncertain save after write');
  }

  @override
  Future<void> delete() async => value = null;
}

class _CountingClient extends http.BaseClient {
  _CountingClient(this.record);
  final void Function() record;
  final _delegate = http.Client();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    record();
    return _delegate.send(request);
  }

  @override
  void close() => _delegate.close();
}

Future<void> _until(bool Function() condition) async {
  final elapsed = Stopwatch()..start();
  while (!condition()) {
    if (elapsed.elapsed > const Duration(seconds: 15)) {
      fail('Notification condition timed out');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

void main() {
  final library = Platform.environment['RUST_LIB_PATH'];
  test(
    'real signed hints backfill; background, lock, uncertain save and removal revoke sessions',
    () async {
      await RustLib.init(externalLibrary: ExternalLibrary.open(library!));
      final reserve = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = reserve.port;
      await reserve.close();
      final origin = 'http://127.0.0.1:$port';
      final states = [_Store(), _Store()];
      final configs = [_Store(), _Store()];
      final memory = MemoryRelayClient();
      final initial = HouseholdController(
        stateStore: states[0],
        configStore: configs[0],
        relayFactory: (_) => memory,
      );
      await initial.initialize();
      expect(await initial.setRelayUrl(origin), isTrue);
      expect(await initial.createHousehold(), isTrue);
      final group = initial.overview!.groupId!;
      final key = (await initial.relayRosterKeys()).single;
      final root = jsonEncode({
        'version': 2,
        'epoch': 0,
        'scope': {'origin': origin, 'kind': 'g', 'id': group},
        'devices': [
          {
            'key': key,
            'operations': ['append', 'membership', 'read'],
          },
        ],
      });
      final process = await Process.start(
        'node',
        ['dev-server.mjs', '$port'],
        workingDirectory: Directory('../relay').absolute.path,
        environment: {
          'LOCAL_AUTH_POLICY': root,
          'LOCAL_AUTH_MEMBERSHIP': 'true',
          'LOCAL_AUTH_SOCKETS': 'true',
        },
      );
      final ready = Completer<void>();
      final output = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            if (line.contains('local roster group relay listening') &&
                !ready.isCompleted) {
              ready.complete();
            }
          });
      final errors = process.stderr.listen((_) {});
      addTearDown(() async {
        process.kill();
        await process.exitCode.timeout(const Duration(seconds: 10));
        await output.cancel();
        await errors.cancel();
      });
      await Future.any([
        ready.future,
        process.exitCode.then((code) => throw StateError('Relay exited $code')),
      ]).timeout(const Duration(seconds: 15));
      final clients = <http.Client>[];
      var requests = 0;
      http.Client client() {
        final c = _CountingClient(() => requests++);
        clients.add(c);
        return c;
      }

      addTearDown(() {
        for (final c in clients) {
          c.close();
        }
      });
      final seed = HttpRelayClient(
        origin,
        client(),
        initial.relayRequestSigner,
        true,
      );
      for (final entry in await memory.readAfter(group, 0)) {
        expect(
          await seed.append(group, entry.sequence - 1, entry.blob),
          entry.sequence,
        );
      }
      initial.dispose();
      var opens = 0;
      var connected = 0;
      final active = <HouseholdController>[];
      addTearDown(() {
        for (final controller in active) {
          controller.dispose();
        }
      });
      RelaySocket socket(Uri uri, String protocol) {
        opens++;
        final result = createRelaySocket(uri, protocol);
        unawaited(
          result.ready.then<void>((_) {
            connected++;
          }, onError: (Object _) {}),
        );
        return result;
      }

      HouseholdController device(int index) {
        late HouseholdController result;
        result = HouseholdController(
          stateStore: states[index],
          configStore: configs[index],
          notificationSocketFactory: socket,
          relayFactory: (url) => HttpRelayClient(
            url,
            client(),
            (m, u, b) => result.relayRequestSigner(m, u, b),
            true,
          ),
        );
        active.add(result);
        return result;
      }

      final alice = device(0), bob = device(1);
      for (final d in [alice, bob]) {
        await d.initialize();
        expect(await d.setRelayUrl(origin, authenticated: true), isTrue);
      }
      expect(await alice.syncNow(), isTrue, reason: alice.errorMessage);
      final request = await bob.prepareJoinRequest();
      final invite = await alice.invite(request!);
      expect(await bob.acceptInvite(invite!), isTrue, reason: bob.errorMessage);
      expect(await alice.syncNow(), isTrue, reason: alice.errorMessage);
      expect(
        opens,
        0,
        reason: 'Notifications require explicit opt-in and foreground',
      );
      bob.setNotificationsEnabled(true);
      expect(opens, 0);
      alice.setNotificationsEnabled(true);
      alice.setNotificationForeground(true);
      bob.setNotificationForeground(true);
      await _until(() => connected >= 2 && !bob.isBusy);
      expect(
        await alice.addExpense(title: 'Synthetic online', amount: '1.00'),
        isTrue,
      );
      await _until(() => bob.overview?.balanceLabel == 'USD -1.00');
      // Two subscribers also see their own confirmed-save receipts. They must
      // drain to silence instead of turning hints/ACKs into an HTTP echo loop.
      final settling = Stopwatch()..start();
      final quiet = Stopwatch()..start();
      var lastRequests = requests;
      while (quiet.elapsed < const Duration(seconds: 2)) {
        if (settling.elapsed > const Duration(seconds: 15))
          fail('Two notification peers never drained their HTTP work');
        await Future<void>.delayed(const Duration(milliseconds: 50));
        if (requests != lastRequests) {
          lastRequests = requests;
          quiet.reset();
        }
      }
      bob.setNotificationForeground(false);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final paused = Uint8List.fromList(states[1].value!);
      expect(
        await alice.addExpense(title: 'Synthetic offline', amount: '2.00'),
        isTrue,
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(states[1].value, paused);
      bob.setNotificationForeground(true);
      await _until(() => bob.overview?.balanceLabel == 'USD -3.00');
      bob.setNotificationUnlocked(false);
      expect(
        await alice.addExpense(title: 'Synthetic locked', amount: '3.00'),
        isTrue,
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(bob.overview!.balanceLabel, 'USD -3.00');
      bob.setNotificationUnlocked(true);
      await _until(() => bob.overview?.balanceLabel == 'USD -6.00');
      states[1].hold = Completer<void>();
      states[1].entered = Completer<void>();
      expect(
        await alice.addExpense(title: 'Synthetic slow save', amount: '0.50'),
        isTrue,
      );
      await states[1].entered!.future.timeout(const Duration(seconds: 15));
      final beforeChurn = opens;
      for (var i = 0; i < 100; i++) {
        bob.setNotificationForeground(false);
        bob.setNotificationForeground(true);
      }
      bob.setNotificationForeground(false);
      states[1].hold!.complete();
      await _until(() => !bob.isBusy);
      states[1].hold = null;
      expect(
        opens,
        beforeChurn,
        reason: 'No late handshake from abandoned queued signers',
      );
      bob.setNotificationForeground(true);
      await _until(
        () => opens > beforeChurn && bob.overview?.balanceLabel == 'USD -6.50',
      );
      states[1].fail = true;
      expect(
        await alice.addExpense(title: 'Synthetic uncertain', amount: '4.00'),
        isTrue,
      );
      await _until(() => bob.requiresRestart);
      final failedOpens = opens;
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(
        opens,
        failedOpens,
        reason: 'An uncertain save must not reconnect or sign',
      );
      expect(bob.hasIdentity, isFalse);
      bob.dispose();
      active.remove(bob);
      states[1].fail = false;
      final restarted = device(1);
      await restarted.initialize();
      restarted.setNotificationsEnabled(true);
      restarted.setNotificationForeground(true);
      await _until(() => restarted.overview?.balanceLabel == 'USD -10.50');
      final bobId = restarted.overview!.memberId;
      expect(
        await alice.removeMember(bobId),
        isTrue,
        reason: alice.errorMessage,
      );
      await _until(() => !restarted.isMember);
      final removedOpens = opens;
      expect(
        await alice.addExpense(
          title: 'Synthetic after removal',
          amount: '5.00',
        ),
        isTrue,
      );
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(opens, removedOpens, reason: 'Removed peers must stop retrying');
      expect(restarted.overview!.balanceLabel, 'USD -10.50');
    },
    skip: library == null
        ? 'Set RUST_LIB_PATH for actual native bridge acceptance'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
