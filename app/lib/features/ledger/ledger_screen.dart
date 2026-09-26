import 'package:flutter/material.dart';

import '../../data/rust/api/categories.dart';
import '../../data/rust/api/ledger.dart';
import 'add_transaction_sheet.dart';
import 'category_presets.dart';
import 'ledger_controller.dart';

class LedgerScreen extends StatefulWidget {
  const LedgerScreen({required this.controller, super.key});

  final LedgerController controller;

  @override
  State<LedgerScreen> createState() => _LedgerScreenState();
}

class _LedgerScreenState extends State<LedgerScreen> {
  int selectedIndex = 0;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        return LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 840;
            final content = _content();
            return Scaffold(
              appBar: AppBar(
                title: const Text('Private Ledger'),
                actions: const [
                  Padding(
                    padding: EdgeInsets.only(right: 16),
                    child: Tooltip(
                      message: 'Local prototype session',
                      child: Icon(Icons.lock_outline_rounded),
                    ),
                  ),
                ],
              ),
              body: wide
                  ? Row(
                      children: [
                        NavigationRail(
                          selectedIndex: selectedIndex,
                          onDestinationSelected: _select,
                          labelType: NavigationRailLabelType.all,
                          destinations: const [
                            NavigationRailDestination(
                              icon: Icon(Icons.space_dashboard_outlined),
                              selectedIcon: Icon(Icons.space_dashboard_rounded),
                              label: Text('Overview'),
                            ),
                            NavigationRailDestination(
                              icon: Icon(Icons.receipt_long_outlined),
                              selectedIcon: Icon(Icons.receipt_long_rounded),
                              label: Text('Activity'),
                            ),
                          ],
                        ),
                        const VerticalDivider(width: 1),
                        Expanded(child: content),
                      ],
                    )
                  : content,
              bottomNavigationBar: wide
                  ? null
                  : NavigationBar(
                      selectedIndex: selectedIndex,
                      onDestinationSelected: _select,
                      destinations: const [
                        NavigationDestination(
                          icon: Icon(Icons.space_dashboard_outlined),
                          selectedIcon: Icon(Icons.space_dashboard_rounded),
                          label: 'Overview',
                        ),
                        NavigationDestination(
                          icon: Icon(Icons.receipt_long_outlined),
                          selectedIcon: Icon(Icons.receipt_long_rounded),
                          label: 'Activity',
                        ),
                      ],
                    ),
              floatingActionButton: widget.controller.overview == null
                  ? null
                  : FloatingActionButton.extended(
                      onPressed: widget.controller.isLoading ? null : _add,
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('Add'),
                    ),
            );
          },
        );
      },
    );
  }

  Widget _content() {
    final controller = widget.controller;
    if (controller.isLoading && controller.overview == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (controller.overview == null) {
      return _ErrorState(
        message: controller.errorMessage ?? 'Ledger unavailable',
      );
    }
    return Stack(
      children: [
        IndexedStack(
          index: selectedIndex,
          children: [
            OverviewPane(
              overview: controller.overview!,
              categories: controller.categories,
              onAdd: _add,
            ),
            ActivityPane(
              transactions: controller.overview!.transactions,
              categories: controller.categories,
            ),
          ],
        ),
        if (controller.isLoading)
          const Align(
            alignment: Alignment.topCenter,
            child: LinearProgressIndicator(),
          ),
      ],
    );
  }

  void _select(int index) => setState(() => selectedIndex = index);

  Future<void> _add() async {
    final controller = widget.controller;
    final draft = await showModalBottomSheet<TransactionDraft>(
      context: context,
      isScrollControlled: true,
      showDragHandle: false,
      builder: (context) => AddTransactionSheet(
        categories: controller.categories,
        onSuggestCategory: controller.suggestCategoryFor,
        onAddCategory: (name, iconKey) =>
            controller.addCategory(name: name, iconKey: iconKey),
      ),
    );
    if (draft == null || !mounted) {
      return;
    }
    final saved = await widget.controller.record(
      title: draft.title,
      amount: draft.amount,
      kind: draft.kind,
      categoryId: draft.categoryId,
    );
    if (!mounted) {
      return;
    }
    if (!saved) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.controller.errorMessage ?? 'Could not add transaction',
          ),
        ),
      );
    }
  }
}

class OverviewPane extends StatelessWidget {
  const OverviewPane({
    required this.overview,
    required this.categories,
    required this.onAdd,
    super.key,
  });

  final LedgerOverview overview;
  final List<CategoryView> categories;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 112),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1080),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Overview',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 4),
              Text(
                'Your private, on-device ledger',
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 20),
              LayoutBuilder(
                builder: (context, constraints) {
                  final balance = _BalanceCard(label: overview.balanceLabel);
                  final accounts = _AccountsCard(accounts: overview.accounts);
                  if (constraints.maxWidth < 680) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [balance, const SizedBox(height: 12), accounts],
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 3, child: balance),
                      const SizedBox(width: 12),
                      Expanded(flex: 2, child: accounts),
                    ],
                  );
                },
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Recent activity',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  if (overview.transactions.isNotEmpty)
                    Text('${overview.transactions.length} total'),
                ],
              ),
              const SizedBox(height: 10),
              if (overview.transactions.isEmpty)
                _EmptyTransactions(onAdd: onAdd)
              else
                ...overview.transactions
                    .take(5)
                    .map(
                      (transaction) => TransactionTile(
                        transaction,
                        categories: categories,
                      ),
                    ),
            ],
          ),
        ),
      ),
    );
  }
}

class ActivityPane extends StatelessWidget {
  const ActivityPane({
    required this.transactions,
    required this.categories,
    super.key,
  });

  final List<TransactionView> transactions;
  final List<CategoryView> categories;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 112),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Activity',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 16),
                if (transactions.isEmpty)
                  const _ActivityEmpty()
                else
                  ...transactions.map(
                    (transaction) =>
                        TransactionTile(transaction, categories: categories),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _BalanceCard extends StatelessWidget {
  const _BalanceCard({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('Net balance', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              label,
              style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                color: scheme.onPrimaryContainer,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 16),
            const Row(
              children: [
                Icon(Icons.shield_outlined, size: 18),
                SizedBox(width: 8),
                Flexible(child: Text('Calculated by the local Rust ledger')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _AccountsCard extends StatelessWidget {
  const _AccountsCard({required this.accounts});

  final List<AccountView> accounts;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Accounts', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            for (final account in accounts)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const CircleAvatar(child: Icon(Icons.wallet_outlined)),
                title: Text(account.name),
                subtitle: const Text('Cash account'),
                trailing: Text(
                  account.balanceLabel,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class TransactionTile extends StatelessWidget {
  const TransactionTile(this.transaction, {this.categories = const [], super.key});

  final TransactionView transaction;
  final List<CategoryView> categories;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final category = categories.cast<CategoryView?>().firstWhere(
      (candidate) => candidate?.id == transaction.categoryId,
      orElse: () => null,
    );
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: transaction.isExpense
              ? scheme.errorContainer
              : scheme.tertiaryContainer,
          child: Icon(
            category != null
                ? categoryIcon(category.iconKey)
                : (transaction.isExpense
                      ? Icons.arrow_upward_rounded
                      : Icons.arrow_downward_rounded),
            color: transaction.isExpense
                ? scheme.onErrorContainer
                : scheme.onTertiaryContainer,
          ),
        ),
        title: Text(transaction.title),
        subtitle: Text(category?.name ?? 'Uncategorized'),
        trailing: Text(
          '${transaction.isExpense ? '−' : '+'}${transaction.amountLabel}',
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            color: transaction.isExpense ? scheme.error : scheme.tertiary,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _EmptyTransactions extends StatelessWidget {
  const _EmptyTransactions({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          children: [
            const Icon(Icons.receipt_long_outlined, size: 42),
            const SizedBox(height: 12),
            Text(
              'No transactions yet',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            const Text('Add an expense or income to start your ledger.'),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add first transaction'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActivityEmpty extends StatelessWidget {
  const _ActivityEmpty();

  @override
  Widget build(BuildContext context) {
    return const Card(
      child: Padding(
        padding: EdgeInsets.all(28),
        child: Text('Your immutable transaction history will appear here.'),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline_rounded, size: 48),
            const SizedBox(height: 12),
            Text(
              'Could not open the ledger',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 6),
            Text(message, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
