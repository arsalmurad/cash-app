import 'package:flutter/material.dart';

import '../../data/rust/api/budgets.dart' show BudgetView;
import '../../data/rust/api/categories.dart';
import '../../data/rust/api/goals.dart' show GoalView;
import '../../data/rust/api/ledger.dart';
import '../../data/rust/api/recurring.dart' show UpcomingView;
import 'activity_filter.dart';
import 'add_transaction_sheet.dart';
import 'budgets_pane.dart';
import 'categories_screen.dart';
import 'category_presets.dart';
import 'csv_import_export.dart';
import 'definition_removal_dialog.dart';
import 'exchange_rate_dialog.dart';
import '../household/household_controller.dart';
import '../household/household_screen.dart';
import 'goals_pane.dart';
import 'ledger_controller.dart';
import '../lock/lock_settings_dialog.dart';
import 'recurring_pane.dart';

class LedgerScreen extends StatefulWidget {
  const LedgerScreen({required this.controller, this.household, super.key});

  final LedgerController controller;

  /// The shared layer. When null (as in most tests) the Household entry is
  /// not offered.
  final HouseholdController? household;

  @override
  State<LedgerScreen> createState() => _LedgerScreenState();
}

class _LedgerScreenState extends State<LedgerScreen> {
  int selectedIndex = 0;
  bool _removalPending = false;

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
                actions: [
                  if (widget.controller.overview != null)
                    PopupMenuButton<_DataMenuAction>(
                      tooltip: 'Import or export',
                      icon: const Icon(Icons.more_vert_rounded),
                      onSelected: _onDataMenuSelected,
                      itemBuilder: (context) => [
                        const PopupMenuItem(
                          value: _DataMenuAction.exportCsv,
                          child: Text('Export CSV'),
                        ),
                        const PopupMenuItem(
                          value: _DataMenuAction.importCsv,
                          child: Text('Import CSV'),
                        ),
                        const PopupMenuItem(
                          value: _DataMenuAction.manageCategories,
                          child: Text('Manage categories'),
                        ),
                        const PopupMenuItem(
                          value: _DataMenuAction.lockSettings,
                          child: Text('Screen lock'),
                        ),
                        if (widget.household != null)
                          const PopupMenuItem(
                            value: _DataMenuAction.household,
                            child: Text('Household'),
                          ),
                      ],
                    ),
                  const Padding(
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
                            NavigationRailDestination(
                              icon: Icon(Icons.pie_chart_outline_rounded),
                              selectedIcon: Icon(Icons.pie_chart_rounded),
                              label: Text('Budgets'),
                            ),
                            NavigationRailDestination(
                              icon: Icon(Icons.flag_outlined),
                              selectedIcon: Icon(Icons.flag_rounded),
                              label: Text('Goals'),
                            ),
                            NavigationRailDestination(
                              icon: Icon(Icons.event_repeat_outlined),
                              selectedIcon: Icon(Icons.event_repeat_rounded),
                              label: Text('Recurring'),
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
                        NavigationDestination(
                          icon: Icon(Icons.pie_chart_outline_rounded),
                          selectedIcon: Icon(Icons.pie_chart_rounded),
                          label: 'Budgets',
                        ),
                        NavigationDestination(
                          icon: Icon(Icons.flag_outlined),
                          selectedIcon: Icon(Icons.flag_rounded),
                          label: 'Goals',
                        ),
                        NavigationDestination(
                          icon: Icon(Icons.event_repeat_outlined),
                          selectedIcon: Icon(Icons.event_repeat_rounded),
                          label: 'Recurring',
                        ),
                      ],
                    ),
              floatingActionButton: widget.controller.overview == null
                  ? null
                  : FloatingActionButton.extended(
                      onPressed: widget.controller.isLoading || _removalPending
                          ? null
                          : switch (selectedIndex) {
                              2 => _addBudget,
                              3 => _addGoal,
                              4 => _addRecurring,
                              _ => _add,
                            },
                      icon: const Icon(Icons.add_rounded),
                      label: Text(switch (selectedIndex) {
                        2 => 'Add budget',
                        3 => 'Add goal',
                        4 => 'Add recurring',
                        _ => 'Add',
                      }),
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
        AbsorbPointer(
          absorbing: _removalPending,
          child: IndexedStack(
            index: selectedIndex,
            children: [
              OverviewPane(
                overview: controller.overview!,
                categories: controller.categories,
                onAdd: _add,
                onAddAccount: _addAccount,
              ),
              ActivityPane(
                transactions: controller.overview!.transactions,
                transfers: controller.overview!.transfers,
                categories: controller.categories,
                accounts: controller.overview!.accounts,
              ),
              BudgetsPane(
                budgets: controller.budgets,
                categories: controller.categories,
                onEdit: _editBudget,
                onRemove: (budget) => _confirmRemoval(
                  'budget',
                  budget.name,
                  () => controller.removeBudget(budget.id),
                ),
              ),
              GoalsPane(
                goals: controller.goals,
                onEdit: _editGoal,
                onRemove: (goal) => _confirmRemoval(
                  'goal',
                  goal.name,
                  () => controller.removeGoal(goal.id),
                ),
              ),
              RecurringPane(
                upcoming: controller.upcoming,
                onRecord: _recordUpcoming,
                onEdit: _editRecurring,
                onStop: (rule) => _confirmRemoval(
                  'recurring rule',
                  rule.title,
                  () => controller.stopRecurring(rule.recurringId),
                ),
              ),
            ],
          ),
        ),
        if (controller.isLoading || _removalPending)
          const Align(
            alignment: Alignment.topCenter,
            child: LinearProgressIndicator(),
          ),
      ],
    );
  }

  void _select(int index) => setState(() => selectedIndex = index);

  Future<void> _confirmRemoval(
    String kind,
    String name,
    Future<bool> Function() remove,
  ) async {
    if (_removalPending) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => DefinitionRemovalDialog(kind: kind, name: name),
    );
    if (confirmed != true || !mounted || _removalPending) return;
    setState(() => _removalPending = true);
    final saved = await remove();
    if (!mounted) return;
    setState(() => _removalPending = false);
    if (!saved) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.controller.errorMessage ??
                'Could not remove $kind. Try again.',
          ),
        ),
      );
    }
  }

  Future<void> _add() async {
    final controller = widget.controller;
    final draft = await showModalBottomSheet<EntryDraft>(
      context: context,
      isScrollControlled: true,
      showDragHandle: false,
      builder: (context) => AddTransactionSheet(
        accounts: controller.overview?.accounts ?? const [],
        reportingCurrencyCode: controller.reportingCurrencyCode,
        categories: controller.categories,
        onSuggestCategory: controller.suggestCategoryFor,
        onAddCategory: (name, iconKey) =>
            controller.addCategory(name: name, iconKey: iconKey),
      ),
    );
    if (draft == null || !mounted) {
      return;
    }
    final saved = switch (draft) {
      TransactionDraft() => await controller.record(
        title: draft.title,
        amount: draft.amount,
        kind: draft.kind,
        accountId: draft.accountId,
        categoryId: draft.categoryId,
        rate: draft.rate,
      ),
      TransferDraft() => await controller.transfer(
        fromAccountId: draft.fromAccountId,
        toAccountId: draft.toAccountId,
        sentAmount: draft.sentAmount,
        receivedAmount: draft.receivedAmount,
        title: draft.title,
        sentRate: draft.sentRate,
        receivedRate: draft.receivedRate,
      ),
    };
    if (!mounted) {
      return;
    }
    if (!saved) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(widget.controller.errorMessage ?? 'Could not save'),
        ),
      );
    }
  }

  Future<void> _addBudget() => _editBudget(null);

  Future<void> _editBudget(BudgetView? existing) async {
    final controller = widget.controller;
    final draft = await showDialog<BudgetDraft>(
      context: context,
      builder: (context) => NewBudgetDialog(
        categories: controller.categories,
        existing: existing,
      ),
    );
    if (draft == null || !mounted) {
      return;
    }
    final saved = await controller.addOrUpdateBudget(
      budgetId: existing?.id,
      name: draft.name,
      categoryId: draft.categoryId,
      limitAmount: draft.limitAmount,
      period: draft.period,
      customPeriodDays: draft.customPeriodDays,
    );
    if (!mounted) {
      return;
    }
    if (!saved) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.controller.errorMessage ?? 'Could not save budget',
          ),
        ),
      );
    }
  }

  void _onDataMenuSelected(_DataMenuAction action) {
    switch (action) {
      case _DataMenuAction.exportCsv:
        _exportCsv();
      case _DataMenuAction.importCsv:
        _importCsv();
      case _DataMenuAction.manageCategories:
        _manageCategories();
      case _DataMenuAction.lockSettings:
        showDialog<void>(
          context: context,
          builder: (context) => const LockSettingsDialog(),
        );
      case _DataMenuAction.household:
        final household = widget.household;
        if (household != null) {
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (context) => HouseholdScreen(controller: household),
            ),
          );
        }
    }
  }

  Future<void> _exportCsv() async {
    final csv = widget.controller.exportTransactionsCsv();
    if (csv == null || !mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => ExportCsvDialog(csv: csv),
    );
  }

  Future<void> _importCsv() async {
    final csvText = await showDialog<String>(
      context: context,
      builder: (context) => const ImportCsvDialog(),
    );
    if (csvText == null || !mounted) {
      return;
    }
    final summary = await widget.controller.importTransactionsCsv(csvText);
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          summary.errors.isEmpty
              ? 'Imported ${summary.imported} transaction(s)'
              : 'Imported ${summary.imported}, ${summary.errors.length} skipped: ${summary.errors.first}',
        ),
      ),
    );
  }

  void _manageCategories() {
    final controller = widget.controller;
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (context) => AnimatedBuilder(
          animation: controller,
          builder: (context, _) => CategoriesScreen(
            categories: controller.categories,
            onCreate: (name, iconKey) =>
                controller.addCategory(name: name, iconKey: iconKey),
            onUpdate: (categoryId, name, iconKey) => controller.updateCategory(
              categoryId: categoryId,
              name: name,
              iconKey: iconKey,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _addGoal() => _editGoal(null);

  Future<void> _editGoal(GoalView? existing) async {
    final controller = widget.controller;
    final draft = await showDialog<GoalDraft>(
      context: context,
      builder: (context) => NewGoalDialog(
        accounts: controller.overview?.accounts ?? const [],
        categories: controller.categories,
        reportingCurrencyCode: controller.reportingCurrencyCode,
        existing: existing,
      ),
    );
    if (draft == null || !mounted) {
      return;
    }
    final saved = await controller.addOrUpdateGoal(
      goalId: existing?.id,
      name: draft.name,
      kind: draft.kind,
      targetAmount: draft.targetAmount,
      linkedAccountId: draft.linkedAccountId,
      categoryId: draft.categoryId,
      deadlineMillis: draft.deadlineMillis,
    );
    if (!mounted) {
      return;
    }
    if (!saved) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.controller.errorMessage ?? 'Could not save goal',
          ),
        ),
      );
    }
  }

  Future<void> _addRecurring() => _editRecurring(null);

  Future<void> _editRecurring(UpcomingView? existing) async {
    final controller = widget.controller;
    final draft = await showDialog<RecurringDraft>(
      context: context,
      builder: (context) => NewRecurringDialog(
        accounts: controller.overview?.accounts ?? const [],
        categories: controller.categories,
        existing: existing,
      ),
    );
    if (draft == null || !mounted) {
      return;
    }
    final saved = await controller.addOrUpdateRecurring(
      recurringId: existing?.recurringId,
      title: draft.title,
      kind: draft.kind,
      amount: draft.amount,
      accountId: draft.accountId,
      categoryId: draft.categoryId,
      frequency: draft.frequency,
      startMillis: draft.startMillis,
    );
    if (!mounted) {
      return;
    }
    if (!saved) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.controller.errorMessage ?? 'Could not save recurring rule',
          ),
        ),
      );
    }
  }

  Future<void> _recordUpcoming(UpcomingView occurrence) async {
    String? rate;
    final account = widget.controller.overview?.accounts
        .where((account) => account.id == occurrence.accountId)
        .firstOrNull;
    final reportingCurrency = widget.controller.reportingCurrencyCode;
    if (account != null && account.currencyCode != reportingCurrency) {
      // The rule carries no rate (it would go stale); ask for today's.
      rate = await showDialog<String>(
        context: context,
        builder: (context) => ExchangeRateDialog(
          sourceCurrencyCode: account.currencyCode,
          reportingCurrencyCode: reportingCurrency,
        ),
      );
      if (rate == null || !mounted) {
        return;
      }
    }
    final saved = await widget.controller.recordUpcoming(
      occurrence,
      rate: rate,
    );
    if (!mounted) {
      return;
    }
    if (!saved) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(widget.controller.errorMessage ?? 'Could not record'),
        ),
      );
    }
  }

  Future<void> _addAccount() async {
    final draft = await showDialog<_AccountDraft>(
      context: context,
      builder: (context) => const _NewAccountDialog(),
    );
    if (draft == null || !mounted) {
      return;
    }
    final saved = await widget.controller.createAccount(
      name: draft.name,
      currencyCode: draft.currencyCode,
    );
    if (!mounted) {
      return;
    }
    if (!saved) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.controller.errorMessage ?? 'Could not add account',
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
    required this.onAddAccount,
    super.key,
  });

  final LedgerOverview overview;
  final List<CategoryView> categories;
  final VoidCallback onAdd;
  final VoidCallback onAddAccount;

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
                  final accounts = _AccountsCard(
                    accounts: overview.accounts,
                    onAddAccount: onAddAccount,
                  );
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
                      (transaction) =>
                          TransactionTile(transaction, categories: categories),
                    ),
            ],
          ),
        ),
      ),
    );
  }
}

class ActivityPane extends StatefulWidget {
  const ActivityPane({
    required this.transactions,
    required this.transfers,
    required this.categories,
    required this.accounts,
    super.key,
  });

  final List<TransactionView> transactions;
  final List<TransferView> transfers;
  final List<CategoryView> categories;
  final List<AccountView> accounts;

  @override
  State<ActivityPane> createState() => _ActivityPaneState();
}

class _ActivityPaneState extends State<ActivityPane> {
  ActivityFilter filter = const ActivityFilter();

  @override
  Widget build(BuildContext context) {
    final filteredTransactions = filter.applyToTransactions(
      widget.transactions,
      widget.categories,
    );
    final filteredTransfers = filter.applyToTransfers(widget.transfers);
    final somethingToShow =
        widget.transactions.isNotEmpty || widget.transfers.isNotEmpty;

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
                if (somethingToShow) ...[
                  _ActivitySearchAndFilters(
                    filter: filter,
                    accounts: widget.accounts,
                    onChanged: (updated) => setState(() => filter = updated),
                  ),
                  const SizedBox(height: 12),
                ],
                if (!somethingToShow)
                  const _ActivityEmpty()
                else if (filteredTransactions.isEmpty &&
                    filteredTransfers.isEmpty)
                  const _NoMatchingActivity()
                else ...[
                  ...filteredTransactions.map(
                    (transaction) => TransactionTile(
                      transaction,
                      categories: widget.categories,
                    ),
                  ),
                  ...filteredTransfers.map(
                    (transfer) =>
                        TransferTile(transfer, accounts: widget.accounts),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ActivitySearchAndFilters extends StatefulWidget {
  const _ActivitySearchAndFilters({
    required this.filter,
    required this.accounts,
    required this.onChanged,
  });

  final ActivityFilter filter;
  final List<AccountView> accounts;
  final ValueChanged<ActivityFilter> onChanged;

  @override
  State<_ActivitySearchAndFilters> createState() =>
      _ActivitySearchAndFiltersState();
}

class _ActivitySearchAndFiltersState extends State<_ActivitySearchAndFilters> {
  late final queryController = TextEditingController(text: widget.filter.query);

  @override
  void dispose() {
    queryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filter = widget.filter;
    final accounts = widget.accounts;
    final onChanged = widget.onChanged;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: queryController,
          decoration: InputDecoration(
            hintText: 'Search title or category',
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: filter.query.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.clear_rounded),
                    onPressed: () {
                      queryController.clear();
                      onChanged(filter.copyWith(query: ''));
                    },
                  ),
          ),
          onChanged: (value) => onChanged(filter.copyWith(query: value)),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final kind in ActivityKindFilter.values)
              ChoiceChip(
                label: Text(_kindLabel(kind)),
                selected: filter.kind == kind,
                onSelected: (_) => onChanged(filter.copyWith(kind: kind)),
              ),
            if (accounts.length > 1)
              DropdownButton<String?>(
                value: filter.accountId,
                hint: const Text('All accounts'),
                underline: const SizedBox.shrink(),
                items: [
                  const DropdownMenuItem(
                    value: null,
                    child: Text('All accounts'),
                  ),
                  for (final account in accounts)
                    DropdownMenuItem(
                      value: account.id,
                      child: Text(account.name),
                    ),
                ],
                onChanged: (value) =>
                    onChanged(filter.copyWith(accountId: () => value)),
              ),
          ],
        ),
      ],
    );
  }

  String _kindLabel(ActivityKindFilter kind) => switch (kind) {
    ActivityKindFilter.all => 'All',
    ActivityKindFilter.expense => 'Expense',
    ActivityKindFilter.income => 'Income',
    ActivityKindFilter.transfer => 'Transfer',
  };
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
  const _AccountsCard({required this.accounts, required this.onAddAccount});

  final List<AccountView> accounts;
  final VoidCallback onAddAccount;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Accounts',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  onPressed: onAddAccount,
                  icon: const Icon(Icons.add_rounded),
                  tooltip: 'Add account',
                ),
              ],
            ),
            for (final account in accounts)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const CircleAvatar(child: Icon(Icons.wallet_outlined)),
                title: Text(account.name),
                subtitle: Text(account.currencyCode),
                trailing: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      account.balanceLabel,
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    if (account.reportingBalanceLabel != null)
                      Text(
                        '≈ ${account.reportingBalanceLabel}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _AccountDraft {
  const _AccountDraft({required this.name, required this.currencyCode});

  final String name;
  final String currencyCode;
}

class _NewAccountDialog extends StatefulWidget {
  const _NewAccountDialog();

  @override
  State<_NewAccountDialog> createState() => _NewAccountDialogState();
}

class _NewAccountDialogState extends State<_NewAccountDialog> {
  static const _currencyCodes = ['USD', 'EUR', 'GBP', 'JPY'];

  final nameController = TextEditingController();
  String currencyCode = _currencyCodes.first;

  @override
  void dispose() {
    nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New account'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: nameController,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: currencyCode,
            decoration: const InputDecoration(labelText: 'Currency'),
            items: [
              for (final code in _currencyCodes)
                DropdownMenuItem(value: code, child: Text(code)),
            ],
            onChanged: (value) =>
                setState(() => currencyCode = value ?? currencyCode),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final name = nameController.text.trim();
            if (name.isEmpty) {
              return;
            }
            Navigator.pop(
              context,
              _AccountDraft(name: name, currencyCode: currencyCode),
            );
          },
          child: const Text('Create'),
        ),
      ],
    );
  }
}

class TransactionTile extends StatelessWidget {
  const TransactionTile(
    this.transaction, {
    this.categories = const [],
    super.key,
  });

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

class TransferTile extends StatelessWidget {
  const TransferTile(this.transfer, {this.accounts = const [], super.key});

  final TransferView transfer;
  final List<AccountView> accounts;

  String _accountName(String id) {
    for (final account in accounts) {
      if (account.id == id) {
        return account.name;
      }
    }
    return id;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: scheme.secondaryContainer,
          child: Icon(
            Icons.swap_horiz_rounded,
            color: scheme.onSecondaryContainer,
          ),
        ),
        title: Text(transfer.title),
        subtitle: Text(
          '${_accountName(transfer.fromAccountId)} → '
          '${_accountName(transfer.toAccountId)}',
        ),
        trailing: Text(
          transfer.sentLabel == transfer.receivedLabel
              ? transfer.sentLabel
              : '${transfer.sentLabel} → ${transfer.receivedLabel}',
          style: Theme.of(context).textTheme.titleSmall,
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

class _NoMatchingActivity extends StatelessWidget {
  const _NoMatchingActivity();

  @override
  Widget build(BuildContext context) {
    return const Card(
      child: Padding(
        padding: EdgeInsets.all(28),
        child: Text('Nothing matches this search or filter.'),
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

enum _DataMenuAction {
  exportCsv,
  importCsv,
  manageCategories,
  lockSettings,
  household,
}
