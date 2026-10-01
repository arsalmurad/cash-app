import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show PlatformInt64Util;
import 'package:private_ledger/data/rust/api/ledger.dart';
import 'package:private_ledger/data/rust/api/shared.dart';
import 'package:private_ledger/features/household/household_pane.dart';
import 'package:private_ledger/features/household/household_setup_pane.dart';

const _me = 'aaaa0000aaaa0000aaaa0000aaaa0000';
const _other = 'bbbb1111bbbb1111bbbb1111bbbb1111';

HouseholdOverview _overview({
  List<SharedTransactionView> transactions = const [],
  List<RejectedView> rejected = const [],
  int pending = 0,
  List<String> members = const [_me, _other],
}) => HouseholdOverview(
  memberId: _me,
  groupId: '0123456789abcdef0123456789abcdef',
  isMember: true,
  cursor: PlatformInt64Util.from(7),
  pendingCount: PlatformInt64Util.from(pending),
  memberIds: members,
  balanceLabel: 'USD -40.00',
  accounts: const [
    AccountView(
      id: 'household',
      name: 'Household',
      currencyCode: 'USD',
      balanceLabel: 'USD -40.00',
    ),
  ],
  transactions: transactions,
  conflicts: const [],
  rejected: rejected,
);

const _dinner = SharedTransactionView(
  id: 'dinner',
  accountId: 'household',
  title: 'Dinner',
  amountLabel: 'USD 40.00',
  isExpense: true,
  voided: false,
  conflicted: false,
);

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('HouseholdPane', () {
    Future<Map<String, int>> pump(
      WidgetTester tester,
      HouseholdOverview overview, {
      bool busy = false,
    }) async {
      final calls = <String, int>{};
      void count(String name) => calls[name] = (calls[name] ?? 0) + 1;
      await tester.pumpWidget(
        _host(
          HouseholdPane(
            overview: overview,
            busy: busy,
            onSync: () => count('sync'),
            onInvite: () => count('invite'),
            onAddExpense: () => count('add'),
            onRemoveMember: (id) => count('remove:$id'),
            onVerifyMember: (id) => count('verify:$id'),
            onEditAmount: (t) => count('edit:${t.id}'),
            onVoid: (t) => count('void:${t.id}'),
          ),
        ),
      );
      return calls;
    }

    testWidgets('shows the shared balance, expenses, and members', (
      tester,
    ) async {
      await pump(tester, _overview(transactions: [_dinner]));
      expect(find.text('USD -40.00'), findsWidgets);
      expect(find.text('Dinner'), findsOneWidget);
      expect(find.text('−USD 40.00'), findsOneWidget);
      expect(find.text('You'), findsOneWidget);
      expect(find.text('Member bbbb11'), findsOneWidget);
    });

    testWidgets('only other members can be verified or removed', (
      tester,
    ) async {
      final calls = await pump(tester, _overview());
      expect(find.byKey(const Key('verify-$_me')), findsNothing);
      expect(find.byKey(const Key('remove-$_me')), findsNothing);

      await tester.tap(find.byKey(const Key('verify-$_other')));
      await tester.tap(find.byKey(const Key('remove-$_other')));
      expect(calls['verify:$_other'], 1);
      expect(calls['remove:$_other'], 1);
    });

    testWidgets('a conflicted expense says two people edited it', (
      tester,
    ) async {
      await pump(
        tester,
        _overview(
          transactions: [
            const SharedTransactionView(
              id: 'dinner',
              accountId: 'household',
              title: 'Dinner',
              amountLabel: 'USD 42.00',
              isExpense: true,
              voided: false,
              conflicted: true,
            ),
          ],
        ),
      );
      expect(find.text('Edited by two people at once'), findsOneWidget);
    });

    testWidgets('a voided expense is marked and cannot be edited again', (
      tester,
    ) async {
      await pump(
        tester,
        _overview(
          transactions: [
            const SharedTransactionView(
              id: 'dinner',
              accountId: 'household',
              title: 'Dinner',
              amountLabel: 'USD 40.00',
              isExpense: true,
              voided: true,
              conflicted: false,
            ),
          ],
        ),
      );
      expect(find.text('Voided'), findsOneWidget);
      expect(find.byKey(const Key('actions-dinner')), findsNothing);
    });

    testWidgets('edit and void are offered on a live expense', (tester) async {
      final calls = await pump(tester, _overview(transactions: [_dinner]));
      await tester.tap(find.byKey(const Key('actions-dinner')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Change amount'));
      await tester.pumpAndSettle();
      expect(calls['edit:dinner'], 1);

      await tester.tap(find.byKey(const Key('actions-dinner')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Void'));
      await tester.pumpAndSettle();
      expect(calls['void:dinner'], 1);
    });

    testWidgets('pending writes and rejected changes are surfaced', (
      tester,
    ) async {
      await pump(
        tester,
        _overview(
          pending: 2,
          rejected: const [RejectedView(eventId: 'e1', reason: 'x')],
        ),
      );
      expect(find.text('2 changes waiting to send'), findsOneWidget);
      expect(
        find.textContaining("1 change couldn't be applied"),
        findsOneWidget,
      );
    });

    testWidgets('sync and invite are wired, and sync is disabled while busy', (
      tester,
    ) async {
      var calls = await pump(tester, _overview());
      await tester.tap(find.byKey(const Key('sync')));
      await tester.tap(find.byKey(const Key('invite')));
      expect(calls['sync'], 1);
      expect(calls['invite'], 1);

      calls = await pump(tester, _overview(), busy: true);
      await tester.tap(find.byKey(const Key('sync')), warnIfMissed: false);
      expect(calls['sync'], isNull);
    });

    testWidgets('an empty household invites the first expense', (tester) async {
      final calls = await pump(tester, _overview());
      expect(find.text('No shared expenses yet'), findsOneWidget);
      await tester.tap(find.text('Add the first shared expense'));
      expect(calls['add'], 1);
    });

    testWidgets('a removed member is told so and cannot act', (tester) async {
      final removed = HouseholdOverview(
        memberId: _me,
        groupId: '0123456789abcdef0123456789abcdef',
        isMember: false,
        cursor: PlatformInt64Util.from(7),
        pendingCount: PlatformInt64Util.from(0),
        memberIds: const [],
        balanceLabel: 'USD 0.00',
        accounts: const [],
        transactions: const [],
        conflicts: const [],
        rejected: const [],
      );
      await pump(tester, removed);
      expect(
        find.textContaining('no longer in this household'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('sync')), findsNothing);
    });
  });

  group('HouseholdSetupPane', () {
    testWidgets(
      'recovered history is read-only and a joined replacement can finish',
      (tester) async {
        var synced = 0;
        await tester.pumpWidget(
          _host(
            HouseholdSetupPane(
              relayUrl: 'https://relay.example',
              busy: false,
              onSaveRelay: (_) async {},
              onCreate: () {},
              onJoin: () {},
              onRestore: () {},
              recoveryOverview: _overview(transactions: const [_dinner]),
              recoveryJoined: true,
              onFinishRecovery: () => synced++,
            ),
          ),
        );
        expect(find.text('Backup history saved'), findsOneWidget);
        expect(
          tester
              .widget<FilledButton>(find.byKey(const Key('create')))
              .onPressed,
          isNull,
        );
        await tester.tap(find.byType(ExpansionTile));
        await tester.pumpAndSettle();
        expect(find.text('Dinner'), findsOneWidget);
        expect(find.byType(PopupMenuButton), findsNothing);
        await tester.scrollUntilVisible(
          find.byKey(const Key('join')),
          250,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(find.byKey(const Key('join')));
        expect(synced, 1);
      },
    );
    testWidgets('saves the relay address and offers create, join, restore', (
      tester,
    ) async {
      String? saved;
      var created = 0;
      var joined = 0;
      var restored = 0;
      await tester.pumpWidget(
        _host(
          HouseholdSetupPane(
            relayUrl: null,
            busy: false,
            onSaveRelay: (url) async => saved = url,
            onCreate: () => created += 1,
            onJoin: () => joined += 1,
            onRestore: () => restored += 1,
          ),
        ),
      );

      // Creating needs a relay first.
      expect(
        tester.widget<FilledButton>(find.byKey(const Key('create'))).onPressed,
        isNull,
      );

      await tester.enterText(
        find.byKey(const Key('relayField')),
        ' https://relay.example ',
      );
      await tester.tap(find.byKey(const Key('saveRelay')));
      await tester.pump();
      expect(saved, ' https://relay.example ');

      await tester.tap(find.byKey(const Key('join')));
      await tester.tap(find.byKey(const Key('restore')));
      expect(joined, 1);
      expect(restored, 1);
      expect(created, 0);
    });

    testWidgets('with a relay saved, creating is enabled', (tester) async {
      var created = 0;
      await tester.pumpWidget(
        _host(
          HouseholdSetupPane(
            relayUrl: 'https://relay.example',
            busy: false,
            onSaveRelay: (_) async {},
            onCreate: () => created += 1,
            onJoin: () {},
            onRestore: () {},
          ),
        ),
      );
      expect(find.text('https://relay.example'), findsOneWidget);
      await tester.tap(find.byKey(const Key('create')));
      expect(created, 1);
    });
  });
}
