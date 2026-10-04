import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:private_ledger/data/rust/frb_generated.dart';
import 'package:private_ledger/data/storage/blob_store.dart';
import 'package:private_ledger/data/storage/secret_blob_store.dart';
import 'package:private_ledger/data/storage/vault_keys_native.dart';
import 'package:private_ledger/features/household/household_controller.dart';
import 'package:private_ledger/features/household/invite_codes.dart';
import 'package:private_ledger/features/household/household_journal.dart';
import 'package:private_ledger/features/household/relay_client.dart';

/// Run through scripts/verify_android_authenticated.mjs. Only public bootstrap
/// metadata crosses stdout; the host owns the production SQLite relay.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const origin = String.fromEnvironment('AUTH_RELAY_ORIGIN');
  testWidgets('Android protected peers use actual authenticated HTTP', (
    tester,
  ) async {
    final uri = Uri.parse(origin);
    expect(uri.scheme, 'http');
    expect(uri.host, '127.0.0.1');
    expect(uri.hasPort, isTrue);
    await RustLib.init();
    final namespace = 'android-auth-${DateTime.now().microsecondsSinceEpoch}';
    const marker = 'Private Android authenticated grocery';
    final live = <HouseholdController>{};
    final scopes = <String>{};

    HouseholdController restore(String scope) {
      scopes.add(scope);
      final next = HouseholdController(
        stateStore: SecretBlobStore(
          BlobStore('$namespace-$scope-state'),
          keys: NativeVaultKeys(key: 'cash-app.test.$namespace.$scope'),
        ),
        configStore: BlobStore('$namespace-$scope-config'),
      );
      live.add(next);
      return next;
    }

    void close(HouseholdController controller) {
      live.remove(controller);
      controller.dispose();
    }

    Future<void> consumed(HouseholdController device, String invite) async {
      final client = http.Client();
      try {
        final descriptor = decodeInvite(invite);
        final relay = HttpRelayClient(
          origin,
          client,
          device.relayRequestSigner,
          true,
        );
        expect(
          await relay.peekRosterWelcome(
            device.overview!.groupId!,
            descriptor.mailbox,
          ),
          isNull,
        );
      } finally {
        client.close();
      }
    }

    try {
      var alice = restore('alice');
      var bob = restore('bob');
      for (final device in [alice, bob]) {
        await device.initialize();
        expect(await device.setRelayUrl(origin, authenticated: true), isTrue);
      }
      // No worker exists until the owning host accepts this public setup.
      expect(await alice.createHousehold(), isFalse);
      expect(alice.overview!.isMember, isTrue);
      expect(alice.requiresRestart, isFalse);
      final aliceId = alice.overview!.memberIds.single;
      final root = await alice.relayBootstrapPolicy();
      expect(root, isNotNull);
      final policy = jsonDecode(root!) as Map<String, dynamic>;
      expect(policy['epoch'], 0);
      expect((policy['devices'] as List).length, 1);
      // Never print a recovery phrase, journal, private key or financial data.
      // ignore: avoid_print -- public owning-host fixture protocol, not app logging.
      print('ANDROID_AUTH_BOOTSTRAP:$root');
      final readyDeadline = DateTime.now().add(const Duration(seconds: 45));
      while (!await alice.syncNow()) {
        expect(alice.requiresRestart, isFalse);
        expect(DateTime.now().isBefore(readyDeadline), isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      expect(await alice.relayBootstrapPolicy(), isNull);
      final request = (await bob.prepareJoinRequest())!;
      final invite = (await alice.invite(request))!;
      expect(decodeInvite(invite).authenticated, isTrue);
      expect(await bob.acceptInvite(invite), isTrue);
      await consumed(bob, invite);
      final bobId = bob.overview!.memberIds.singleWhere((id) => id != aliceId);
      final groupId = alice.overview!.groupId;
      close(bob);
      bob = restore('bob');
      await bob.initialize();
      expect(bob.authenticatedRelay, isTrue);
      expect(bob.overview!.isMember, isTrue);
      expect(bob.overview!.groupId, groupId);
      expect(await bob.syncNow(), isTrue);
      expect(await alice.addExpense(title: marker, amount: '2.50'), isTrue);
      expect(await bob.syncNow(), isTrue);
      expect(bob.overview!.balanceLabel, 'USD -2.50');
      final earlyBobCiphertext = (await BlobStore('$namespace-bob-state')
          .read())!;
      final backup = (await bob.createBackup())!;
      final earlyBobCursor = bob.overview!.cursor.toInt();

      final keysBeforeRefresh = await alice.relayRosterKeys();
      final membersBeforeRefresh = List<String>.of(alice.overview!.memberIds);
      expect(await alice.refreshEncryptionKeys(), isTrue);
      expect(await bob.syncNow(), isTrue);
      expect(await alice.relayRosterKeys(), keysBeforeRefresh);
      expect(await bob.relayRosterKeys(), keysBeforeRefresh);
      expect(alice.overview!.memberIds, membersBeforeRefresh);
      expect(bob.overview!.balanceLabel, 'USD -2.50');

      expect(await alice.syncNow(), isTrue);
      expect(alice.canManageRelayRetention, isTrue);
      final retentionRequest = (await alice.prepareRetentionRequest())!;
      final approval = (await bob.approveRetentionRequest(retentionRequest))!;
      expect(await alice.reclaimRelayHistory(retentionRequest, []), isFalse);
      expect(
        await alice.reclaimRelayHistory(retentionRequest, [approval]),
        isTrue,
      );
      final authenticatedClient = http.Client();
      try {
        final relay = HttpRelayClient(
          origin,
          authenticatedClient,
          alice.relayRequestSigner,
          true,
        );
        await expectLater(
          relay.readAfter(groupId!, 0),
          throwsA(
            isA<RelayUnavailable>().having(
              (error) => error.message,
              'actual deleted-prefix status',
              contains('410'),
            ),
          ),
        );
      } finally {
        authenticatedClient.close();
      }

      // Controlled rollback of only this owned test namespace's sealed archive.
      // Keep its actual Android wrapping key; never export or log private bytes.
      // A closed controller owns no operation while SQLite is replaced.
      final currentBobCiphertext = (await BlobStore('$namespace-bob-state')
          .read())!;
      close(bob);
      await BlobStore('$namespace-bob-state').write(earlyBobCiphertext);
      bob = restore('bob');
      await bob.initialize();
      expect(bob.overview!.cursor.toInt(), earlyBobCursor);
      final stalePlaintext = (await SecretBlobStore(
        BlobStore('$namespace-bob-state'),
        keys: NativeVaultKeys(key: 'cash-app.test.$namespace.bob'),
      ).read())!;
      final staleJournal = HouseholdJournal.decode(stalePlaintext);
      expect(await bob.syncNow(), isFalse);
      expect(bob.errorMessage, contains('410'));
      expect(bob.overview!.cursor.toInt(), earlyBobCursor);
      // Sync confirms/reseals the same save before transport. AEAD uses a fresh
      // nonce, so require exact plaintext/journal preservation, not identical
      // envelope bytes; do not relax the original Rust-state/cursor invariant.
      final resealedStale = (await BlobStore('$namespace-bob-state').read())!;
      expect(
        latin1.decode(resealedStale),
        startsWith('cash-app sealed vault v1\u0000'),
      );
      expect(latin1.decode(resealedStale), isNot(contains(marker)));
      final afterFailure = (await SecretBlobStore(
        BlobStore('$namespace-bob-state'),
        keys: NativeVaultKeys(key: 'cash-app.test.$namespace.bob'),
      ).read())!;
      expect(afterFailure, stalePlaintext);
      expect(HouseholdJournal.decode(afterFailure).state, staleJournal.state);
      close(bob);
      await BlobStore('$namespace-bob-state').write(currentBobCiphertext);
      bob = restore('bob');
      await bob.initialize();
      expect(await bob.syncNow(), isTrue);

      final cara = restore('cara');
      await cara.initialize();
      expect(await cara.setRelayUrl(origin, authenticated: true), isTrue);
      final caraInvite = (await alice.invite(
        (await cara.prepareJoinRequest())!,
      ))!;
      expect(await cara.acceptInvite(caraInvite), isTrue);
      await consumed(cara, caraInvite);
      expect(await alice.syncNow(), isTrue);
      expect(await bob.syncNow(), isTrue);
      expect(cara.overview!.balanceLabel, 'USD -2.50');
      expect(
        cara.overview!.memberIds.toSet(),
        alice.overview!.memberIds.toSet(),
      );
      close(alice);
      alice = restore('alice');
      await alice.initialize();
      expect(alice.authenticatedRelay, isTrue);
      expect(await alice.syncNow(), isTrue);
      expect(await alice.removeMember(bobId), isTrue);
      expect(await bob.syncNow(), isTrue);
      expect(bob.overview!.isMember, isFalse);
      expect(await alice.addExpense(title: marker, amount: '2.50'), isTrue);
      expect(await cara.syncNow(), isTrue);
      expect(cara.overview!.balanceLabel, 'USD -5.00');
      expect(alice.overview!.balanceLabel, cara.overview!.balanceLabel);
      expect(await bob.addExpense(title: marker, amount: '2.50'), isFalse);
      expect(bob.overview!.balanceLabel, 'USD -2.50');

      // The early phrase backup cannot restore an old sender ratchet. A fourth
      // independently OS-protected identity rejoins and imports current history.
      var recovered = restore('recovered');
      await recovered.initialize();
      expect(
        await recovered.restoreBackup(backup.phrase, backup.backup),
        isTrue,
      );
      expect(recovered.needsRecoveryInvite, isTrue);
      final recoveredInvite = (await alice.invite(
        (await recovered.prepareJoinRequest())!,
      ))!;
      expect(await recovered.acceptInvite(recoveredInvite), isTrue);
      await consumed(recovered, recoveredInvite);
      close(recovered);
      close(alice);
      recovered = restore('recovered');
      alice = restore('alice');
      await recovered.initialize();
      await alice.initialize();
      expect(await alice.syncNow(), isTrue);
      expect(await recovered.syncNow(), isTrue);
      expect(await alice.syncNow(), isTrue);
      expect(recovered.needsRecoveryInvite, isFalse);
      expect(recovered.overview!.balanceLabel, 'USD -5.00');
      expect(recovered.overview!.transactions, alice.overview!.transactions);
      expect((await recovered.relayRosterKeys()).length, 3);
      expect(await recovered.addExpense(title: marker, amount: '1.00'), isTrue);
      expect(await cara.syncNow(), isTrue);
      expect(await alice.syncNow(), isTrue);
      expect(alice.overview!.balanceLabel, 'USD -6.00');
      expect(cara.overview!.balanceLabel, 'USD -6.00');

      // Actual app-private physical SQLite, not controlled save mocks.
      final directory = await getApplicationSupportDirectory();
      final physical = latin1.decode(
        await File('${directory.path}/cash-app.v1.sqlite').readAsBytes(),
      );
      expect(physical, startsWith('SQLite format 3\u0000'));
      expect(physical, contains('cash-app sealed vault v1\u0000'));
      expect(physical, isNot(contains(marker)));
      for (final scope in scopes) {
        final raw = (await BlobStore('$namespace-$scope-state').read())!;
        expect(
          latin1.decode(raw),
          startsWith('cash-app sealed vault v1\u0000'),
        );
        expect(latin1.decode(raw), isNot(contains(marker)));
      }
    } finally {
      for (final device in live) {
        device.dispose();
      }
      for (final scope in scopes) {
        await BlobStore('$namespace-$scope-state').delete();
        await BlobStore('$namespace-$scope-config').delete();
        await const FlutterSecureStorage().delete(
          key: 'cash-app.test.$namespace.$scope',
        );
      }
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
