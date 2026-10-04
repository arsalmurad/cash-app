// Actual HTTP, production roster/MLS controller and deleted SQLite prefix.
// Test stores are memory-backed confirmed saves, not protected OS durability.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:private_ledger/data/rust/frb_generated.dart';
import 'package:private_ledger/data/storage/blob_store.dart';
import 'package:private_ledger/features/household/household_controller.dart';
import 'package:private_ledger/features/household/household_journal.dart';

class _Store implements BlobStore {
  Uint8List? value;
  bool failRead = false;
  Uint8List? staleRead;
  @override
  Future<Uint8List?> read() async {
    if (failRead) {
      throw const FileSystemException(
        'Controlled retained-archive read failure',
      );
    }
    return staleRead ?? value;
  }

  @override
  Future<void> write(Uint8List bytes) async =>
      value = Uint8List.fromList(bytes);
  @override
  Future<void> delete() async => value = null;
  _Store copy() =>
      _Store()..value = value == null ? null : Uint8List.fromList(value!);
}

void main() {
  final library = Platform.environment['RUST_LIB_PATH'];
  test(
    'actual missing SQLite prefix requires fresh-key authenticated peer recovery',
    () async {
      await RustLib.init(externalLibrary: ExternalLibrary.open(library!));
      final reserve = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = reserve.port;
      await reserve.close();
      final origin = 'http://127.0.0.1:$port';
      final aliceState = _Store(), aliceConfig = _Store();
      final bobState = _Store(), bobConfig = _Store();
      final liveControllers = <HouseholdController>{};
      addTearDown(() {
        for (final controller in liveControllers) {
          controller.dispose();
        }
      });
      HouseholdController device(_Store state, _Store config) {
        final result = HouseholdController(
          stateStore: state,
          configStore: config,
        );
        liveControllers.add(result);
        return result;
      }

      var alice = device(aliceState, aliceConfig);
      await alice.initialize();
      expect(await alice.setRelayUrl(origin, authenticated: true), isTrue);
      expect(
        await alice.createHousehold(),
        isFalse,
        reason: 'No operator relay exists yet',
      );
      final root = (await alice.relayBootstrapPolicy())!;
      final group = alice.overview!.groupId!;
      final process = await Process.start(
        'node',
        ['test/native-prefix-recovery-relay.mjs', '$port'],
        workingDirectory: Directory('../relay').absolute.path,
        environment: {
          'LOCAL_AUTH_POLICY': root,
          'LOCAL_AUTH_RETENTION': 'true',
        },
      );
      final ready = Completer<void>();
      Completer<Map<String, dynamic>>? response;
      final output = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            if (line == 'PREFIX-READY' && !ready.isCompleted) {
              ready.complete();
            }
            if (line.startsWith('PREFIX-RESULT:')) {
              response!.complete(
                jsonDecode(line.substring(14)) as Map<String, dynamic>,
              );
            }
            if (line == 'PREFIX-FAIL') {
              response!.completeError(
                StateError('Owned prefix fixture failed'),
              );
            }
          });
      final errors = process.stderr.listen((_) {});
      var exited = false;
      final exit = process.exitCode.then((code) {
        exited = true;
        return code;
      });
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
          (code) => throw StateError('Fixture exited before ready: $code'),
        ),
      ]).timeout(const Duration(seconds: 15));
      Future<Map<String, dynamic>> command(String kind) async {
        response = Completer<Map<String, dynamic>>();
        process.stdin.writeln(jsonEncode({'kind': kind}));
        await process.stdin.flush();
        return response!.future.timeout(const Duration(seconds: 10));
      }

      final external = http.Client();
      addTearDown(external.close);
      expect(
        (await external.post(Uri.parse('$origin/g/$group/prune'))).statusCode,
        401,
      );
      expect(await alice.syncNow(), isTrue);
      final bob = device(bobState, bobConfig);
      await bob.initialize();
      final request = (await bob.prepareJoinRequest())!;
      expect(await bob.acceptInvite((await alice.invite(request))!), isTrue);
      expect(
        await alice.addExpense(
          title: 'Early recoverable expense',
          amount: '2.50',
        ),
        isTrue,
      );
      expect(await bob.syncNow(), isTrue);
      final backup = (await bob.createBackup())!;
      final oldAliceArchive = Uint8List.fromList(aliceState.value!);
      final staleCursor = bob.overview!.cursor.toInt();
      final staleState = bobState.copy(), staleConfig = bobConfig.copy();
      final oldKey = (await bob.relayRosterKeys()).singleWhere(
        (key) => !jsonDecode(
          root,
        )['devices'].any((dynamic device) => device['key'] == key),
      );
      expect(
        await alice.addExpense(title: 'Later retained expense', amount: '7.25'),
        isTrue,
      );
      expect(await bob.syncNow(), isTrue);
      expect(await alice.syncNow(), isTrue);
      final latestCursor = bob.overview!.cursor.toInt();
      expect(latestCursor, greaterThan(staleCursor));
      final before = await command('inspect');
      final retentionRequest = (await alice.prepareRetentionRequest())!;
      final approval = (await bob.approveRetentionRequest(retentionRequest))!;
      for (final failure in ['read-failed', 'stale-read']) {
        aliceState.failRead = failure == 'read-failed';
        aliceState.staleRead = failure == 'stale-read' ? oldAliceArchive : null;
        expect(await alice.prepareRetentionRequest(), isNull);
        expect(alice.requiresRestart, isTrue);
        expect(
          await command('inspect'),
          before,
          reason: 'Unconfirmed archive must not authorize deletion',
        );
        alice.dispose();
        liveControllers.remove(alice);
        aliceState.failRead = false;
        aliceState.staleRead = null;
        alice = device(aliceState, aliceConfig);
        await alice.initialize();
        expect(alice.requiresRestart, isFalse);
      }
      expect(await alice.reclaimRelayHistory(retentionRequest, []), isFalse);
      expect(
        await command('inspect'),
        before,
        reason: 'Missing approval must not delete any records',
      );
      expect(
        await bob.reclaimRelayHistory(retentionRequest, [approval]),
        isFalse,
      );
      expect(
        await command('inspect'),
        before,
        reason: 'Only the designated holder may prune',
      );
      expect(
        await alice.reclaimRelayHistory(retentionRequest, [approval]),
        isTrue,
      );
      final trimmed = await command('inspect');
      final through = trimmed['floor'] as int;
      expect(through, greaterThan(staleCursor));
      expect(through, lessThanOrEqualTo(latestCursor));
      expect(trimmed['floor'], through);
      expect(trimmed['tail'], before['tail']);
      expect(trimmed['entries'], (before['entries'] as int) - through);
      expect((trimmed['capacity'] as Map)['entries'], trimmed['entries']);
      final stale = device(staleState, staleConfig);
      await stale.initialize();
      final cursor = stale.overview!.cursor;
      final oldArchive = Uint8List.fromList(
        HouseholdJournal.decode(staleState.value!).state,
      );
      expect(cursor.toInt(), lessThan(through));
      expect(await stale.syncNow(), isFalse);
      expect(stale.errorMessage, contains('410'));
      expect(stale.overview!.cursor, cursor);
      expect(HouseholdJournal.decode(staleState.value!).state, oldArchive);
      expect(
        await command('inspect'),
        trimmed,
        reason: 'Failed catch-up must never append or erase',
      );
      // Actual recovery starts a new signing/MLS identity, not the stale cursor.
      final replacementState = _Store(), replacementConfig = _Store();
      var replacement = device(replacementState, replacementConfig);
      await replacement.initialize();
      expect(
        await replacement.restoreBackup(backup.phrase, backup.backup),
        isTrue,
      );
      expect(replacement.needsRecoveryInvite, isTrue);
      final replacementRequest = (await replacement.prepareJoinRequest())!;
      expect(await alice.removeMember(bob.overview!.memberId), isTrue);
      final code = (await alice.invite(replacementRequest))!;
      expect(await replacement.acceptInvite(code), isTrue);
      expect(replacement.needsRecoveryInvite, isFalse);
      // Replace actual controllers before pending history catch-up resumes.
      alice.dispose();
      replacement.dispose();
      liveControllers.remove(alice);
      liveControllers.remove(replacement);
      alice = device(aliceState, aliceConfig);
      replacement = device(replacementState, replacementConfig);
      await alice.initialize();
      await replacement.initialize();
      expect(await alice.syncNow(), isTrue);
      expect(await replacement.syncNow(), isTrue);
      expect(await alice.syncNow(), isTrue);
      expect(replacement.overview!.balanceLabel, 'USD -9.75');
      expect(replacement.overview!.transactions, alice.overview!.transactions);
      expect(replacement.overview!.cursor.toInt(), greaterThan(through));
      final keys = await replacement.relayRosterKeys();
      expect(keys, await alice.relayRosterKeys());
      expect(keys, isNot(contains(oldKey)));
      expect(
        await replacement.addExpense(
          title: 'Fresh sender after recovery',
          amount: '1.00',
        ),
        isTrue,
      );
      expect(await alice.syncNow(), isTrue);
      expect(alice.overview!.balanceLabel, 'USD -10.75');
      expect(await stale.syncNow(), isFalse);
      expect(stale.overview!.cursor, cursor);
      expect((await command('inspect'))['floor'], through);
    },
    timeout: const Timeout(Duration(seconds: 90)),
    skip: library == null
        ? 'Requires existing native bridge and cached local relay'
        : false,
  );
}
