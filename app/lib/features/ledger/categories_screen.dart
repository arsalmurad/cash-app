import 'package:flutter/material.dart';

import '../../data/rust/api/categories.dart';
import 'category_edit_dialog.dart';
import 'category_presets.dart';

/// Lists every category with a way to rename/re-icon it, and to create a new
/// one. Reachable from `LedgerScreen`'s overflow menu ("Manage categories").
class CategoriesScreen extends StatelessWidget {
  const CategoriesScreen({
    required this.categories,
    required this.onCreate,
    required this.onUpdate,
    super.key,
  });

  final List<CategoryView> categories;
  final Future<CategoryView?> Function(String name, String iconKey) onCreate;
  final Future<bool> Function(String categoryId, String name, String iconKey)
  onUpdate;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Categories')),
      body: categories.isEmpty
          ? const Center(child: Text('No categories yet'))
          : ListView.builder(
              padding: const EdgeInsets.only(bottom: 112),
              itemCount: categories.length,
              itemBuilder: (context, index) {
                final category = categories[index];
                return ListTile(
                  leading: Icon(categoryIcon(category.iconKey)),
                  title: Text(category.name),
                  trailing: IconButton(
                    icon: const Icon(Icons.edit_outlined),
                    tooltip: 'Edit category',
                    onPressed: () => _edit(context, category),
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _create(context),
        icon: const Icon(Icons.add_rounded),
        label: const Text('New category'),
      ),
    );
  }

  Future<void> _create(BuildContext context) async {
    final draft = await showDialog<CategoryDraft>(
      context: context,
      builder: (context) => const CategoryEditDialog(),
    );
    if (draft == null) {
      return;
    }
    await onCreate(draft.name, draft.iconKey);
  }

  Future<void> _edit(BuildContext context, CategoryView category) async {
    final draft = await showDialog<CategoryDraft>(
      context: context,
      builder: (context) => CategoryEditDialog(
        initialName: category.name,
        initialIconKey: category.iconKey,
      ),
    );
    if (draft == null) {
      return;
    }
    final saved = await onUpdate(category.id, draft.name, draft.iconKey);
    if (!saved && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Could not save category')));
    }
  }
}
