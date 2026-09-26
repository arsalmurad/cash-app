import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/rust/api/categories.dart';
import '../../data/rust/api/ledger.dart';
import 'category_presets.dart';

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
  const AddTransactionSheet({
    required this.categories,
    required this.onSuggestCategory,
    required this.onAddCategory,
    super.key,
  });

  final List<CategoryView> categories;
  final Future<String?> Function(String title) onSuggestCategory;
  final Future<CategoryView?> Function(String name, String iconKey)
  onAddCategory;

  @override
  State<AddTransactionSheet> createState() => _AddTransactionSheetState();
}

class _AddTransactionSheetState extends State<AddTransactionSheet> {
  final formKey = GlobalKey<FormState>();
  final titleController = TextEditingController();
  final amountController = TextEditingController();
  EntryKind kind = EntryKind.expense;
  String? categoryId;
  bool categoryManuallyChosen = false;
  Timer? suggestionDebounce;
  late List<CategoryView> categories = widget.categories;

  @override
  void initState() {
    super.initState();
    if (categories.isNotEmpty) {
      categoryId = categories.first.id;
    }
    titleController.addListener(_onTitleChanged);
  }

  @override
  void dispose() {
    suggestionDebounce?.cancel();
    titleController.removeListener(_onTitleChanged);
    titleController.dispose();
    amountController.dispose();
    super.dispose();
  }

  void _onTitleChanged() {
    // "Custom titles that auto-assign on repeat": once the user has picked a
    // category themselves, stop overriding their choice.
    if (categoryManuallyChosen) {
      return;
    }
    suggestionDebounce?.cancel();
    final title = titleController.text;
    suggestionDebounce = Timer(const Duration(milliseconds: 400), () async {
      final suggested = await widget.onSuggestCategory(title);
      if (!mounted || suggested == null || categoryManuallyChosen) {
        return;
      }
      if (categories.any((category) => category.id == suggested)) {
        setState(() => categoryId = suggested);
      }
    });
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
                initialValue: categoryId,
                decoration: const InputDecoration(labelText: 'Category'),
                items: [
                  for (final category in categories)
                    DropdownMenuItem(
                      value: category.id,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(categoryIcon(category.iconKey), size: 18),
                          const SizedBox(width: 8),
                          Text(category.name),
                        ],
                      ),
                    ),
                  const DropdownMenuItem(
                    value: _addCategoryValue,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.add_rounded, size: 18),
                        SizedBox(width: 8),
                        Text('New category'),
                      ],
                    ),
                  ),
                ],
                onChanged: (value) async {
                  if (value == _addCategoryValue) {
                    await _promptNewCategory();
                    return;
                  }
                  setState(() {
                    categoryId = value;
                    categoryManuallyChosen = true;
                  });
                },
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

  static const _addCategoryValue = '__add_category__';

  Future<void> _promptNewCategory() async {
    final draft = await showDialog<CategoryDraft>(
      context: context,
      builder: (context) => const _NewCategoryDialog(),
    );
    if (draft == null || !mounted) {
      return;
    }
    final created = await widget.onAddCategory(draft.name, draft.iconKey);
    if (!mounted || created == null) {
      return;
    }
    setState(() {
      categories = [...categories, created];
      categoryId = created.id;
      categoryManuallyChosen = true;
    });
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
        categoryId: categoryId,
      ),
    );
  }
}

class CategoryDraft {
  const CategoryDraft({required this.name, required this.iconKey});

  final String name;
  final String iconKey;
}

class _NewCategoryDialog extends StatefulWidget {
  const _NewCategoryDialog();

  @override
  State<_NewCategoryDialog> createState() => _NewCategoryDialogState();
}

class _NewCategoryDialogState extends State<_NewCategoryDialog> {
  final nameController = TextEditingController();
  String iconKey = availableCategoryIconKeys.first;

  @override
  void dispose() {
    nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New category'),
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
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final key in availableCategoryIconKeys)
                ChoiceChip(
                  label: Icon(categoryIcon(key), size: 20),
                  selected: iconKey == key,
                  onSelected: (_) => setState(() => iconKey = key),
                ),
            ],
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
            Navigator.pop(context, CategoryDraft(name: name, iconKey: iconKey));
          },
          child: const Text('Create'),
        ),
      ],
    );
  }
}
