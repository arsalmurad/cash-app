import 'package:flutter/material.dart';

import '../../data/rust/api/budgets.dart';
import '../../data/rust/api/categories.dart';
import 'progress_label.dart';

/// Shows every budget's current progress. Progress is computed fresh by the
/// Rust core each time (see `budget_progress`), so this widget is purely
/// presentational.
class BudgetsPane extends StatelessWidget {
  const BudgetsPane({
    required this.budgets,
    required this.categories,
    this.onEdit,
    this.onRemove,
    super.key,
  });

  final List<BudgetView> budgets;
  final List<CategoryView> categories;
  final void Function(BudgetView budget)? onEdit;
  final void Function(BudgetView budget)? onRemove;

  @override
  Widget build(BuildContext context) {
    if (budgets.isEmpty) {
      return const _EmptyBudgets();
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      itemCount: budgets.length,
      itemBuilder: (context, index) => _BudgetCard(
        budget: budgets[index],
        categoryName: _categoryName(budgets[index].categoryId),
        onEdit: onEdit == null ? null : () => onEdit!(budgets[index]),
        onRemove: onRemove == null ? null : () => onRemove!(budgets[index]),
      ),
    );
  }

  String? _categoryName(String? categoryId) {
    if (categoryId == null) {
      return null;
    }
    for (final category in categories) {
      if (category.id == categoryId) {
        return category.name;
      }
    }
    return null;
  }
}

class _BudgetCard extends StatelessWidget {
  const _BudgetCard({
    required this.budget,
    required this.categoryName,
    this.onEdit,
    this.onRemove,
  });

  final BudgetView budget;
  final String? categoryName;
  final VoidCallback? onEdit;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final percent = budget.percentUsed.toInt();
    final overBudget = percent > 100;
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(budget.name, style: theme.textTheme.titleMedium),
                ),
                Text(
                  budget.periodLabel,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (onRemove != null)
                  PopupMenuButton<String>(
                    tooltip: 'budget actions',
                    onSelected: (value) =>
                        value == 'edit' ? onEdit?.call() : onRemove?.call(),
                    itemBuilder: (_) => [
                      if (onEdit != null)
                        const PopupMenuItem(
                          value: 'edit',
                          child: Text('Edit budget'),
                        ),
                      const PopupMenuItem(
                        value: 'remove',
                        child: Text('Remove budget'),
                      ),
                    ],
                  )
                else if (onEdit != null)
                  IconButton(
                    icon: const Icon(Icons.edit_outlined, size: 20),
                    tooltip: 'Edit budget',
                    onPressed: onEdit,
                  ),
              ],
            ),
            Text(
              categoryName ?? 'All categories',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: (percent / 100).clamp(0, 1).toDouble(),
                minHeight: 8,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
                color: overBudget
                    ? theme.colorScheme.error
                    : theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              spacing: 12,
              runSpacing: 8,
              children: [
                Text('${budget.spentLabel} of ${budget.limitLabel}'),
                Text(
                  progressPercentLabel(percent),
                  style: TextStyle(
                    color: overBudget ? theme.colorScheme.error : null,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyBudgets extends StatelessWidget {
  const _EmptyBudgets();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text('No budgets yet. Tap Add to set a spending limit.'),
      ),
    );
  }
}

class BudgetDraft {
  const BudgetDraft({
    required this.name,
    this.categoryId,
    required this.limitAmount,
    required this.period,
    this.customPeriodDays,
  });

  final String name;
  final String? categoryId;
  final String limitAmount;
  final BudgetPeriodKind period;
  final int? customPeriodDays;
}

class NewBudgetDialog extends StatefulWidget {
  const NewBudgetDialog({required this.categories, this.existing, super.key});

  final List<CategoryView> categories;

  /// When set, the dialog starts pre-filled from this budget and behaves as
  /// an edit rather than a create (see [BudgetsPane.onEdit]).
  final BudgetView? existing;

  bool get isEditing => existing != null;

  @override
  State<NewBudgetDialog> createState() => _NewBudgetDialogState();
}

class _NewBudgetDialogState extends State<NewBudgetDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _nameController = TextEditingController(
    text: widget.existing?.name,
  );
  late final _limitController = TextEditingController(
    text: widget.existing == null
        ? null
        : _amountFromLabel(widget.existing!.limitLabel),
  );
  late final _customDaysController = TextEditingController(
    text: _parsedPeriod.$2?.toString() ?? '30',
  );
  late String? _categoryId = widget.existing?.categoryId;
  late BudgetPeriodKind _period = _parsedPeriod.$1;

  /// A limit/spent label is always `"<CODE> <amount>"`; the amount alone is
  /// what the limit field edits (mirrors `_amountFromLabel` in
  /// `ledger_controller.dart`).
  String _amountFromLabel(String label) {
    final spaceIndex = label.indexOf(' ');
    return spaceIndex < 0 ? label : label.substring(spaceIndex + 1);
  }

  /// `BudgetView.periodLabel` is a display string ("This week", "This
  /// month", "This year", "Last N days" — see `period_label` in
  /// `rust/api/src/api/budgets.rs`), not the `BudgetPeriodKind` this dialog
  /// needs to pre-select. It's deterministic in exactly those four shapes,
  /// so it's parsed back rather than adding a bridge field just to round-trip
  /// what the label already encodes.
  (BudgetPeriodKind, int?) get _parsedPeriod {
    final label = widget.existing?.periodLabel;
    if (label == null) {
      return (BudgetPeriodKind.monthly, null);
    }
    switch (label) {
      case 'This week':
        return (BudgetPeriodKind.weekly, null);
      case 'This month':
        return (BudgetPeriodKind.monthly, null);
      case 'This year':
        return (BudgetPeriodKind.yearly, null);
      default:
        final match = RegExp(r'^Last (\d+) days$').firstMatch(label);
        final days = match == null ? null : int.tryParse(match.group(1)!);
        return (BudgetPeriodKind.custom, days ?? 30);
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _limitController.dispose();
    _customDaysController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.isEditing ? 'Edit budget' : 'New budget'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(labelText: 'Name'),
                validator: (value) => (value == null || value.trim().isEmpty)
                    ? 'Enter a name'
                    : null,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                key: const Key('budgetCategoryDropdown'),
                initialValue: _categoryId,
                decoration: const InputDecoration(labelText: 'Category'),
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('All categories'),
                  ),
                  ...widget.categories.map(
                    (category) => DropdownMenuItem<String?>(
                      value: category.id,
                      child: Text(category.name),
                    ),
                  ),
                ],
                onChanged: (value) => setState(() => _categoryId = value),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _limitController,
                decoration: const InputDecoration(labelText: 'Limit amount'),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                validator: (value) => (value == null || value.trim().isEmpty)
                    ? 'Enter a limit'
                    : null,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<BudgetPeriodKind>(
                key: const Key('budgetPeriodDropdown'),
                initialValue: _period,
                decoration: const InputDecoration(labelText: 'Period'),
                items: const [
                  DropdownMenuItem(
                    value: BudgetPeriodKind.weekly,
                    child: Text('Weekly'),
                  ),
                  DropdownMenuItem(
                    value: BudgetPeriodKind.monthly,
                    child: Text('Monthly'),
                  ),
                  DropdownMenuItem(
                    value: BudgetPeriodKind.yearly,
                    child: Text('Yearly'),
                  ),
                  DropdownMenuItem(
                    value: BudgetPeriodKind.custom,
                    child: Text('Custom (rolling days)'),
                  ),
                ],
                onChanged: (value) =>
                    setState(() => _period = value ?? BudgetPeriodKind.monthly),
              ),
              if (_period == BudgetPeriodKind.custom) ...[
                const SizedBox(height: 12),
                TextFormField(
                  controller: _customDaysController,
                  decoration: const InputDecoration(labelText: 'Days'),
                  keyboardType: TextInputType.number,
                  validator: (value) {
                    if (_period != BudgetPeriodKind.custom) {
                      return null;
                    }
                    final days = int.tryParse(value ?? '');
                    return (days == null || days <= 0)
                        ? 'Enter a positive number of days'
                        : null;
                  },
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    Navigator.of(context).pop(
      BudgetDraft(
        name: _nameController.text,
        categoryId: _categoryId,
        limitAmount: _limitController.text.trim(),
        period: _period,
        customPeriodDays: _period == BudgetPeriodKind.custom
            ? int.tryParse(_customDaysController.text.trim())
            : null,
      ),
    );
  }
}
