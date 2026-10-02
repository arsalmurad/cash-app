import 'dart:async';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/data/rust/api/budgets.dart';
import 'package:private_ledger/data/rust/api/goals.dart';
import 'package:private_ledger/data/rust/api/ledger.dart';
import 'package:private_ledger/data/rust/api/recurring.dart';
import 'package:private_ledger/data/rust/frb_generated.dart';
import 'package:private_ledger/data/storage/event_store.dart';
import 'package:private_ledger/features/ledger/ledger_controller.dart';

class _Identity implements DeviceIdentity {
  String? actor;
  @override
  Future<String?> readActorId() async => actor;
  @override
  Future<void> writeActorId(String actorId) async => actor = actorId;
}

class _Store implements EventStore {
  Uint8List bytes = Uint8List(0);
  String? failure;
  bool failRead = false;
  Completer<void>? entered;
  Completer<void>? release;
  int appends = 0;

  @override
  Future<Uint8List> readLog() async {
    if (failRead) throw StateError('read unavailable');
    return Uint8List.fromList(bytes);
  }

  @override
  Future<void> appendFrame(Uint8List frame) async {
    appends++;
    if (entered != null && !entered!.isCompleted) entered!.complete();
    await release?.future;
    final mode = failure;
    failure = null;
    if (mode == 'torn') {
      bytes = Uint8List.fromList([...bytes, ...frame.take(3)]);
    } else if (mode != 'before') {
      bytes = Uint8List.fromList([...bytes, ...frame]);
    }
    if (mode != null) throw StateError('save unavailable');
  }

  @override
  Future<void> recoverPrefix(
    int validLength, {
    required int expectedLength,
  }) async {
    expect(bytes.length, expectedLength);
    bytes = Uint8List.fromList(bytes.take(validLength).toList());
  }
}

Future<bool> _write(
  LedgerController controller,
  String kind,
  String title,
) async {
  switch (kind) {
    case 'ledger':
      return controller.record(
        accountId: 'everyday',
        title: title,
        amount: '10.00',
        kind: EntryKind.expense,
      );
    case 'categories':
      return await controller.addCategory(name: title, iconKey: 'home') != null;
    case 'budgets':
      return controller.addOrUpdateBudget(
        name: title,
        limitAmount: '100.00',
        period: BudgetPeriodKind.monthly,
      );
    case 'goals':
      return controller.addOrUpdateGoal(
        name: title,
        kind: GoalKind.save,
        targetAmount: '200.00',
        linkedAccountId: 'everyday',
      );
    case 'recurring':
      return controller.addOrUpdateRecurring(
        title: title,
        kind: RecurringKind.expense,
        amount: '1.00',
        accountId: 'everyday',
        frequency: RecurringFrequency.monthly,
        startMillis: PlatformInt64Util.from(
          DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch,
        ),
      );
    default:
      throw StateError(kind);
  }
}

List<String> _labels(LedgerController controller, String kind) =>
    switch (kind) {
      'ledger' =>
        controller.overview!.transactions.map((item) => item.title).toList(),
      'categories' => controller.categories.map((item) => item.name).toList(),
      'budgets' => controller.budgets.map((item) => item.name).toList(),
      'goals' => controller.goals.map((item) => item.name).toList(),
      'recurring' => controller.upcoming.map((item) => item.title).toList(),
      _ => throw StateError(kind),
    };

void main() {
  final path = Platform.environment['RUST_LIB_PATH'];
  group('failed saves against the real Rust bridge', () {
    late _Identity identity;
    late Map<String, _Store> stores;
    LedgerController create({DateTime Function()? now}) {
      final controller = LedgerController(
        identity: identity,
        ledgerStore: stores['ledger'],
        categoryStore: stores['categories'],
        budgetStore: stores['budgets'],
        goalStore: stores['goals'],
        recurringStore: stores['recurring'],
        now: now,
      );
      addTearDown(controller.dispose);
      return controller;
    }

    setUpAll(() async {
      await RustLib.init(externalLibrary: ExternalLibrary.open(path!));
    });
    setUp(() {
      identity = _Identity();
      stores = {
        for (final name in [
          'ledger',
          'categories',
          'budgets',
          'goals',
          'recurring',
        ])
          name: _Store(),
      };
    });

    test(
      'queued entries in one clock tick keep distinct transaction IDs',
      () async {
        final instant = DateTime(2030);
        final controller = create(now: () => instant);
        await controller.initialize();
        final results = await Future.wait([
          for (var i = 0; i < 8; i++)
            controller.record(
              accountId: 'everyday',
              title: 'Entry $i',
              amount: '1',
              kind: EntryKind.expense,
            ),
        ]);
        expect(results, everyElement(isTrue));
        expect(controller.overview!.transactions, hasLength(8));
        expect(
          controller.overview!.transactions.map((entry) => entry.id).toSet(),
          hasLength(8),
        );
        expect(controller.overview!.balanceLabel, 'USD -8.00');
        final restarted = create(now: () => instant);
        await restarted.initialize();
        expect(restarted.errorMessage, isNull);
        expect(restarted.overview!.transactions, hasLength(8));
      },
    );

    test(
      'same clock tick after restart cannot reuse a transaction ID',
      () async {
        final instant = DateTime(2030);
        final controller = create(now: () => instant);
        await controller.initialize();
        expect(
          await controller.record(
            accountId: 'everyday',
            title: 'Before',
            amount: '1',
            kind: EntryKind.expense,
          ),
          isTrue,
        );
        final restarted = create(now: () => instant);
        await restarted.initialize();
        expect(
          await restarted.record(
            accountId: 'everyday',
            title: 'After',
            amount: '2',
            kind: EntryKind.expense,
          ),
          isTrue,
        );
        expect(restarted.overview!.transactions, hasLength(2));
        expect(restarted.overview!.balanceLabel, 'USD -3.00');
      },
    );

    test(
      'queued transfers in one clock tick keep distinct transfer IDs',
      () async {
        final instant = DateTime(2030);
        final controller = create(now: () => instant);
        await controller.initialize();
        expect(
          await controller.createAccount(name: 'Other', currencyCode: 'USD'),
          isTrue,
        );
        final results = await Future.wait([
          for (var i = 0; i < 4; i++)
            controller.transfer(
              fromAccountId: 'everyday',
              toAccountId: 'other',
              sentAmount: '1',
              title: 'Transfer $i',
            ),
        ]);
        expect(results, everyElement(isTrue));
        expect(controller.overview!.transfers, hasLength(4));
        expect(
          controller.overview!.transfers.map((entry) => entry.id).toSet(),
          hasLength(4),
        );
        final restarted = create(now: () => instant);
        await restarted.initialize();
        expect(restarted.errorMessage, isNull);
        expect(restarted.overview!.transfers, hasLength(4));
      },
    );

    for (final kind in [
      'ledger',
      'categories',
      'budgets',
      'goals',
      'recurring',
    ]) {
      for (final mode in ['before', 'torn', 'complete']) {
        test(
          '$kind append failure ($mode) blocks writes until restart',
          () async {
            final controller = create();
            await controller.initialize();
            expect(controller.errorMessage, isNull);
            final before = _labels(controller, kind);
            stores[kind]!.failure = mode;
            expect(await _write(controller, kind, 'Failed'), isFalse);
            expect(_labels(controller, kind), before);
            expect(await _write(controller, kind, 'Later'), isFalse);
            expect(await _write(controller, 'ledger', 'Other log'), isFalse);
            expect(_labels(controller, kind), before);
            expect(controller.errorMessage, contains('Restart'));

            final restarted = create();
            await restarted.initialize();
            expect(restarted.errorMessage, isNull);
            // A flush error is ambiguous: the complete frame may be durable.
            expect(
              _labels(restarted, kind).contains('Failed'),
              mode == 'complete',
            );
            expect(_labels(restarted, kind), isNot(contains('Later')));
            expect(await _write(restarted, kind, 'After restart'), isTrue);
            expect(_labels(restarted, kind), contains('After restart'));
          },
        );
      }
    }

    test('a queued write cannot pass an in-flight failed append', () async {
      final controller = create();
      await controller.initialize();
      final store = stores['ledger']!;
      final before = store.appends;
      store.failure = 'torn';
      store.entered = Completer<void>();
      store.release = Completer<void>();
      final first = _write(controller, 'ledger', 'Failed');
      await store.entered!.future;
      final second = _write(controller, 'ledger', 'Queued');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      try {
        expect(store.appends, before + 1);
      } finally {
        store.release!.complete();
      }
      expect(await first, isFalse);
      expect(await second, isFalse);
      expect(store.appends, before + 1);
      expect(controller.overview!.balanceLabel, 'USD 0.00');
    });

    test('invalid input does not disable subsequent valid writes', () async {
      final controller = create();
      await controller.initialize();
      expect(
        await controller.record(
          accountId: 'everyday',
          title: 'Bad',
          amount: 'not money',
          kind: EntryKind.expense,
        ),
        isFalse,
      );
      expect(await _write(controller, 'ledger', 'Valid'), isTrue);
      expect(controller.overview!.balanceLabel, 'USD -10.00');
    });

    test(
      'successful overlapping saves are confirmed in order and survive restart',
      () async {
        final controller = create();
        await controller.initialize();
        final store = stores['ledger']!;
        final before = store.appends;
        store.entered = Completer<void>();
        store.release = Completer<void>();
        final first = _write(controller, 'ledger', 'First');
        await store.entered!.future;
        final second = _write(controller, 'ledger', 'Second');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        try {
          expect(store.appends, before + 1);
          expect(controller.overview!.balanceLabel, 'USD 0.00');
        } finally {
          store.release!.complete();
        }
        expect(await first, isTrue);
        expect(await second, isTrue);
        expect(controller.overview!.balanceLabel, 'USD -20.00');
        final restarted = create();
        await restarted.initialize();
        expect(restarted.errorMessage, isNull);
        expect(restarted.overview!.balanceLabel, 'USD -20.00');
        expect(_labels(restarted, 'ledger'), containsAll(['First', 'Second']));
      },
    );

    test('partially loaded initialization cannot accept writes', () async {
      stores['categories']!.failRead = true;
      final controller = create();
      await controller.initialize();
      expect(controller.errorMessage, isNotNull);
      expect(
        await controller.createAccount(name: 'Unsafe', currencyCode: 'USD'),
        isFalse,
      );
      expect(stores['ledger']!.appends, 0);
    });
  }, skip: path == null ? 'set RUST_LIB_PATH to the built Rust library' : false);
}
