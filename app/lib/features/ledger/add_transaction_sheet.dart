import 'package:flutter/material.dart';

import '../../data/rust/api/ledger.dart';

class TransactionDraft {
  const TransactionDraft({
    required this.title,
    required this.amount,
    required this.kind,
    this.categoryId,
  });

  final String title;
  final String amount;
  final EntryKind kind;
  final String? categoryId;
}

class AddTransactionSheet extends StatefulWidget {
  const AddTransactionSheet({super.key});

  @override
  State<AddTransactionSheet> createState() => _AddTransactionSheetState();
}

class _AddTransactionSheetState extends State<AddTransactionSheet> {
  final formKey = GlobalKey<FormState>();
  final titleController = TextEditingController();
  final amountController = TextEditingController();
  EntryKind kind = EntryKind.expense;
  String category = 'Everyday';

  @override
  void dispose() {
    titleController.dispose();
    amountController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(24, 16, 24, 24 + bottomInset),
        child: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'Add transaction',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 20),
              SegmentedButton<EntryKind>(
                segments: const [
                  ButtonSegment(
                    value: EntryKind.expense,
                    icon: Icon(Icons.arrow_upward_rounded),
                    label: Text('Expense'),
                  ),
                  ButtonSegment(
                    value: EntryKind.income,
                    icon: Icon(Icons.arrow_downward_rounded),
                    label: Text('Income'),
                  ),
                ],
                selected: {kind},
                onSelectionChanged: (selection) {
                  setState(() => kind = selection.first);
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: titleController,
                autofocus: true,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Title'),
                validator: (value) => value == null || value.trim().isEmpty
                    ? 'Enter a title'
                    : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: amountController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'Amount',
                  prefixText: 'USD ',
                  hintText: '0.00',
                ),
                validator: (value) => value == null || value.trim().isEmpty
                    ? 'Enter an amount'
                    : null,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: category,
                decoration: const InputDecoration(labelText: 'Category'),
                items: const [
                  DropdownMenuItem(value: 'Everyday', child: Text('Everyday')),
                  DropdownMenuItem(value: 'Food', child: Text('Food')),
                  DropdownMenuItem(
                    value: 'Transport',
                    child: Text('Transport'),
                  ),
                  DropdownMenuItem(value: 'Home', child: Text('Home')),
                  DropdownMenuItem(value: 'Income', child: Text('Income')),
                ],
                onChanged: (value) => category = value ?? 'Everyday',
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _submit,
                icon: const Icon(Icons.check_rounded),
                label: const Text('Add transaction'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _submit() {
    if (!formKey.currentState!.validate()) {
      return;
    }
    Navigator.pop(
      context,
      TransactionDraft(
        title: titleController.text,
        amount: amountController.text.trim(),
        kind: kind,
        categoryId: category,
      ),
    );
  }
}
