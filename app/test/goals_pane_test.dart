import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/data/rust/api/goals.dart';
import 'package:private_ledger/data/rust/api/ledger.dart';
import 'package:private_ledger/features/ledger/goals_pane.dart';

void main() {
  testWidgets('empty state prompts to add a goal', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: GoalsPane(goals: []))),
    );

    expect(find.textContaining('No goals yet'), findsOneWidget);
  });

  testWidgets('a save goal card shows its progress toward the target', (
    tester,
  ) async {
    final goal = GoalView(
      id: 'vacation',
      name: 'Vacation',
      isSave: true,
      linkedAccountId: 'savings',
      categoryId: null,
      targetLabel: 'USD 1000.00',
      progressLabel: 'USD 250.00',
      percentComplete: PlatformInt64Util.from(25),
    );

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: GoalsPane(goals: [goal]))),
    );

    expect(find.text('Vacation'), findsOneWidget);
    expect(find.text('Save'), findsOneWidget);
    expect(find.text('USD 250.00 of USD 1000.00'), findsOneWidget);
    expect(find.text('25%'), findsOneWidget);
  });

  testWidgets('a spend goal past its cap is shown as over', (tester) async {
    final goal = GoalView(
      id: 'less-takeout',
      name: 'Less takeout',
      isSave: false,
      linkedAccountId: null,
      categoryId: 'food',
      targetLabel: 'USD 100.00',
      progressLabel: 'USD 150.00',
      percentComplete: PlatformInt64Util.from(150),
    );

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: GoalsPane(goals: [goal]))),
    );

    expect(find.text('Spend'), findsOneWidget);
    expect(find.text('150%'), findsOneWidget);
  });

  testWidgets('NewGoalDialog returns a save GoalDraft with a linked account', (
    tester,
  ) async {
    GoalDraft? result;
    const accounts = [
      AccountView(
        id: 'savings',
        name: 'Savings',
        currencyCode: 'USD',
        balanceLabel: 'USD 0.00',
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await showDialog<GoalDraft>(
                  context: context,
                  builder: (context) =>
                      const NewGoalDialog(accounts: accounts),
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

    await tester.enterText(find.byType(TextFormField).first, 'Vacation');
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Target amount'),
      '1000',
    );

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.name, 'Vacation');
    expect(result!.kind, GoalKind.save);
    expect(result!.targetAmount, '1000');
    expect(result!.linkedAccountId, 'savings');
  });

  testWidgets('NewGoalDialog returns a spend GoalDraft with no account', (
    tester,
  ) async {
    GoalDraft? result;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await showDialog<GoalDraft>(
                  context: context,
                  builder: (context) =>
                      const NewGoalDialog(accounts: []),
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

    await tester.enterText(find.byType(TextFormField).first, 'Less takeout');
    await tester.tap(find.byKey(const Key('goalKindDropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Spend under a cap').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Target amount'),
      '100',
    );

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.kind, GoalKind.spend);
    expect(result!.linkedAccountId, isNull);
  });

  testWidgets('tapping a goal\'s edit icon opens the dialog pre-filled', (
    tester,
  ) async {
    final goal = GoalView(
      id: 'vacation',
      name: 'Vacation',
      isSave: true,
      linkedAccountId: 'savings',
      categoryId: null,
      targetLabel: 'USD 1000.00',
      progressLabel: 'USD 250.00',
      percentComplete: PlatformInt64Util.from(25),
    );
    GoalView? edited;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GoalsPane(goals: [goal], onEdit: (g) => edited = g),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pump();

    expect(edited, goal);
  });

  testWidgets('NewGoalDialog in edit mode pre-fills name, kind, and target', (
    tester,
  ) async {
    final goal = GoalView(
      id: 'vacation',
      name: 'Vacation',
      isSave: true,
      linkedAccountId: 'savings',
      categoryId: null,
      targetLabel: 'USD 1000.00',
      progressLabel: 'USD 250.00',
      percentComplete: PlatformInt64Util.from(25),
    );
    const account = AccountView(
      id: 'savings',
      name: 'Savings',
      currencyCode: 'USD',
      balanceLabel: 'USD 250.00',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showDialog<GoalDraft>(
                context: context,
                builder: (context) =>
                    NewGoalDialog(accounts: const [account], existing: goal),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Edit goal'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Vacation'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, '1000.00'), findsOneWidget);
  });
}
