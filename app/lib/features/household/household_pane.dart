import 'package:flutter/material.dart';

import '../../data/rust/api/shared.dart';

/// How a member ID is shown. IDs are random, opaque identifiers (the group's
/// credentials never carry a real name), so a short prefix is the stable,
/// comparable label until names travel inside the encrypted stream.
String memberLabel(String memberId) =>
    'Member ${memberId.length > 6 ? memberId.substring(0, 6) : memberId}';

enum _ExpenseAction { changeAmount, voidExpense }

/// A household this device belongs to: the shared balance, the people in
/// it, and the shared expenses, with conflicts and pending sends visible.
class HouseholdPane extends StatelessWidget {
  const HouseholdPane({
    required this.overview,
    required this.busy,
    required this.onSync,
    required this.onInvite,
    required this.onAddExpense,
    required this.onRemoveMember,
    required this.onVerifyMember,
    required this.onEditAmount,
    required this.onVoid,
    super.key,
  });

  final HouseholdOverview overview;
  final bool busy;
  final VoidCallback onSync;
  final VoidCallback onInvite;
  final VoidCallback onAddExpense;
  final ValueChanged<String> onRemoveMember;
  final ValueChanged<String> onVerifyMember;
  final ValueChanged<SharedTransactionView> onEditAmount;
  final ValueChanged<SharedTransactionView> onVoid;

  @override
  Widget build(BuildContext context) {
    if (!overview.isMember) {
      return const _RemovedNotice();
    }
    final theme = Theme.of(context);
    final pending = overview.pendingCount.toInt();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Shared balance', style: theme.textTheme.labelLarge),
                const SizedBox(height: 8),
                Text(
                  overview.balanceLabel,
                  style: theme.textTheme.headlineMedium,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        pending == 0
                            ? 'Everything is sent'
                            : '$pending change${pending == 1 ? '' : 's'} '
                                  'waiting to send',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    FilledButton.tonalIcon(
                      key: const Key('sync'),
                      onPressed: busy ? null : onSync,
                      icon: const Icon(Icons.sync_rounded),
                      label: const Text('Sync'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (overview.rejected.isNotEmpty) ...[
          const SizedBox(height: 12),
          _RejectedNotice(count: overview.rejected.length),
        ],
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(child: Text('People', style: theme.textTheme.titleMedium)),
            TextButton.icon(
              key: const Key('invite'),
              onPressed: busy ? null : onInvite,
              icon: const Icon(Icons.person_add_alt_1_rounded),
              label: const Text('Invite'),
            ),
          ],
        ),
        for (final id in overview.memberIds)
          _MemberTile(
            id: id,
            isMe: id == overview.memberId,
            busy: busy,
            onVerify: () => onVerifyMember(id),
            onRemove: () => onRemoveMember(id),
          ),
        const SizedBox(height: 16),
        Text('Shared expenses', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        if (overview.transactions.isEmpty)
          _EmptyExpenses(onAdd: onAddExpense)
        else
          for (final transaction in overview.transactions)
            _ExpenseTile(
              transaction: transaction,
              onEdit: () => onEditAmount(transaction),
              onVoid: () => onVoid(transaction),
            ),
        const SizedBox(height: 16),
        Text('Shared accounts', style: theme.textTheme.titleMedium),
        for (final account in overview.accounts)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('${account.name} (${account.currencyCode})'),
            subtitle: Text(account.balanceLabel),
          ),
      ],
    );
  }
}

class _MemberTile extends StatelessWidget {
  const _MemberTile({
    required this.id,
    required this.isMe,
    required this.busy,
    required this.onVerify,
    required this.onRemove,
  });

  final String id;
  final bool isMe;
  final bool busy;
  final VoidCallback onVerify;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const CircleAvatar(child: Icon(Icons.person_outline_rounded)),
      title: Text(isMe ? 'You' : memberLabel(id)),
      trailing: isMe
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  key: Key('verify-$id'),
                  tooltip: 'Verify safety number',
                  onPressed: busy ? null : onVerify,
                  icon: const Icon(Icons.verified_user_outlined),
                ),
                IconButton(
                  key: Key('remove-$id'),
                  tooltip: 'Remove from household',
                  onPressed: busy ? null : onRemove,
                  icon: const Icon(Icons.person_remove_outlined),
                ),
              ],
            ),
    );
  }
}

class _ExpenseTile extends StatelessWidget {
  const _ExpenseTile({
    required this.transaction,
    required this.onEdit,
    required this.onVoid,
  });

  final SharedTransactionView transaction;
  final VoidCallback onEdit;
  final VoidCallback onVoid;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final voided = transaction.voided;
    final amount =
        '${transaction.isExpense ? '−' : '+'}${transaction.amountLabel}';
    final style = voided
        ? TextStyle(
            decoration: TextDecoration.lineThrough,
            color: theme.colorScheme.outline,
          )
        : null;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        child: Icon(
          transaction.isExpense
              ? Icons.arrow_upward_rounded
              : Icons.arrow_downward_rounded,
        ),
      ),
      title: Text(transaction.title, style: style),
      subtitle: voided
          ? const Text('Voided')
          : transaction.conflicted
          ? Text(
              'Edited by two people at once',
              style: TextStyle(color: theme.colorScheme.error),
            )
          : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(amount, style: style ?? theme.textTheme.labelLarge),
          if (!voided)
            PopupMenuButton<_ExpenseAction>(
              key: Key('actions-${transaction.id}'),
              tooltip: 'Expense actions',
              onSelected: (action) => switch (action) {
                _ExpenseAction.changeAmount => onEdit(),
                _ExpenseAction.voidExpense => onVoid(),
              },
              itemBuilder: (context) => const [
                PopupMenuItem(
                  value: _ExpenseAction.changeAmount,
                  child: Text('Change amount'),
                ),
                PopupMenuItem(
                  value: _ExpenseAction.voidExpense,
                  child: Text('Void'),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _EmptyExpenses extends StatelessWidget {
  const _EmptyExpenses({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        children: [
          const Text('No shared expenses yet'),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: onAdd,
            child: const Text('Add the first shared expense'),
          ),
        ],
      ),
    );
  }
}

class _RejectedNotice extends StatelessWidget {
  const _RejectedNotice({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          "$count change${count == 1 ? '' : 's'} couldn't be applied, for "
          'example an edit to an expense someone else had already voided. '
          'They are kept in the history rather than dropped.',
          style: TextStyle(color: scheme.onErrorContainer),
        ),
      ),
    );
  }
}

class _RemovedNotice extends StatelessWidget {
  const _RemovedNotice();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Text(
          'You are no longer in this household. Nothing written after you '
          'were removed can be read on this device. Leave the household to '
          'clear it, then join or create another.',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
