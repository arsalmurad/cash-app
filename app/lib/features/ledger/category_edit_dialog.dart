import 'package:flutter/material.dart';

import 'category_presets.dart';

/// The name and icon for a category to create or rename.
class CategoryDraft {
  const CategoryDraft({required this.name, required this.iconKey});

  final String name;
  final String iconKey;
}

/// Collects a category's name and icon, for either creating a new category
/// or renaming/re-iconing an existing one. Passing [initialName]/[initialIconKey]
/// switches the dialog into edit mode (title and button text change to match).
class CategoryEditDialog extends StatefulWidget {
  const CategoryEditDialog({this.initialName, this.initialIconKey, super.key});

  final String? initialName;
  final String? initialIconKey;

  bool get isEditing => initialName != null;

  @override
  State<CategoryEditDialog> createState() => _CategoryEditDialogState();
}

class _CategoryEditDialogState extends State<CategoryEditDialog> {
  late final nameController = TextEditingController(text: widget.initialName);
  late String iconKey = widget.initialIconKey ?? availableCategoryIconKeys.first;

  @override
  void dispose() {
    nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.isEditing ? 'Edit category' : 'New category'),
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
          child: Text(widget.isEditing ? 'Save' : 'Create'),
        ),
      ],
    );
  }
}
