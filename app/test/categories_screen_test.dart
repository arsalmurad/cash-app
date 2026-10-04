import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ledger/data/rust/api/categories.dart';
import 'package:private_ledger/features/ledger/categories_screen.dart';
import 'package:private_ledger/theme.dart';

void main() {
  for (final size in [
    const Size(360, 740),
    const Size(840, 600),
    const Size(1280, 900),
  ]) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'last category edit stays clear of Add at $size, $brightness, 2x text',
        (tester) async {
          await tester.binding.setSurfaceSize(size);
          addTearDown(() => tester.binding.setSurfaceSize(null));
          var writes = 0;
          await tester.pumpWidget(
            MaterialApp(
              theme: ledgerTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(2)),
                child: child!,
              ),
              home: CategoriesScreen(
                categories: List.generate(
                  30,
                  (index) => CategoryView(
                    id: 'category-$index',
                    name: 'Category $index',
                    iconKey: 'restaurant',
                  ),
                ),
                onCreate: (_, _) async {
                  writes++;
                  return null;
                },
                onUpdate: (_, _, _) async {
                  writes++;
                  return true;
                },
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.scrollUntilVisible(
            find.text('Category 29'),
            500,
            scrollable: find.byType(Scrollable),
          );
          final scroll = tester.state<ScrollableState>(find.byType(Scrollable));
          scroll.position.jumpTo(scroll.position.maxScrollExtent);
          await tester.pumpAndSettle();
          final lastTile = find.ancestor(
            of: find.text('Category 29'),
            matching: find.byType(ListTile),
          );
          final edit = find.descendant(
            of: lastTile,
            matching: find.byTooltip('Edit category'),
          );
          final floating = find.byType(FloatingActionButton);
          expect(
            tester.getRect(edit).overlaps(tester.getRect(floating)),
            isFalse,
            reason: 'The last edit control must not be covered at the end of normal scrolling',
          );
          expect(edit.hitTestable(), findsOneWidget);
          await tester.tap(edit);
          await tester.pumpAndSettle();
          expect(find.widgetWithText(TextField, 'Category 29'), findsOneWidget);
          await tester.tap(find.text('Cancel'));
          await tester.pumpAndSettle();
          expect(
            writes,
            0,
            reason: 'Opening/cancelling must not change category state',
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

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
    const category = CategoryView(
      id: 'food',
      name: 'Food',
      iconKey: 'restaurant',
    );

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

  testWidgets(
    'editing a category opens the dialog pre-filled and saves the rename',
    (tester) async {
      const category = CategoryView(
        id: 'food',
        name: 'Food',
        iconKey: 'restaurant',
      );
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
    },
  );

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
