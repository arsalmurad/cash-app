import 'package:flutter/material.dart';

import '../../data/rust/api/categories.dart';
import '../../data/rust/api/ledger.dart';

enum TransactionAction { amount, category, remove, history }

class TransactionCorrectionDraft {
  const TransactionCorrectionDraft({this.amount, this.categoryId});
  final String? amount;
  final String? categoryId;
}

class TransactionCorrectionDialog extends StatefulWidget {
  const TransactionCorrectionDialog({
    required this.transaction,
    required this.action,
    required this.categories,
    super.key,
  });
  final TransactionView transaction;
  final TransactionAction action;
  final List<CategoryView> categories;

  @override
  State<TransactionCorrectionDialog> createState() =>
      _TransactionCorrectionDialogState();
}

class _TransactionCorrectionDialogState
    extends State<TransactionCorrectionDialog> {
  late final TextEditingController amount;
  late String? categoryId;
  String? error;

  @override
  void initState() {
    super.initState();
    amount = TextEditingController(
      text: widget.transaction.amountLabel.split(' ').last,
    );
    categoryId = widget.transaction.categoryId;
  }

  @override
  void dispose() {
    amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final correctingAmount = widget.action == TransactionAction.amount;
    final missing =
        categoryId != null && !widget.categories.any((c) => c.id == categoryId);
    return AlertDialog(
      title: Text(correctingAmount ? 'Correct amount' : 'Change category'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(widget.transaction.title),
              const SizedBox(height: 16),
              if (correctingAmount) ...[
                Text(
                  'Currency: ${widget.transaction.amountLabel.split(' ').first}',
                ),
                const Text(
                  'Uses the original exchange rate. The earlier amount stays in history.',
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: amount,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: 'Amount',
                    errorText: error,
                  ),
                ),
              ] else
                DropdownButtonFormField<String>(
                  initialValue: categoryId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Category'),
                  items: [
                    const DropdownMenuItem<String>(
                      value: null,
                      child: Text('Uncategorized'),
                    ),
                    if (missing)
                      DropdownMenuItem(
                        value: categoryId,
                        child: Text('Unavailable category ($categoryId)'),
                      ),
                    ...widget.categories.map(
                      (c) => DropdownMenuItem(value: c.id, child: Text(c.name)),
                    ),
                  ],
                  onChanged: (value) => setState(() => categoryId = value),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (correctingAmount && amount.text.trim().isEmpty) {
              setState(() => error = 'Enter an amount greater than zero.');
              return;
            }
            if (!correctingAmount && missing) {
              setState(
                () => error = 'Choose an available category or Uncategorized.',
              );
              return;
            }
            Navigator.pop(
              context,
              TransactionCorrectionDraft(
                amount: correctingAmount ? amount.text.trim() : null,
                categoryId: categoryId,
              ),
            );
          },
          child: const Text('Save correction'),
        ),
        if (!correctingAmount && error != null) Text(error!),
      ],
    );
  }
}

class TransactionRemovalDialog extends StatelessWidget {
  const TransactionRemovalDialog({required this.transaction, super.key});
  final TransactionView transaction;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Remove transaction?'),
    content: SingleChildScrollView(
      child: Text(
        '“${transaction.title}” will be excluded from balances, budgets, goals and CSV exports. '
        'Its original entry and corrections stay in Activity history.',
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, false),
        child: const Text('Keep transaction'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, true),
        child: const Text('Remove transaction'),
      ),
    ],
  );
}

class TransactionHistoryDialog extends StatelessWidget {
  const TransactionHistoryDialog({
    required this.transaction,
    required this.history,
    required this.categories,
    super.key,
  });
  final TransactionView transaction;
  final List<TransactionHistoryView> history;
  final List<CategoryView> categories;

  String _category(String? id) {
    if (id == null) return 'Uncategorized';
    for (final category in categories) {
      if (category.id == id) return '${category.name} ($id)';
    }
    return 'Unavailable category ($id)';
  }

  String _time(TransactionHistoryView event) {
    try {
      final date = DateTime.fromMillisecondsSinceEpoch(
        event.physicalMillis.toInt(),
      );
      final local = date.toLocal();
      String two(int value) => value.toString().padLeft(2, '0');
      return '${local.year}-${two(local.month)}-${two(local.day)} '
          '${two(local.hour)}:${two(local.minute)} (device time)';
    } on ArgumentError {
      return 'Date outside the supported display range';
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Transaction history'),
    content: SizedBox(
      width: 440,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(transaction.title),
            const Text(
              'Earlier entries are kept. Category names below are their current names.',
            ),
            ...history.map(
              (event) => Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      event.action,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    if (event.amountLabel != null) Text(event.amountLabel!),
                    if (event.reportingAmountLabel != null)
                      Text('Reporting: ${event.reportingAmountLabel}'),
                    if (event.action == 'Recorded' ||
                        event.action == 'Category changed')
                      Text(_category(event.categoryId)),
                    Text(_time(event)),
                    SelectableText(
                      'Event: ${event.eventId}\nDevice: ${event.actorId}\n'
                      'Ledger time: ${event.physicalMillis}:${event.logical}',
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Close'),
      ),
    ],
  );
}
