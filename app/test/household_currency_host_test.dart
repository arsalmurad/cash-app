import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/data/rust/frb_generated.dart';
import 'package:private_ledger/data/storage/blob_store.dart';
import 'package:private_ledger/features/household/household_controller.dart';
import 'package:private_ledger/features/household/relay_client.dart';

class _Store implements BlobStore {
  Uint8List? value;
  @override
  Future<Uint8List?> read() async => value;
  @override
  Future<void> write(Uint8List bytes) async =>
      value = Uint8List.fromList(bytes);
  @override
  Future<void> delete() async => value = null;
}

void main() {
  final libraryPath = Platform.environment['RUST_LIB_PATH'];
  test(
    'shared foreign currency freezes rates across edits, sync and restart',
    () async {
      await RustLib.init(externalLibrary: ExternalLibrary.open(libraryPath!));
      final relay = MemoryRelayClient();
      final state = _Store();
      final config = _Store();
      var clock = 1000;
      HouseholdController device() => HouseholdController(
        stateStore: state,
        configStore: config,
        relayFactory: (_) => relay,
        clockMillis: () => ++clock,
        newMemberId: () => 'alice-currency',
      );
      final alice = device();
      addTearDown(alice.dispose);
      await alice.initialize();
      expect(await alice.setRelayUrl('http://127.0.0.1:8787'), isTrue);
      expect(await alice.createHousehold(), isTrue);
      final beforeAccount = Uint8List.fromList(state.value!);
      expect(await alice.addAccount(name: '  ', currencyCode: 'EUR'), isFalse);
      expect(state.value, orderedEquals(beforeAccount));
      final bob = HouseholdController(
        stateStore: _Store(),
        configStore: _Store(),
        relayFactory: (_) => relay,
        newMemberId: () => 'bob-currency',
        clockMillis: () => ++clock,
      );
      addTearDown(bob.dispose);
      await bob.initialize();
      final request = await bob.prepareJoinRequest();
      final invite = await alice.invite(request!);
      expect(await bob.acceptInvite(invite!), isTrue);
      expect(
        await alice.addAccount(name: 'Travel', currencyCode: 'EUR'),
        isTrue,
      );
      final account = alice.overview!.accounts.singleWhere(
        (a) => a.currencyCode == 'EUR',
      );
      final savedBefore = Uint8List.fromList(state.value!);
      expect(
        await alice.addExpense(
          title: 'Missing rate',
          amount: '10',
          accountId: account.id,
        ),
        isFalse,
      );
      expect(
        state.value,
        orderedEquals(savedBefore),
        reason: 'Invalid input must not mutate persisted keys/events',
      );
      for (final rate in [
        '0',
        '-1',
        'NaN',
        '1e3',
        '999999999999999999999999999',
      ]) {
        expect(
          await alice.addExpense(
            title: 'Invalid rate',
            amount: '10',
            accountId: account.id,
            rate: rate,
          ),
          isFalse,
        );
        expect(state.value, orderedEquals(savedBefore));
      }
      expect(
        await alice.addExpense(
          title: 'Not shared',
          amount: '10',
          accountId: 'private-account',
          rate: '1',
        ),
        isFalse,
      );
      expect(state.value, orderedEquals(savedBefore));
      expect(
        await alice.addExpense(
          title: 'First',
          amount: '10',
          accountId: account.id,
          rate: '1.1',
        ),
        isTrue,
      );
      expect(
        await alice.addExpense(
          title: 'Second',
          amount: '10',
          accountId: account.id,
          rate: '1.2',
        ),
        isTrue,
      );
      expect(alice.overview!.balanceLabel, 'USD -23.00');
      expect(
        alice.overview!.transactions.map((t) => t.amountLabel),
        everyElement('EUR 10.00'),
      );
      final first = alice.overview!.transactions.singleWhere(
        (t) => t.title == 'First',
      );
      expect(await alice.adjustAmount(first.id, '12', rate: '1.1'), isTrue);
      expect(alice.overview!.balanceLabel, 'USD -25.20');
      final beforeEdit = Uint8List.fromList(state.value!);
      expect(await alice.adjustAmount(first.id, '50'), isFalse);
      expect(state.value, orderedEquals(beforeEdit));
      expect(
        await alice.addAccount(name: 'Japan', currencyCode: 'JPY'),
        isTrue,
      );
      final yen = alice.overview!.accounts.singleWhere(
        (a) => a.currencyCode == 'JPY',
      );
      expect(
        await alice.addExpense(
          title: 'Train',
          amount: '100',
          accountId: yen.id,
          rate: '0.0067',
        ),
        isTrue,
      );
      expect(alice.overview!.balanceLabel, 'USD -25.87');
      expect(
        await alice.addExpense(
          title: 'Fractional yen',
          amount: '1.5',
          accountId: yen.id,
          rate: '0.0067',
        ),
        isFalse,
      );
      expect(alice.overview!.balanceLabel, 'USD -25.87');
      expect(await bob.syncNow(), isTrue);
      expect(bob.overview!.balanceLabel, 'USD -25.87');
      expect(bob.overview!.accounts.length, 3);
      expect(
        bob.overview!.transactions
            .singleWhere((t) => t.title == 'Second')
            .amountLabel,
        'EUR 10.00',
      );
      expect(bob.overview!.rejected, isEmpty);
      final restarted = device();
      addTearDown(restarted.dispose);
      await restarted.initialize();
      expect(restarted.errorMessage, isNull);
      expect(restarted.overview!.balanceLabel, 'USD -25.87');
      expect(
        restarted.overview!.transactions
            .singleWhere((t) => t.title == 'First')
            .amountLabel,
        'EUR 12.00',
      );
      expect(restarted.overview!.rejected, isEmpty);
    },
    skip: libraryPath == null ? 'Set RUST_LIB_PATH for the real bridge' : false,
  );
}
