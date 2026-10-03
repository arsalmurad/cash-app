import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show PlatformInt64Util;
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/data/rust/api/ledger.dart';
import 'package:private_ledger/data/rust/api/shared.dart';
import 'package:private_ledger/features/household/household_controller.dart';
import 'package:private_ledger/features/household/household_screen.dart';

const _me = 'aaaa0000aaaa0000aaaa0000aaaa0000';
const _other = 'bbbb1111bbbb1111bbbb1111bbbb1111';

HouseholdOverview _member({bool foreign = false}) => HouseholdOverview(
  memberId: _me,
  groupId: '0123456789abcdef0123456789abcdef',
  isMember: true,
  cursor: PlatformInt64Util.from(3),
  pendingCount: PlatformInt64Util.from(0),
  memberIds: const [_me, _other],
  balanceLabel: 'USD -40.00',
  accounts: [
    AccountView(
      id: 'household',
      name: 'Household',
      currencyCode: foreign ? 'EUR' : 'USD',
      balanceLabel: 'USD -40.00',
    ),
  ],
  transactions: [
    SharedTransactionView(
      id: 'dinner',
      accountId: 'household',
      title: 'Dinner',
      amountLabel: foreign ? 'EUR 40.00' : 'USD 40.00',
      isExpense: true,
      voided: false,
      conflicted: false,
    ),
  ],
  conflicts: const [],
  rejected: const [],
);

/// Records what the screen asks for; never touches the Rust bridge.
class _FakeController extends HouseholdController {
  _FakeController() : super(relayFactory: (_) => throw UnimplementedError());

  final calls = <String>[];
  bool nextResult = true;
  bool restartRequired = false;
  bool relayMode = false;
  bool setupAvailable = false;
  @override
  bool get canExportRelayBootstrap => setupAvailable;
  @override
  Future<String?> relayBootstrapPolicy() async {
    calls.add('relay-setup');
    if (!nextResult) {
      errorMessage = 'Setup unavailable';
      return null;
    }
    return '{"public":"setup"}';
  }

  @override
  bool get authenticatedRelay => relayMode;
  @override
  bool get requiresRestart => restartRequired;
  String? inviteCode = 'cashinv1:INVITE';

  void _fail(bool ok) {
    if (!ok) {
      errorMessage = 'boom';
    }
    notifyListeners();
  }

  @override
  Future<void> initialize() async {
    isLoading = false;
    notifyListeners();
  }

  @override
  Future<bool> setRelayUrl(String url, {bool? authenticated}) async {
    calls.add('relay:$url');
    relayMode = authenticated ?? relayMode;
    relayUrl = url.trim();
    notifyListeners();
    return nextResult;
  }

  @override
  Future<bool> createHousehold() async {
    calls.add('create');
    if (nextResult) {
      overview = _member();
    }
    _fail(nextResult);
    return nextResult;
  }

  @override
  Future<String?> prepareJoinRequest() async {
    calls.add('prepare');
    return 'cashkp1:REQUEST';
  }

  @override
  Future<bool> acceptInvite(String inviteCode) async {
    calls.add('accept:$inviteCode');
    if (nextResult) {
      overview = _member();
    }
    _fail(nextResult);
    return nextResult;
  }

  @override
  Future<String?> invite(String joinRequest) async {
    calls.add('invite:$joinRequest');
    return inviteCode;
  }

  @override
  Future<bool> syncNow() async {
    calls.add('sync');
    return nextResult;
  }

  @override
  Future<bool> addExpense({
    required String title,
    required String amount,
    EntryKind kind = EntryKind.expense,
    String accountId = 'household',
    String? rate,
  }) async {
    calls.add('add:$title:$amount${rate == null ? '' : ':$accountId:$rate'}');
    return nextResult;
  }

  @override
  Future<bool> adjustAmount(
    String transactionId,
    String amount, {
    String? rate,
  }) async {
    calls.add('adjust:$transactionId:$amount${rate == null ? '' : ':$rate'}');
    return nextResult;
  }

  @override
  Future<bool> addAccount({
    required String name,
    required String currencyCode,
  }) async {
    calls.add('account:$name:$currencyCode');
    return nextResult;
  }

  @override
  Future<bool> voidTransaction(String transactionId) async {
    calls.add('void:$transactionId');
    return nextResult;
  }

  @override
  Future<bool> removeMember(String memberId) async {
    calls.add('remove:$memberId');
    return nextResult;
  }

  @override
  Future<String?> safetyNumberWith(String memberId) async {
    calls.add('safety:$memberId');
    return '11111 22222 33333 44444 55555 66666';
  }

  @override
  Future<({String phrase, String backup})?> createBackup() async {
    calls.add('backup');
    return (phrase: 'one two three', backup: 'cashbk1:SEALED');
  }

  @override
  Future<void> forgetHousehold() async {
    calls.add('forget');
    overview = null;
    notifyListeners();
  }
}

Future<_FakeController> _pump(
  WidgetTester tester, {
  bool member = false,
  Duration syncInterval = const Duration(hours: 1),
}) async {
  final controller = _FakeController();
  await controller.initialize();
  if (member) {
    controller.overview = _member();
    controller.relayUrl = 'https://relay.example';
  }
  await tester.pumpWidget(
    MaterialApp(
      home: HouseholdScreen(controller: controller, syncInterval: syncInterval),
    ),
  );
  await tester.pumpAndSettle();
  controller.calls.clear();
  return controller;
}

void main() {
  testWidgets('public setup menu is conditional and shows export failure', (
    tester,
  ) async {
    final controller = await _pump(tester, member: true);
    await tester.tap(find.byTooltip('Household options'));
    await tester.pumpAndSettle();
    expect(find.text('Export local relay setup'), findsNothing);
    await tester.tapAt(const Offset(10, 200));
    await tester.pumpAndSettle();
    controller.setupAvailable = true;
    await tester.tap(find.byTooltip('Household options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export local relay setup'));
    await tester.pumpAndSettle();
    expect(find.text('Relay operator setup'), findsOneWidget);
    expect(find.text('{"public":"setup"}'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    controller.nextResult = false;
    await tester.tap(find.byTooltip('Household options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export local relay setup'));
    await tester.pumpAndSettle();
    expect(find.text('Setup unavailable'), findsOneWidget);
    expect(find.text('Relay operator setup'), findsNothing);
  });
  testWidgets('failed load stays visible instead of offering a new household', (
    tester,
  ) async {
    final controller = await _pump(tester);
    controller
      ..overview = null
      ..restartRequired = true
      ..errorMessage = 'The saved household could not be loaded.';
    controller.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('Household unavailable'), findsOneWidget);
    expect(
      find.text('The saved household could not be loaded.'),
      findsOneWidget,
    );
    expect(find.text('Create a household'), findsNothing);
    expect(find.text('Join a household'), findsNothing);
  });
  testWidgets(
    'foreign shared expense requires explicit rate; cancelling sends nothing',
    (tester) async {
      final controller = await _pump(tester, member: true);
      controller.overview = _member(foreign: true);
      controller.notifyListeners();
      await tester.pumpAndSettle();
      Future<void> open() async {
        await tester.tap(find.text('Add shared expense'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const Key('expenseTitle')), 'Coffee');
        await tester.enterText(find.byKey(const Key('expenseAmount')), '4.50');
        await tester.tap(find.byKey(const Key('expenseSubmit')));
        await tester.pumpAndSettle();
        expect(find.textContaining('USD per 1 EUR'), findsOneWidget);
      }

      await open();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(controller.calls, isEmpty);
      await open();
      await tester.enterText(find.byType(TextFormField), '1.1');
      await tester.tap(find.text('Use rate'));
      await tester.pumpAndSettle();
      expect(controller.calls, ['add:Coffee:4.50:household:1.1']);
    },
  );

  testWidgets('shared account menu persists explicit name and currency', (
    tester,
  ) async {
    final controller = await _pump(tester, member: true);
    await tester.tap(find.byTooltip('Household options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create shared account'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('sharedAccountName')),
      'Travel',
    );
    await tester.tap(find.text('Create shared account'));
    await tester.pumpAndSettle();
    expect(controller.calls, ['account:Travel:USD']);
  });

  testWidgets('with no household it shows setup; saving a relay and creating '
      'move into the household', (tester) async {
    final controller = await _pump(tester);
    expect(find.text('Create a household'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('relayField')),
      'https://relay.example',
    );
    await tester.tap(find.byKey(const Key('authenticatedRelay')));
    await tester.tap(find.byKey(const Key('saveRelay')));
    await tester.pumpAndSettle();
    expect(controller.relayMode, isTrue);
    await tester.tap(find.byKey(const Key('create')));
    await tester.pumpAndSettle();

    expect(controller.calls, ['relay:https://relay.example', 'create']);
    expect(find.text('Shared balance'), findsOneWidget);
  });

  testWidgets('a failure is reported in a snackbar', (tester) async {
    final controller = await _pump(tester)
      ..nextResult = false;
    await tester.enterText(find.byKey(const Key('relayField')), 'nonsense');
    await tester.tap(find.byKey(const Key('saveRelay')));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsOneWidget);
    controller.relayUrl = 'https://relay.example';
    controller.notifyListeners();
  });

  testWidgets('joining shows the request, then sends the pasted invite', (
    tester,
  ) async {
    final controller = await _pump(tester);
    await tester.tap(find.byKey(const Key('join')));
    await tester.pumpAndSettle();
    expect(find.text('cashkp1:REQUEST'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('inviteField')), 'cashinv1:X');
    await tester.tap(find.byKey(const Key('joinSubmit')));
    await tester.pumpAndSettle();

    expect(controller.calls, ['prepare', 'accept:cashinv1:X']);
    expect(find.text('Shared balance'), findsOneWidget);
  });

  testWidgets('a member can add a shared expense from the button', (
    tester,
  ) async {
    final controller = await _pump(tester, member: true);
    await tester.tap(find.text('Add shared expense'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('expenseTitle')), 'Coffee');
    await tester.enterText(find.byKey(const Key('expenseAmount')), '4.50');
    await tester.tap(find.byKey(const Key('expenseSubmit')));
    await tester.pumpAndSettle();
    expect(controller.calls, ['add:Coffee:4.50']);
  });

  for (final message in [
    'Saved on this device. Do not repeat this change. Relay unavailable.',
    null,
  ]) {
    testWidgets('failed expense send closes the form without repeating '
        '(message=$message)', (tester) async {
      final controller = await _pump(tester, member: true);
      controller
        ..nextResult = false
        ..errorMessage = message;
      await tester.tap(find.text('Add shared expense'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('expenseTitle')), 'Coffee');
      await tester.enterText(find.byKey(const Key('expenseAmount')), '4.50');
      await tester.tap(find.byKey(const Key('expenseSubmit')));
      await tester.pumpAndSettle();
      expect(controller.calls, ['add:Coffee:4.50']);
      expect(find.byKey(const Key('expenseSubmit')), findsNothing);
      expect(
        find.text(
          message ?? 'Could not finish saving and sending the expense.',
        ),
        findsOneWidget,
      );
      if (message == null) {
        expect(find.textContaining('It is saved and will send'), findsNothing);
      }
    });
  }

  testWidgets('inviting pastes a request and shows the invite to send', (
    tester,
  ) async {
    final controller = await _pump(tester, member: true);
    await tester.tap(find.byKey(const Key('invite')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('requestField')), 'cashkp1:R');
    await tester.tap(find.byKey(const Key('inviteSubmit')));
    await tester.pumpAndSettle();
    expect(controller.calls, ['invite:cashkp1:R']);
    expect(find.text('cashinv1:INVITE'), findsOneWidget);
  });

  testWidgets('verifying a member shows their safety number', (tester) async {
    final controller = await _pump(tester, member: true);
    await tester.tap(find.byKey(const Key('verify-$_other')));
    await tester.pumpAndSettle();
    expect(controller.calls, ['safety:$_other']);
    expect(find.text('11111 22222 33333 44444 55555 66666'), findsOneWidget);
  });

  testWidgets('removing a member asks first', (tester) async {
    final controller = await _pump(tester, member: true);
    await tester.tap(find.byKey(const Key('remove-$_other')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(controller.calls, isEmpty);

    await tester.tap(find.byKey(const Key('remove-$_other')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(controller.calls, ['remove:$_other']);
  });

  testWidgets('changing an amount prefills it and voiding is direct', (
    tester,
  ) async {
    final controller = await _pump(tester, member: true);
    await tester.tap(find.byKey(const Key('actions-dinner')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Change amount'));
    await tester.pumpAndSettle();
    expect(find.text('40.00'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('amountField')), '42.00');
    await tester.tap(find.byKey(const Key('amountSubmit')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('actions-dinner')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Void'));
    await tester.pumpAndSettle();
    expect(controller.calls, ['adjust:dinner:42.00', 'void:dinner']);
  });

  testWidgets('backing up shows the phrase and the sealed backup', (
    tester,
  ) async {
    final controller = await _pump(tester, member: true);
    await tester.tap(find.byTooltip('Household options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Back up'));
    await tester.pumpAndSettle();
    expect(controller.calls, ['backup']);
    expect(find.text('one two three'), findsOneWidget);
    expect(find.text('cashbk1:SEALED'), findsOneWidget);
  });

  testWidgets('leaving asks first, then clears the household', (tester) async {
    final controller = await _pump(tester, member: true);
    await tester.tap(find.byTooltip('Household options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Leave household'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(controller.calls, isEmpty);

    await tester.tap(find.byTooltip('Household options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Leave household'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Leave'));
    await tester.pumpAndSettle();
    expect(controller.calls, ['forget']);
    expect(find.text('Create a household'), findsOneWidget);
  });

  testWidgets('it syncs on open and on a timer while a member', (tester) async {
    final controller = _FakeController();
    await controller.initialize();
    controller.overview = _member();
    controller.relayUrl = 'https://relay.example';
    await tester.pumpWidget(
      MaterialApp(
        home: HouseholdScreen(
          controller: controller,
          syncInterval: const Duration(seconds: 10),
        ),
      ),
    );
    await tester.pump();
    expect(controller.calls.where((c) => c == 'sync'), hasLength(1));

    await tester.pump(const Duration(seconds: 10));
    await tester.pump(const Duration(seconds: 10));
    expect(controller.calls.where((c) => c == 'sync').length, 3);

    // Leaving the screen stops the timer (no pending timers at teardown).
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('it does not sync when there is no household', (tester) async {
    final controller = _FakeController();
    await controller.initialize();
    await tester.pumpWidget(
      MaterialApp(
        home: HouseholdScreen(
          controller: controller,
          syncInterval: const Duration(seconds: 10),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 30));
    expect(controller.calls, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
}
