import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/data/rust/api/categories.dart';
import 'package:private_ledger/features/ledger/categories_screen.dart';

void main() {
  testWidgets('empty state shows no categories', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: CategoriesScreen(
          categories: const [],
          onCreate: (_, _) async => null,
          onUpdate: (_, _, _) async => true,
        ),
      ),
    );

    expect(find.text('No categories yet'), findsOneWidget);
  });

  testWidgets('lists each category by name and icon', (tester) async {
    const category = CategoryView(id: 'food', name: 'Food', iconKey: 'restaurant');

    await tester.pumpWidget(
      MaterialApp(
        home: CategoriesScreen(
          categories: const [category],
          onCreate: (_, _) async => null,
          onUpdate: (_, _, _) async => true,
        ),
      ),
    );

    expect(find.text('Food'), findsOneWidget);
    expect(find.byIcon(Icons.restaurant_outlined), findsOneWidget);
  });

  testWidgets('editing a category opens the dialog pre-filled and saves the rename', (
    tester,
  ) async {
    const category = CategoryView(id: 'food', name: 'Food', iconKey: 'restaurant');
    String? updatedId;
    String? updatedName;
    String? updatedIconKey;

    await tester.pumpWidget(
      MaterialApp(
        home: CategoriesScreen(
          categories: const [category],
          onCreate: (_, _) async => null,
          onUpdate: (categoryId, name, iconKey) async {
            updatedId = categoryId;
            updatedName = name;
            updatedIconKey = iconKey;
            return true;
          },
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();

    expect(find.text('Edit category'), findsOneWidget);
    final nameField = find.widgetWithText(TextField, 'Food');
    expect(nameField, findsOneWidget);

    await tester.enterText(nameField, 'Groceries');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(updatedId, 'food');
    expect(updatedName, 'Groceries');
    expect(updatedIconKey, 'restaurant');
  });

  testWidgets('the New category button creates a category', (tester) async {
    String? createdName;
    String? createdIconKey;

    await tester.pumpWidget(
      MaterialApp(
        home: CategoriesScreen(
          categories: const [],
          onCreate: (name, iconKey) async {
            createdName = name;
            createdIconKey = iconKey;
            return const CategoryView(
              id: 'travel',
              name: 'Travel',
              iconKey: 'flight',
            );
          },
          onUpdate: (_, _, _) async => true,
        ),
      ),
    );

    await tester.tap(find.text('New category'));
    await tester.pumpAndSettle();

    expect(find.text('New category'), findsWidgets);
    await tester.enterText(find.byType(TextField), 'Travel');
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    expect(createdName, 'Travel');
    expect(createdIconKey, isNotNull);
  });
}
