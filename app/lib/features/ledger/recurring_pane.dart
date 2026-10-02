import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show PlatformInt64, PlatformInt64Util;

import '../../data/rust/api/ledger.dart';
import '../../data/rust/api/recurring.dart';

/// Shows every recurring rule's next occurrence, soonest first. Occurrences
/// are computed fresh by the Rust core each time (see
/// `upcoming_occurrences`), so this widget is purely presentational.
class RecurringPane extends StatelessWidget {
  const RecurringPane({
    required this.upcoming,
    required this.onRecord,
    this.onEdit,
    this.onStop,
    super.key,
  });

  final List<UpcomingView> upcoming;
  final Future<void> Function(UpcomingView occurrence) onRecord;
  final void Function(UpcomingView occurrence)? onEdit;
  final void Function(UpcomingView occurrence)? onStop;

  @override
  Widget build(BuildContext context) {
    if (upcoming.isEmpty) {
      return const _EmptyUpcoming();
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      itemCount: upcoming.length,
      itemBuilder: (context, index) => _UpcomingCard(
        occurrence: upcoming[index],
        onRecord: () => onRecord(upcoming[index]),
        onEdit: onEdit == null ? null : () => onEdit!(upcoming[index]),
        onStop: onStop == null ? null : () => onStop!(upcoming[index]),
      ),
    );
  }
}

class _UpcomingCard extends StatelessWidget {
  const _UpcomingCard({
    required this.occurrence,
    required this.onRecord,
    this.onEdit,
    this.onStop,
  });

  final UpcomingView occurrence;
  final VoidCallback onRecord;
  final VoidCallback? onEdit;
  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final date = DateTime.fromMillisecondsSinceEpoch(
      occurrence.occurrenceMillis.toInt(),
    );
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Row(
          children: [
            Icon(
              occurrence.isExpense
                  ? Icons.arrow_upward_rounded
                  : Icons.arrow_downward_rounded,
              color: occurrence.isExpense
                  ? theme.colorScheme.error
                  : theme.colorScheme.primary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(occurrence.title, style: theme.textTheme.titleMedium),
                  Text(
                    'Due ${_formatDate(date)}',
                    style: TextStyle(
                      color: occurrence.isOverdue
                          ? theme.colorScheme.error
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (onStop != null)
              PopupMenuButton<String>(
                tooltip: 'recurring rule actions',
                onSelected: (value) =>
                    value == 'edit' ? onEdit?.call() : onStop?.call(),
                itemBuilder: (_) => [
                  if (onEdit != null)
                    const PopupMenuItem(
                      value: 'edit',
                      child: Text('Edit recurring rule'),
                    ),
                  const PopupMenuItem(
                    value: 'stop',
                    child: Text('Stop recurring rule'),
                  ),
                ],
              )
            else if (onEdit != null)
              IconButton(
                icon: const Icon(Icons.edit_outlined, size: 20),
                tooltip: 'Edit recurring rule',
                onPressed: onEdit,
              ),
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(occurrence.amountLabel),
                TextButton(
                  onPressed: occurrence.isOverdue ? onRecord : null,
                  child: const Text('Record'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
}

class _EmptyUpcoming extends StatelessWidget {
  const _EmptyUpcoming();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text('No upcoming bills or income. Tap Add to set one up.'),
      ),
    );
  }
}

class RecurringDraft {
  const RecurringDraft({
    required this.title,
    required this.kind,
    required this.amount,
    required this.accountId,
    this.categoryId,
    required this.frequency,
    required this.startMillis,
  });

  final String title;
  final RecurringKind kind;
  final String amount;
  final String accountId;
  final String? categoryId;
  final RecurringFrequency frequency;
  final PlatformInt64 startMillis;
}

class NewRecurringDialog extends StatefulWidget {
  const NewRecurringDialog({required this.accounts, this.existing, super.key});

  final List<AccountView> accounts;

  /// When set, the dialog starts pre-filled from this rule's next upcoming
  /// occurrence and behaves as an edit rather than a create (see
  /// [RecurringPane.onEdit]). `existing.occurrenceMillis` doubles as the
  /// rule's start date here: it equals the rule's real `start_millis` when
  /// no occurrence has been recorded yet (the common edit case, since a
  /// rule's next occurrence only advances once one has been recorded), and
  /// is otherwise inert — `upsert_recurring`'s `start_millis` only anchors a
  /// rule that has no recorded history yet (see `docs/DECISIONS.md`).
  final UpcomingView? existing;

  bool get isEditing => existing != null;

  @override
  State<NewRecurringDialog> createState() => _NewRecurringDialogState();
}

class _NewRecurringDialogState extends State<NewRecurringDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _titleController = TextEditingController(
    text: widget.existing?.title,
  );
  late final _amountController = TextEditingController(
    text: widget.existing == null
        ? null
        : _amountFromLabel(widget.existing!.amountLabel),
  );
  late RecurringKind _kind = widget.existing == null
      ? RecurringKind.expense
      : (widget.existing!.isExpense
            ? RecurringKind.expense
            : RecurringKind.income);
  late RecurringFrequency _frequency =
      widget.existing?.frequency ?? RecurringFrequency.monthly;
  String? _accountId;
  late DateTime _startDate = widget.existing == null
      ? DateTime.now()
      : DateTime.fromMillisecondsSinceEpoch(
          widget.existing!.occurrenceMillis.toInt(),
        );

  /// An amount label is always `"<CODE> <amount>"`; the amount alone is what
  /// this field edits (mirrors the same helper in `ledger_controller.dart`).
  String _amountFromLabel(String label) {
    final spaceIndex = label.indexOf(' ');
    return spaceIndex < 0 ? label : label.substring(spaceIndex + 1);
  }

  @override
  void initState() {
    super.initState();
    _accountId =
        widget.existing?.accountId ??
        (widget.accounts.isNotEmpty ? widget.accounts.first.id : null);
  }

  @override
  void dispose() {
    _titleController.dispose();
    _amountController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.isEditing ? 'Edit recurring rule' : 'New recurring rule',
      ),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _titleController,
                decoration: const InputDecoration(labelText: 'Title'),
                validator: (value) => (value == null || value.trim().isEmpty)
                    ? 'Enter a title'
                    : null,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<RecurringKind>(
                key: const Key('recurringKindDropdown'),
                initialValue: _kind,
                decoration: const InputDecoration(labelText: 'Kind'),
                items: const [
                  DropdownMenuItem(
                    value: RecurringKind.expense,
                    child: Text('Expense'),
                  ),
                  DropdownMenuItem(
                    value: RecurringKind.income,
                    child: Text('Income'),
                  ),
                ],
                onChanged: (value) =>
                    setState(() => _kind = value ?? RecurringKind.expense),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _amountController,
                decoration: const InputDecoration(labelText: 'Amount'),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                validator: (value) => (value == null || value.trim().isEmpty)
                    ? 'Enter an amount'
                    : null,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: const Key('recurringAccountDropdown'),
                initialValue: _accountId,
                decoration: const InputDecoration(labelText: 'Account'),
                items: [
                  for (final account in widget.accounts)
                    DropdownMenuItem(
                      value: account.id,
                      child: Text(account.name),
                    ),
                ],
                onChanged: (value) => setState(() => _accountId = value),
                validator: (value) =>
                    value == null ? 'Choose an account' : null,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<RecurringFrequency>(
                key: const Key('recurringFrequencyDropdown'),
                initialValue: _frequency,
                decoration: const InputDecoration(labelText: 'Frequency'),
                items: const [
                  DropdownMenuItem(
                    value: RecurringFrequency.daily,
                    child: Text('Daily'),
                  ),
                  DropdownMenuItem(
                    value: RecurringFrequency.weekly,
                    child: Text('Weekly'),
                  ),
                  DropdownMenuItem(
                    value: RecurringFrequency.monthly,
                    child: Text('Monthly'),
                  ),
                  DropdownMenuItem(
                    value: RecurringFrequency.yearly,
                    child: Text('Yearly'),
                  ),
                ],
                onChanged: (value) => setState(
                  () => _frequency = value ?? RecurringFrequency.monthly,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Starts ${_startDate.year}-${_startDate.month.toString().padLeft(2, '0')}-${_startDate.day.toString().padLeft(2, '0')}',
                  ),
                  TextButton(
                    onPressed: _pickStartDate,
                    child: const Text('Change'),
                  ),
                ],
              ),
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

  Future<void> _pickStartDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _startDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() => _startDate = picked);
    }
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    Navigator.of(context).pop(
      RecurringDraft(
        title: _titleController.text,
        kind: _kind,
        amount: _amountController.text.trim(),
        accountId: _accountId!,
        // This dialog has no category picker of its own; carry an edited
        // rule's existing category through unchanged rather than dropping it
        // (a new rule simply has none).
        categoryId: widget.existing?.categoryId,
        frequency: _frequency,
        startMillis: PlatformInt64Util.from(_startDate.millisecondsSinceEpoch),
      ),
    );
  }
}
