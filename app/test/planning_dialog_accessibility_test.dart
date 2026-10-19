import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/data/rust/api/budgets.dart';
import 'package:private_ledger/data/rust/api/categories.dart';
import 'package:private_ledger/data/rust/api/goals.dart';
import 'package:private_ledger/data/rust/api/ledger.dart';
import 'package:private_ledger/data/rust/api/recurring.dart';
import 'package:private_ledger/features/ledger/budgets_pane.dart';
import 'package:private_ledger/features/ledger/goals_pane.dart';
import 'package:private_ledger/features/ledger/recurring_pane.dart';
import 'package:private_ledger/theme.dart';

const _categoryName = 'Groceries and household supplies for the entire family';
const _otherCategoryName =
    'Travel and accommodation for the annual family holiday';
const _accountName =
    'Everyday purchases and household expenses in Japanese yen';
const _otherAccountName =
    'Long term holiday savings and emergency fund in Japanese yen';
const _categories = [
  CategoryView(id: 'food', name: _categoryName, iconKey: 'restaurant'),
  CategoryView(id: 'travel', name: _otherCategoryName, iconKey: 'flight'),
];
const _accounts = [
  AccountView(
    id: 'daily',
    name: _accountName,
    currencyCode: 'JPY',
    balanceLabel: 'JPY 123',
  ),
  AccountView(
    id: 'savings',
    name: _otherAccountName,
    currencyCode: 'JPY',
    balanceLabel: 'JPY 0',
  ),
];

Future<void> _open<T>(
  WidgetTester tester, {
  required Widget dialog,
  required Brightness brightness,
  required ValueChanged<T?> onResult,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ledgerTheme(brightness),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(2)),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async => onResult(
              await showDialog<T>(context: context, builder: (_) => dialog),
            ),
            child: const Text('Open planning dialog'),
          ),
        ),
      ),
    ),
  );
  await tester.sendKeyEvent(LogicalKeyboardKey.tab);
  await tester.pump();
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.pumpAndSettle();
  expect(
    tester.takeException(),
    isNull,
    reason: 'The enlarged dialog must lay out without overflow.',
  );
}

Future<void> _select(WidgetTester tester, String key, String label) async {
  final field = find.byKey(Key(key));
  await Scrollable.ensureVisible(tester.element(field), alignment: 0.5);
  await tester.pumpAndSettle();
  expect(field.hitTestable(), findsOneWidget);
  await tester.tap(field);
  await tester.pumpAndSettle();
  expect(
    tester.takeException(),
    isNull,
    reason: 'The dropdown must fit full enlarged labels.',
  );
  final option = find.text(label).last;
  await tester.ensureVisible(option);
  await tester.pumpAndSettle();
  await tester.tap(option);
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  final paragraph = tester.renderObject<RenderParagraph>(
    find.text(label).first,
  );
  final bounds = tester.getRect(field).inflate(1);
  for (final box in paragraph.getBoxesForSelection(
    TextSelection(baseOffset: 0, extentOffset: label.length),
  )) {
    final start = paragraph.localToGlobal(Offset(box.left, box.top));
    final end = paragraph.localToGlobal(Offset(box.right, box.bottom));
    expect(
      bounds.contains(start) && bounds.contains(end),
      isTrue,
      reason:
          'Every line of the selected label must be visible inside its field.',
    );
  }
}

Future<void> _save(WidgetTester tester) async {
  final save = find.widgetWithText(FilledButton, 'Save');
  expect(save.hitTestable(), findsOneWidget);
  await tester.tap(save);
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

void main() {
  for (final size in [
    const Size(360, 740),
    const Size(840, 600),
    const Size(1280, 900),
  ]) {
    for (final brightness in Brightness.values) {
      testWidgets('budget dialog at $size, $brightness, 200% text', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final existing = BudgetView(
          id: 'budget',
          name: 'Household budget',
          categoryId: 'food',
          periodLabel: 'Last 365 days',
          limitLabel: 'USD 92233720368547758.07',
          spentLabel: 'USD 1.00',
          percentUsed: PlatformInt64Util.from(0),
        );
        BudgetDraft? result;
        var returns = 0;
        await _open<BudgetDraft>(
          tester,
          dialog: NewBudgetDialog(categories: _categories, existing: existing),
          brightness: brightness,
          onResult: (draft) {
            result = draft;
            returns++;
          },
        );
        await _select(tester, 'budgetCategoryDropdown', _otherCategoryName);
        await _select(tester, 'budgetPeriodDropdown', 'Custom (rolling days)');
        await _save(tester);
        expect(returns, 1);
        expect(result!.categoryId, 'travel');
        expect(result!.limitAmount, '92233720368547758.07');
        expect(result!.customPeriodDays, 365);
        expect(result!.period, BudgetPeriodKind.custom);
        expect(existing.categoryId, 'food');
        await tester.pumpWidget(const SizedBox.shrink());
      });

      testWidgets('recurring dialog at $size, $brightness, 200% text', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final start = PlatformInt64Util.from(
          DateTime(2030, 1, 20, 12).millisecondsSinceEpoch,
        );
        final existing = UpcomingView(
          recurringId: 'bill',
          title: 'Annual household insurance',
          isExpense: true,
          amountLabel: 'JPY 9223372036854775807',
          accountId: 'daily',
          categoryId: 'food',
          frequency: RecurringFrequency.monthly,
          occurrenceMillis: start,
          isOverdue: false,
        );
        RecurringDraft? result;
        var returns = 0;
        await _open<RecurringDraft>(
          tester,
          dialog: NewRecurringDialog(
            accounts: _accounts,
            categories: _categories,
            existing: existing,
          ),
          brightness: brightness,
          onResult: (draft) {
            result = draft;
            returns++;
          },
        );
        await _select(tester, 'recurringKindDropdown', 'Income');
        await _select(tester, 'recurringAccountDropdown', _otherAccountName);
        await _select(tester, 'recurringCategoryDropdown', _otherCategoryName);
        await _select(tester, 'recurringFrequencyDropdown', 'Yearly');
        await _save(tester);
        expect(returns, 1);
        expect(result!.amount, '9223372036854775807');
        expect(result!.accountId, 'savings');
        expect(result!.categoryId, 'travel');
        expect(result!.frequency, RecurringFrequency.yearly);
        expect(result!.kind, RecurringKind.income);
        expect(result!.startMillis, start);
        expect(existing.accountId, 'daily');
        await tester.pumpWidget(const SizedBox.shrink());
      });

      for (final saving in [true, false]) {
        testWidgets(
          '${saving ? 'saving' : 'spending'} goal dialog at $size, $brightness, 200% text',
          (tester) async {
            await tester.binding.setSurfaceSize(size);
            addTearDown(() => tester.binding.setSurfaceSize(null));
            final deadline = PlatformInt64Util.from(
              DateTime(2030, 1, 20, 12).millisecondsSinceEpoch,
            );
            final existing = GoalView(
              id: 'goal',
              name: saving ? 'Holiday savings' : 'Holiday spending',
              isSave: saving,
              linkedAccountId: saving ? 'daily' : null,
              categoryId: saving ? null : 'food',
              deadlineMillis: deadline,
              targetLabel: saving
                  ? 'JPY 9223372036854775807'
                  : 'USD 92233720368547758.07',
              progressLabel: saving ? 'JPY 123' : 'USD 1.00',
              percentComplete: PlatformInt64Util.from(0),
            );
            GoalDraft? result;
            var returns = 0;
            final dialog = NewGoalDialog(
              accounts: _accounts,
              categories: _categories,
              existing: existing,
            );
            await _open<GoalDraft>(
              tester,
              dialog: dialog,
              brightness: brightness,
              onResult: (draft) {
                result = draft;
                returns++;
              },
            );
            await _select(
              tester,
              'goalKindDropdown',
              saving ? 'Save toward a target' : 'Spend under a cap',
            );
            await _select(
              tester,
              saving ? 'goalAccountDropdown' : 'goalCategoryDropdown',
              saving ? _otherAccountName : _otherCategoryName,
            );
            await _save(tester);
            expect(returns, 1);
            expect(
              result!.targetAmount,
              saving ? '9223372036854775807' : '92233720368547758.07',
            );
            expect(result!.deadlineMillis, deadline);
            expect(result!.linkedAccountId, saving ? 'savings' : null);
            expect(result!.categoryId, saving ? null : 'travel');

            await tester.pumpWidget(const SizedBox.shrink());
            await _open<GoalDraft>(
              tester,
              dialog: dialog,
              brightness: brightness,
              onResult: (draft) {
                result = draft;
                returns++;
              },
            );
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
            await tester.pumpAndSettle();
            expect(result, isNull);
            expect(returns, 2);
            expect(
              find.text('Open planning dialog').hitTestable(),
              findsOneWidget,
            );
            final opener = find
                .widgetWithText(TextButton, 'Open planning dialog')
                .evaluate()
                .single;
            var focusReturned = false;
            FocusManager.instance.primaryFocus?.context?.visitAncestorElements((
              element,
            ) {
              if (element == opener) focusReturned = true;
              return !focusReturned;
            });
            expect(focusReturned, isTrue);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox.shrink());
          },
        );
      }
    }
  }
}
