// Real native MLS commits and device proofs over owned loopback workerd/SQLite.
// Trusted bootstrap and Welcome delivery are out of band, not public enrolment.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:private_ledger/data/rust/api/shared.dart';
import 'package:private_ledger/data/rust/frb_generated.dart';
import 'package:private_ledger/features/household/relay_client.dart';
import 'package:private_ledger/features/household/relay_policy.dart';

String _hex(Uint8List bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

RelayRequestSigner _signer(Household device) => (method, uri, body) async {
  final proof = await householdSignRelayRequest(
    household: device,
    origin: uri.origin,
    method: method,
    path: uri.toString().substring(uri.origin.length),
    body: body,
    expires: PlatformInt64Util.from(
      DateTime.now().millisecondsSinceEpoch + 50000,
    ),
  );
  return jsonEncode({
    'publicKey': _hex(proof.publicKey),
    'nonce': _hex(proof.nonce),
    'expires': proof.expires.toInt(),
    'signature': _hex(proof.signature),
  });
};

void main() {
  final library = Platform.environment['RUST_LIB_PATH'];
  test(
    'native staged membership, exact policy transport and revocation over SQLite HTTP',
    () async {
      await RustLib.init(externalLibrary: ExternalLibrary.open(library!));
      final alice = await householdNew(
        memberId: 'private-alice',
        reportingCurrencyCode: 'USD',
      );
      final bob = await householdNew(
        memberId: 'private-bob',
        reportingCurrencyCode: 'USD',
      );
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      final group = await householdFound(household: alice);
      final own = (await householdRelayRosterKeys(household: alice))
          .map(_hex)
          .toList();
      final reserve = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = reserve.port;
      await reserve.close();
      final origin = 'http://127.0.0.1:$port';
      final root = RelayAuthorizationPolicy.fromJson(
        {
          'version': 2,
          'epoch': 0,
          'scope': {'origin': origin, 'kind': 'g', 'id': group},
          'devices': [
            {
              'key': own.single,
              'operations': ['append', 'membership', 'read'],
            },
          ],
        },
        origin: origin,
        group: group,
      );
      final process = await Process.start(
        'node',
        ['dev-server.mjs', '$port'],
        workingDirectory: Directory('../relay').absolute.path,
        environment: {
          'LOCAL_AUTH_POLICY': jsonEncode(root.toJson()),
          'LOCAL_AUTH_MEMBERSHIP': 'true',
        },
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
            if (line.contains('local roster group relay listening') &&
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
      HttpRelayClient transport(Household device) {
        final client = http.Client();
        addTearDown(client.close);
        return HttpRelayClient(origin, client, _signer(device), true);
      }

      final sponsor = transport(alice);
      final invitee = transport(bob);
      expect((await sponsor.readPolicy(group)).toJson(), root.toJson());
      await expectLater(
        invitee.readPolicy(group),
        throwsA(isA<RelayUnavailable>()),
      );
      final invitation = await householdBeginInvite(
        household: alice,
        keyPackage: await householdKeyPackage(household: bob),
      );
      final saved = await householdExport(household: alice);
      final resumed = await householdRestore(saved: saved);
      addTearDown(resumed.dispose);
      final restarted = transport(resumed);
      final proposedKeys = (await householdRelayRosterKeys(household: resumed))
          .map(_hex)
          .toList();
      final next = root.nextForRosterKeys(proposedKeys);
      final sequence = await restarted.appendMembership(
        group,
        invitation.commit.expectedTail.toInt(),
        invitation.commit.blob,
        next,
      );
      expect(sequence, 1);
      // A lost successful response is not rejection: retry sees the advanced
      // tail, and the original ciphertext is still the only confirmed entry.
      await expectLater(
        restarted.appendMembership(group, 0, invitation.commit.blob, next),
        throwsA(isA<RelayConflict>().having((error) => error.tail, 'tail', 1)),
      );
      final log = await restarted.readAfter(group, 0);
      expect(log, hasLength(1));
      expect(log.single.blob, invitation.commit.blob);
      expect((await restarted.readPolicy(group)).toJson(), next.toJson());
      expect(await householdExport(household: resumed), saved);
      await householdCommitAccepted(
        household: resumed,
        sequence: PlatformInt64Util.from(sequence),
      );
      await householdJoin(
        household: bob,
        groupId: group,
        welcome: invitation.welcome,
        joinedAfter: PlatformInt64Util.from(sequence),
      );
      expect(
        (await householdRelayRosterKeys(household: bob)).map(_hex),
        proposedKeys,
      );
      expect((await invitee.readPolicy(group)).toJson(), next.toJson());
      final oldProof = await _signer(bob)(
        'GET',
        Uri.parse('$origin/g/$group/policy'),
        Uint8List(0),
      );
      final removal = await householdBeginRemoval(
        household: resumed,
        memberId: 'private-bob',
      );
      final last = next.nextForRosterKeys(
        (await householdRelayRosterKeys(household: resumed)).map(_hex).toList(),
      );
      expect(last.devices.map((device) => device.key), own);
      expect(
        await restarted.appendMembership(
          group,
          removal.expectedTail.toInt(),
          removal.blob,
          last,
        ),
        2,
      );
      await householdCommitAccepted(
        household: resumed,
        sequence: PlatformInt64Util.from(2),
      );
      expect((await restarted.readPolicy(group)).toJson(), last.toJson());
      await expectLater(
        invitee.readPolicy(group),
        throwsA(isA<RelayUnavailable>()),
      );
      final rejected = await http.get(
        Uri.parse('$origin/g/$group/policy'),
        headers: {'x-cash-device-proof': oldProof},
      );
      expect(rejected.statusCode, 401);
      await householdIngest(
        household: bob,
        entries: [
          RelayEntry(sequence: PlatformInt64Util.from(2), blob: removal.blob),
        ],
      );
      await expectLater(
        householdRelayRosterKeys(household: bob),
        throwsA('no active household for relay permissions'),
      );
      expect(await restarted.readAfter(group, 0), hasLength(2));
    },
    skip: library == null
        ? 'Requires the rebuilt native bridge and cached relay dependencies'
        : false,
  );
}
