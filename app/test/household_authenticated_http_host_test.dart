// Real native identities, HTTP sockets and the loopback SQLite/workerd relay.
// Membership is prepared in memory and explicitly trusted by the test operator;
// this is not an acceptance test for public enrolment or invite mailboxes.
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

class _Store implements BlobStore {
  Uint8List? value;
  @override
  Future<Uint8List?> read() async =>
      value == null ? null : Uint8List.fromList(value!);
  @override
  Future<void> write(Uint8List bytes) async =>
      value = Uint8List.fromList(bytes);
  @override
  Future<void> delete() async => value = null;
}

void main() {
  final library = Platform.environment['RUST_LIB_PATH'];
  test(
    'restored native peers exchange encrypted expenses over authenticated HTTP',
    () async {
      await RustLib.init(externalLibrary: ExternalLibrary.open(library!));
      final memory = MemoryRelayClient();
      final states = [_Store(), _Store()];
      final configs = [_Store(), _Store()];
      final initial = List.generate(
        2,
        (index) => HouseholdController(
          stateStore: states[index],
          configStore: configs[index],
          relayFactory: (_) => memory,
        ),
      );
      for (final device in initial) {
        addTearDown(device.dispose);
        await device.initialize();
        expect(await device.setRelayUrl('https://relay.test'), isTrue);
      }
      expect(await initial[0].createHousehold(), isTrue);
      final join = await initial[1].prepareJoinRequest();
      final invite = await initial[0].invite(join!);
      expect(await initial[1].acceptInvite(invite!), isTrue);
      expect(await initial[0].syncNow(), isTrue);
      final group = initial[0].overview!.groupId!;
      final reserve = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = reserve.port;
      await reserve.close();
      final origin = 'http://127.0.0.1:$port';
      final url = Uri.parse('$origin/g/$group?after=0');
      final keys = <String>[];
      for (final device in initial) {
        final proof = jsonDecode(
          await device.relayRequestSigner('GET', url, Uint8List(0)),
        ) as Map<String, dynamic>;
        keys.add(proof['publicKey'] as String);
      }
      keys.sort();
      final policy = jsonEncode({
        'version': 2,
        'epoch': 0,
        'scope': {'origin': origin, 'kind': 'g', 'id': group},
        'devices': [
          for (final key in keys)
            {
              'key': key,
              'operations': ['append', 'read'],
            },
        ],
      });
      final process = await Process.start(
        'node',
        ['dev-server.mjs', '$port'],
        workingDirectory: Directory('../relay').absolute.path,
        environment: {'LOCAL_AUTH_POLICY': policy},
      );
      var exited = false;
      final exit = process.exitCode.then((code) {
        exited = true;
        return code;
      });
      final ready = Completer<void>();
      final output = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            if (line.contains('local authenticated group relay listening') &&
                !ready.isCompleted) {
              ready.complete();
            }
          });
      final errors = process.stderr.listen((_) {});
      addTearDown(() async {
        if (!exited) {
          if (Platform.isWindows) {
            await Process.run(r'C:\Windows\System32\taskkill.exe', [
              '/PID',
              '${process.pid}',
              '/T',
              '/F',
            ]);
          } else {
            process.kill(ProcessSignal.sigterm);
          }
        }
        await exit.timeout(const Duration(seconds: 10));
        await output.cancel();
        await errors.cancel();
      });
      await Future.any([
        ready.future,
        exit.then(
          (code) => throw StateError('Owned relay exited before ready: $code'),
        ),
      ]).timeout(const Duration(seconds: 15));
      final clients = <http.Client>[];
      HttpRelayClient transport(HouseholdController device) {
        final client = http.Client();
        clients.add(client);
        return HttpRelayClient(origin, client, device.relayRequestSigner);
      }

      addTearDown(() {
        for (final client in clients) {
          client.close();
        }
      });
      // Fresh authenticated storage receives original MLS ciphertext via signed
      // appends, never a legacy-log adoption or a debug/seed endpoint.
      final seed = transport(initial[0]);
      for (final entry in await memory.readAfter(group, 0)) {
        expect(
          await seed.append(group, entry.sequence - 1, entry.blob),
          entry.sequence,
        );
      }
      HouseholdController restore(int index) {
        late HouseholdController device;
        device = HouseholdController(
          stateStore: states[index],
          configStore: configs[index],
          relayFactory: (base) {
            final client = http.Client();
            clients.add(client);
            return HttpRelayClient(
              base,
              client,
              (method, uri, body) =>
                  device.relayRequestSigner(method, uri, body),
            );
          },
        );
        addTearDown(device.dispose);
        return device;
      }

      final alice = restore(0);
      final bob = restore(1);
      for (final device in [alice, bob]) {
        await device.initialize();
        expect(await device.setRelayUrl(origin), isTrue);
        expect(await device.syncNow(), isTrue, reason: device.errorMessage);
      }
      // Bob remains offline while Alice produces more than one relay page.
      for (var index = 0; index < 18; index++) {
        expect(
          await alice.addExpense(
            title: 'Private HTTP expense $index',
            amount: '1.00',
          ),
          isTrue,
          reason: alice.errorMessage,
        );
      }
      expect(await bob.syncNow(), isTrue, reason: bob.errorMessage);
      expect(bob.overview!.transactions.length, 18);
      expect(
        await bob.addExpense(title: 'Private Bob purchase', amount: '2.50'),
        isTrue,
        reason: bob.errorMessage,
      );
      expect(await alice.syncNow(), isTrue, reason: alice.errorMessage);
      expect(alice.overview!.balanceLabel, bob.overview!.balanceLabel);
      expect(alice.overview!.balanceLabel, 'USD -20.50');
      expect(alice.overview!.transactions.length, 19);
      final restarted = restore(1);
      await restarted.initialize();
      expect(await restarted.syncNow(), isTrue, reason: restarted.errorMessage);
      expect(restarted.overview!.balanceLabel, alice.overview!.balanceLabel);
      final read = transport(alice);
      // Reach a stable receipt frontier; a further idle sync must not ACK an ACK.
      expect(await alice.syncNow(), isTrue, reason: alice.errorMessage);
      final before = await read.readAfter(group, 0);
      expect(await alice.syncNow(), isTrue, reason: alice.errorMessage);
      final after = await read.readAfter(group, 0);
      expect(after.length, before.length);
      for (final entry in after) {
        expect(
          utf8.decode(entry.blob, allowMalformed: true),
          isNot(contains('Private HTTP expense')),
        );
        expect(
          utf8.decode(entry.blob, allowMalformed: true),
          isNot(contains('Private Bob purchase')),
        );
      }
      final raw = http.Client();
      addTearDown(raw.close);
      expect((await raw.get(url)).statusCode, 401);
      final proof = await alice.relayRequestSigner('GET', url, Uint8List(0));
      expect(
        (await raw.get(
          url,
          headers: {'x-cash-device-proof': proof},
        )).statusCode,
        200,
      );
      expect(
        (await raw.get(
          url,
          headers: {'x-cash-device-proof': proof},
        )).statusCode,
        409,
      );
      final appendUrl = Uri.parse('$origin/g/$group/append');
      final body = utf8.encode(
        jsonEncode({'expected_tail': after.length, 'blob': 'AQ=='}),
      );
      final bodyProof = await alice.relayRequestSigner(
        'POST',
        appendUrl,
        Uint8List.fromList(body),
      );
      expect(
        (await raw.post(
          appendUrl,
          headers: {'x-cash-device-proof': bodyProof},
          body: [...body, 32],
        )).statusCode,
        401,
      );
      final stranger = HouseholdController(
        stateStore: _Store(),
        configStore: _Store(),
      );
      addTearDown(stranger.dispose);
      await stranger.initialize();
      expect(await stranger.prepareJoinRequest(), isNotNull);
      final strangerProof = await stranger.relayRequestSigner(
        'GET',
        url,
        Uint8List(0),
      );
      expect(
        (await raw.get(
          url,
          headers: {'x-cash-device-proof': strangerProof},
        )).statusCode,
        401,
      );
      expect((await read.readAfter(group, 0)).length, after.length);
    },
    skip: library == null ? 'Requires the built native library' : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
