import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:private_ledger/data/rust/api/goals.dart';
import 'package:private_ledger/data/rust/frb_generated.dart';
import 'package:private_ledger/data/storage/event_store.dart';
import 'package:private_ledger/features/ledger/ledger_controller.dart';

class _Paths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

void main() {
  final libraryPath = Platform.environment['RUST_LIB_PATH'];
  group(
    'real savings-goal currency validation',
    () {
      late Directory directory;
      late PathProviderPlatform previousPaths;
      setUpAll(() async {
        await RustLib.init(externalLibrary: ExternalLibrary.open(libraryPath!));
      });
      setUp(() async {
        directory = await Directory.systemTemp.createTemp(
          'cash-goal-currency-',
        );
        previousPaths = PathProviderPlatform.instance;
        PathProviderPlatform.instance = _Paths(directory.path);
      });
      tearDown(() async {
        PathProviderPlatform.instance = previousPaths;
        await directory.delete(recursive: true);
      });

      test(
        'JPY target uses linked-account units through edit and restart',
        () async {
          final controller = LedgerController();
          addTearDown(controller.dispose);
          await controller.initialize();
          expect(
            await controller.createAccount(name: 'Yen', currencyCode: 'JPY'),
            isTrue,
          );
          expect(
            await controller.addOrUpdateGoal(
              name: 'Yen savings',
              kind: GoalKind.save,
              targetAmount: '100',
              linkedAccountId: 'yen',
            ),
            isTrue,
          );
          expect(controller.goals.single.targetLabel, 'JPY 100');
          final id = controller.goals.single.id;
          expect(
            await controller.addOrUpdateGoal(
              goalId: id,
              name: 'Yen savings',
              kind: GoalKind.save,
              targetAmount: '123',
              linkedAccountId: 'yen',
            ),
            isTrue,
          );
          final restarted = LedgerController();
          addTearDown(restarted.dispose);
          await restarted.initialize();
          expect(restarted.errorMessage, isNull);
          expect(restarted.goals.single.targetLabel, 'JPY 123');
        },
      );

      test('fractional JPY and unknown linked accounts cannot persist invalid goals', () async {
        final controller = LedgerController();
        addTearDown(controller.dispose);
        await controller.initialize();
        expect(
          await controller.createAccount(name: 'Yen', currencyCode: 'JPY'),
          isTrue,
        );
        final before = await EventStore('goals').readLog();
        expect(
          await controller.addOrUpdateGoal(
            name: 'Invalid yen',
            kind: GoalKind.save,
            targetAmount: '1.5',
            linkedAccountId: 'yen',
          ),
          isFalse,
        );
        expect(await EventStore('goals').readLog(), orderedEquals(before));
        expect(
          await controller.addOrUpdateGoal(
            name: 'Missing account',
            kind: GoalKind.save,
            targetAmount: '100',
            linkedAccountId: 'missing',
          ),
          isFalse,
        );
        expect(await EventStore('goals').readLog(), orderedEquals(before));
        final restarted = LedgerController();
        addTearDown(restarted.dispose);
        await restarted.initialize();
        expect(restarted.errorMessage, isNull);
        expect(restarted.goals, isEmpty);
      });
      test(
        'missing linked account is rejected before writing a goal',
        () async {
          final controller = LedgerController();
          addTearDown(controller.dispose);
          await controller.initialize();
          final before = await EventStore('goals').readLog();
          expect(
            await controller.addOrUpdateGoal(
              name: 'Missing account',
              kind: GoalKind.save,
              targetAmount: '100',
              linkedAccountId: 'missing',
            ),
            isFalse,
          );
          expect(await EventStore('goals').readLog(), orderedEquals(before));
          final restarted = LedgerController();
          addTearDown(restarted.dispose);
          await restarted.initialize();
          expect(restarted.errorMessage, isNull);
          expect(restarted.goals, isEmpty);
        },
      );
    },
    skip: libraryPath == null
        ? 'Set RUST_LIB_PATH for actual bridge tests'
        : false,
  );
}
