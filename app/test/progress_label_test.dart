import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/data/rust/api/budgets.dart';
import 'package:private_ledger/data/rust/api/goals.dart';
import 'package:private_ledger/features/ledger/budgets_pane.dart';
import 'package:private_ledger/features/ledger/goals_pane.dart';
import 'package:private_ledger/features/ledger/progress_label.dart';

void main() {
  test(
    'ordinary percentages remain exact; huge ones use a truthful lower bound',
    () {
      expect(progressPercentLabel(0), '0%');
      expect(progressPercentLabel(33), '33%');
      expect(progressPercentLabel(150), '150%');
      expect(progressPercentLabel(1000000), '1000000%');
      expect(progressPercentLabel(1000001), '>1,000,000%');
      expect(progressPercentLabel(9223372036854775807), '>1,000,000%');
    },
  );
  testWidgets('extreme goal and budget ratios stay readable on a phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final percent = PlatformInt64Util.from(9223372036854775807);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GoalsPane(
            goals: [
              GoalView(
                id: 'large',
                name: 'Large',
                isSave: true,
                linkedAccountId: 'checking',
                targetLabel: 'USD 0.01',
                progressLabel: 'USD 92233720368547758.07',
                percentComplete: percent,
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.text('>1,000,000%'), findsOneWidget);
    expect(find.textContaining('USD 92233720368547758.07'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BudgetsPane(
            categories: const [],
            budgets: [
              BudgetView(
                id: 'large',
                name: 'Large',
                periodLabel: 'This month',
                limitLabel: 'USD 0.01',
                spentLabel: 'USD 92233720368547758.07',
                percentUsed: percent,
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.text('>1,000,000%'), findsOneWidget);
    expect(find.textContaining('USD 92233720368547758.07'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
