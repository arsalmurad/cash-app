import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth_platform_interface/local_auth_platform_interface.dart';
import 'package:private_ledger/data/rust/api/ledger.dart';
import 'package:private_ledger/features/ledger/budgets_pane.dart';
import 'package:private_ledger/features/ledger/goals_pane.dart';
import 'package:private_ledger/features/ledger/ledger_controller.dart';
import 'package:private_ledger/features/ledger/ledger_screen.dart';
import 'package:private_ledger/features/ledger/recurring_pane.dart';
import 'package:private_ledger/features/lock/lock_settings_dialog.dart';
import 'package:private_ledger/theme.dart';

class _UnavailableAuthPlatform extends LocalAuthPlatform {
  @override
  Future<bool> isDeviceSupported() async =>
      throw UnsupportedError('Synthetic unavailable authentication plugin');
}

void main() {
  for (final size in [
    const Size(360, 740),
    const Size(840, 600),
    const Size(1280, 900),
  ]) {
    for (final brightness in Brightness.values) {
      for (final textScale in [1.5, 2.0]) {
        testWidgets(
          'all ledger destinations at $size, $brightness, ${textScale}x text',
          (tester) async {
            await tester.binding.setSurfaceSize(size);
            addTearDown(() => tester.binding.setSurfaceSize(null));
            final semantics = tester.ensureSemantics();
            final previousPlatform = debugDefaultTargetPlatformOverride;
            try {
              debugDefaultTargetPlatformOverride = TargetPlatform.windows;
              final previousAuth = LocalAuthPlatform.instance;
              LocalAuthPlatform.instance = _UnavailableAuthPlatform();
              addTearDown(() => LocalAuthPlatform.instance = previousAuth);
              final controller = LedgerController()
                ..isLoading = false
                ..overview = const LedgerOverview(
                  balanceLabel: 'USD -10000000000000000.00',
                  accounts: [
                    AccountView(
                      id: 'daily',
                      name: 'Everyday',
                      currencyCode: 'USD',
                      balanceLabel: 'USD -10000000000000000.00',
                      reportingBalanceLabel: 'USD -10000000000000000.00',
                    ),
                  ],
                  transactions: [
                    TransactionView(
                      id: 'groceries',
                      accountId: 'daily',
                      title: 'Groceries and household supplies for the week',
                      amountLabel: 'USD 10000000000000000.00',
                      voided: false,
                      isExpense: true,
                    ),
                  ],
                  transfers: [],
                );
              addTearDown(controller.dispose);
              await tester.pumpWidget(
                MaterialApp(
                  theme: ledgerTheme(brightness),
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(context)
                        .copyWith(textScaler: TextScaler.linear(textScale)),
                    child: child!,
                  ),
                  home: LedgerScreen(controller: controller),
                ),
              );
              await tester.pumpAndSettle();
              final wide = size.width >= 840;
              expect(
                find.byType(NavigationRail),
                wide ? findsOneWidget : findsNothing,
              );
              expect(
                find.byType(NavigationBar),
                wide ? findsNothing : findsOneWidget,
              );
              expect(tester.takeException(), isNull);
              expect(find.text('USD -10000000000000000.00'), findsNWidgets(2));
              expect(find.text('≈ USD -10000000000000000.00'), findsOneWidget);
              expect(find.byIcon(Icons.repeat_outlined), findsOneWidget);
              final destinations = <String, Type>{
                'Activity': ActivityPane,
                'Budgets': BudgetsPane,
                'Goals': GoalsPane,
                'Recurring': RecurringPane,
                'Overview': OverviewPane,
              };
              for (final destination in destinations.entries) {
                final target = find.descendant(
                  of: find.byType(wide ? NavigationRail : NavigationBar),
                  matching: find.text(destination.key),
                );
                expect(target.hitTestable(), findsOneWidget);
                await tester.tap(target);
                await tester.pumpAndSettle();
                expect(find.byType(destination.value), findsOneWidget);
                if (destination.key == 'Recurring') {
                  expect(find.byIcon(Icons.repeat), findsOneWidget);
                }
                expect(
                  tester.takeException(),
                  isNull,
                  reason: '${destination.key} must fit without render overflow',
                );
                await expectLater(
                  tester,
                  meetsGuideline(labeledTapTargetGuideline),
                );
                await expectLater(
                  tester,
                  meetsGuideline(androidTapTargetGuideline),
                );
                if (destination.key == 'Overview') {
                  await expectLater(
                    tester,
                    meetsGuideline(textContrastGuideline),
                  );
                }
              }
              expect(find.text('Calculated on this device'), findsOneWidget);
              final lockSettings = find.byTooltip('Screen lock settings');
              expect(lockSettings.hitTestable(), findsOneWidget);
              await tester.tap(lockSettings);
              await tester.pumpAndSettle();
              expect(find.byType(LockSettingsDialog), findsOneWidget);
              await tester.tap(find.text('Close'));
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull);
              await tester.pumpWidget(const SizedBox.shrink());
            } finally {
              debugDefaultTargetPlatformOverride = previousPlatform;
              semantics.dispose();
            }
          },
        );
      }
    }
  }
}
