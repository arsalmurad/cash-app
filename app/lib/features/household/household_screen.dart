import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/rust/api/shared.dart' show SharedTransactionView;
import '../ledger/exchange_rate_dialog.dart';
import 'household_controller.dart';
import 'household_dialogs.dart';
import 'household_pane.dart';
import 'household_setup_pane.dart';
import 'vault_pane.dart';

enum _MenuAction { addAccount, backup, leave }

/// The shared layer's screen: set up or join a household, then share
/// expenses with it. It syncs on open, on demand, and every half minute
/// while it is showing.
class HouseholdScreen extends StatefulWidget {
  const HouseholdScreen({
    required this.controller,
    this.syncInterval = const Duration(seconds: 30),
    super.key,
  });

  final HouseholdController controller;
  final Duration syncInterval;

  @override
  State<HouseholdScreen> createState() => _HouseholdScreenState();
}

class _HouseholdScreenState extends State<HouseholdScreen> {
  Timer? timer;

  HouseholdController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(widget.syncInterval, (_) => _autoSync());
    unawaited(_autoSync());
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> _autoSync() async {
    if (controller.isMember &&
        !controller.isBusy &&
        controller.relayUrl != null) {
      // Quiet: a failed background sync shows only as "waiting to send".
      await controller.syncNow();
    }
  }

  void _tell(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _reportFailure(String fallback) =>
      _tell(controller.errorMessage ?? fallback);

  Future<void> _create() async {
    if (!await controller.createHousehold()) {
      _reportFailure("Couldn't create the household");
    }
  }

  Future<void> _saveRelay(String url) async {
    if (!await controller.setRelayUrl(url)) {
      _reportFailure('That relay address is not valid');
    }
  }

  Future<void> _join() async {
    await showDialog<bool>(
      context: context,
      builder: (context) => JoinDialog(
        prepareRequest: controller.prepareJoinRequest,
        join: (invite) async {
          final joined = await controller.acceptInvite(invite);
          if (!joined) {
            _reportFailure("Couldn't join");
          }
          return joined;
        },
      ),
    );
  }

  Future<void> _restore() async {
    await showDialog<bool>(
      context: context,
      builder: (context) => RestoreDialog(
        restore: (phrase, backup) async {
          final restored = await controller.restoreBackup(phrase, backup);
          if (!restored) {
            _reportFailure("Couldn't restore");
          }
          return restored;
        },
      ),
    );
  }

  Future<void> _restoreLockedVault() async {
    final phrase = await showDialog<String>(
      context: context,
      builder: (dialogContext) => Dialog(
        child: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: VaultPane(
                  hasCiphertext: false,
                  generatePhrase: controller.generateBrowserUnlockPhrase,
                  unlock: (phrase) async {
                    Navigator.pop(dialogContext, phrase);
                    return true;
                  },
                ),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      ),
    );
    if (phrase == null || !mounted) return;
    await showDialog<bool>(
      context: context,
      builder: (context) => RestoreDialog(
        restore: (backupPhrase, backup) async {
          final restored = await controller.restoreBackupWithNewUnlock(
            backupPhrase,
            backup,
            phrase,
          );
          if (!restored) {
            _reportFailure("Couldn't restore the encrypted backup");
          }
          return restored;
        },
      ),
    );
  }

  Future<void> _invite() async {
    if (controller.hasPendingInvitation) {
      if (await controller.resumeInvitation() == null) {
        _reportFailure('The pending invitation could not be completed');
        return;
      }
      if (!mounted) return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => InviteDialog(
        initialInvite: controller.lastInviteCode,
        createInvite: (request) async {
          final invite = await controller.invite(request);
          if (invite == null) {
            _reportFailure("Couldn't add them");
          }
          return invite;
        },
      ),
    );
  }

  Future<void> _verify(String memberId) async {
    final number = await controller.safetyNumberWith(memberId);
    if (number == null || !mounted) {
      _reportFailure("Couldn't compute a safety number");
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => SafetyNumberDialog(
        memberLabel: memberLabel(memberId),
        number: number,
      ),
    );
  }

  Future<void> _remove(String memberId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${memberLabel(memberId)}?'),
        content: const Text(
          'They will not be able to read anything written from now on. '
          'What they already saw stays with them.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    if (!await controller.removeMember(memberId)) {
      _reportFailure("Couldn't remove them");
    }
  }

  Future<void> _addExpense() async {
    final expense = await showDialog<SharedExpenseDraft>(
      context: context,
      builder: (context) =>
          ExpenseDialog(accounts: controller.overview?.accounts ?? const []),
    );
    if (expense == null || !mounted) {
      return;
    }
    final rate = await _rateForAccount(expense.accountId);
    if (!mounted || rate.cancelled) return;
    if (!await controller.addExpense(
      title: expense.title,
      amount: expense.amount,
      accountId: expense.accountId,
      rate: rate.value,
    )) {
      _reportFailure(
        "Couldn't send the expense yet. It is saved and will send.",
      );
    }
  }

  Future<({bool cancelled, String? value})> _rateForAccount(
    String accountId,
  ) async {
    final account = controller.overview?.accounts
        .where((a) => a.id == accountId)
        .firstOrNull;
    if (account == null) {
      _reportFailure(
        'Shared account not found. Reopen the form and try again.',
      );
      return (cancelled: true, value: null);
    }
    if (account.currencyCode == HouseholdController.reportingCurrency) {
      return (cancelled: false, value: null);
    }
    final rate = await showDialog<String>(
      context: context,
      builder: (_) => ExchangeRateDialog(
        sourceCurrencyCode: account.currencyCode,
        reportingCurrencyCode: HouseholdController.reportingCurrency,
      ),
    );
    return (cancelled: rate == null, value: rate);
  }

  Future<void> _addAccount() async {
    final draft = await showDialog<SharedAccountDraft>(
      context: context,
      builder: (_) => const SharedAccountDialog(),
    );
    if (draft == null || !mounted) return;
    if (!await controller.addAccount(
      name: draft.name,
      currencyCode: draft.currencyCode,
    )) {
      _reportFailure('Could not create the shared account.');
    }
  }

  Future<void> _editAmount(SharedTransactionView transaction) async {
    final amount = await showDialog<String>(
      context: context,
      builder: (context) => AmountDialog(
        title: 'Change amount',
        initial: transaction.amountLabel.split(' ').last,
      ),
    );
    if (amount == null || !mounted) {
      return;
    }
    final rate = await _rateForAccount(transaction.accountId);
    if (!mounted || rate.cancelled) return;
    if (!await controller.adjustAmount(
      transaction.id,
      amount,
      rate: rate.value,
    )) {
      _reportFailure(
        "Couldn't send the change yet. It is saved and will send.",
      );
    }
  }

  Future<void> _void(SharedTransactionView transaction) async {
    if (!await controller.voidTransaction(transaction.id)) {
      _reportFailure("Couldn't send the void yet. It is saved and will send.");
    }
  }

  Future<void> _backup() async {
    final backup = await controller.createBackup();
    if (backup == null || !mounted) {
      _reportFailure("Couldn't create a backup");
      return;
    }
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) =>
          BackupDialog(phrase: backup.phrase, backup: backup.backup),
    );
  }

  Future<void> _leave() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Leave this household?'),
        content: const Text(
          'This clears the household from this phone. The others keep '
          'theirs, and to come back you need a new invite. Your private '
          'ledger is not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await controller.forgetHousehold();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final overview = controller.overview;
        final inHousehold =
            overview != null &&
            overview.groupId != null &&
            !controller.needsRecoveryInvite;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Household'),
            actions: [
              if (controller.canLockVault)
                IconButton(
                  tooltip: 'Lock household in this browser',
                  icon: const Icon(Icons.lock_outline),
                  onPressed: controller.isBusy
                      ? null
                      : controller.lockBrowserVault,
                ),
              if (inHousehold || controller.needsRecoveryInvite)
                PopupMenuButton<_MenuAction>(
                  tooltip: 'Household options',
                  onSelected: (action) => switch (action) {
                    _MenuAction.addAccount => _addAccount(),
                    _MenuAction.backup => _backup(),
                    _MenuAction.leave => _leave(),
                  },
                  itemBuilder: (context) => [
                    if ((overview?.isMember ?? false) &&
                        !controller.needsRecoveryInvite &&
                        !controller.needsVaultUnlock &&
                        !controller.isBusy)
                      const PopupMenuItem(
                        value: _MenuAction.addAccount,
                        child: Text('Create shared account'),
                      ),
                    if ((overview?.isMember ?? false) ||
                        controller.needsRecoveryInvite)
                      const PopupMenuItem(
                        value: _MenuAction.backup,
                        child: Text('Back up'),
                      ),
                    const PopupMenuItem(
                      value: _MenuAction.leave,
                      child: Text('Leave household'),
                    ),
                  ],
                ),
            ],
          ),
          body: Stack(
            children: [
              if (controller.isLoading)
                const Center(child: CircularProgressIndicator())
              else if (controller.needsVaultUnlock)
                VaultPane(
                  hasCiphertext: controller.vaultHasCiphertext,
                  generatePhrase: controller.generateBrowserUnlockPhrase,
                  unlock: controller.unlockBrowserVault,
                  error: controller.errorMessage,
                  recover: _restoreLockedVault,
                )
              else if (inHousehold)
                HouseholdPane(
                  overview: overview,
                  busy: controller.isBusy,
                  onSync: () async {
                    if (!await controller.syncNow()) {
                      _reportFailure("Couldn't sync");
                    }
                  },
                  onInvite: _invite,
                  onAddExpense: _addExpense,
                  onRemoveMember: _remove,
                  onVerifyMember: _verify,
                  onEditAmount: _editAmount,
                  onVoid: _void,
                )
              else
                HouseholdSetupPane(
                  relayUrl: controller.relayUrl,
                  busy: controller.isBusy,
                  onSaveRelay: _saveRelay,
                  onCreate: _create,
                  onJoin: _join,
                  onRestore: _restore,
                  recoveryOverview: controller.recoveryOverview,
                  recoveryJoined: overview?.groupId != null,
                  onFinishRecovery: () async {
                    if (!await controller.syncNow()) {
                      _reportFailure(
                        'Recovery is waiting for the old device to be removed',
                      );
                    }
                  },
                ),
              if (controller.isBusy)
                const Align(
                  alignment: Alignment.topCenter,
                  child: LinearProgressIndicator(),
                ),
            ],
          ),
          floatingActionButton:
              inHousehold && overview.isMember && !controller.needsVaultUnlock
              ? FloatingActionButton.extended(
                  onPressed: controller.isBusy ? null : _addExpense,
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Add shared expense'),
                )
              : null,
        );
      },
    );
  }
}
