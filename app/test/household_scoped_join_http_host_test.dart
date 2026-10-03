// Real native controllers and owned SQLite HTTP relay. Store failures are
// controlled in-memory outcomes, not OS secure-storage or power-loss evidence.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:private_ledger/data/rust/api/shared.dart';
import 'package:private_ledger/data/rust/frb_generated.dart';
import 'package:private_ledger/data/storage/blob_store.dart';
import 'package:private_ledger/features/household/household_controller.dart';
import 'package:private_ledger/features/household/household_journal.dart';
import 'package:private_ledger/features/household/invite_codes.dart';
import 'package:private_ledger/features/household/relay_client.dart';

class _Store implements BlobStore {
  Uint8List? value;
  bool fail = false;
  bool writeThenFail = false;
  @override
  Future<Uint8List?> read() async => value;
  @override
  Future<void> write(Uint8List bytes) async {
    if (!fail || writeThenFail) value = Uint8List.fromList(bytes);
    if (fail) throw const FileSystemException('controlled uncertain save');
  }

  @override
  Future<void> delete() async => value = null;
}

class _Observe extends http.BaseClient {
  _Observe(this.before, this.loseAck);
  final Future<void> Function(http.BaseRequest) before;
  final bool Function() loseAck;
  final http.Client inner = http.Client();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    await before(request);
    final response = await inner.send(request);
    if (request.url.path.endsWith('/ack') && loseAck()) {
      await response.stream.drain<void>();
      throw const SocketException('controlled lost acknowledgement reply');
    }
    return response;
  }

  @override
  void close() => inner.close();
}

void main() {
  final library = Platform.environment['RUST_LIB_PATH'];
  group(
    'controller-managed authenticated HTTP join',
    () {
      setUpAll(
        () => RustLib.init(externalLibrary: ExternalLibrary.open(library!)),
      );
      for (final failure in [
        'before-save',
        'after-save',
        'lost-ack',
        'after-ack-save',
        'default-client',
        'storage-audit',
      ]) {
        test(
          '$failure never consumes Welcome before saved joined keys, and restart resumes',
          () async {
            final audit = failure == 'storage-audit';
            final defaultClient = failure == 'default-client' || audit;
            final reserve = await ServerSocket.bind(
              InternetAddress.loopbackIPv4,
              0,
            );
            final port = reserve.port;
            await reserve.close();
            final origin = 'http://127.0.0.1:$port';
            final memory = MemoryRelayClient();
            final states = [_Store(), _Store()], configs = [_Store(), _Store()];
            final initial = List.generate(
              2,
              (i) => HouseholdController(
                stateStore: states[i],
                configStore: configs[i],
                newMemberId: audit ? () => 'Private audit member $i' : null,
                relayFactory: defaultClient ? null : (_) => memory,
              ),
            );
            for (var i = 0; i < initial.length; i++) {
              final device = initial[i];
              await device.initialize();
              expect(
                await device.setRelayUrl(
                  defaultClient ? origin : 'https://relay.test',
                  authenticated: defaultClient && i == 0,
                ),
                isTrue,
              );
            }
            expect(await initial[0].createHousehold(), !defaultClient);
            final request = (await initial[1].prepareJoinRequest())!;
            expect(
              await initial[1].relayBootstrapPolicy(),
              isNull,
              reason:
                  'An unjoined identity cannot grant itself founding authority',
            );
            final group = initial[0].overview!.groupId!;
            final proof = jsonDecode(
              await initial[0].relayRequestSigner(
                'GET',
                Uri.parse('$origin/g/$group/policy'),
                Uint8List(0),
              ),
            ) as Map<String, dynamic>;
            final beforeExport = Uint8List.fromList(states[0].value!);
            final root = defaultClient
                ? jsonDecode((await initial[0].relayBootstrapPolicy())!)
                : {
                    'version': 2,
                    'epoch': 0,
                    'scope': {'origin': origin, 'kind': 'g', 'id': group},
                    'devices': [
                      {
                        'key': proof['publicKey'],
                        'operations': ['append', 'membership', 'read'],
                      },
                    ],
                  };
            if (defaultClient) {
              expect(
                states[0].value,
                beforeExport,
                reason: 'Public setup export cannot mutate saved identity or ledger',
              );
              expect(
                jsonDecode((await initial[0].relayBootstrapPolicy())!),
                root,
              );
              expect((root as Map)['devices'], [
                {
                  'key': proof['publicKey'],
                  'operations': ['append', 'membership', 'read'],
                },
              ]);
            }
            // Only initial Alice is operator trusted; Bob enrols via actual MLS and
            // atomic relay membership, never test-supplied two-member policy.
            final process = await Process.start(
              'node',
              [
                audit ? 'test/native-app-audit-relay.mjs' : 'dev-server.mjs',
                '$port',
              ],
              workingDirectory: Directory('../relay').absolute.path,
              environment: {
                'LOCAL_AUTH_POLICY': jsonEncode(root),
                'LOCAL_AUTH_MEMBERSHIP': 'true',
              },
            );
            var exited = false;
            final exit = process.exitCode.then((code) {
              exited = true;
              return code;
            });
            final ready = Completer<void>();
            final inspection = Completer<Map<String, dynamic>>();
            final output = process.stdout
                .transform(utf8.decoder)
                .transform(const LineSplitter())
                .listen((line) {
                  if (line.startsWith('AUDIT:') && !inspection.isCompleted) {
                    inspection.complete(
                      jsonDecode(line.substring(6)) as Map<String, dynamic>,
                    );
                  } else if (line.startsWith('AUDIT-FAIL:') &&
                      !inspection.isCompleted) {
                    inspection.completeError(
                      StateError('Actual roster storage audit failed'),
                    );
                  }
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
                (code) =>
                    throw StateError('Owned relay exited before ready: $code'),
              ),
            ]).timeout(const Duration(seconds: 15));
            for (var i = 0; i < initial.length; i++) {
              final device = initial[i];
              expect(
                await device.setRelayUrl(
                  origin,
                  authenticated: defaultClient && i == 0,
                ),
                isTrue,
              );
              device.dispose();
            }
            var failAfterAck = failure == 'after-ack-save';
            var acknowledgements = 0,
                legacyRequests = 0,
                dropAck = failure == 'lost-ack';
            final clients = <http.Client>[];
            HouseholdController restore(int i, {bool roster = true}) {
              if (defaultClient && roster) {
                return HouseholdController(
                  stateStore: states[i],
                  configStore: configs[i],
                );
              }
              late HouseholdController device;
              device = HouseholdController(
                stateStore: states[i],
                configStore: configs[i],
                relayFactory: (base) {
                  final client = _Observe((request) async {
                    if (request.url.path.startsWith('/m/')) legacyRequests++;
                    if (i == 1 && request.url.path.endsWith('/ack')) {
                      acknowledgements++;
                      final saved = HouseholdJournal.decode(states[i].value!);
                      expect(saved.pendingAckRoster, isTrue);
                      expect(saved.pendingAck, isNotNull);
                      final joined = await householdRestore(saved: saved.state);
                      try {
                        final overview = await householdOverview(
                          household: joined,
                        );
                        expect(overview.isMember, isTrue);
                        expect(overview.groupId, group);
                      } finally {
                        joined.dispose();
                      }
                      if (failAfterAck) states[i].fail = true;
                    }
                  }, () => i == 1 && dropAck);
                  clients.add(client);
                  return HttpRelayClient(
                    base,
                    client,
                    device.relayRequestSigner,
                    roster,
                  );
                },
              );
              return device;
            }

            addTearDown(() {
              for (final client in clients) {
                client.close();
              }
            });
            final alice = restore(0);
            addTearDown(alice.dispose);
            await alice.initialize();
            final seedClient = http.Client();
            addTearDown(seedClient.close);
            final seed = HttpRelayClient(
              origin,
              seedClient,
              alice.relayRequestSigner,
              true,
            );
            for (final entry in await memory.readAfter(group, 0)) {
              await seed.append(group, entry.sequence - 1, entry.blob);
            }
            expect(await alice.syncNow(), isTrue);
            if (defaultClient) {
              expect(
                await alice.relayBootstrapPolicy(),
                isNull,
                reason:
                    'A synced group cannot be used to reset operator authority',
              );
            }
            final invite = (await alice.invite(request))!;
            final descriptor = decodeInvite(invite);
            final downgraded = restore(1, roster: false);
            await downgraded.initialize();
            expect(await downgraded.acceptInvite(invite), isFalse);
            expect(
              legacyRequests,
              0,
              reason: 'An explicitly authenticated invite cannot use legacy delivery',
            );
            expect(downgraded.overview!.isMember, isFalse);
            downgraded.dispose();
            final bob = restore(1);
            await bob.initialize();
            if (failure == 'before-save' || failure == 'after-save') {
              states[1].fail = true;
              states[1].writeThenFail = failure == 'after-save';
            }
            expect(descriptor.authenticated, isTrue);
            expect(await bob.acceptInvite(invite), defaultClient);
            final initiallyAcknowledged =
                failure == 'lost-ack' || failure == 'after-ack-save';
            expect(acknowledgements, initiallyAcknowledged ? 1 : 0);
            expect(
              bob.requiresRestart,
              failure != 'lost-ack' && !defaultClient,
            );
            bob.dispose();
            states[1].fail = false;
            failAfterAck = false;
            dropAck = false;
            if (failure != 'before-save') {
              final wrong = restore(1, roster: false);
              await wrong.initialize();
              expect(await wrong.syncNow(), isFalse);
              expect(
                legacyRequests,
                0,
                reason:
                    'Saved scoped ack intent cannot fall back after restart',
              );
              wrong.dispose();
            }
            final restarted = restore(1);
            addTearDown(restarted.dispose);
            await restarted.initialize();
            expect(
              await (defaultClient
                  ? restarted.syncNow()
                  : restarted.acceptInvite(invite)),
              isTrue,
            );
            expect(restarted.authenticatedRelay, isTrue);
            expect(restarted.overview!.isMember, isTrue);
            final saved = HouseholdJournal.decode(states[1].value!);
            expect(saved.authenticatedRelay, isTrue);
            expect(saved.pendingAck, isNull);
            expect(saved.pendingAckRoster, isFalse);
            final bobClient = http.Client();
            addTearDown(bobClient.close);
            final recipient = HttpRelayClient(
              origin,
              bobClient,
              restarted.relayRequestSigner,
              true,
            );
            expect(
              await recipient.peekRosterWelcome(group, descriptor.mailbox),
              isNull,
            );
            expect(legacyRequests, 0);
            expect(
              acknowledgements,
              defaultClient
                  ? 0
                  : initiallyAcknowledged
                  ? 2
                  : 1,
            );
            expect(await alice.syncNow(), isTrue);
            expect(
              alice.overview!.memberIds.toSet(),
              restarted.overview!.memberIds.toSet(),
            );
            if (defaultClient) {
              expect(
                await alice.addExpense(
                  title: 'shared-after-join',
                  amount: '2.50',
                ),
                isTrue,
              );
              expect(await restarted.syncNow(), isTrue);
              expect(restarted.overview!.balanceLabel, 'USD -2.50');
            }
            if (audit) {
              final aliceKey = (root as Map)['devices'][0]['key'] as String;
              final bobKey = (await alice.relayRosterKeys()).singleWhere(
                (key) => key != aliceKey,
              );
              for (var i = 0; i < 20; i++) {
                expect(
                  await alice.addExpense(
                    title: 'Private audit grocery marker',
                    amount: '2.50',
                  ),
                  isTrue,
                );
              }
              expect(await restarted.syncNow(), isTrue);
              final bobName = restarted.overview!.memberId;
              expect(await alice.removeMember(bobName), isTrue);
              // The saved retired cursor is the actual confirmed removal slot.
              expect(await restarted.syncNow(), isTrue);
              expect(restarted.overview!.isMember, isFalse);
              final removalSlot = restarted.overview!.cursor.toInt();
              final cara = HouseholdController(
                stateStore: _Store(),
                configStore: _Store(),
                newMemberId: () => 'Private audit replacement member',
              );
              addTearDown(cara.dispose);
              await cara.initialize();
              final nextRequest = (await cara.prepareJoinRequest())!;
              final nextCode = (await alice.invite(nextRequest))!;
              final nextDescriptor = decodeInvite(nextCode);
              final currentKeys = await alice.relayRosterKeys();
              final caraKey = currentKeys.singleWhere((key) => key != aliceKey);
              expect(await cara.acceptInvite(nextCode), isTrue);
              expect(await alice.syncNow(), isTrue);
              expect(cara.overview!.balanceLabel, 'USD -52.50');
              final entryCount = (await seed.readAfter(group, 0)).length;
              expect(entryCount, greaterThan(20));
              final external = http.Client();
              addTearDown(external.close);
              expect(
                (await external.get(Uri.parse('$origin/inspect'))).statusCode,
                403,
              );
              process.stdin.writeln(
                'audit:${jsonEncode({
                  'currentPolicy': {
                    'version': 2,
                    'epoch': 3,
                    'scope': {'origin': origin, 'kind': 'g', 'id': group},
                    'devices': [
                      for (final key in currentKeys) {
                          'key': key,
                          'operations': ['append', 'membership', 'read'],
                        },
                    ],
                  },
                  'publicKeys': {...currentKeys, bobKey}.toList(),
                  'retired': [
                    {'key': bobKey, 'through': removalSlot},
                  ],
                  'mailboxes': [
                    {'id': descriptor.mailbox, 'recipient': bobKey},
                    {'id': nextDescriptor.mailbox, 'recipient': caraKey},
                  ],
                  'needles': {'Private audit grocery marker', ...alice.overview!.memberIds, bobName, alice.overview!.balanceLabel, for (final account in alice.overview!.accounts) account.name, for (final transaction in alice.overview!.transactions) transaction.id}.toList(),
                })}',
              );
              await process.stdin.flush();
              expect(
                await inspection.future.timeout(const Duration(seconds: 10)),
                {
                  'entries': {
                    'entries': entryCount,
                    'welcomes': 2,
                    'retired': 1,
                    'authorities': 1,
                  },
                  'plaintextPoisonRejected': true,
                  'metadataPoisonRejected': true,
                  'rosterPoisonRejected': true,
                  'retirementPoisonRejected': true,
                  'welcomePoisonRejected': true,
                  'binaryPoisonRejected': true,
                },
              );
              expect(
                (await seed.readAfter(group, 0)).length,
                entryCount,
                reason: 'Negative controls must never change real persisted records',
              );
            }
          },
        );
      }
    },
    skip: library == null
        ? 'Requires rebuilt native bridge and cached local relay'
        : false,
  );
}
