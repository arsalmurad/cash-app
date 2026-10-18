import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show PlatformInt64Util;
import 'package:private_ledger/data/rust/api/ledger.dart';
import 'package:private_ledger/data/rust/api/shared.dart';
import 'package:private_ledger/features/household/household_pane.dart';
import 'package:private_ledger/theme.dart';

void main() {
  for (final size in [
    const Size(360, 740),
    const Size(840, 600),
    const Size(1280, 900),
  ]) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'exact shared amount and actions at $size / $brightness / 200%',
        (tester) async {
          await tester.binding.setSurfaceSize(size);
          addTearDown(() => tester.binding.setSurfaceSize(null));
          var edits = 0;
          final overview = HouseholdOverview(
            memberId: 'me',
            groupId: '0123456789abcdef0123456789abcdef',
            isMember: true,
            cursor: PlatformInt64Util.from(1),
            pendingCount: PlatformInt64Util.from(0),
            memberIds: const ['me'],
            balanceLabel: 'USD -92233720368547758.07',
            accounts: const [
              AccountView(
                id: 'household',
                name: 'Shared household emergency expenses',
                currencyCode: 'USD',
                balanceLabel: 'USD -92233720368547758.07',
              ),
            ],
            transactions: const [
              SharedTransactionView(
                id: 'expense',
                accountId: 'household',
                title: 'International household emergency equipment and travel',
                amountLabel: 'USD 92233720368547758.07',
                isExpense: true,
                voided: false,
                conflicted: true,
              ),
            ],
            conflicts: const [],
            rejected: const [],
          );
          await tester.pumpWidget(
            MaterialApp(
              theme: ledgerTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(2)),
                child: child!,
              ),
              home: Scaffold(
                body: HouseholdPane(
                  overview: overview,
                  busy: false,
                  onSync: () {},
                  onInvite: () {},
                  onAddExpense: () {},
                  onRemoveMember: (_) {},
                  onVerifyMember: (_) {},
                  onEditAmount: (_) => edits++,
                  onVoid: (_) {},
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.scrollUntilVisible(
            find.text('−USD 92233720368547758.07'),
            300,
            scrollable: find.byType(Scrollable).first,
            maxScrolls: 30,
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.text('−USD 92233720368547758.07'), findsOneWidget);
          expect(find.text('Edited by two people at once'), findsOneWidget);
          final actions = find.byKey(const Key('actions-expense'));
          await Scrollable.ensureVisible(
            tester.element(actions),
            alignment: 0.5,
          );
          await tester.pumpAndSettle();
          expect(actions.hitTestable(), findsOneWidget);
          await tester.tap(actions);
          await tester.pumpAndSettle();
          await tester.tap(find.text('Change amount'));
          await tester.pumpAndSettle();
          expect(edits, 1);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }
}
