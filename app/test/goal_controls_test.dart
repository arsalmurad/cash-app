import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/data/rust/api/categories.dart';
import 'package:private_ledger/data/rust/api/goals.dart';
import 'package:private_ledger/data/rust/api/ledger.dart';
import 'package:private_ledger/features/ledger/goals_pane.dart';

const accounts = [
  AccountView(
    id: 'yen',
    name: 'Yen',
    currencyCode: 'JPY',
    balanceLabel: 'JPY 0',
  ),
];
const categories = [CategoryView(id: 'food', name: 'Food', iconKey: 'food')];

GoalView spendingGoal({String? categoryId = 'food'}) => GoalView(
  id: 'cap',
  name: 'Food cap',
  isSave: false,
  categoryId: categoryId,
  targetLabel: 'USD 100.00',
  progressLabel: 'USD 0.00',
  percentComplete: PlatformInt64Util.from(0),
  deadlineMillis: PlatformInt64Util.from(
    DateTime(2030, 1, 20, 12).millisecondsSinceEpoch,
  ),
);

Future<void> open(
  WidgetTester tester,
  NewGoalDialog dialog,
  void Function(GoalDraft?) receive,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              receive(
                await showDialog<GoalDraft>(
                  context: context,
                  builder: (_) => dialog,
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('spending category can be selected and cleared', (tester) async {
    GoalDraft? result;
    await open(
      tester,
      NewGoalDialog(
        accounts: accounts,
        categories: categories,
        existing: spendingGoal(categoryId: null),
      ),
      (draft) => result = draft,
    );
    await tester.ensureVisible(find.byKey(const Key('goalCategoryDropdown')));
    await tester.tap(find.byKey(const Key('goalCategoryDropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Food').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(result!.categoryId, 'food');
    await open(
      tester,
      NewGoalDialog(
        accounts: accounts,
        categories: categories,
        existing: spendingGoal(),
      ),
      (draft) => result = draft,
    );
    await tester.ensureVisible(find.byKey(const Key('goalCategoryDropdown')));
    await tester.tap(find.byKey(const Key('goalCategoryDropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All categories').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(result!.categoryId, isNull);
  });
  testWidgets(
    'saving currency follows the account and spending uses reporting currency',
    (tester) async {
      await open(tester, const NewGoalDialog(accounts: accounts), (_) {});
      expect(find.text('Target currency: JPY'), findsOneWidget);
      await tester.tap(find.byKey(const Key('goalKindDropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Spend under a cap').last);
      await tester.pumpAndSettle();
      expect(find.text('Target currency: USD'), findsOneWidget);
      expect(find.text('All categories'), findsOneWidget);
    },
  );

  testWidgets('editing preserves category and exact deadline unless cleared', (
    tester,
  ) async {
    final existing = spendingGoal();
    GoalDraft? result;
    await open(
      tester,
      NewGoalDialog(
        accounts: accounts,
        categories: categories,
        existing: existing,
      ),
      (draft) => result = draft,
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(result!.categoryId, 'food');
    expect(result!.deadlineMillis, existing.deadlineMillis);
    await open(
      tester,
      NewGoalDialog(
        accounts: accounts,
        categories: categories,
        existing: existing,
      ),
      (draft) => result = draft,
    );
    await tester.ensureVisible(
      find.byKey(const Key('goalClearDeadlineButton')),
    );
    await tester.tap(find.byKey(const Key('goalClearDeadlineButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(result!.deadlineMillis, isNull);
    expect(result!.categoryId, 'food');
  });

  testWidgets(
    'changing a spending goal to saving clears incompatible category',
    (tester) async {
      GoalDraft? result;
      await open(
        tester,
        NewGoalDialog(
          accounts: accounts,
          categories: categories,
          existing: spendingGoal(),
        ),
        (draft) => result = draft,
      );
      await tester.tap(find.byKey(const Key('goalKindDropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save toward a target').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(result!.categoryId, isNull);
      expect(result!.linkedAccountId, 'yen');
    },
  );

  testWidgets(
    'missing category remains explicit and is not silently replaced',
    (tester) async {
      GoalDraft? result;
      await open(
        tester,
        NewGoalDialog(
          accounts: accounts,
          categories: categories,
          existing: spendingGoal(categoryId: 'missing'),
        ),
        (draft) => result = draft,
      );
      expect(find.text('Unavailable category'), findsOneWidget);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(result!.categoryId, 'missing');
    },
  );

  testWidgets(
    'deadline picker stores inclusive end of selected local day on phone',
    (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      GoalDraft? result;
      await open(
        tester,
        NewGoalDialog(
          accounts: accounts,
          existing: spendingGoal(categoryId: null),
        ),
        (draft) => result = draft,
      );
      await tester.ensureVisible(find.byKey(const Key('goalDeadlineButton')));
      await tester.tap(find.byKey(const Key('goalDeadlineButton')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(
        result!.deadlineMillis!.toInt(),
        DateTime(2030, 1, 21).millisecondsSinceEpoch - 1,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
